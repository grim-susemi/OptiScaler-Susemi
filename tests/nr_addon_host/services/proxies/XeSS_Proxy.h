#pragma once
#include "OwnedVendorModule.h"
#include <xess_d3d12.h>
#include <xess.h>

class XeSSProxy
{
    inline static OwnedVendorModule owned;
    inline static decltype(&xessD3D12CreateContext) create = nullptr;
    inline static decltype(&xessD3D12Init) init = nullptr;
    inline static decltype(&xessD3D12Execute) execute = nullptr;
    inline static decltype(&xessDestroyContext) destroy = nullptr;
    inline static decltype(&xessSetVelocityScale) velocity = nullptr;
    inline static decltype(&xessGetOptimalInputResolution) resolution = nullptr;
    static xess_result_t Create(ID3D12Device* device, xess_context_handle_t* context)
    {
        ++owned.nativeCalls;
        const auto result = create(device, context);
        if (result == XESS_RESULT_SUCCESS && context && *context) ++owned.liveContexts;
        return result;
    }
    static xess_result_t Destroy(xess_context_handle_t context)
    {
        ++owned.nativeCalls;
        const auto result = destroy(context);
        if (result == XESS_RESULT_SUCCESS && context && owned.liveContexts) --owned.liveContexts;
        return result;
    }
public:
    static void SupplyOwnedRuntime(const std::filesystem::path& path) { owned.Supply(path); }
    static bool InitXeSS(HMODULE requested = nullptr)
    {
        if (!owned.Open(requested)) return false;
        create = owned.Export<decltype(create)>("xessD3D12CreateContext");
        init = owned.Export<decltype(init)>("xessD3D12Init");
        execute = owned.Export<decltype(execute)>("xessD3D12Execute");
        destroy = owned.Export<decltype(destroy)>("xessDestroyContext");
        velocity = owned.Export<decltype(velocity)>("xessSetVelocityScale");
        resolution = owned.Export<decltype(resolution)>("xessGetOptimalInputResolution");
        return create && init && execute && destroy && velocity && resolution;
    }
    static HMODULE Module() { return owned.module; }
    static auto D3D12CreateContext() -> decltype(create) { ++owned.exportAccesses; return create ? &Create : nullptr; }
    static auto D3D12Init() -> decltype(init) { ++owned.exportAccesses; return init; }
    static auto D3D12Execute() -> decltype(execute) { ++owned.exportAccesses; return execute; }
    static auto DestroyContext() -> decltype(destroy) { ++owned.exportAccesses; return destroy ? &Destroy : nullptr; }
    static auto SetVelocityScale() -> decltype(velocity) { ++owned.exportAccesses; return velocity; }
    static auto GetOptimalInputResolution() -> decltype(resolution) { ++owned.exportAccesses; return resolution; }
    static const OwnedVendorModule& OwnedObservation() { return owned; }
    static void CloseOwnedRuntime()
    {
        owned.Close(); create = nullptr; init = nullptr; execute = nullptr;
        destroy = nullptr; velocity = nullptr; resolution = nullptr;
    }
};
