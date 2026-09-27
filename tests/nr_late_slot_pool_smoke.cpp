// ============================================================================
// nr_late_slot_pool_smoke.cpp - finished-picture late slot ownership + submission.
//
// LIVE EVIDENCE
//   .omo/evidence/nr-xefg-live-20260926/capture-20260926-1255-run-end-pid87148
//   OptiScaler.log:1879 - the only late-context status line of the whole 60 MB
//   log, after the fifth NR evaluation, then 11835 no_current_capture skips and
//   0 NR_XEFG_APPLY: four captures armed before XeFG activated stayed owned with
//   nothing to consume them.
//
// WHAT THIS MODELS
//   The production state machine (shaders/dlssnr/DlssNr_LateSlot.h) as a four-slot
//   pool with the production call sites:
//     - Arm (DlssNr_Dx12_Late.cpp);
//     - Promise (ResTrack_dx12.cpp hkNrExecuteCommandLists BEFORE the real
//       ExecuteCommandLists -> State::FinishedPicturePromised): records a token only,
//       the slot stays owned and NOT enqueued;
//     - Enqueue (the post-execute pass -> State::FinishedPictureSubmitted): consumes the
//       token's value and queues the signal, on the promised queue;
//     - consumer predicates: LateCaptureEnqueued (facts query + composition selection)
//       and LateSlotReusable (Acquire);
//     - Discard (FinishedPictureResetCommandList), ClearLateSlotSelection
//       (CloseFinishedCaptures / Cancel), Pin (compose/queue failure);
//     - the consumer publication policy (dlssnr/DlssNr_FinishedConsumer.h).
//   Fence completion is exactly the value the test writes, never elapsed time.
//
// WHAT IS PINNED
//   submission transaction (R1): promise_is_not_an_enqueue_for_the_consumer_or_reuse,
//     competing_presentation_between_promise_and_execute_is_refused,
//     post_execute_resolution_uses_the_promised_value
//   ownership: four_unresolved_arms_recover_only_through_a_proven_event,
//     cancel_before_submit_does_not_release,
//     delayed_submission_after_close_promises_and_gates_reuse,
//     unsubmitted_discard_releases_the_slot, reset_of_an_executed_list_is_not_a_discard
//   watermark: queued_signal_gates_reuse_before_completion,
//     compose_close_failure_pins_without_rollback, compose_signal_allocation_is_monotonic
//   consumer lifecycle (R2/R3): active_release_after_teardown_restores_generic,
//     reentrant_release_publishes_nothing, non_owner_release_leaves_the_owner_alone,
//     paused_activation_does_not_admit_captures, capture_admission_predicate_follows_the_consumer
//   stale-frame identity (H1): newest_unresolved_capture_is_not_replaced_by_an_older_ready_one
// ============================================================================
#include "../OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h"
#include "../OptiScaler/dlssnr/DlssNr_FinishedConsumer.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace
{
constexpr size_t kSlots = 4; // LateContext::slots capacity (DlssNr_Dx12_State.h)

int checks = 0;

void Check(bool condition, const std::string& what)
{
    ++checks;
    if (!condition)
        throw std::runtime_error(what);
}

struct Pool
{
    struct Slot
    {
        DlssNr::LateSlotBook book;
        const void* producer = nullptr;
        const void* promisedQueue = nullptr; // the queue the token was recorded for
        uint64_t promisedValue = 0;
        uint64_t serial = 0;                 // LateContext serial; identity for selection
        bool hasFence = false;
        bool extentValid = false;
        uint64_t queued = 0;    // highest fence value NR queued
        uint64_t completed = 0; // value the fence has reached
    };
    std::array<Slot, kSlots> slots;
    uint64_t serialCounter = 0;

    size_t PendingCount() const
    {
        size_t count = 0;
        for (const auto& slot : slots)
            if (slot.book.pending)
                ++count;
        return count;
    }

    bool Reusable(size_t index) const
    {
        const auto& slot = slots[index];
        return DlssNr::LateSlotReusable(slot.book.pending, slot.book.owned, slot.book.pinned,
                                        slot.book.promisePending, slot.hasFence, slot.book.done, slot.completed);
    }

    // The consumer predicate: production uses LateCaptureEnqueued for both the facts
    // query (PendingFinishedCapture) and the composition selection (ApplyFinishedColor).
    bool Composable(size_t index) const
    {
        const auto& slot = slots[index];
        return DlssNr::LateCaptureSelectable(slot.book.pending, slot.book.pinned, slot.book.submitted,
                                             slot.book.promisePending);
    }

    int Acquire() const
    {
        for (size_t i = 0; i < slots.size(); ++i)
            if (Reusable(i))
                return (int) i;
        return -1;
    }

    int Arm(const void* object, const void* deProxied)
    {
        const int index = Acquire();
        if (index < 0)
            return -1;
        auto& slot = slots[(size_t) index];
        slot.producer = DlssNr::NormalizedCommandIdentity(object, deProxied);
        slot.serial = ++serialCounter;
        slot.hasFence = true;
        slot.extentValid = true;
        slot.promisedQueue = nullptr;
        slot.promisedValue = 0;
        DlssNr::ArmLateSlot(slot.book.ready, slot.book.done, slot.book.pending, slot.book.submitted,
                            slot.book.owned);
        return index;
    }

    // Pre-execute promise: a token only.
    bool Promise(int index, const void* object, const void* deProxied, const void* queue)
    {
        auto& slot = slots[(size_t) index];
        if (!slot.book.owned || slot.book.submitted || slot.book.promisePending ||
            !DlssNr::SameRecordedCommandIdentity(slot.producer, object, deProxied))
            return false;
        DlssNr::RecordLateSlotPromise(slot.book.ready, slot.promisedValue, slot.book.promisePending);
        slot.promisedQueue = queue;
#if defined(NR_LATE_SLOT_SEED_PREV)
        // SEED (pre-review semantics): the promise resolved the submission immediately, so a
        // consumer could compose a producer that had not executed yet. Must break a case.
        DlssNr::EnqueueLateSlotPromise(slot.promisedValue, slot.book.done, slot.book.submitted, slot.book.owned,
                                       slot.book.promisePending);
        slot.queued = (slot.queued > slot.promisedValue ? slot.queued : slot.promisedValue);
        slot.promisedQueue = nullptr;
#endif
        return true;
    }

    // Post-execute resolution, bound to the token (value and queue), not to `ready`.
    bool Enqueue(int index, const void* queue)
    {
        auto& slot = slots[(size_t) index];
        if (!slot.book.promisePending || slot.promisedQueue != queue)
            return false;
        const uint64_t promised = slot.promisedValue;
        slot.promisedQueue = nullptr;
        DlssNr::EnqueueLateSlotPromise(promised, slot.book.done, slot.book.submitted, slot.book.owned,
                                       slot.book.promisePending);
        slot.queued = (slot.queued > promised ? slot.queued : promised);
        return true;
    }

    uint64_t ComposeSignal(int index)
    {
        auto& slot = slots[(size_t) index];
        slot.book.ready = (slot.book.ready > slot.book.done ? slot.book.ready : slot.book.done) + 1;
        slot.book.done = slot.book.ready;
        slot.queued = (slot.queued > slot.book.ready ? slot.queued : slot.book.ready);
        return slot.book.ready;
    }

    bool Discard(int index, const void* object, const void* deProxied)
    {
        auto& slot = slots[(size_t) index];
        if (!slot.book.owned || slot.book.submitted || slot.book.promisePending ||
            !DlssNr::SameRecordedCommandIdentity(slot.producer, object, deProxied))
            return false;
        DlssNr::DiscardLateSlot(slot.book.pending, slot.book.owned);
        return true;
    }

    void ClearSelection(int index)
    {
        auto& slot = slots[(size_t) index];
        if (slot.book.pending && !slot.book.submitted)
            slot.extentValid = false;
        DlssNr::ClearLateSlotSelection(slot.book.pending);
    }
    void Cancel(int index) { ClearSelection(index); }
    void Close(int index) { ClearSelection(index); }
    void CloseAll()
    {
        for (int i = 0; i < (int) kSlots; ++i)
            Close(i);
    }

    void Pin(int index) { slots[(size_t) index].book.pinned = true; }
    void CompleteFence(int index) { slots[(size_t) index].completed = slots[(size_t) index].queued; }
};

// Mirror of the XeFG publication order with the production policy helpers:
//   CreateSwapchain -> ResetNrHandoff            (XeFG_Dx12.cpp: reset publishes Waiting)
//   Activate                                     (Activate publishes the usable state)
//   Present                                      (per-present publication)
//   ReleaseSwapchain -> nested Deactivate ->
//     ResetNrHandoff -> teardown -> Generic      (after the nested teardown)
struct Lifecycle
{
    // The registered FG swapchain is process-wide state (State::Instance()), not per instance.
    static const void*& Registered()
    {
        static const void* registered = nullptr;
        return registered;
    }
    const void* proxy = nullptr;

    static DlssNr::FinishedConsumer State() { return DlssNr::CurrentFinishedConsumer(); }
    bool MayPublish() const { return DlssNr::FinishedConsumerMayPublish(proxy, Registered()); }
    bool IsOwner() const { return DlssNr::FinishedConsumerIsOwner(proxy, Registered()); }

    static void Reset()
    {
        Registered() = nullptr;
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
    }

    void CreateProxy(const void* swapchain)
    {
        proxy = swapchain;
        if (MayPublish())
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGWaiting);
    }
    void Register() { Registered() = proxy; }
    void Activate(bool paused)
    {
        if (MayPublish())
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGWaiting);
        if (IsOwner())
            DlssNr::PublishFinishedConsumer(paused ? DlssNr::FinishedConsumer::XeFGWaiting
                                                   : DlssNr::FinishedConsumer::XeFGAvailable);
    }
    // The per-present publication. A pause edge closes every interval (ResetNrHandoff).
    void Present(bool active, bool paused, Pool& pool)
    {
        if (!IsOwner())
            return;
        if (!active || paused)
        {
            if (DlssNr::CurrentFinishedConsumer() == DlssNr::FinishedConsumer::XeFGAvailable)
            {
                pool.CloseAll(); // ResetNrHandoff: stale captures are closed, generation bumped
                DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGWaiting);
            }
            return;
        }
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
    }
    void Release(bool reentrant)
    {
        const bool owned = IsOwner();
        if (reentrant)
            return; // an aborted reentrant release publishes nothing
        // nested teardown: DestroyFGContext -> Deactivate -> ResetNrHandoff
        if (MayPublish())
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGWaiting);
        Registered() = nullptr;
        if (DlssNr::ReleasePublishesGeneric(owned, false))
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
    }
};

