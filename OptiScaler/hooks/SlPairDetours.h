#pragma once
// ============================================================================
// SlPairDetours.h - installation policy for the OPTIONAL nr-xefg R12 Streamline pair detours
// (W1 hkslSetD3DDevice, W2 hkslGetNativeInterface).
//
// WHY IT IS SEPARATE FROM THE CORE HOOK SET (R12 review, H1)
//   A failure to attach an optional diagnostic must never be able to disable the functional hook set.
//   The core detours commit in their own transaction; this policy runs only AFTER that commit succeeded,
//   in its OWN transaction. A failure here aborts that transaction - rolling back a partly attached
//   optional pair - and reports which step failed; it cannot touch the core detours.
//   On a failed Commit the policy performs no second Abort and clears no trampoline pointer: rollback of
//   a failed commit belongs to Detours, and the pending-transaction state after it is not ours to
//   reinterpret.
//
// WHY IT TAKES AN Api STRUCT
//   So a behavioural test can drive THIS code - not a copy of it - against the real Detours entry points
//   with one step injected to fail (tests/sl_pair_detours_smoke.cpp).
//
// CONTRACT
//   - writes nothing outside `outcome`/`detached` and the trampoline pointers Detours itself updates;
//   - `Installed` is true only for a detour that really committed, and Detach() consults nothing else: a
//     resolved-but-unattached export has a non-null trampoline pointer and must never be detached by it;
//   - a target is "wanted" only when its trampoline pointer is non-null AND holds a resolved address AND
//     the hook is known;
//   - when nothing is wanted, no transaction is opened at all.
// ============================================================================
#include <cstdint>
#include <Windows.h>
#include <wrl/client.h>

namespace SlPairDetours
{
// A canonical COM identity acquired with our OWN temporary QueryInterface reference, owned by a scope-bound
// ComPtr: the reference is released when this object dies, including while unwinding out of the log call or
// out of the original. CanonicalIdentity is therefore freely copyable/movable with balanced semantics (the
// repository's existing Microsoft::WRL::ComPtr pattern, e.g. dlssnr/DlssNr_GpuLifetime.cpp). `state` is the
// truthful literal "ok"/"failed"/"not_called" (not_called = no handle, so no query ran).
struct CanonicalIdentity
{
    Microsoft::WRL::ComPtr<IUnknown> identity;
    const char* state = "not_called";

