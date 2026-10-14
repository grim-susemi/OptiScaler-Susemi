#pragma once
#include <Windows.h>
#include <filesystem>
#include <stdexcept>
#include <cstdint>

#ifndef OPTISCALER_NR_SELF_TEST
#error Owned vendor startup service is host-only.
#endif

// An explicit fixture-supplied path is the only load source. No module search,
// interception, provider selection or processing behavior is implemented here.
struct OwnedVendorModule
{
    std::filesystem::path suppliedPath;
    HMODULE module = nullptr;
    uint64_t initRequests = 0, exportAccesses = 0, nativeCalls = 0, loads = 0, liveContexts = 0;
    void Supply(const std::filesystem::path& path)
    {
        if (module || !path.is_absolute() || !std::filesystem::is_regular_file(path))
            throw std::runtime_error("HOST_VENDOR_PATH_INVALID");
        suppliedPath = path;
    }
    bool Open(HMODULE requested = nullptr)
    {
        ++initRequests;
        if (module) return !requested || requested == module;
        if (suppliedPath.empty()) return false;
        if (requested)
        {
            wchar_t actual[32768] {};
            const auto length = GetModuleFileNameW(requested, actual, DWORD(std::size(actual)));
            if (!length || length == std::size(actual) || !std::filesystem::equivalent(suppliedPath, actual))
                return false;
        }
        module = LoadLibraryExW(suppliedPath.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (module) ++loads;
        return module != nullptr && (!requested || requested == module);
    }
    template<class T> T Export(const char* name)
    {
        return module ? reinterpret_cast<T>(GetProcAddress(module, name)) : nullptr;
    }
    void Close()
    {
        if (liveContexts) throw std::runtime_error("HOST_VENDOR_CONTEXTS_NOT_CLOSED");
        if (module && !FreeLibrary(module)) throw std::runtime_error("HOST_VENDOR_UNLOAD_FAILED");
        module = nullptr;
    }
};