const void* ListFor(int index) { return (const void*) (uintptr_t) (0x1000 + index * 0x10); }
const void* QueueFor(int index) { return (const void*) (uintptr_t) (0x5000 + index * 0x10); }

// Mirror of the production IDENTITY scans' candidate filter (PendingFinishedCapture and
// ApplyFinishedColor): a candidate is any slot still armed for the picture (pending) that
// matches its placement/extent. Eligibility is never a prefilter - LateSelection decides
// after the newest serial is chosen. The seed restores the rejected pinned/eligibility
// prefilter so a caller regression reddens the pinned cases.
void FoldIdentity(const Pool& pool, DlssNr::LateSelection& selection)
{
    for (size_t i = 0; i < kSlots; ++i)
    {
        const auto& slot = pool.slots[i];
        if (!slot.book.pending)
            continue;
#if defined(NR_LATE_SLOT_SEED_SELECT_PREV)
        if (!pool.Composable(i))
            continue; // SEED: the rejected eligibility prefilter, applied before identity
#endif
        selection.Consider(slot.serial, pool.Composable(i));
    }
}

// ---------------------------------------------------------------------------
// R1 - a promise is not an enqueue
// ---------------------------------------------------------------------------

// While the producer is suspended between the promise and the real ExecuteCommandLists,
// neither the consumer (facts query + composition) nor Acquire may use the slot, and the
// signal is queued only when the token is resolved.
void PromiseIsNotAnEnqueueForTheConsumerOrReuse()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    Check(!pool.Composable(0), "a promised-but-not-executed capture was offered to the consumer");
    Check(!pool.Reusable(0), "a promised-but-not-executed slot was reusable");
    Check(pool.slots[0].queued == 0, "the promise already queued a signal");
    Check(pool.slots[0].book.done == 0, "the promise advanced the completion watermark before executing");
    Check(pool.Enqueue(0, QueueFor(0)), "the post-execute pass did not consume its own token");
    Check(pool.Composable(0), "an enqueued capture was not offered to the consumer");
    Check(!pool.Reusable(0), "the slot was reusable before its close and its promised signal");
    pool.Close(0);
    Check(!pool.Reusable(0), "the slot was reusable before its promised signal completed");
    pool.CompleteFence(0);
    Check(pool.Reusable(0), "the slot was not reused after its signal completed");
}

