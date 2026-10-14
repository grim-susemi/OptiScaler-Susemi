#include <pch.h>
#include "Runtime.h"
#include <bcrypt.h>
#include <fstream>
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <cstring>
#include <charconv>

#ifndef OPTISCALER_NR_SELF_TEST
#error Host contracts must never enter a product build.
#endif

namespace NrAddonHost
{
namespace
{
[[noreturn]] void Reject(const char* name) { throw std::runtime_error(name); }
std::vector<unsigned char> Read(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) Reject("HOST_RUNTIME_MISSING");
    const auto length = input.tellg();
    if (length < 0 || length > 512ll * 1024 * 1024) Reject("HOST_ABI_INVALID");
    std::vector<unsigned char> bytes(static_cast<size_t>(length));
    input.seekg(0);
    if (!input.read(reinterpret_cast<char*>(bytes.data()), bytes.size())) Reject("HOST_ABI_INVALID");
    return bytes;
}
void ValidateAbi(const std::filesystem::path& path)
{
    const auto bytes = Read(path);
    const auto range = [&](size_t offset, size_t length) { return offset <= bytes.size() && length <= bytes.size() - offset; };
    if (!range(0, sizeof(IMAGE_DOS_HEADER))) Reject("HOST_ABI_INVALID");
    IMAGE_DOS_HEADER dos {};
    std::memcpy(&dos, bytes.data(), sizeof(dos));
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 ||
        !range(dos.e_lfanew, sizeof(IMAGE_NT_HEADERS64))) Reject("HOST_ABI_INVALID");
    IMAGE_NT_HEADERS64 nt {};
    std::memcpy(&nt, bytes.data() + dos.e_lfanew, sizeof(nt));
    if (nt.Signature != IMAGE_NT_SIGNATURE || nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt.FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64) ||
        nt.OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) Reject("HOST_ABI_INVALID");
    const size_t sectionOffset = size_t(dos.e_lfanew) + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) + nt.FileHeader.SizeOfOptionalHeader;
    if (!range(sectionOffset, size_t(nt.FileHeader.NumberOfSections) * sizeof(IMAGE_SECTION_HEADER))) Reject("HOST_ABI_INVALID");
    const auto offsetOf = [&](DWORD rva, size_t length) -> size_t
    {
        if (rva < nt.OptionalHeader.SizeOfHeaders && range(rva, length)) return rva;
        for (unsigned i = 0; i < nt.FileHeader.NumberOfSections; ++i)
        {
            IMAGE_SECTION_HEADER section {};
            std::memcpy(&section, bytes.data() + sectionOffset + i * sizeof(section), sizeof(section));
            if (rva >= section.VirtualAddress && rva - section.VirtualAddress < section.SizeOfRawData &&
                length <= section.SizeOfRawData - (rva - section.VirtualAddress))
            {
                const size_t offset = size_t(section.PointerToRawData) + rva - section.VirtualAddress;
                if (range(offset, length)) return offset;
            }
        }
        Reject("HOST_ABI_INVALID");
    };
    const auto directory = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!directory.VirtualAddress || directory.Size < sizeof(IMAGE_EXPORT_DIRECTORY)) Reject("HOST_ABI_EXPORT_MISSING");
    IMAGE_EXPORT_DIRECTORY exports {};
    std::memcpy(&exports, bytes.data() + offsetOf(directory.VirtualAddress, sizeof(exports)), sizeof(exports));
    if (!exports.NumberOfNames || exports.NumberOfNames > 65536) Reject("HOST_ABI_EXPORT_MISSING");
    const size_t namesOffset = offsetOf(exports.AddressOfNames, size_t(exports.NumberOfNames) * sizeof(DWORD));
    const char* required[] = { "NVSDK_NGX_D3D12_Init_Ext", "NVSDK_NGX_D3D12_CreateFeature", "NVSDK_NGX_D3D12_EvaluateFeature", "NVSDK_NGX_D3D12_ReleaseFeature", "NVSDK_NGX_D3D12_Shutdown1" };
    bool found[std::size(required)] {};
    for (DWORD i = 0; i < exports.NumberOfNames; ++i)
    {
        DWORD nameRva {};
        std::memcpy(&nameRva, bytes.data() + namesOffset + i * sizeof(DWORD), sizeof(nameRva));
        const size_t offset = offsetOf(nameRva, 1);
        const auto* name = reinterpret_cast<const char*>(bytes.data() + offset);
        const auto* end = static_cast<const char*>(std::memchr(name, 0, bytes.size() - offset));
        if (!end || end - name > 512) Reject("HOST_ABI_INVALID");
        for (unsigned j = 0; j < std::size(required); ++j)
            found[j] = found[j] || std::string_view(name, end - name) == required[j];
    }
    for (bool present : found) if (!present) Reject("HOST_ABI_EXPORT_MISSING");
}
std::string NarrowHash(std::wstring_view value)
{
    if (value.size() != 64) Reject("HOST_IDENTITY_INVALID");
    std::string result;
    for (wchar_t c : value)
    {
        if (c >= L'a' && c <= L'f') c -= L'a' - L'A';
        if (!((c >= L'0' && c <= L'9') || (c >= L'A' && c <= L'F'))) Reject("HOST_IDENTITY_INVALID");
        result.push_back(static_cast<char>(c));
    }
    return result;
}
uint64_t Budget(std::wstring_view value)
{
    std::string digits;
    for (const auto c : value)
    {
        if (c < L'0' || c > L'9') Reject("HOST_BUDGET_INVALID");
        digits.push_back(static_cast<char>(c));
    }
    uint64_t result = 0;
    const auto parsed = std::from_chars(digits.data(), digits.data() + digits.size(), result);
    if (digits.empty() || parsed.ec != std::errc {} || parsed.ptr != digits.data() + digits.size())
        Reject("HOST_BUDGET_INVALID");
    return result;
}
}

