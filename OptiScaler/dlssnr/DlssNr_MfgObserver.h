#pragma once
#include "DlssNr_FinishedConsumer.h"
#include <array>
#include <mutex>

namespace DlssNr::MfgObserver
{
// These are seam-local address values, never borrowed objects or lifetime handles.
// No address join, extent match, callback counter or index assigns an application.
enum class Seam : uint32_t { NgxNative, NgxReplacement, NgxCombo, StreamlineEvaluate, StreamlinePresent, Nr };
enum class Role : uint32_t { Unknown, Backbuffer, OutputReal, OutputInterpolated, Hudless, Depth, Motion, NrColour };
enum class Declaration : uint32_t { Unknown, ApplicationInput, ProviderReal, ProviderGenerated };
enum class IndexSource : uint32_t { Unknown, NgxMultiFrameIndex, StreamlineFrameToken };
struct Resource
{
    uint64_t value = 0;
    Role role = Role::Unknown;
    Declaration declaration = Declaration::Unknown;
    uint32_t readResult = 0;
    bool readAttempted = false, readSuccess = false;
    bool ngxVkResource = false;
    uint32_t tagType = 0, lifecycle = 0;
};
struct Identity
{
    uint64_t owner = 0, consumer = 0, generation = 0, application = 0;
    bool applicationKnown = false;
};
inline uint64_t Value(const void* object) { return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(object)); }
inline Identity CopyIdentity(const FinishedIdentity& source)
{
    return { Value(source.owner), Value(source.consumer), source.generation,
             source.applicationKnown ? source.application : 0, source.applicationKnown };
}
struct Event
{
    uint64_t session = 0, activity = 0;
    Seam seam = Seam::Nr;
    Identity identity {};
    uint64_t provider = 0, handle = 0, commands = 0, captureSerial = 0;
    uint32_t handleId = 0, feature = 0, stage = 0, result = 0;
    uint32_t inputCount = 0, inputEntriesObserved = 0;
    bool featureKnown = false, resultKnown = false;
    uint32_t rawIndex = 0, indexReadResult = 0;
    IndexSource indexSource = IndexSource::Unknown;
    bool indexReadResultKnown = false;
    bool indexReadAttempted = false, indexReadSuccess = false;
    // MultiFrameIndex has no documented numeric phase convention here.
    bool phaseKnown = false, pixelOriginKnown = false, displayTimingAvailable = false;
    std::array<Resource, 6> resources {};
    uint32_t resourceCount = 0;
};
inline constexpr uint32_t kApplicationSeamCap = 64, kEventCap = 512;
struct Snapshot
{
    uint64_t session = 0, owner = 0;
    uint32_t applicationSeams = 0, eventCount = 0;
    uint64_t contentionDrops = 0;
    bool active = false, capped = false;
    std::array<Event, kEventCap> events {};
};
struct Publisher
{
    std::mutex mutex;
    std::atomic_bool active { false };
    std::atomic_uint64_t session { 0 };
    std::atomic_uint64_t owner { 0 };
    std::atomic_uint64_t contentionDrops { 0 };
    Snapshot snapshot;
};
inline Publisher& State() { static Publisher state; return state; }
inline bool Enabled() { return State().active.load(std::memory_order_relaxed); }
inline uint64_t Session() { return State().session.load(std::memory_order_acquire); }
inline bool Begin(const void* owner, unsigned run)
{
    auto& state = State();
    std::unique_lock lock(state.mutex, std::try_to_lock);
    if (!lock.owns_lock()) return false;
    auto& snapshot = state.snapshot;
    snapshot.session = snapshot.owner = snapshot.contentionDrops = 0;
    snapshot.applicationSeams = snapshot.eventCount = 0;
    snapshot.active = snapshot.capped = false;
    snapshot.events.fill(Event {});
    state.snapshot.session = run;
    state.snapshot.owner = Value(owner);
    state.snapshot.active = owner && run;
    state.contentionDrops.store(0, std::memory_order_relaxed);
    state.session.store(run, std::memory_order_release);
    state.owner.store(Value(owner), std::memory_order_release);
    state.active.store(state.snapshot.active, std::memory_order_release);
    return state.snapshot.active;
}
inline void Stop(const void* owner)
{
    auto& state = State();
    if (!Enabled()) return;
    if (state.owner.load(std::memory_order_acquire) != Value(owner)) return;
    // Begin/Stop are serialized by the existing NR owner lock. Stop does not
    // need the observer lock to close admission when publication is contended.
    state.active.store(false, std::memory_order_release);
    std::unique_lock lock(state.mutex, std::try_to_lock);
    if (!lock.owns_lock()) return;
    if (state.snapshot.owner == Value(owner))
    {
        state.snapshot.active = false;
        state.active.store(false, std::memory_order_release);
    }
}
inline void Publish(Event event)
{
    auto& state = State();
    if (!Enabled()) return;
    std::unique_lock lock(state.mutex, std::try_to_lock);
    if (!lock.owns_lock())
    {
        state.contentionDrops.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    auto& snapshot = state.snapshot;
    if (!snapshot.active || !Enabled()) return;
    if (event.session && event.session != snapshot.session) return;
    if (event.seam == Seam::Nr && (event.stage == 0 || event.stage == 3))
    {
        if (snapshot.applicationSeams == kApplicationSeamCap)
        {
            snapshot.capped = true;
            snapshot.active = false;
            state.active.store(false, std::memory_order_release);
            return;
        }
        // Diagnostic stage zero and the before-reconstruction seam are conservative
        // application markers. All owners and unknown/duplicate tokens consume budget;
        // observing both markers can stop earlier. This is never a frame/display clock.
        ++snapshot.applicationSeams;
    }
    if (snapshot.eventCount == kEventCap)
    {
        snapshot.capped = true;
        snapshot.active = false;
        state.active.store(false, std::memory_order_release);
        return;
    }
    event.session = snapshot.session;
    event.activity = snapshot.eventCount + 1;
    snapshot.events[snapshot.eventCount++] = event;
}
// Ordinary-thread diagnostic publisher. Render callbacks never call this blocking read.
inline void Read(Snapshot& result)
{
    auto& state = State();
    std::lock_guard lock(state.mutex);
    state.snapshot.active = Enabled();
    state.snapshot.contentionDrops = state.contentionDrops.load(std::memory_order_relaxed);
    // Copy into caller-owned value storage. A layered by-value return of this
    // bounded array can exhaust an unoptimized Windows worker's default stack.
    result = state.snapshot;
}
inline void Nr(const void* owner, const FinishedIdentity& identity, unsigned stage, const void* colour)
{
    if (!Enabled()) return;
    Event event;
    event.identity = CopyIdentity(identity);
    event.identity.owner = Value(owner);
    event.stage = stage;
    event.resources[0].value = Value(colour);
    event.resources[0].role = Role::NrColour;
    event.resourceCount = 1;
    Publish(event);
}
}