// The competing presentation that R1 describes: another thread acquires the locks while
// the producer is descheduled, then the producer resumes. Composition and reuse must be
// refused in the window, and the post-execute signal must use the token's value.
void CompetingPresentationBetweenPromiseAndExecuteIsRefused()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    // Presentation thread: facts query + composition attempt + acquire attempt.
    Check(!pool.Composable(0), "the presentation thread composed a capture before it executed");
    Check(pool.Acquire() != 0, "the presentation thread reused the slot before its producer executed");
    // A writer advancing `ready` must not change what the token resolves to.
    pool.slots[0].book.ready += 7;
    const uint64_t token = pool.slots[0].promisedValue;
    Check(pool.Enqueue(0, QueueFor(0)), "the post-execute pass did not resolve the token");
    Check(pool.slots[0].book.done == token,
          "post_execute_resolution_uses_the_promised_value: the signal used the mutable ready");
    Check(pool.slots[0].queued == token, "the queued value is not the promised value");
}

// ---------------------------------------------------------------------------
// R2 - release publication ordering and ownership
// ---------------------------------------------------------------------------

void ActiveReleaseAfterTeardownRestoresGeneric()
{
    Lifecycle::Reset();
    Lifecycle life;
    Pool pool;
    life.CreateProxy(ListFor(0));
    life.Register();
    life.Activate(false);
    life.Present(true, false, pool);
    Check(DlssNr::CurrentFinishedConsumer() == DlssNr::FinishedConsumer::XeFGAvailable,
          "an active owner did not publish XeFGAvailable");
    life.Release(false);
    Check(!DlssNr::FinishedConsumerUnavailable(),
          "releasing the owning proxy left the consumer stuck in XeFGWaiting");
    Check(DlssNr::CurrentFinishedConsumer() == DlssNr::FinishedConsumer::Generic,
          "a completed active release did not restore the generic route");
}

