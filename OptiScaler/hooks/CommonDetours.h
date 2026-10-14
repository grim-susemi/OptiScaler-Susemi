#pragma once
#include "SlPairDetours.h"
#include <atomic>

namespace CommonDetours
{
// installed records our successful Commit; externallyCommitted records a real
// Detours slot update observed despite our failed Commit. Either owns teardown
// authority and the module association. Transition ownership is
// non-blocking: a loader callback must never wait for another loader callback.
struct State
{
    std::atomic_flag changing = ATOMIC_FLAG_INIT;
    std::atomic<bool> installed { false };
    std::atomic<bool> externallyCommitted { false };
    HMODULE module = nullptr;
};

struct Outcome
{
    SlPairDetours::Step failedStep = SlPairDetours::Step::None;
    long failedHr = 0;
    bool busy = false;
    bool detached = false;
};

struct Transition
{
    State& state;
    bool acquired;
    explicit Transition(State& value) : state(value), acquired(!value.changing.test_and_set(std::memory_order_acquire)) {}
    ~Transition()
    {
        if (acquired)
            state.changing.clear(std::memory_order_release);
    }
};

// Called only while holding Transition. Use the repository's checked Detours
// teardown policy; a failed teardown leaves the module, slot and flag intact.
inline Outcome RemoveOwned(const SlPairDetours::Api& api, State& state, void** slot, void* hook,
                           void (*onDetached)())
{
    Outcome outcome;
    if (!state.installed.load(std::memory_order_acquire) &&
        !state.externallyCommitted.load(std::memory_order_acquire))
        return outcome;

    const SlPairDetours::Targets targets { slot, nullptr };
    const SlPairDetours::Installed installed { true, false };
    const auto detached = SlPairDetours::Detach(api, targets, installed, hook, nullptr);
    outcome.failedStep = detached.failedStep;
    outcome.failedHr = detached.failedHr;
    if (outcome.failedStep != SlPairDetours::Step::None)
        return outcome;

    state.installed.store(false, std::memory_order_release);
    state.externallyCommitted.store(false, std::memory_order_release);
    state.module = nullptr;
    outcome.detached = detached.getNativeDetached;
    // Detours restored the real export in the slot. Keep it callable rather
    // than clearing a dispatch slot that an in-flight hook may still use.
    if (onDetached)
        onDetached();
    return outcome;
}

inline Outcome Remove(const SlPairDetours::Api& api, State& state, void** slot, void* hook,
                      void (*onDetached)() = nullptr)
{
    Transition transition(state);
    if (!transition.acquired)
        return { SlPairDetours::Step::None, 0, true, false };
    return RemoveOwned(api, state, slot, hook, onDetached);
}

inline Outcome Install(const SlPairDetours::Api& api, State& state, void** slot, void* hook, HMODULE module,
                       void* (*resolve)(HMODULE), void (*onDetached)() = nullptr)
{
    Transition transition(state);
    if (!transition.acquired)
        return { SlPairDetours::Step::None, 0, true, false };
    if ((state.installed.load(std::memory_order_acquire) ||
         state.externallyCommitted.load(std::memory_order_acquire)) && state.module == module)
        return {};

    // Resolve before disturbing a live association or opening a transaction.
    void* resolved = resolve(module);
    if (resolved == nullptr)
        return {};
    auto outcome = RemoveOwned(api, state, slot, hook, onDetached);
    if (outcome.failedStep != SlPairDetours::Step::None)
        return outcome;

    long hr = api.Begin();
    if (hr != NO_ERROR)
    {
        outcome.failedStep = SlPairDetours::Step::Begin;
        outcome.failedHr = hr;
        return outcome; // no transaction acquired: no dependent call or Abort
    }
    hr = api.UpdateThread();
    if (hr != NO_ERROR)
    {
        api.Abort();
        outcome.failedStep = SlPairDetours::Step::UpdateThread;
        outcome.failedHr = hr;
        return outcome;
    }

    void* previous = *slot;
    *slot = resolved;
    hr = api.Attach(slot, hook);
    if (hr != NO_ERROR)
    {
        api.Abort();
        *slot = previous;
        outcome.failedStep = SlPairDetours::Step::AttachGetNative;
        outcome.failedHr = hr;
        return outcome;
    }
    hr = api.Commit();
    if (hr != NO_ERROR)
    {
        // Match SlPairDetours: Commit owns its rollback. Do not Abort again
        // or erase the slot, including when a nested foreign installer already
        // committed the queued hook and our Commit reports lost ownership.
        outcome.failedStep = SlPairDetours::Step::Commit;
        outcome.failedHr = hr;
        // Attach only queues an operation. The real Detours Commit is what
        // replaces this resolved address with its trampoline. That native slot
        // update proves a foreign commit applied our hook; retain its module and
        // teardown authority without claiming that our own Commit succeeded.
        if (*slot != resolved)
        {
            state.module = module;
            state.externallyCommitted.store(true, std::memory_order_release);
        }
        return outcome;
    }
    state.module = module;
    state.installed.store(true, std::memory_order_release);
    return outcome;
}
}
