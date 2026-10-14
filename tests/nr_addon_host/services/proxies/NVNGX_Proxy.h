#pragma once
#include <SysUtils.h>
#include <d3d12.h>
#include <filesystem>
#include <wrl/client.h>

#ifndef OPTISCALER_NR_SELF_TEST
#error Owned driver startup service is host-only.
#endif

// This replaces process/game startup only. Every exposed function pointer is
// resolved from the retained installed NVIDIA dispatcher; model code is unchanged.
class NVNGXProxy
{
public:
    using Init = NVSDK_NGX_Result (*)(unsigned long long, const wchar_t*, ID3D12Device*, NVSDK_NGX_Version, const NVSDK_NGX_FeatureCommonInfo*);
    using Parameters = NVSDK_NGX_Result (*)(NVSDK_NGX_Parameter**);
    using Destroy = NVSDK_NGX_Result (*)(NVSDK_NGX_Parameter*);
    using Create = NVSDK_NGX_Result (*)(ID3D12GraphicsCommandList*, NVSDK_NGX_Feature, NVSDK_NGX_Parameter*, NVSDK_NGX_Handle**);
    using Evaluate = NVSDK_NGX_Result (*)(ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*, const NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
    using Release = NVSDK_NGX_Result (*)(NVSDK_NGX_Handle*);
    using Shutdown = NVSDK_NGX_Result (*)(ID3D12Device*);
    static void OpenOwnedDriver(const std::filesystem::path& path, const std::filesystem::path& runtimeRoot, const std::filesystem::path& dataRoot);
    static void CloseOwnedDriver();
    static bool InitDx12(ID3D12Device* device);
    static bool IsDx12Inited() { return initialized; }
    static Parameters D3D12_GetCapabilityParameters() { return capabilities; }
    static Parameters D3D12_AllocateParameters() { return allocate; }
    static Destroy D3D12_DestroyParameters() { return destroy; }
    static Create D3D12_CreateFeature() { return create; }
    static Evaluate D3D12_EvaluateFeature() { return evaluate; }
    static Release D3D12_ReleaseFeature() { return release; }
    static std::filesystem::path NVNGXModule_Path() { return driverPath; }
    class ScopedFeatureCreationTrace {};
private:
    inline static HMODULE module = nullptr;
    inline static bool initialized = false;
    inline static Microsoft::WRL::ComPtr<ID3D12Device> retainedDevice;
    inline static std::filesystem::path driverPath, runtimePath, dataPath;
    inline static Init init = nullptr;
    inline static Parameters capabilities = nullptr, allocate = nullptr;
    inline static Destroy destroy = nullptr;
    inline static Create create = nullptr;
    inline static Evaluate evaluate = nullptr;
    inline static Release release = nullptr;
    inline static Shutdown shutdown = nullptr;
};