void ReentrantReleasePublishesNothing()
{
    Lifecycle::Reset();
    Lifecycle life;
    Pool pool;
    life.CreateProxy(ListFor(0));
    life.Register();
    life.Activate(false);
    life.Present(true, false, pool);
    life.Release(true); // reentrant: aborted before any teardown
    Check(DlssNr::CurrentFinishedConsumer() == DlssNr::FinishedConsumer::XeFGAvailable,
          "an aborted reentrant release changed the consumer state");
}

void NonOwnerReleaseLeavesTheOwnerAlone()
{
    Lifecycle::Reset();
    Lifecycle owner;
    Pool pool;
    owner.CreateProxy(ListFor(0));
    owner.Register();
    owner.Activate(false);
    owner.Present(true, false, pool);
    // A stale instance whose proxy is no longer registered releases: it must not clobber.
    Lifecycle stale;
    stale.CreateProxy(ListFor(1));
    stale.Release(false);
    Check(DlssNr::CurrentFinishedConsumer() == DlssNr::FinishedConsumer::XeFGAvailable,
          "a non-owner release clobbered the registered owner's consumer state");
}

void PausedActivationDoesNotAdmitCaptures()
{
    Lifecycle::Reset();
    Lifecycle life;
    Pool pool;
    life.CreateProxy(ListFor(0));
    life.Register();
    // NewFrame's reactivation: UpdateTarget() (a ten-frame pause) then Activate().
    life.Activate(true);
    Check(DlssNr::FinishedConsumerUnavailable(), "a paused activation admitted captures");
    life.Present(true, true, pool); // still paused
    Check(DlssNr::FinishedConsumerUnavailable(), "a paused present admitted captures");
    life.Present(true, false, pool);
    Check(!DlssNr::FinishedConsumerUnavailable(), "the resumed consumer never admitted captures again");
}

// The pause edge must close the intervals armed while the consumer was available, so a
// stale paused-frame capture can never be selected after the resume.
void PauseEdgeClosesIntervals()
{
    Lifecycle::Reset();
    Lifecycle life;
    Pool pool;
    life.CreateProxy(ListFor(0));
    life.Register();
    life.Activate(false);
    life.Present(true, false, pool);
    for (int i = 0; i < (int) kSlots; ++i)
        Check(pool.Arm(ListFor(i), nullptr) == i, "the armed capture did not take the expected slot");
    life.Present(true, true, pool); // pause edge: close every pending interval
    Check(DlssNr::FinishedConsumerUnavailable(), "the pause did not refuse admission");
    Check(pool.PendingCount() == 0, "the pause left stale capture intervals open");
    for (size_t i = 0; i < kSlots; ++i)
        Check(!pool.Composable(i), "a stale paused interval stayed selectable");
    life.Present(true, false, pool);
    Check(!DlssNr::FinishedConsumerUnavailable(), "the resumed present did not admit captures again");
}

