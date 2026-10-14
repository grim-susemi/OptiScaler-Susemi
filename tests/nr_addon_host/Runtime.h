#pragma once
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <cstdint>

namespace NrAddonHost
{
struct RuntimeCase
{
    const wchar_t* id;
    enum class Route { Render, Upscaled, Present } route;
    bool adopted;
    float scale;
    unsigned passes, signal, filter, transfer, effectiveTransfer, ui;
    bool hdr;
};
const RuntimeCase& FindRuntimeCase(std::wstring_view id);
struct RuntimeOptions
{
    enum class Mode { Cpu, Warp, Runtime } mode = Mode::Cpu;
    std::filesystem::path fixtureRoot, candidate, runtimeRoot;
    std::string candidateSha256, runtimeSha256;
    enum class GuideContract { None, Missing, ForeignDevice, AdapterMismatch } guideContract = GuideContract::None;
    bool task15Candidate = false, diagnosticPair = false, diagnosticObserver = false;
    const RuntimeCase* runtimeCase = nullptr;
    std::filesystem::path finalCandidate, qualifiedInputs;
    std::string finalCandidateSha256, qualifiedInputsSha256;
    std::filesystem::path driver;
    std::string driverSha256;
    uint32_t adapterLow = 0, adapterHigh = 0;
    uint64_t retainedBytes = 0, reservationBytes = 0;
};
std::optional<int> TryRunHost(int argc, wchar_t** argv);
void ValidateHostInputs(const RuntimeOptions& options);
std::string FileSha256(const std::filesystem::path& path);
void RunWarpHost(const RuntimeOptions& options);
void RunRuntimeHost(const RuntimeOptions& options);
}
