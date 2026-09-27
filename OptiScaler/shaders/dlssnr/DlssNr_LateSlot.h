#pragma once
// ============================================================================
// DlssNr_LateSlot.h - the finished-picture late slot lifecycle (pure, testable).
//
// WHAT THIS IS
//   The state machine of DlssNr_Dx12::State::LateContext::Slot: the monotonic
//   fence watermark (ready/done), the presentation-eligibility flag (pending),
//   the recording-ownership flag (owned), the promised/pinned flags, the
//   command-list identity rule, and the pure decisions that read them. No D3D12,
//   no GPU resource, no clock, no wait, so the contract is unit-testable without
//   a device (tests/nr_late_slot_pool_smoke.cpp).
//
// RECORDING OWNERSHIP AND THE WATERMARK
//   A slot holds GPU resources (depth/motion/residual/cleanScene) that the game's
//   producer command list references through recorded CopyResource calls. Arming
//   a recording therefore takes *ownership* of the slot: `owned = true` until the
//   recording is resolved by one of exactly two transitions:
//     - promise then enqueue: the ExecuteCommandLists hook records a token before
//       running the producer list (owned stays true, nothing is submitted) and only
//       the post-execute pass consumes that token - submitted = true, owned = false,
//       done = the token's captured value. Until then the capture is neither
//       composable nor reusable; or
//     - discarded: the game successfully Reset the recorded list, so the copies
//       can never execute and no signal was ever owed
//       (owned = false, pending = false, done untouched).
//   `ready` is allocated monotonically (ready = max(ready, done) + 1), so no arm
//   ever hands out a watermark value that was already signalled; `done` only
//   moves when a signal is consumed (or when the composition signals a fresh
//   value), so no release has to decrement it and no queued value is re-issued.
//
//   Presentation invalidation is not a resolution. State::CloseFinishedCaptures
//   (including XeFGCloseCaptures at a generation reset) and LateContext::Cancel
//   only decide that the capture is no longer a presentation candidate: the game
//   command list that recorded into the slot can still execute afterwards.
//   `pending` may be cleared; `owned`, `done` and `ready` are read-only there.
//
//   A recording that can neither be promised nor discarded - an abandoned list,
//   or a queue signal that failed - is pinned: the slot is never reused and the
//   condition is logged. Unknown abandonment is pinned, never released.
//
// INVARIANTS (asserted by tests/nr_late_slot_pool_smoke.cpp)
//   L1 arm      ArmLateSlot() allocates a strictly larger watermark, marks the
//               slot owned and pending, and does not promise anything.
//   L2 identity SameRecordedCommandIdentity() matches the recorded de-proxied
//               object against the normalized incoming object; Arm, promise and
//               discard all normalize the same way.
//   L3 fence    LateFenceReached() is the only completion evidence; a removed
//               device (UINT64_MAX) is never completion.
//   L4 reuse    LateSlotReusable() == not pending AND not owned AND not pinned AND not
//               promisePending AND (no fence OR the fence reached the watermark).
//   L5 select   ClearLateSlotSelection() changes presentation eligibility only.
//   L6 resolve  RecordLateSlotPromise()/EnqueueLateSlotPromise() are the only way a
//               submitted recording becomes reusable, DiscardLateSlot() only resolves
//               an unpromised one, and the per-call LatePromiseEntry is what binds a
//               post-execute resolution to the call that promised it.
// ============================================================================
#include <cstdint>
#include <vector>

namespace DlssNr
{
struct LateSlotBook
{
    uint64_t ready = 0, done = 0;
    bool pending = false, submitted = false, owned = false, pinned = false;
    // A pre-execute promise only records its intent here (with the token's value); the
    // submission transaction stays unresolved until EnqueueLateSlotPromise() consumes it.
    bool promisePending = false;
};

// Arm a new recording on the slot: allocate a watermark strictly above both the
// last allocation and the last promise, take ownership, mark it a presentation
// candidate, and promise nothing yet (done moves only when the signal is owed).
inline void ArmLateSlot(uint64_t& ready, uint64_t& done, bool& pending, bool& submitted, bool& owned)
{
    ready = (ready > done ? ready : done) + 1;
    owned = true;
    pending = true;
    submitted = false;
}

// The pre-execute promise: the hook is about to run this producer list, so the
// queue will owe a signal for `ready`. It records only that intent - the slot is
// still owned and NOT enqueued, so no consumer, composition or reuse may treat it
// as submitted yet (the submission transaction is unresolved until the post-execute
// pass binds the value).
inline void RecordLateSlotPromise(uint64_t ready, uint64_t& promisedValue, bool& promisePending)
{
    promisedValue = ready;
    promisePending = true;
}

// The post-execute resolution: the real ExecuteCommandLists returned, so the
// promise becomes a submission. It consumes the token's value, never the slot's
// mutable `ready` (which a composition could have advanced meanwhile), and clears
// ownership so the fence at `promisedValue` is what gates reuse.
inline void EnqueueLateSlotPromise(uint64_t promisedValue, uint64_t& done, bool& submitted, bool& owned,
                                   bool& promisePending)
{
    promisePending = false;
    submitted = true;
    owned = false;
    done = promisedValue;
}

// A capture is only usable once its submission transaction is resolved: a promise
// is not an enqueue, and composition/facts queries must not treat it as one.
inline bool LateCaptureEnqueued(bool submitted, bool promisePending) { return submitted && !promisePending; }

// Every consumer of a capture (facts query, composition, the DX11 precheck) uses this one
// predicate, so an unresolved promise can never be selected.
inline bool LateCaptureSelectable(bool pending, bool pinned, bool submitted, bool promisePending)
{
    return pending && !pinned && LateCaptureEnqueued(submitted, promisePending);
}

// The finished picture's capture IDENTITY: the newest slot matching the picture. Serial
// order alone decides which frame is current - resolution state must not influence it, or
// an older enqueued capture would be substituted for a newer unresolved one and the wrong
// frame's guides would be composed into the new picture. Selectability is read from the
// chosen candidate only, after it is chosen.
struct LateSelection
{
    uint64_t serial = 0;
    bool have = false;
    bool selectable = false;