// The fatal interleaving the per-call batch prevents: an unrelated list M submitted on the
// same queue must not consume list L's promise.
void WrongTokenSameQueueDoesNotResolveAnotherListsPromise()
{
    const void* const owner = (const void*) 0x9000;
    const void* const queue = QueueFor(0);
    const void* const listL = ListFor(1);
    const void* const listM = ListFor(2);
    DlssNr::LatePromiseEntry entry {};
    entry.owner = owner;
    entry.slot = 0;
    entry.serial = 7;
    entry.token = 3;
    entry.queue = queue;
    entry.producer = listL;
    Check(!DlssNr::LatePromiseEntryMatches(entry, owner, 0, 7, true, 3, queue, listM),
          "an unrelated list on the same queue resolved another list's promise");
    Check(!DlssNr::LatePromiseEntryMatches(entry, (const void*) 0x9001, 0, 7, true, 3, queue, listL),
          "an unrelated owner resolved the promise");
    Check(!DlssNr::LatePromiseEntryMatches(entry, owner, 0, 8, true, 3, queue, listL),
          "a re-armed slot serial resolved the old promise");
    Check(!DlssNr::LatePromiseEntryMatches(entry, owner, 0, 7, true, 4, queue, listL),
          "a different token value resolved the promise");
    Check(DlssNr::LatePromiseEntryMatches(entry, owner, 0, 7, true, 3, queue, listL),
          "the promised call did not match its own entry");
}

void CaptureAdmissionPredicateFollowsTheConsumer()
{
    // The pool's admission rule is production code (dlssnr/DlssNr_FinishedConsumer.h) and
    // both capture entry points call exactly it. NARROW GUARANTEE: this case covers the
    // predicate, not the call sites - removing the check from one capture route would not
    // be caught here (LateContext::Capture / CaptureResidual are not executable off-device).
    DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGWaiting);
    Check(!DlssNr::FinishedConsumerAdmitsCapture(), "the warmup consumer admitted a capture");
    DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
    Check(DlssNr::FinishedConsumerAdmitsCapture(), "an available consumer was refused a capture");
    DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
    Check(DlssNr::FinishedConsumerAdmitsCapture(), "the generic route was refused a capture");
}

// H1: the capture identity is the NEWEST matching slot, chosen before any eligibility test.
// An older enqueued/ready capture must never be substituted for a newer unresolved one -
// otherwise the handoff composes the old frame's guides into the new picture. The facts
// query (PendingFinishedCapture) and the composition (ApplyFinishedColor) share this rule.
void NewestUnresolvedCaptureIsNotReplacedByAnOlderReadyOne()
{
    Pool pool;
    const int older = pool.Arm(ListFor(0), nullptr);   // A: enqueued, ready, small serial
    Check(pool.Promise(older, ListFor(0), nullptr, QueueFor(0)), "A was not promised");
    Check(pool.Enqueue(older, QueueFor(0)), "A was not enqueued");
    pool.CompleteFence(older);
    const int newer = pool.Arm(ListFor(1), nullptr);    // B: newer serial, unresolved promise
    Check(pool.Promise(newer, ListFor(1), nullptr, QueueFor(1)), "B was not promised");
    Check(pool.slots[newer].serial > pool.slots[older].serial, "B does not own the newer serial");
    Check(pool.Composable(older), "the older enqueued capture is not composable");
    Check(!pool.Composable(newer), "the newer promise is already composable");

    // Facts query / composition identity fold over every matching pending capture.
    DlssNr::LateSelection selection;
    FoldIdentity(pool, selection);
    Check(selection.have, "no capture candidate was identified");
    Check(selection.serial == pool.slots[newer].serial,
          "the older ready capture won the identity over the newer unresolved one");
    Check(!selection.Usable(), "the older ready capture was substituted for the newer unresolved one");
    Check(DlssNr::LateCompositionRefuses(selection), "the unresolved newer capture did not refuse the frame");

    // Closure/recovery: once the newer capture resolves and is ready, it is the composed one.
    Check(pool.Enqueue(newer, QueueFor(1)), "B was not enqueued");
    pool.CompleteFence(newer);
    DlssNr::LateSelection resolved;
    FoldIdentity(pool, resolved);
    Check(resolved.Usable(), "the resolved newer capture was refused");
    Check(resolved.serial == pool.slots[newer].serial, "recovery composed the older capture");
}