const RuntimeCase& FindRuntimeCase(std::wstring_view id)
{
    using Route = RuntimeCase::Route;
    static constexpr RuntimeCase cases[] = {
        { L"B00", Route::Present, false, 1.f, 1, 0, 0, 0, 0, 1, false },
        { L"R01", Route::Render, true, 1.f, 1, 0, 0, 0, 0, 0, false },
        { L"U02", Route::Upscaled, true, 1.f, 1, 0, 0, 0, 0, 0, false },
        { L"P03", Route::Present, true, 1.f, 1, 0, 0, 0, 0, 1, false },
        { L"R04", Route::Render, true, .65f, 2, 0, 0, 4, 3, 0, false },
        { L"R05", Route::Render, true, .65f, 1, 0, 0, 2, 1, 0, false },
        { L"U06", Route::Upscaled, true, .65f, 1, 0, 1, 0, 0, 0, false },
        { L"P07", Route::Present, true, .65f, 2, 0, 2, 0, 0, 1, false },
        { L"H08", Route::Present, true, .65f, 1, 0, 0, 0, 0, 1, true },
        { L"H09", Route::Present, true, .65f, 1, 1, 0, 0, 0, 1, true },
        { L"H10", Route::Upscaled, true, .65f, 2, 2, 1, 0, 0, 0, true },
        { L"H11", Route::Render, true, .65f, 1, 3, 2, 0, 0, 0, true }
    };
    for (const auto& candidate : cases) if (id == candidate.id) return candidate;
    Reject("HOST_RUNTIME_CASE_INVALID");
}

std::string FileSha256(const std::filesystem::path& path)
{
    const auto bytes = Read(path);
    unsigned char digest[32] {};
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) Reject("HOST_HASH_ERROR");
    const auto status = BCryptHash(algorithm, nullptr, 0, const_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()), digest, sizeof(digest));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status < 0) Reject("HOST_HASH_ERROR");
    constexpr char hex[] = "0123456789ABCDEF";
    std::string result;
    for (auto value : digest) { result.push_back(hex[value >> 4]); result.push_back(hex[value & 15]); }
    return result;
}

