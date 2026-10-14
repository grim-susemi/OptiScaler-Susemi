#include <pch.h>
#include <proxies/NVNGX_Proxy.h>
#include <stdexcept>
#include <cstdio>

namespace
{
template<class T> T Export(HMODULE module, const char* name)
{
    auto address = GetProcAddress(module, name);
    if (!address) throw std::runtime_error(std::string("HOST_DRIVER_ABI_MISSING: ") + name);
    return reinterpret_cast<T>(address);
}
}

void NVNGXProxy::OpenOwnedDriver(const std::filesystem::path& path, const std::filesystem::path& runtimeRoot, const std::filesystem::path& dataRoot)
{
    if (module || !path.is_absolute() || !std::filesystem::is_regular_file(path)) throw std::runtime_error("HOST_DRIVER_PATH_INVALID");
    driverPath = path;
    runtimePath = runtimeRoot;
    dataPath = dataRoot;
    module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module) throw std::runtime_error("HOST_DRIVER_LOAD_FAILED");
    try
    {
        init = Export<Init>(module, "NVSDK_NGX_D3D12_Init_Ext");
        capabilities = Export<Parameters>(module, "NVSDK_NGX_D3D12_GetCapabilityParameters");
        allocate = Export<Parameters>(module, "NVSDK_NGX_D3D12_AllocateParameters");
        destroy = Export<Destroy>(module, "NVSDK_NGX_D3D12_DestroyParameters");
        create = Export<Create>(module, "NVSDK_NGX_D3D12_CreateFeature");
        evaluate = Export<Evaluate>(module, "NVSDK_NGX_D3D12_EvaluateFeature");
        release = Export<Release>(module, "NVSDK_NGX_D3D12_ReleaseFeature");
        shutdown = Export<Shutdown>(module, "NVSDK_NGX_D3D12_Shutdown1");
    }
    catch (...) { FreeLibrary(module); module = nullptr; throw; }
}

bool NVNGXProxy::InitDx12(ID3D12Device* device)
{
    if (initialized) return device == retainedDevice.Get();
    if (!module || !device) return false;
    const auto path = runtimePath.wstring();
    const wchar_t* paths[] = { path.c_str() };
    NVSDK_NGX_FeatureCommonInfo info {};
    info.PathListInfo.Path = paths;
    info.PathListInfo.Length = 1;
    const auto result = init(0x24480451, dataPath.c_str(), device, NVSDK_NGX_Version_API, &info);
    std::printf("HOST_DRIVER_INIT result=0x%08X device=%p\n", unsigned(result), device);
    if (result != NVSDK_NGX_Result_Success) return false;
    retainedDevice = device;
    return initialized = true;
}

void NVNGXProxy::CloseOwnedDriver()
{
    if (initialized)
    {
        const auto result = shutdown(retainedDevice.Get());
        std::printf("HOST_DRIVER_SHUTDOWN result=0x%08X\n", unsigned(result));
        if (result != NVSDK_NGX_Result_Success) throw std::runtime_error("HOST_DRIVER_SHUTDOWN_FAILED");
    }
    initialized = false;
    retainedDevice.Reset();
    if (module && !FreeLibrary(module)) throw std::runtime_error("HOST_DRIVER_UNLOAD_FAILED");
    module = nullptr;
    init = nullptr; capabilities = allocate = nullptr; destroy = nullptr;
    create = nullptr; evaluate = nullptr; release = nullptr; shutdown = nullptr;
}