// A failed producer Signal pins the newest capture (pending stays true). It is still a
// capture: it must win the serial identity and refuse the frame, never let an older ready
// capture be composed into the new picture.
void NewerPinnedCaptureIsNotReplacedByAnOlderReadyOne()
{
    Pool pool;
    const int older = pool.Arm(ListFor(0), nullptr);
    Check(pool.Promise(older, ListFor(0), nullptr, QueueFor(0)), "A was not promised");
    Check(pool.Enqueue(older, QueueFor(0)), "A was not enqueued");
    pool.CompleteFence(older);
    const int newer = pool.Arm(ListFor(1), nullptr);
    Check(pool.Promise(newer, ListFor(1), nullptr, QueueFor(1)), "B was not promised");
    Check(pool.Enqueue(newer, QueueFor(1)), "B was not enqueued");
    pool.Pin(newer); // the producer's Signal failed: pending stays true, the slot is pinned
    Check(pool.slots[newer].book.pending && pool.slots[newer].book.pinned,
          "the pinned capture is not pending+pinned as the failure branch leaves it");
    Check(pool.slots[newer].serial > pool.slots[older].serial, "B does not own the newer serial");

    DlssNr::LateSelection selection;
    FoldIdentity(pool, selection);
    Check(selection.have, "the pinned capture disappeared from the identity scan");
    Check(selection.serial == pool.slots[newer].serial,
          "the older ready capture won the identity over the newer pinned one");
    Check(!selection.Usable(), "the pinned newest capture was treated as selectable");
    Check(DlssNr::LateCompositionRefuses(selection), "the pinned newest capture did not refuse the frame");
    Check(!DlssNr::LateCompositionMayUseHeld(selection),
          "the held edit was allowed while a pinned current capture exists");
}

// The no-other-capture variant: a pinned-only matching capture must refuse the frame rather
// than let the held-edit bridge replay an older held slot.
void PinnedOnlyCaptureRefusesInsteadOfHeldEdit()
{
    Pool pool;
    const int pinned = pool.Arm(ListFor(0), nullptr);
    Check(pool.Promise(pinned, ListFor(0), nullptr, QueueFor(0)), "the capture was not promised");
    Check(pool.Enqueue(pinned, QueueFor(0)), "the capture was not enqueued");
    pool.Pin(pinned);
    DlssNr::LateSelection selection;
    FoldIdentity(pool, selection);
    Check(selection.have && !selection.Usable(),
          "a pinned-only matching capture was treated as no capture at all");
    Check(DlssNr::LateCompositionRefuses(selection), "the pinned-only frame was not refused");
    Check(!DlssNr::LateCompositionMayUseHeld(selection),
          "the held edit replaced a pinned current capture");
}

// ---------------------------------------------------------------------------
// Ownership and watermark (retained from the previous revision)
// ---------------------------------------------------------------------------

void FourUnresolvedArmsRecoverOnlyThroughAProvenEvent()
{
    Pool pool;
    for (int i = 0; i < (int) kSlots; ++i)
        Check(pool.Arm(ListFor(i), nullptr) == i, "pre-XeFG arm did not take the expected slot");
    pool.CloseAll();
    Check(pool.PendingCount() == 0, "the closed captures stayed presentation candidates");
    for (size_t i = 0; i < kSlots; ++i)
        Check(!pool.Reusable(i), "a closed capture with an unresolved recording was offered for reuse");
    for (int i = 0; i < (int) kSlots; ++i)
        Check(pool.Discard(i, ListFor(i), nullptr), "the discard path refused its own owned recording");
    for (size_t i = 0; i < kSlots; ++i)
        Check(pool.Reusable(i), "a proven-discarded capture did not return to the pool");
    Check(pool.Arm(ListFor(9), nullptr) == 0, "the fifth evaluation could not re-arm the recovered pool");
}

void CancelBeforeSubmitDoesNotRelease()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    pool.Cancel(0);
    Check(!pool.slots[0].extentValid, "Cancel did not invalidate the presentation extents");
    Check(!pool.Reusable(0), "Cancel released a recording that may still execute");
}