void ValidateHostInputs(const RuntimeOptions& options)
{
    if (!options.fixtureRoot.is_absolute() || !std::filesystem::is_directory(options.fixtureRoot)) Reject("HOST_FIXTURE_PATH_INVALID");
    if (!options.candidate.is_absolute() || !std::filesystem::is_regular_file(options.candidate)) Reject("HOST_CANDIDATE_PATH_INVALID");
    wchar_t own[MAX_PATH] {};
    const auto count = GetModuleFileNameW(nullptr, own, std::size(own));
    if (!count || count == std::size(own) || !std::filesystem::equivalent(options.candidate, own)) Reject("HOST_CANDIDATE_PATH_MISMATCH");
    if (options.candidateSha256.empty() || FileSha256(options.candidate) != options.candidateSha256) Reject("HOST_CANDIDATE_IDENTITY_MISMATCH");
    if (options.runtimeRoot.empty()) Reject("HOST_RUNTIME_MISSING");
    if (!options.runtimeRoot.is_absolute() || !std::filesystem::is_directory(options.runtimeRoot)) Reject("HOST_RUNTIME_PATH_INVALID");
    const auto runtime = options.runtimeRoot / L"nvngx_dlssnr.dll";
    if (!std::filesystem::is_regular_file(runtime)) Reject("HOST_RUNTIME_MISSING");
    if (options.runtimeSha256.empty() || FileSha256(runtime) != options.runtimeSha256) Reject("HOST_RUNTIME_IDENTITY_MISMATCH");
    ValidateAbi(runtime);
    if (options.task15Candidate)
    {
        if (!options.runtimeCase) Reject("HOST_RUNTIME_CASE_REQUIRED");
        if (options.mode == RuntimeOptions::Mode::Warp || options.guideContract != RuntimeOptions::GuideContract::None)
            Reject("HOST_CASE_MODE_UNSUPPORTED");
        if (!options.finalCandidate.is_absolute() || !std::filesystem::is_regular_file(options.finalCandidate))
            Reject("HOST_FINAL_CANDIDATE_REQUIRED");
        if (options.finalCandidateSha256 != "02CB71546ECB2EA1525F4EA07DC65ADBE344B4C0787464F503FD6C00F7B71C84" ||
            std::filesystem::file_size(options.finalCandidate) != 27289088 ||
            FileSha256(options.finalCandidate) != options.finalCandidateSha256)
            Reject("HOST_FINAL_CANDIDATE_IDENTITY_MISMATCH");
        if (!options.qualifiedInputs.is_absolute() || !std::filesystem::is_regular_file(options.qualifiedInputs) ||
            options.qualifiedInputsSha256.empty()) Reject("HOST_QUALIFIED_INPUTS_REQUIRED");
        if (FileSha256(options.qualifiedInputs) != options.qualifiedInputsSha256)
            Reject("HOST_QUALIFIED_INPUTS_IDENTITY_MISMATCH");
        if (options.reservationBytes < 16777216 || options.reservationBytes > 134217728 ||
            options.retainedBytes > 268435456 || options.reservationBytes > 268435456 - options.retainedBytes)
            Reject("HOST_RETAINED_BUDGET_REFUSED");
        if (options.mode == RuntimeOptions::Mode::Runtime &&
            (!options.driver.is_absolute() || options.driverSha256.empty()))
            Reject("HOST_DRIVER_BINDING_REQUIRED");
        std::printf("HOST_TASK15_CPU_INPUTS_PASS case=%ls hostExeSeparate=1 finalDllLoaded=0 runtimeLoaded=0 gpuCreated=0 retained=%llu reservation=%llu\n",
            options.runtimeCase->id, options.retainedBytes, options.reservationBytes);
    }
    else std::printf("HOST_CPU_INPUTS_PASS candidateCliIdentity=hostExe candidateDllState=unbuiltPendingTask14 runtimeAbi=AMD64 requiredExports=5 runtimeLoaded=0 gpuCreated=0\n");
}