    // Fold one matching slot; returns true when it became the new candidate.
    bool Consider(uint64_t candidateSerial, bool candidateSelectable)
    {
        if (have && candidateSerial <= serial)
            return false;
        serial = candidateSerial;
        have = true;
        selectable = candidateSelectable;
        return true;
    }

    // The capture this picture may use: a candidate exists AND it is selectable. An
    // unusable candidate means refuse - never fall back to an older matching capture.
    bool Usable() const { return have && selectable; }
};

// The composition decision, shared with State::ApplyFinishedColor: a candidate that exists
// but is unusable REFUSES the frame (a pinned or unresolved newer capture is a capture, not
// the absence of one), and the held edit may only bridge a frame where no capture matches
// the picture at all.
inline bool LateCompositionRefuses(const LateSelection& selection) { return selection.have && !selection.Usable(); }
inline bool LateCompositionMayUseHeld(const LateSelection& selection) { return !selection.have; }

// One promise produced by the pre-execute pass for one specific ExecuteCommandLists call.
// It is the only thing the post-execute pass may resolve: matching merely on a queue lets
// an unrelated list submitted on the same queue consume another list's promise.
struct LatePromiseEntry
{
    const void* owner = nullptr;
    unsigned slot = 0;
    uint64_t serial = 0;
    uint64_t token = 0;             // the promised watermark value
    const void* queue = nullptr;    // normalized queue identity of this call
    const void* producer = nullptr; // normalized producer list identity
};

// The per-call batch: built before the real ExecuteCommandLists and consumed by the
// post-execute pass of the same call, on the same thread. Nothing global, so calls
// interleaved on different threads can never resolve each other's promises.
using LatePromiseBatch = std::vector<LatePromiseEntry>;

// The post-execute pass resolves a slot only through this call's entry for that exact
// recording: same owner, slot and serial, the same unresolved token, the same normalized
// queue and the same producer list.
inline bool LatePromiseEntryMatches(const LatePromiseEntry& entry, const void* owner, unsigned slot,
                                   uint64_t serial, bool promisePending, uint64_t promisedValue,
                                   const void* normalizedQueue, const void* producer)
{
    return entry.owner == owner && entry.slot == slot && entry.serial == serial && promisePending &&
           entry.token == promisedValue && entry.queue == normalizedQueue && entry.producer == producer;
}

// A successful Reset of the recorded producer list: the copies can never execute
// and no signal was owed, so ownership is resolved without touching the
// watermark (the arm never advanced `done`).
inline void DiscardLateSlot(bool& pending, bool& owned)
{
    owned = false;
    pending = false;
}

// Presentation invalidation: the capture stops being a finished-picture
// candidate. Ownership and the watermark are deliberately read-only here.
inline void ClearLateSlotSelection(bool& pending) { pending = false; }

// The de-proxied identity of a command list or queue. `deProxied` is what the
// caller obtained from Util::CheckForRealObject, or nullptr when the object is
// already real.
inline const void* NormalizedCommandIdentity(const void* object, const void* deProxied)
{
    return deProxied != nullptr ? deProxied : object;
}

// Whether an incoming command list is the recording a slot armed. Arm records
// the normalized identity, so the promise and the discard only have to normalize
// their own argument the same way - never compare the raw hook pointer against it.
inline bool SameRecordedCommandIdentity(const void* recorded, const void* object, const void* deProxied)
{
    return recorded != nullptr && recorded == NormalizedCommandIdentity(object, deProxied);
}

// The slot's fence is the only completion evidence. A removed device reports
// UINT64_MAX and is never completion.
inline bool LateFenceReached(uint64_t done, uint64_t completed)
{
    return completed != UINT64_MAX && completed >= done;
}

// Acquire's slot predicate. A slot is reusable only when it is neither a
// presentation candidate nor owned by an unresolved recording nor pinned, and -
// when it has a fence - the fence has reached the promised watermark. A slot
// without a fence promised no GPU signal, so only its flags gate it.
inline bool LateSlotReusable(bool pending, bool owned, bool pinned, bool promisePending, bool hasFence,
                            uint64_t done, uint64_t completed)
{
    return !pending && !owned && !pinned && !promisePending &&
           (!hasFence || LateFenceReached(done, completed));
}
} // namespace DlssNr