void DelayedSubmissionAfterClosePromisesAndGatesReuse()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    pool.Close(0);
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)),
          "a closed slot's later execution was not promised (recording left unresolved)");
    Check(pool.Enqueue(0, QueueFor(0)), "the token was not resolved after execution");
    Check(!pool.slots[0].book.owned && !pool.slots[0].book.pending,
          "the resolution did not clear ownership while keeping the capture out of selection");
    Check(!pool.Reusable(0), "the slot was reused before its promised signal completed");
    pool.CompleteFence(0);
    Check(pool.Reusable(0), "the slot was not reused after its promised signal completed");
}

void UnsubmittedDiscardReleasesTheSlot()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    const uint64_t watermark = pool.slots[0].book.ready;
    Check(pool.Discard(0, ListFor(0), nullptr), "the discard path refused its own recording");
    Check(pool.slots[0].book.ready == watermark, "the discard moved the watermark");
    Check(pool.Reusable(0), "the discarded recording's slot did not return to the pool");
    Check(pool.Arm(ListFor(1), nullptr) == 0, "the reclaimed slot could not be re-armed");
    Check(pool.slots[0].book.ready > watermark,
          "the re-arm reused a watermark value instead of allocating a fresh one");
}

// A promised list is not a discard: a Reset arriving during the promise window must be
// refused, and the token must still resolve to a fenced submission.
void ResetDuringThePromiseWindowIsNotADiscard()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    Check(!pool.Discard(0, ListFor(0), nullptr),
          "a promised recording was discarded as if it had never executed");
    Check(pool.slots[0].book.owned && pool.slots[0].book.promisePending,
          "the rejected discard changed the submission transaction");
    Check(pool.Enqueue(0, QueueFor(0)), "the token was not resolved after execution");
    pool.Close(0);
    Check(!pool.Reusable(0), "the promised slot was reused before its fence completed");
    pool.CompleteFence(0);
    Check(pool.Reusable(0), "the promised slot was not reused after its fence completed");
}

void QueuedSignalGatesReuseBeforeCompletion()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    Check(pool.Enqueue(0, QueueFor(0)), "the token was not resolved after execution");
    pool.Close(0);
    Check(!pool.Reusable(0), "the slot was reused before the queued producer signal completed");
    pool.CompleteFence(0);
    Check(pool.Reusable(0), "the slot was not reused after its signal completed");
}

void ComposeCloseFailurePinsWithoutRollback()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    Check(pool.Enqueue(0, QueueFor(0)), "the token was not resolved after execution");
    const uint64_t promised = pool.slots[0].book.done;
    pool.Pin(0);
    Check(pool.slots[0].book.done == promised && pool.slots[0].book.submitted,
          "the composition Close failure rolled the producer promise back");
    pool.Close(0);
    Check(!pool.Reusable(0), "a pinned slot was reused");
    pool.CompleteFence(0);
    Check(!pool.Reusable(0), "a pinned slot was reused once its fence completed");
}

void ComposeSignalAllocationIsMonotonic()
{
    Pool pool;
    Check(pool.Arm(ListFor(0), nullptr) == 0, "the first arm did not take slot 0");
    Check(pool.Promise(0, ListFor(0), nullptr, QueueFor(0)), "the promise token was not recorded");
    Check(pool.Enqueue(0, QueueFor(0)), "the token was not resolved after execution");
    const uint64_t producerSignal = pool.slots[0].queued;
    const uint64_t composed = pool.ComposeSignal(0);
    Check(composed > producerSignal, "the composition reused the producer's signal value");
    DlssNr::LateSlotBook next {};
    next.ready = pool.slots[0].book.ready;
    next.done = pool.slots[0].book.done;
    DlssNr::ArmLateSlot(next.ready, next.done, next.pending, next.submitted, next.owned);
    Check(next.ready > pool.slots[0].queued, "the next arm reused an already-queued watermark value");
}