std::optional<int> TryRunHost(int argc, wchar_t** argv)
{
    RuntimeOptions options;
    bool selected = false;
    for (int i = 1; i < argc; ++i)
    {
        const std::wstring_view argument = argv[i];
        if (argument == L"--host-contracts") { options.mode = RuntimeOptions::Mode::Cpu; selected = true; }
        if (argument == L"--warp-handoff") { options.mode = RuntimeOptions::Mode::Warp; selected = true; }
        if (argument == L"--runtime") { options.mode = RuntimeOptions::Mode::Runtime; selected = true; }
    }
    if (!selected) return std::nullopt;
    for (int i = 1; i < argc; ++i)
    {
        const std::wstring_view argument = argv[i];
        if (argument == L"--host-contracts" || argument == L"--warp-handoff" || argument == L"--runtime" || argument == L"--headless") continue;
        if (argument == L"--task15-candidate") { options.task15Candidate = true; continue; }
        if (i + 1 >= argc) Reject("HOST_ARGUMENT_INVALID");
        const std::wstring_view value = argv[++i];
        if (argument == L"--fixture-root") options.fixtureRoot = value;
        else if (argument == L"--candidate") options.candidate = value;
        else if (argument == L"--runtime-root") options.runtimeRoot = value;
        else if (argument == L"--candidate-sha256") options.candidateSha256 = NarrowHash(value);
        else if (argument == L"--runtime-sha256") options.runtimeSha256 = NarrowHash(value);
        else if (argument == L"--runtime-case")
        {
            if (options.runtimeCase) Reject("HOST_RUNTIME_CASE_DUPLICATE");
            options.runtimeCase = &FindRuntimeCase(value);
        }
        else if (argument == L"--final-candidate") options.finalCandidate = value;
        else if (argument == L"--final-candidate-sha256") options.finalCandidateSha256 = NarrowHash(value);
        else if (argument == L"--qualified-inputs") options.qualifiedInputs = value;
        else if (argument == L"--qualified-inputs-sha256") options.qualifiedInputsSha256 = NarrowHash(value);
        else if (argument == L"--driver") options.driver = value;
        else if (argument == L"--driver-sha256") options.driverSha256 = NarrowHash(value);
        else if (argument == L"--adapter-luid-low" || argument == L"--adapter-luid-high")
        {
            const auto bits = Budget(value);
            if (bits > UINT32_MAX) Reject("HOST_DRIVER_ADAPTER_BINDING_INVALID");
            if (argument == L"--adapter-luid-low") options.adapterLow = static_cast<uint32_t>(bits);
            else options.adapterHigh = static_cast<uint32_t>(bits);
        }
        else if (argument == L"--retained-bytes") options.retainedBytes = Budget(value);
        else if (argument == L"--reservation-bytes") options.reservationBytes = Budget(value);
        else if (argument == L"--diagnostic-pair")
        {
            if (value != L"off" && value != L"on") Reject("HOST_DIAGNOSTIC_PAIR_INVALID");
            options.diagnosticPair = true; options.diagnosticObserver = value == L"on";
        }
        else if (argument == L"--guide-contract" && options.mode == RuntimeOptions::Mode::Warp)
        {
            if (value == L"missing") options.guideContract = RuntimeOptions::GuideContract::Missing;
            else if (value == L"foreign-device") options.guideContract = RuntimeOptions::GuideContract::ForeignDevice;
            else if (value == L"adapter-mismatch") options.guideContract = RuntimeOptions::GuideContract::AdapterMismatch;
            else Reject("HOST_ARGUMENT_INVALID");
        }
        else Reject("HOST_ARGUMENT_INVALID");
    }
    if (!options.task15Candidate && (options.runtimeCase || !options.finalCandidate.empty() ||
        !options.finalCandidateSha256.empty() || !options.qualifiedInputs.empty() ||
        !options.qualifiedInputsSha256.empty() || !options.driver.empty() || !options.driverSha256.empty() ||
        options.adapterLow || options.adapterHigh || options.retainedBytes || options.reservationBytes || options.diagnosticPair))
        Reject("HOST_CASE_MODE_REQUIRED");
    if (options.task15Candidate && !options.runtimeCase) Reject("HOST_RUNTIME_CASE_REQUIRED");
    if (options.task15Candidate && options.mode == RuntimeOptions::Mode::Warp) Reject("HOST_CASE_MODE_UNSUPPORTED");
    ValidateHostInputs(options);
    if (options.mode == RuntimeOptions::Mode::Warp) RunWarpHost(options);
    else if (options.mode == RuntimeOptions::Mode::Runtime) RunRuntimeHost(options);
    return 0;
}
}
