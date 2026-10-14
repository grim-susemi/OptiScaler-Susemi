#include <Windows.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <future>
#include <thread>
#include <hooks/SlPairDetours.h>
#include <detours/detours.h>
#ifndef COMMON_LIFECYCLE_OLD
#include <hooks/CommonDetours.h>
#endif

namespace
{
using Function = int (*)(const char*);
Function original = nullptr;
int entered = 0, originals = 0, failures = 0, attaches = 0, detaches = 0;
__declspec(noinline) int TargetA(const char* name)
{
    ++originals;
    return name[0] + 100;
}
__declspec(noinline) int TargetB(const char* name)
{
    ++originals;
    return name[0] + 200;
}
int Hook(const char* name)
{
    ++entered;
    return original(name);
}
Function volatile entryA = TargetA, entryB = TargetB;
const auto moduleA = reinterpret_cast<HMODULE>(1);
const auto moduleB = reinterpret_cast<HMODULE>(2);
void* Resolve(HMODULE module) { return module == moduleA ? (void*) TargetA : (void*) TargetB; }
const SlPairDetours::Api api {
    [] { return DetourTransactionBegin(); },
    [] { return DetourUpdateThread(GetCurrentThread()); },
    [](void** slot, void* hook) { ++attaches; return DetourAttach((PVOID*) slot, hook); },
    [](void** slot, void* hook) { ++detaches; return DetourDetach((PVOID*) slot, hook); },
    [] { return DetourTransactionCommit(); },
    [] { return DetourTransactionAbort(); },
};
void Check(bool ok, const char* name)
{
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok)
        ++failures;
}

#ifdef COMMON_LIFECYCLE_OLD
// Frozen pre-repair common lifecycle, with only logging/export resolution replaced.
// This deliberately retains the old unchecked transaction calls and pointer writes.
void Remove()
{
    api.Begin();
    api.UpdateThread();
    if (original)
        api.Detach((void**) &original, (void*) Hook);
    if (api.Commit() == NO_ERROR)
        original = nullptr;
}
void Install(HMODULE module)
{
    if (original)
        Remove();
    original = reinterpret_cast<Function>(Resolve(module));
    if (original)
    {
        api.Begin();
        api.UpdateThread();
        api.Attach((void**) &original, (void*) Hook);
        if (api.Commit() != NO_ERROR)
            original = nullptr;
    }
}
#else
CommonDetours::State state;
CommonDetours::Outcome last;
void Install(HMODULE module)
{
    last = CommonDetours::Install(api, state, (void**) &original, (void*) Hook, module, Resolve);
}
void Remove() { last = CommonDetours::Remove(api, state, (void**) &original, (void*) Hook); }
#endif

void Dispatch(Function volatile& entry, int expected, const char* name)
{
    const int before = entered, originalBefore = originals;
    Check(entry("slOnPluginLoad") == expected && entered == before + 1 && originals == originalBefore + 1, name);
}
}

int main()
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
#ifdef COMMON_LIFECYCLE_OLD
    std::puts("COMMON_LIFECYCLE mode=old real_detours=1");
#else
    std::puts("COMMON_LIFECYCLE mode=production real_detours=1");
#endif
    Check(api.Begin() == NO_ERROR, "prearm outer real transaction");
    Install(moduleA);
    Check(original == nullptr, "failed nested Begin leaves unresolved slot untouched");
    const long outerCommit = api.Commit();
    Check(outerCommit == NO_ERROR, "nested installer preserves outer transaction ownership");
#ifdef COMMON_LIFECYCLE_OLD
    // Recover the fixture's stolen, committed detour, not the production implementation.
    if (outerCommit != NO_ERROR && original)
        Remove();
#endif
    Install(moduleA);
    Dispatch(entryA, 's' + 100, "installed hook dispatches actual original");
    const int attachBefore = attaches, detachBefore = detaches;
    const Function saved = original;
    Install(moduleA);
    Check(attaches == attachBefore && detaches == detachBefore && original == saved,
          "duplicate module is a no-op with stable trampoline");
    Dispatch(entryA, 's' + 100, "duplicate preserves actual dispatch");

    // Exact event handoff: another thread owns Detours until the replacement returns.
    std::promise<long> ready;
    auto armed = ready.get_future();
    std::promise<void> release;
    auto released = release.get_future();
    long workerAbort = -1;
    std::thread worker([&] {
        ready.set_value(api.Begin());
        released.wait();
        workerAbort = api.Abort();
    });
    const bool signalled = armed.wait_for(std::chrono::seconds(10)) == std::future_status::ready;
    Check(signalled && armed.get() == NO_ERROR, "other thread prearms real transaction");
    const Function live = original;
    Install(moduleB);
    Check(original == live, "failed teardown preserves live trampoline");
