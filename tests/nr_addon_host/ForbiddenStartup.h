#pragma once
#include <atomic>
#include <cstdio>
#include <stdexcept>
#include <windows.h>

#ifndef OPTISCALER_NR_SELF_TEST
#error Forbidden game startup guards are host-only.
#endif

namespace NrAddonHost
{
inline std::atomic_uint backendInputAttempts[5] {};
inline bool backendPollingSensitivity = false;
[[noreturn]] inline void RefuseBackendInput(unsigned call, const char* name)
{
    ++backendInputAttempts[call];
    std::printf("HOST_BACKEND_INPUT_REFUSED api=%s attempted=%u osRead=0\n",
                name, backendInputAttempts[call].load());
    std::fflush(stdout);
    throw std::runtime_error("HOST_BACKEND_DESKTOP_INPUT_REFUSED");
}
inline BOOL BackendGetCursorPos(LPPOINT) { RefuseBackendInput(0, "GetCursorPos"); }
inline SHORT BackendGetKeyState(int) { RefuseBackendInput(1, "GetKeyState"); }
inline HWND BackendGetForegroundWindow() { RefuseBackendInput(2, "GetForegroundWindow"); }
inline HWND BackendWindowFromPoint(POINT) { RefuseBackendInput(3, "WindowFromPoint"); }
inline BOOL BackendSetCursorPos(int, int) { RefuseBackendInput(4, "SetCursorPos"); }
inline void AssertBackendInputUnused()
{
    std::printf("HOST_BACKEND_INPUT_OBSERVED cursor=%u key=%u focus=%u hit=%u cursorWrite=%u osReads=0\n",
                backendInputAttempts[0].load(), backendInputAttempts[1].load(),
                backendInputAttempts[2].load(), backendInputAttempts[3].load(), backendInputAttempts[4].load());
    for (auto& count : backendInputAttempts)
        if (count)
            throw std::runtime_error("HOST_BACKEND_DESKTOP_INPUT_WAS_ATTEMPTED");
}
inline std::atomic_uint forbiddenMenuStartup { 0 }, forbiddenConfigSave { 0 };
inline std::atomic_uint forbiddenProviderStartup { 0 }, forbiddenGpuDiscovery { 0 };
[[noreturn]] inline void ForbidProviderStartup()
{
    ++forbiddenProviderStartup;
    throw std::runtime_error("HOST_PROVIDER_STARTUP_REFUSED");
}
[[noreturn]] inline void ForbidGpuDiscovery()
{
    ++forbiddenGpuDiscovery;
    throw std::runtime_error("HOST_GPU_DISCOVERY_REFUSED");
}
[[noreturn]] inline void ForbidMenuStartup()
{
    ++forbiddenMenuStartup;
    throw std::runtime_error("HOST_UNOWNED_GAME_MENU_STARTUP");
}
[[noreturn]] inline void ForbidConfigSave()
{
    ++forbiddenConfigSave;
    throw std::runtime_error("HOST_UNOWNED_CONFIG_SAVE");
}
inline void AssertForbiddenStartupUnused()
{
    std::printf("HOST_FORBIDDEN_STARTUP_OBSERVED menu=%u configSave=%u provider=%u gpuDiscovery=%u\n",
        forbiddenMenuStartup.load(), forbiddenConfigSave.load(), forbiddenProviderStartup.load(),
        forbiddenGpuDiscovery.load());
    if (forbiddenMenuStartup || forbiddenConfigSave || forbiddenProviderStartup || forbiddenGpuDiscovery)
        throw std::runtime_error("HOST_FORBIDDEN_STARTUP_WAS_CALLED");
}
}
