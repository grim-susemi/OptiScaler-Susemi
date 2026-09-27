// ============================================================================
// tests/sl_pair_detours_smoke.cpp - behavioural smoke for the R12 optional Streamline pair detours.
//
// WHAT IT DRIVES
//   The PRODUCTION code - OptiScaler/hooks/SlPairDetours.h - exactly as Streamline_Hooks.cpp calls it:
//   Install(), RemoveOptionalPair() (the replacement transition's first step), Detach(), Canonicalize().
//   Real Detours library, real target functions, real patched entries, real transactions.
//
// HOW A FAILING STEP IS PRODUCED (review R2-M1)
//   Through the REAL API with a documented-invalid attachment: the faulting step calls
//   DetourAttach/DetourDetach with a null detour, which Detours rejects with ERROR_INVALID_PARAMETER (87)
//   before touching any slot. So the failure code, the Abort and the rollback are the real library's
//   behaviour, not an application-level early return. See detours-invalid-attach-probe.cpp for the isolated
//   measurements that this design rests on (87 on attach, 87 on detach, transaction still usable).
//   It is NOT a trampoline-allocation failure: that cannot be forced deterministically here, so no claim is
//   made about it.
//
// WHAT IT COVERS
//   A. install: real invalid attach, real retry, real partial-pair rollback, clean detach.
//   B. the replacement transition: failed optional detach (single and mid-pair), retained state/slots and
//      intact core, then a successful retry through the same production function.
//   C. helper call discipline for the steps real Detours cannot be forced into (Begin/UpdateThread/Commit),
//      explicitly labelled as such.
//   D. Canonicalize ownership: null, success, refused query, and unwinding with the caller's reference
//      retained (the scope-bound ComPtr is the production owner).
//
// WHAT IT DOES NOT COVER
//   The W1/W2 hook bodies themselves (they live in a 2400-line app TU that cannot be linked standalone), the
//   ordering inside production's hookInterposer (source-audited), live 2.14 objects, and module unload/reload.
//   Report: .omo/evidence/nr-xefg-sl-pair-r12/REPORT.md.
//
// DETERMINISM: single-threaded, no sleeps, no polling, no wall-clock ordering. Cases are sequential and
// share state by construction; the PASS lines are checks, not isolated scenarios.
// ============================================================================
#include <hooks/SlPairDetours.h>
#include <shaders/dlssnr/DlssNr_NativeProbe.h>
#include "detours/detours.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace
{
int g_checks = 0;
int g_failures = 0;

void Check(bool ok, const char* what)
{
    ++g_checks;
    std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        ++g_failures;
}

// ---------------------------------------------------------------- targets, trampolines, hooks
volatile long g_sink = 0;
long g_coreEntered = 0, g_coreOriginals = 0;
long g_optAEntered = 0, g_optAOriginals = 0;
long g_optBEntered = 0, g_optBOriginals = 0;

void (*g_coreTrampoline)() = nullptr;
void (*g_optATrampoline)() = nullptr;
void (*g_optBTrampoline)() = nullptr;

__declspec(noinline) void CoreTarget()
{
    ++g_coreOriginals;
    g_sink += 1;
}

__declspec(noinline) void OptTargetA()
{
    ++g_optAOriginals;
    g_sink += 2;
}

__declspec(noinline) void OptTargetB()
{
    ++g_optBOriginals;
    g_sink += 4;
}

void CoreHook()
{
    ++g_coreEntered;
    if (g_coreTrampoline != nullptr)
        g_coreTrampoline();
}

void OptHookA()
{
    ++g_optAEntered;
    if (g_optATrampoline != nullptr)
        g_optATrampoline();
}

void OptHookB()
{
    ++g_optBEntered;
    if (g_optBTrampoline != nullptr)
        g_optBTrampoline();
}

// Reached through volatile pointers so the compiler must emit a real indirect call into the (possibly
// patched) entry instead of folding the call away.
void (*volatile g_coreEntry)() = &CoreTarget;
void (*volatile g_optEntryA)() = &OptTargetA;
void (*volatile g_optEntryB)() = &OptTargetB;

// ---------------------------------------------------------------- real API, with real-API faults
const SlPairDetours::Api realApi {
    [] { return DetourTransactionBegin(); },
    [] { return DetourUpdateThread(GetCurrentThread()); },
    [](void** trampoline, void* hook) { return DetourAttach((PVOID*) trampoline, hook); },
    [](void** trampoline, void* hook) { return DetourDetach((PVOID*) trampoline, hook); },
    [] { return DetourTransactionCommit(); },
    [] { return DetourTransactionAbort(); },
};

long g_attachIndex = 0, g_detachIndex = 0;
long g_failAttachAt = -1, g_failDetachAt = -1;

// The faulting step calls the REAL API with a documented-invalid argument (null detour): Detours validates it
// and returns ERROR_INVALID_PARAMETER without touching the slot or queueing a patch.
long FaultingAttach(void** trampoline, void* hook)
{
    ++g_attachIndex;
    if (g_attachIndex == g_failAttachAt)
        return DetourAttach((PVOID*) trampoline, nullptr);

    return DetourAttach((PVOID*) trampoline, hook);
}

long FaultingDetach(void** trampoline, void* hook)
{
    ++g_detachIndex;
    if (g_detachIndex == g_failDetachAt)
        return DetourDetach((PVOID*) trampoline, nullptr);

    return DetourDetach((PVOID*) trampoline, hook);
}

SlPairDetours::Api faultApi()
{
    SlPairDetours::Api api = realApi;
    api.Attach = &FaultingAttach;
    api.Detach = &FaultingDetach;
    return api;
}

void ClearFaults()
{
    g_attachIndex = g_detachIndex = 0;
    g_failAttachAt = g_failDetachAt = -1;
}

// ---------------------------------------------------------------- fake API: step discipline only
long g_beginHr = 0, g_updateHr = 0, g_commitHr = 0;
long g_callsBegin = 0, g_callsUpdate = 0, g_callsAttach = 0, g_callsDetach = 0, g_callsCommit = 0, g_callsAbort = 0;

void FakeReset()
{
    g_beginHr = g_updateHr = g_commitHr = 0;
    g_callsBegin = g_callsUpdate = g_callsAttach = g_callsDetach = g_callsCommit = g_callsAbort = 0;
}

long FakeBegin()
{
    ++g_callsBegin;
    return g_beginHr;
}

long FakeUpdate()
{
    ++g_callsUpdate;
    return g_updateHr;
}

long FakeAttach(void**, void*)
{
    ++g_callsAttach;
    return 0;
}

long FakeDetach(void**, void*)
{
    ++g_callsDetach;
    return 0;
}

long FakeCommit()
{
    ++g_callsCommit;
    return g_commitHr;
}

long FakeAbort()
{
    ++g_callsAbort;
    return 0;
}

SlPairDetours::Api fakeApi()
{
    return { &FakeBegin, &FakeUpdate, &FakeAttach, &FakeDetach, &FakeCommit, &FakeAbort };
}

// ---------------------------------------------------------------- a COM object without a COM runtime
struct FakeCom : IUnknown
{
    ULONG refs = 0;
    bool supportUnknown = true;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override
    {
        if (ppv == nullptr)
            return E_POINTER;

        if (supportUnknown && riid == __uuidof(IUnknown))
        {
            *ppv = static_cast<IUnknown*>(this);
            AddRef();
            return S_OK;
        }

        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs; }
};

// ---------------------------------------------------------------- small helpers
bool InstallCoreDetour()
{
    g_coreTrampoline = &CoreTarget;

    if (DetourTransactionBegin() != NO_ERROR)
        return false;

    if (DetourUpdateThread(GetCurrentThread()) != NO_ERROR)
    {
        DetourTransactionAbort();
        return false;
    }

    if (DetourAttach((PVOID*) &g_coreTrampoline, (PVOID) &CoreHook) != NO_ERROR)
    {
        DetourTransactionAbort();
        return false;
    }

    return DetourTransactionCommit() == NO_ERROR;
}

bool RemoveCoreDetour()
{
    if (DetourTransactionBegin() != NO_ERROR)
        return false;

    if (DetourUpdateThread(GetCurrentThread()) != NO_ERROR)
    {
        DetourTransactionAbort();
        return false;
    }

    if (DetourDetach((PVOID*) &g_coreTrampoline, (PVOID) &CoreHook) != NO_ERROR)
    {
        DetourTransactionAbort();
        return false;
    }

    return DetourTransactionCommit() == NO_ERROR;
}

// one call through the core entry, returning the deltas it caused
void CallCore(long& enteredDelta, long& originalDelta)
{
    const long entered = g_coreEntered;
    const long originals = g_coreOriginals;
    g_coreEntry();
    enteredDelta = g_coreEntered - entered;
    originalDelta = g_coreOriginals - originals;
}

void ResetOptionalSlots()
{
    g_optATrampoline = &OptTargetA;
    g_optBTrampoline = &OptTargetB;
}
} // namespace