#ifndef COMMON_LIFECYCLE_OLD
    Check(state.installed.load() && state.module == moduleA && last.failedStep == SlPairDetours::Step::Begin,
          "failed replacement preserves committed module association");
#endif
    release.set_value();
    worker.join();
    Check(workerAbort == NO_ERROR, "replacement did not consume another thread transaction");
#ifdef COMMON_LIFECYCLE_OLD
    // The old policy cleared the still-installed dispatch slot. Restore only for fixture cleanup.
    original = live;
#endif
    Dispatch(entryA, 's' + 100, "failed replacement leaves old dispatch operational");
    Install(moduleB);
    Check(entryA("slOnPluginLoad") == 's' + 100, "successful replacement removes old detour");
    Dispatch(entryB, 's' + 200, "successful replacement dispatches new original");
    Remove();
    const int before = entered;
    Check(entryB("slOnPluginLoad") == 's' + 200 && entered == before, "cleanup removes committed hook");
    Check(api.Begin() == NO_ERROR && api.Abort() == NO_ERROR, "cleanup leaves no owned transaction");
#ifndef COMMON_LIFECYCLE_OLD
    // Invoke the actual production transition recursively and concurrently from
    // export resolution, before it owns any native transaction.
    bool recursiveBusy = false, concurrentBusy = false;
    static bool* recursiveResult;
    static bool* concurrentResult;
    recursiveResult = &recursiveBusy;
    concurrentResult = &concurrentBusy;
    const auto reentrantResolve = [](HMODULE module) -> void* {
        *recursiveResult = CommonDetours::Install(api, state, (void**) &original, (void*) Hook, module, Resolve).busy;
        std::thread nested([module] {
            *concurrentResult =
                CommonDetours::Install(api, state, (void**) &original, (void*) Hook, module, Resolve).busy;
        });
        nested.join();
        return Resolve(module);
    };
    last = CommonDetours::Install(api, state, (void**) &original, (void*) Hook, moduleA, reentrantResolve);
    Check(recursiveBusy && concurrentBusy && last.failedStep == SlPairDetours::Step::None,
          "recursive and concurrent installs return busy without loader-lock waits");
    Dispatch(entryA, 's' + 100, "outer installation remains operational after rejected nested installs");
    Remove();

    // Fault injection keeps the real library's transaction and dispatch state.
    auto updateFault = api;
    updateFault.UpdateThread = []() -> long { return ERROR_INVALID_PARAMETER; };
    const Function beforeFault = original;
    last = CommonDetours::Install(updateFault, state, (void**) &original, (void*) Hook, moduleA, Resolve);
    Check(last.failedStep == SlPairDetours::Step::UpdateThread && original == beforeFault &&
              api.Begin() == NO_ERROR && api.Abort() == NO_ERROR,
          "UpdateThread failure aborts acquired transaction and preserves slot");
    auto attachFault = api;
    attachFault.Attach = [](void** slot, void*) -> long { return DetourAttach((PVOID*) slot, nullptr); };
    last = CommonDetours::Install(attachFault, state, (void**) &original, (void*) Hook, moduleA, Resolve);
    Check(last.failedStep == SlPairDetours::Step::AttachGetNative && original == beforeFault &&
              !state.installed.load() && api.Begin() == NO_ERROR && api.Abort() == NO_ERROR,
          "real Attach failure aborts owned transaction and restores previous slot");
    Install(moduleA);
    auto detachFault = api;
    detachFault.Detach = [](void**, void* hook) -> long {
        void* invalid = nullptr;
        return DetourDetach((PVOID*) &invalid, hook);
    };
    const Function beforeDetach = original;
    last = CommonDetours::Install(detachFault, state, (void**) &original, (void*) Hook, moduleB, Resolve);
    Check(last.failedStep == SlPairDetours::Step::DetachGetNative && original == beforeDetach &&
              state.installed.load() && state.module == moduleA,
          "real Detach failure stops replacement and retains committed association");
    Dispatch(entryA, 's' + 100, "failed Detach keeps old actual dispatch");
    Remove();
    auto rollbackCommit = api;
    rollbackCommit.Attach = [](void** slot, void* hook) -> long {
        const long attached = DetourAttach((PVOID*) slot, hook);
        if (attached != NO_ERROR)
            return attached;
        void* invalid = nullptr;
        DetourAttach((PVOID*) &invalid, hook); // poison the owned transaction, not its slot
        return NO_ERROR; // let the real Commit expose and roll back the pending error
    };
    last = CommonDetours::Install(rollbackCommit, state, (void**) &original, (void*) Hook, moduleA, Resolve);
    const int rollbackEntered = entered;
    Check(last.failedStep == SlPairDetours::Step::Commit && last.failedHr == ERROR_INVALID_HANDLE &&
              !state.installed.load() && !state.externallyCommitted.load() && state.module == nullptr &&
              original == TargetA && entryA("slOnPluginLoad") == 's' + 100 && entered == rollbackEntered,
          "ordinary failed Commit rollback cannot claim an externally committed attachment");
    Check(api.Begin() == NO_ERROR && api.Abort() == NO_ERROR, "ordinary failed Commit closes its own transaction");
    // A foreign same-thread Commit can consume our queued attach. This is the
    // exact native 10DD branch: it must never erase the now-live dispatch slot.
    auto stolenCommit = api;
    stolenCommit.Commit = []() -> long {
        const long committed = DetourTransactionCommit();
        if (committed != NO_ERROR)
            return committed;
        return DetourTransactionCommit();
    };
    last = CommonDetours::Install(stolenCommit, state, (void**) &original, (void*) Hook, moduleA, Resolve);
    Check(last.failedStep == SlPairDetours::Step::Commit && last.failedHr == ERROR_INVALID_OPERATION &&
              original != nullptr && !state.installed.load() && state.externallyCommitted.load(),
          "Commit 10DD preserves callable slot without claiming successful own commit");
    Dispatch(entryA, 's' + 100, "already committed detour still dispatches after Commit 10DD");
    const Function committedSlot = original;
    const int committedAttaches = attaches, committedDetaches = detaches;
    Install(moduleA);
    Check(original == committedSlot && attaches == committedAttaches && detaches == committedDetaches &&
              state.module == moduleA,
          "post-10DD same-module retry preserves association without attaching twice");
    Dispatch(entryA, 's' + 100, "post-10DD retry dispatch remains callable without recursion");
    Install(moduleB);
    Check(entryA("slOnPluginLoad") == 's' + 100 && state.module == moduleB && state.installed.load(),
          "post-10DD replacement removes observed old attachment and commits new association");
    Dispatch(entryB, 's' + 200, "post-10DD replacement dispatches new original");
    Remove();
    Check(!state.installed.load() && !state.externallyCommitted.load() &&
              state.module == nullptr && entryB("slOnPluginLoad") == 's' + 200,
          "post-10DD replacement Remove closes actual attachment and association");
    // Also remove the externally committed attachment directly, without a retry
    // or successful replacement first supplying teardown authority.
    last = CommonDetours::Install(stolenCommit, state, (void**) &original, (void*) Hook, moduleA, Resolve);
    Check(last.failedHr == ERROR_INVALID_OPERATION && !state.installed.load() && state.externallyCommitted.load(),
          "direct Remove control starts with failed own Commit and externally live detour");
    Remove();
    const int afterObservedRemove = entered;
    Check(!state.externallyCommitted.load() && state.module == nullptr &&
              entryA("slOnPluginLoad") == 's' + 100 && entered == afterObservedRemove,
          "direct Remove tears down post-10DD observed attachment without recursion");
    Check(api.Begin() == NO_ERROR && api.Abort() == NO_ERROR && !state.changing.test_and_set(),
          "all test transactions and transition ownership closed");
    state.changing.clear();
#endif
    std::printf("COMMON_LIFECYCLE failures=%d\n", failures);
    return failures == 0 ? 0 : 1;
}