void ProxiedAndBareCommandIdentity()
{
    const void* const proxy = (const void*) 0x1000;
    const void* const real = (const void*) 0x2000;

    Pool proxied;
    Check(proxied.Arm(proxy, real) == 0, "the proxied arm did not take slot 0");
    Check(proxied.slots[0].producer == real, "Arm did not record the de-proxied identity");
    Check(proxied.Promise(0, proxy, real, QueueFor(0)), "a proxied promise did not match the recording");
    Check(!proxied.Promise(0, proxy, nullptr, QueueFor(0)), "a raw comparison accepted a proxied list");

    Pool discarded;
    Check(discarded.Arm(proxy, real) == 0, "the proxied arm did not take slot 0");
    Check(discarded.Discard(0, proxy, real), "a proxied reset did not match the recording");
    Check(discarded.Reusable(0), "the proxied discarded recording did not return to the pool");

    const void* const bare = ListFor(0);
    Pool barePool;
    Check(barePool.Arm(bare, nullptr) == 0, "the bare arm did not take slot 0");
    Check(barePool.slots[0].producer == bare, "a bare list was not recorded verbatim");
    Check(!barePool.Discard(0, bare, (const void*) 0x2000), "a bare list was matched as a de-proxied list");
}
} // namespace

int main()
{
    struct Case
    {
        const char* name;
        void (*run)();
    };
    const Case cases[] = {
        { "promise_is_not_an_enqueue_for_the_consumer_or_reuse", PromiseIsNotAnEnqueueForTheConsumerOrReuse },
        { "competing_presentation_between_promise_and_execute_is_refused", CompetingPresentationBetweenPromiseAndExecuteIsRefused },
        { "active_release_after_teardown_restores_generic", ActiveReleaseAfterTeardownRestoresGeneric },
        { "reentrant_release_publishes_nothing", ReentrantReleasePublishesNothing },
        { "non_owner_release_leaves_the_owner_alone", NonOwnerReleaseLeavesTheOwnerAlone },
        { "paused_activation_does_not_admit_captures", PausedActivationDoesNotAdmitCaptures },
        { "pause_edge_closes_intervals", PauseEdgeClosesIntervals },
        { "newest_unresolved_capture_is_not_replaced_by_an_older_ready_one", NewestUnresolvedCaptureIsNotReplacedByAnOlderReadyOne },
        { "newer_pinned_capture_is_not_replaced_by_an_older_ready_one", NewerPinnedCaptureIsNotReplacedByAnOlderReadyOne },
        { "pinned_only_capture_refuses_instead_of_held_edit", PinnedOnlyCaptureRefusesInsteadOfHeldEdit },
        { "capture_admission_predicate_follows_the_consumer", CaptureAdmissionPredicateFollowsTheConsumer },
        { "wrong_token_same_queue_does_not_resolve_another_lists_promise", WrongTokenSameQueueDoesNotResolveAnotherListsPromise },
        { "four_unresolved_arms_recover_only_through_a_proven_event", FourUnresolvedArmsRecoverOnlyThroughAProvenEvent },
        { "cancel_before_submit_does_not_release", CancelBeforeSubmitDoesNotRelease },
        { "delayed_submission_after_close_promises_and_gates_reuse", DelayedSubmissionAfterClosePromisesAndGatesReuse },
        { "unsubmitted_discard_releases_the_slot", UnsubmittedDiscardReleasesTheSlot },
        { "reset_during_the_promise_window_is_not_a_discard", ResetDuringThePromiseWindowIsNotADiscard },
        { "queued_signal_gates_reuse_before_completion", QueuedSignalGatesReuseBeforeCompletion },
        { "compose_close_failure_pins_without_rollback", ComposeCloseFailurePinsWithoutRollback },
        { "compose_signal_allocation_is_monotonic", ComposeSignalAllocationIsMonotonic },
        { "proxied_and_bare_command_identity", ProxiedAndBareCommandIdentity },
    };

    std::printf("NR_LATE_SLOT_POOL production=shaders/dlssnr/DlssNr_LateSlot.h slots=%u cases=%u seed_prev=%d\n",
                (unsigned) kSlots, (unsigned) std::size(cases),
#if defined(NR_LATE_SLOT_SEED_PREV)
                1
#else
                0
#endif
    );
    unsigned failed = 0;
    for (const Case& test : cases)
    {
        checks = 0;
        try
        {
            test.run();
            if (checks == 0)
                throw std::runtime_error("scenario exercised no assertions");
            std::printf("CASE %-58s PASS (%d checks)\n", test.name, checks);
        }
        catch (const std::exception& error)
        {
            ++failed;
            std::printf("CASE %-58s FAIL %s\n", test.name, error.what());
        }
    }
    std::printf("NR_LATE_SLOT_POOL cases=%u failed=%u\n", (unsigned) std::size(cases), failed);
    return failed == 0 ? 0 : 1;
}
