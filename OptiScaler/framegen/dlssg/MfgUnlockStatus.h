#pragma once
#include "MfgUnlockMethod.h"
#include <atomic>
#include <string>

namespace MfgUnlock
{
// Value/status contracts are available in both build flavors. Plain builds do not supply
// an unlock implementation; exposing the shape must not be mistaken for unlock activity.
struct Status
{
    bool ModuleFound = false;
    bool AdvertiseMatched = false;
    bool ValidateMatched = false;
    unsigned int KernelsRewritten = 0;
    TemporalMethod TemporalAttempted = TemporalMethod::None;
    std::string TemporalDetail;
    std::string SnippetVersion;
    std::wstring ModulePath;
    const char* PluginCeiling = "";
    const char* FlipMetering = "";
    unsigned int FlipSites = 0;
    bool FlipRequested = false;
};

struct Telemetry
{
    std::atomic_bool optionsSeen { false };
    std::atomic_bool active { false };
    std::atomic<unsigned int> requested { 1 };
    std::atomic<unsigned int> sent { 1 };
    std::atomic<unsigned int> result { 0 };
    std::atomic_bool stateSeen { false };
    std::atomic<unsigned int> presented { 0 };
    std::atomic<unsigned int> maxPresented { 0 };
};
}