int main()
{
    std::printf("SL_PAIR_DETOURS_SMOKE production=hooks/SlPairDetours.h detours=real detours_lib=linked "
                "fault=real-API-invalid-argument\n\n");

    SlPairDetours::Targets optionalTargets { (void**) &g_optATrampoline, (void**) &g_optBTrampoline };
    SlPairDetours::PairState pairState;

    // ================================================================ A. installation
    Check(InstallCoreDetour(), "A0 core detour installs with real Detours");
    {
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "A0 core detour intercepts and reaches the original exactly once");
    }

    // A1 - first optional attach fails INSIDE the real API
    ResetOptionalSlots();
    ClearFaults();
    g_failAttachAt = 1;
    const auto* slotABefore = (void*) g_optATrampoline;
    const auto failedInstall =
        SlPairDetours::Install(faultApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(failedInstall.failedStep == SlPairDetours::Step::AttachGetNative && failedInstall.aborted,
          "A1 real-API attach failure is reported at attach_get_native and the policy aborted");
    Check(failedInstall.failedHr == ERROR_INVALID_PARAMETER,
          "A1 the reported error is the real library's ERROR_INVALID_PARAMETER");
    Check(!failedInstall.installed.getNative && !failedInstall.installed.setDevice,
          "A1 no optional detour is reported installed");
    Check((void*) g_optATrampoline == slotABefore, "A1 the failed target's trampoline slot was not touched");
    {
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "A1 CORE HOOK STILL INTACT after the optional attach failure");
    }
    {
        const long before = g_optAEntered;
        g_optEntryA();
        Check(g_optAEntered == before, "A1 the failed optional target is not intercepted");
    }

    // A2 - retry on the very same real slot
    ClearFaults();
    const auto okInstall = SlPairDetours::Install(faultApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(okInstall.failedStep == SlPairDetours::Step::None && !okInstall.aborted && okInstall.installed.getNative &&
              okInstall.installed.setDevice,
          "A2 the pair installs on the retry through the same real Detours slots");
    pairState.installed = okInstall.installed;
    {
        const long a = g_optAEntered, aOrig = g_optAOriginals, b = g_optBEntered;
        g_optEntryA();
        g_optEntryB();
        Check(g_optAEntered == a + 1 && g_optAOriginals == aOrig + 1 && g_optBEntered == b + 1,
              "A2 both optional detours intercept and A reaches its original exactly once");
    }
    {
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "A2 core hook still intact after the optional install");
    }

    // A3 - the replacement transition removes the pair first, and succeeds here
    {
        SlPairDetours::DetachOutcome detach {};
        Check(SlPairDetours::RemoveOptionalPair(realApi, optionalTargets, pairState, (void*) &OptHookA,
                                                (void*) &OptHookB, detach),
              "A3 RemoveOptionalPair succeeds on a healthy pair");
        Check(detach.getNativeDetached && detach.setDeviceDetached && !pairState.installed.getNative &&
                  !pairState.installed.setDevice,
              "A3 both detours are detached and the state no longer authorises a detach");
        const long before = g_optAEntered;
        g_optEntryA();
        Check(g_optAEntered == before, "A3 a detached optional target is no longer intercepted");
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "A3 core hook still intact after the optional detach");
    }

    // A4 - second attach fails after a REAL first attach: the real Abort must roll the pending attach back
    ResetOptionalSlots();
    ClearFaults();
    g_failAttachAt = 2;
    const auto rollback =
        SlPairDetours::Install(faultApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(rollback.failedStep == SlPairDetours::Step::AttachSetDevice && rollback.aborted &&
              !rollback.installed.getNative && !rollback.installed.setDevice,
          "A4 a real-API failure on the second attach aborts and reports nothing installed");
    {
        const long beforeA = g_optAEntered, beforeB = g_optBEntered;
        g_optEntryA();
        g_optEntryB();
        Check(g_optAEntered == beforeA && g_optBEntered == beforeB,
              "A4 the REAL pending first attach was rolled back (A is not intercepted)");
    }
    {
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "A4 CORE HOOK STILL INTACT after the partial-pair rollback");
    }

    // ================================================================ B. failed detach in the replacement
    ResetOptionalSlots();
    ClearFaults();
    const auto installForDetach =
        SlPairDetours::Install(faultApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    pairState.installed = installForDetach.installed;
    Check(installForDetach.installed.getNative && installForDetach.installed.setDevice,
          "B0 pair installed again for the detach-failure cases");

    // B1 - the FIRST detach fails inside the real API: the pair is still live, so the transition must stop
    g_detachIndex = 0;
    g_failDetachAt = 1;
    {
        const auto slotA = (void*) g_optATrampoline;
        const auto slotB = (void*) g_optBTrampoline;
        SlPairDetours::DetachOutcome detach {};
        const bool removed = SlPairDetours::RemoveOptionalPair(faultApi(), optionalTargets, pairState,
                                                               (void*) &OptHookA, (void*) &OptHookB, detach);
        Check(!removed, "B1 failed optional detach reports failure to the replacement caller");
        Check(detach.failedStep == SlPairDetours::Step::DetachGetNative && detach.aborted &&
                  detach.failedHr == ERROR_INVALID_PARAMETER,
              "B1 the failure is the real library's ERROR_INVALID_PARAMETER at detach_get_native");
        Check(pairState.installed.getNative && pairState.installed.setDevice,
              "B1 the installed state is retained, so the live pair can still be retried");
        Check((void*) g_optATrampoline == slotA && (void*) g_optBTrampoline == slotB,
              "B1 the old trampoline slots are still associated with the old hooks");
        {
            const long beforeA = g_optAEntered, beforeB = g_optBEntered;
            g_optEntryA();
            g_optEntryB();
            Check(g_optAEntered == beforeA + 1 && g_optBEntered == beforeB + 1,
                  "B1 the old optional hooks are still live and dispatch to their own originals");
        }
        {
            long entered = 0, originals = 0;
            CallCore(entered, originals);
            Check(entered == 1 && originals == 1, "B1 the old core hook is still live after the failed cleanup");
        }
    }

    // B2 - the SECOND detach fails: the real Abort must roll the pending first detach back
    g_detachIndex = 0;
    g_failDetachAt = 2;
    {
        SlPairDetours::DetachOutcome detach {};
        const bool removed = SlPairDetours::RemoveOptionalPair(faultApi(), optionalTargets, pairState,
                                                               (void*) &OptHookA, (void*) &OptHookB, detach);
        Check(!removed && detach.failedStep == SlPairDetours::Step::DetachSetDevice,
              "B2 a failure on the second detach reports failure at detach_set_device");
        Check(pairState.installed.getNative && pairState.installed.setDevice,
              "B2 the installed state is retained after the mid-pair detach failure");
        const long beforeA = g_optAEntered, beforeB = g_optBEntered;
        g_optEntryA();
        g_optEntryB();
        Check(g_optAEntered == beforeA + 1 && g_optBEntered == beforeB + 1,
              "B2 the REAL pending first detach was rolled back, both old hooks still live");
    }

    // B3 - fault removed: the same production function now retries successfully
    ClearFaults();
    {
        SlPairDetours::DetachOutcome detach {};
        const bool removed = SlPairDetours::RemoveOptionalPair(faultApi(), optionalTargets, pairState,
                                                               (void*) &OptHookA, (void*) &OptHookB, detach);
        Check(removed && detach.getNativeDetached && detach.setDeviceDetached,
              "B3 the retried cleanup succeeds once the fault is gone");
        Check(!pairState.installed.getNative && !pairState.installed.setDevice,
              "B3 the retained state is cleared only after that successful retry");
        const long beforeA = g_optAEntered, beforeB = g_optBEntered;
        g_optEntryA();
        g_optEntryB();
        Check(g_optAEntered == beforeA && g_optBEntered == beforeB, "B3 both optional hooks are gone");
        long entered = 0, originals = 0;
        CallCore(entered, originals);
        Check(entered == 1 && originals == 1, "B3 the core hook survived the whole failure/retry transition");
    }

    // ================================================================ C. helper call discipline (fake API)
    FakeReset();
    const SlPairDetours::Targets noTargets { nullptr, nullptr };
    const auto noTargetOutcome = SlPairDetours::Install(fakeApi(), noTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(g_callsBegin == 0 && noTargetOutcome.failedStep == SlPairDetours::Step::None && !noTargetOutcome.aborted,
          "C1 installing with no target opens no transaction (fake API, call discipline only)");

    FakeReset();
    {
        SlPairDetours::PairState empty;
        SlPairDetours::DetachOutcome detach {};
        Check(SlPairDetours::RemoveOptionalPair(fakeApi(), optionalTargets, empty, (void*) &OptHookA,
                                                (void*) &OptHookB, detach) &&
                  g_callsBegin == 0 && g_callsDetach == 0,
              "C2 removing a pair that is not installed opens no transaction (fake API)");
    }

    FakeReset();
    g_beginHr = ERROR_INVALID_PARAMETER;
    const auto beginFailed = SlPairDetours::Install(fakeApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(beginFailed.failedStep == SlPairDetours::Step::Begin && !beginFailed.aborted && g_callsAbort == 0 &&
              g_callsAttach == 0 && g_callsCommit == 0,
          "C3 begin failure: no abort (there is no transaction), no attach, no commit (fake API)");

    FakeReset();
    g_updateHr = ERROR_INVALID_PARAMETER;
    const auto updateFailed = SlPairDetours::Install(fakeApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(updateFailed.failedStep == SlPairDetours::Step::UpdateThread && updateFailed.aborted && g_callsAbort == 1 &&
              g_callsAttach == 0,
          "C4 update_thread failure: exactly one abort, no attach (fake API)");

    FakeReset();
    g_commitHr = ERROR_INVALID_PARAMETER;
    const auto commitFailed =
        SlPairDetours::Install(fakeApi(), optionalTargets, (void*) &OptHookA, (void*) &OptHookB);
    Check(commitFailed.failedStep == SlPairDetours::Step::Commit && !commitFailed.aborted && g_callsAbort == 0 &&
              !commitFailed.installed.getNative && !commitFailed.installed.setDevice,
          "C5 commit failure: the helper issues no second abort and reports nothing installed (fake API)");
    // Deliberately NOT claimed as Detours rollback evidence: the fake API never queued a patch, so this only
    // shows the helper does not itself write the slots (real rollback is proven in A4 and B2).
    Check((void*) g_optATrampoline == (void*) &OptTargetA && (void*) g_optBTrampoline == (void*) &OptTargetB,
          "C5 the helper itself does not write the trampoline slots (not rollback evidence)");

    // ================================================================ D. Canonicalize ownership
    const auto nullIdentity = SlPairDetours::Canonicalize(nullptr);
    Check(nullIdentity.Get() == nullptr && std::strcmp(nullIdentity.state, "not_called") == 0,
          "D1 canonicalize(null): not_called and no query");

    FakeCom com;
    auto comIdentity = SlPairDetours::Canonicalize(&com);
    Check(comIdentity.Get() == static_cast<IUnknown*>(&com) && std::strcmp(comIdentity.state, "ok") == 0,
          "D2 canonicalize(com object): ok, canonical identity acquired");
    Check(com.refs == 1, "D2 canonicalize holds exactly one reference of its own");
    comIdentity = SlPairDetours::CanonicalIdentity {};
    Check(com.refs == 0, "D2 destroying the identity releases that reference (scope-bound owner)");

    FakeCom withoutUnknown;
    withoutUnknown.supportUnknown = false;
    const auto unsupported = SlPairDetours::Canonicalize(&withoutUnknown);
    Check(unsupported.Get() == nullptr && std::strcmp(unsupported.state, "failed") == 0 && withoutUnknown.refs == 0,
          "D3 canonicalize(object refusing IUnknown): failed with nothing acquired");

    // D4 - unwinding through the diagnostic scope must release OUR reference and keep the caller's
    FakeCom retained;
    retained.AddRef(); // the caller's own reference, exactly like a live D3D object handed to the hook
    const ULONG callerRefs = retained.refs;
    bool unwound = false;
    bool refsDuringScope = false;
    try
    {
        const auto scoped = SlPairDetours::Canonicalize(&retained);
        refsDuringScope = retained.refs == callerRefs + 1 && scoped.Get() == static_cast<IUnknown*>(&retained);
        throw std::runtime_error("simulated unwind out of the diagnostic scope");
    }
    catch (const std::exception&)
    {
        unwound = true;
    }
    Check(refsDuringScope, "D4 the owned identity holds its own reference while in scope");
    Check(unwound && retained.refs == callerRefs,
          "D4 unwinding released the own reference and left the caller's reference intact");

    // ================================================================ E. process-wide emission accounting
    // Review R3-M1: the process bound is a property of the three production latches under the declared
    // family-to-latch wiring. This drives the SAME production latch type through an adversarial sequence -
    // hundreds of failed-replacement attempts, each also carrying the hook-call traffic - and counts what
    // could be emitted. (The wiring itself, and the fact that every R12-added log site is inside one of these
    // guards, are asserted by the source audit over the full diff.)
    {
        DlssNr::NativeProbeAdmission sharedData; // W0 + W1
        DlssNr::NativeProbeAdmission w2Data;     // W2
        DlssNr::NativeProbeAdmission statusLatch; // both lifecycle records
        long dataRecords = 0;
        long statusRecords = 0;
        for (int attempt = 0; attempt < 200; ++attempt)
        {
            if (sharedData.Admit())
                ++dataRecords;
            if (w2Data.Admit())
                ++dataRecords;
            if (statusLatch.Admit())
                ++statusRecords;
        }
        Check(dataRecords == 16, "E1 200 adversarial attempts admit exactly 16 data records (two 8-latches)");
        Check(statusRecords == 8, "E1 the lifecycle latch admits exactly 8 status records");
        Check(dataRecords + statusRecords == 24, "E1 the declared process total of 24 records holds");
    }

    // ================================================================ cleanup, results checked
    const bool coreRemoved = RemoveCoreDetour();
    Check(coreRemoved, "Z0 core detour removed and the Detours transaction committed cleanly");
    {
        const long before = g_coreEntered;
        g_coreEntry();
        Check(g_coreEntered == before, "Z0 after cleanup the core entry is no longer intercepted");
    }

    std::printf("\nSL_PAIR_DETOURS_SMOKE checks=%d PASS=%d failures=%d\n", g_checks, g_checks - g_failures, g_failures);
    return g_failures == 0 ? 0 : 1;
}
