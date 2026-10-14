#pragma once
#include "OwnedVendorModule.h"
#include <ffx_api.h>
#include <ffx_upscale.h>
#include <dx12/ffx_api_dx12.h>

class FfxApiProxy
{
    inline static OwnedVendorModule owned;
    inline static PfnFfxCreateContext create = nullptr;
    inline static PfnFfxDestroyContext destroy = nullptr;
    inline static PfnFfxDispatch dispatch = nullptr;
public:
    // UI-only observations: this owned SR service supplies no FG/module inventory.
    static HMODULE Dx12Module() { return nullptr; }
    static HMODULE Dx12Module_SR() { return nullptr; }
    static HMODULE Dx12Module_FG() { return nullptr; }
    static bool IsFGReady(bool = true) { return false; }
    static feature_version VersionDx12_FG() { return {}; }
    static void SupplyOwnedRuntime(const std::filesystem::path& path) { owned.Supply(path); }
    static bool InitFfxDx12(HMODULE requested = nullptr)
    {
        if (!owned.Open(requested)) return false;
        create = owned.Export<PfnFfxCreateContext>("ffxCreateContext");
        destroy = owned.Export<PfnFfxDestroyContext>("ffxDestroyContext");
        dispatch = owned.Export<PfnFfxDispatch>("ffxDispatch");
        return create && destroy && dispatch;
    }
    static bool IsSRReady(bool = true) { ++owned.exportAccesses; return create && destroy && dispatch; }
    static ffxReturnCode_t D3D12_CreateContext(ffxContext* context, ffxCreateContextDescHeader* description,
                                             const ffxAllocationCallbacks* callbacks)
    {
        if (!create) throw std::runtime_error("HOST_FFX_EXPORT_MISSING");
        ++owned.nativeCalls;
        const auto result = create(context, description, callbacks);
        if (result == FFX_API_RETURN_OK && context && *context) ++owned.liveContexts;
        return result;
    }
    static ffxReturnCode_t D3D12_DestroyContext(ffxContext* context, const ffxAllocationCallbacks* callbacks)
    {
        if (!destroy) throw std::runtime_error("HOST_FFX_EXPORT_MISSING");
        ++owned.nativeCalls;
        const bool existed = context && *context;
        const auto result = destroy(context, callbacks);
        if (result == FFX_API_RETURN_OK && existed && owned.liveContexts) --owned.liveContexts;
        return result;
    }
    static ffxReturnCode_t D3D12_Dispatch(ffxContext* context, const ffxDispatchDescHeader* description)
    {
        if (!dispatch) throw std::runtime_error("HOST_FFX_EXPORT_MISSING");
        ++owned.nativeCalls;
        return dispatch(context, description);
    }
    static const OwnedVendorModule& OwnedObservation() { return owned; }
    static void CloseOwnedRuntime() { owned.Close(); create = nullptr; destroy = nullptr; dispatch = nullptr; }
};