    IUnknown* Get() const { return identity.Get(); }
};

// The only call the R12 diagnostics make on a caller-owned object: QueryInterface(IID_IUnknown) on a
// documented D3D/DXGI COM interface pointer. No sl* API is involved. A null handle performs no call.
// NOTE (review R2-L2): production also canonicalizes the incoming proxy when the original returned an error -
// the proxy is the CALLER's own argument, which the Streamline contract describes as an SL proxy interface for
// every call, so its lifetime and type do not depend on the returned status. The returned BASE is only queried
// after a successful original (see the W2 body).
inline CanonicalIdentity Canonicalize(void* interfacePointer)
{
    CanonicalIdentity canonical;
    if (interfacePointer == nullptr)
        return canonical;

    canonical.state = SUCCEEDED(static_cast<IUnknown*>(interfacePointer)->QueryInterface(
                                    IID_PPV_ARGS(canonical.identity.ReleaseAndGetAddressOf())))
                          ? "ok"
                          : "failed";
    return canonical;
}

// The Detours entry points this policy needs. Detours returns LONG; `long` is the same width here, and
// production binds these to DetourTransactionBegin/UpdateThread/Attach/Detach/Commit/Abort.
struct Api
{
    long (*Begin)();
    long (*UpdateThread)();
    long (*Attach)(void** trampoline, void* hook);
    long (*Detach)(void** trampoline, void* hook);
    long (*Commit)();
    long (*Abort)();
};

// The two optional targets, given as the ADDRESSES of the trampoline pointers (e.g.
// &o_slGetNativeInterface) exactly as the Detours API expects to update them.
struct Targets
{
    void** getNative = nullptr;
    void** setDevice = nullptr;
};

enum class Step : std::uint32_t
{
    None = 0,
    Begin,
    UpdateThread,
    AttachGetNative,
    AttachSetDevice,
    DetachGetNative,
    DetachSetDevice,
    Commit,
};

inline const char* StepName(Step step)
{
    switch (step)
    {
    case Step::Begin:
        return "begin";
    case Step::UpdateThread:
        return "update_thread";
    case Step::AttachGetNative:
        return "attach_get_native";
    case Step::AttachSetDevice:
        return "attach_set_device";
    case Step::DetachGetNative:
        return "detach_get_native";
    case Step::DetachSetDevice:
        return "detach_set_device";
    case Step::Commit:
        return "commit";
    default:
        return "none";
    }
}

// Which optional detours really committed - the only detach authority.
struct Installed
{
    bool getNative = false;
    bool setDevice = false;
};

struct Outcome
{
    Installed installed;
    bool aborted = false; // this policy called Abort() and rolled its own transaction back
    Step failedStep = Step::None;
    long failedHr = 0;
};

inline bool Wanted(void** trampoline, const void* hook)
{
    return trampoline != nullptr && *trampoline != nullptr && hook != nullptr;
}

inline Outcome Install(const Api& api, const Targets& targets, void* getNativeHook, void* setDeviceHook)
{
    Outcome outcome;
    const bool wantGetNative = Wanted(targets.getNative, getNativeHook);
    const bool wantSetDevice = Wanted(targets.setDevice, setDeviceHook);

    if (!wantGetNative && !wantSetDevice)
        return outcome; // nothing to attach: no transaction is opened

    long hr = api.Begin();
    if (hr != 0)
    {
        outcome.failedStep = Step::Begin;
        outcome.failedHr = hr;
        return outcome;
    }

    hr = api.UpdateThread();
    if (hr != 0)
    {
        api.Abort();
        outcome.aborted = true;
        outcome.failedStep = Step::UpdateThread;
        outcome.failedHr = hr;
        return outcome;
    }

    if (wantGetNative)
    {
        hr = api.Attach(targets.getNative, getNativeHook);
        if (hr != 0)
        {
            api.Abort(); // drops a partly built optional transaction; core detours are committed elsewhere
            outcome.aborted = true;
            outcome.failedStep = Step::AttachGetNative;
            outcome.failedHr = hr;
            return outcome;
        }
    }

    if (wantSetDevice)
    {
        hr = api.Attach(targets.setDevice, setDeviceHook);
        if (hr != 0)
        {
            api.Abort();
            outcome.aborted = true;
            outcome.failedStep = Step::AttachSetDevice;
            outcome.failedHr = hr;
            return outcome;
        }
    }

    hr = api.Commit();
    if (hr != 0)
    {
        outcome.failedStep = Step::Commit;
        outcome.failedHr = hr;
        return outcome;
    }

    outcome.installed.getNative = wantGetNative;
    outcome.installed.setDevice = wantSetDevice;
    return outcome;
}

struct DetachOutcome
{
    bool getNativeDetached = false;
    bool setDeviceDetached = false;
    bool aborted = false;
    Step failedStep = Step::None;
    long failedHr = 0;
};

// Detaches only what `installed` says really committed, through the same hook each was attached with.
inline DetachOutcome Detach(const Api& api, const Targets& targets, const Installed& installed, void* getNativeHook,
                            void* setDeviceHook)
{
    DetachOutcome outcome;
    const bool wantGetNative = installed.getNative && Wanted(targets.getNative, getNativeHook);
    const bool wantSetDevice = installed.setDevice && Wanted(targets.setDevice, setDeviceHook);

    if (!wantGetNative && !wantSetDevice)
        return outcome; // nothing installed: no transaction is opened

    long hr = api.Begin();
    if (hr != 0)
    {
        outcome.failedStep = Step::Begin;
        outcome.failedHr = hr;
        return outcome;
    }

    hr = api.UpdateThread();
    if (hr != 0)
    {
        api.Abort();
        outcome.aborted = true;
        outcome.failedStep = Step::UpdateThread;
        outcome.failedHr = hr;
        return outcome;
    }

    if (wantGetNative)
    {
        hr = api.Detach(targets.getNative, getNativeHook);
        if (hr != 0)
        {
            api.Abort();
            outcome.aborted = true;
            outcome.failedStep = Step::DetachGetNative;
            outcome.failedHr = hr;
            return outcome;
        }
    }

    if (wantSetDevice)
    {
        hr = api.Detach(targets.setDevice, setDeviceHook);
        if (hr != 0)
        {
            api.Abort();
            outcome.aborted = true;
            outcome.failedStep = Step::DetachSetDevice;
            outcome.failedHr = hr;
            return outcome;
        }
    }

    hr = api.Commit();
    if (hr != 0)
    {
        outcome.failedStep = Step::Commit;
        outcome.failedHr = hr;
        return outcome;
    }

    outcome.getNativeDetached = wantGetNative;
    outcome.setDeviceDetached = wantSetDevice;
    return outcome;
}

// The optional pair's live state: which detours really committed. Production holds one file-scope object and
// the smoke holds its own, so the same code decides what may be detached and what may be reported installed.
struct PairState
{
    Installed installed;
};

// The FIRST step of a replacement: the optional pair must be gone before anything destructive happens to the
// core set (review R2-H1). Returns false when the pair is still live - the caller must then keep the old module
// association and every pointer and flag it owns, and stop BEFORE resolving or overwriting anything. True means
// the pair is gone (or was never installed) and `state` no longer authorises any detach.
inline bool RemoveOptionalPair(const Api& api, const Targets& targets, PairState& state, void* getNativeHook,
                               void* setDeviceHook, DetachOutcome& outcome)
{
    outcome = Detach(api, targets, state.installed, getNativeHook, setDeviceHook);

    if (outcome.failedStep != Step::None)
        return false;

    if (outcome.getNativeDetached)
        state.installed.getNative = false;

    if (outcome.setDeviceDetached)
        state.installed.setDevice = false;

    return true;
}
} // namespace SlPairDetours
