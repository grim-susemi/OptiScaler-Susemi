// Executes the original and patched callback with mock engine interfaces, never the game DLL.
#include <Windows.h>
#include <array>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
#define LOG_INFO(...) ((void)0)
#define LOG_WARN(...) ((void)0)
enum class GameQuirk { Kcd2DlssgHdr10 };
enum class FGOutput { NoFG, DLSSG };
enum class FGNvngxReplacement { None, Other };
struct Quirks { bool enabled = false; bool operator[](GameQuirk) const { return enabled; } };
struct State
{
    Quirks gameQuirks;
    FGOutput activeFgOutput = FGOutput::NoFG;
    FGNvngxReplacement activeFgNvngx = FGNvngxReplacement::None;
    static State& Instance() { static State state; return state; }
};
HMODULE testModule = nullptr;
unsigned moduleQueries = 0;
HMODULE TestGetModuleHandle(LPCWSTR) { ++moduleQueries; return testModule; }
#define GetModuleHandleW TestGetModuleHandle
#include "../../OptiScaler/framegen/dlssg/Kcd2Hdr.cpp"
#undef GetModuleHandleW

void Expect(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}
struct Cvar { void** table; int value; unsigned writes = 0; };
std::array<void*, 24> cvarTable {}, consoleTable {}, rendererTable {};
Cvar pipeline { cvarTable.data(), 2 }, hdr { cvarTable.data(), 1 };
bool supported = true, haveRenderer = true, havePipeline = true;
void* renderer = rendererTable.data();
int GetInt(Cvar* var) { return var->value; }
void SetInt(Cvar* var, int value) { var->value = value; ++var->writes; }
void* FindCvar(void*, const char* name)
{
    Expect(std::strcmp(name, "r_HDRPipeline") == 0, "Callback looked up unexpected CVar");
    return havePipeline ? &pipeline : nullptr;
}
void* GetService(void*) { return haveRenderer ? &renderer : nullptr; }
bool SupportsHdr(void*) { return supported; }

void Jump(unsigned char* at, void* target)
{
    // mov rax,target; jmp rax. Stub only the callback's two external service lookups.
    at[0] = 0x48; at[1] = 0xb8;
    std::memcpy(at + 2, &target, 8);
    at[10] = 0xff; at[11] = 0xe0;
}

int wmain(int argc, wchar_t** argv) try
{
    Expect(argc == 2, "Pass WHGame.dll for an independent signature check");
    // Read disk bytes as data. Verify the production signature against the installed build.
    std::ifstream file(argv[1], std::ios::binary);
    std::vector<unsigned char> disk((std::istreambuf_iterator<char>(file)), {});
    Expect(disk.size() > sizeof(IMAGE_DOS_HEADER), "Game DLL could not be read");
    auto* fileDos = reinterpret_cast<IMAGE_DOS_HEADER*>(disk.data());
    auto* fileNt = reinterpret_cast<IMAGE_NT_HEADERS64*>(disk.data() + fileDos->e_lfanew);
    Expect(fileNt->FileHeader.TimeDateStamp == kTimestamp && fileNt->OptionalHeader.SizeOfImage == kImageSize,
           "Installed game build differs from validated build");
    auto* sections = IMAGE_FIRST_SECTION(fileNt);
    const unsigned char* actual = nullptr;
    for (unsigned i = 0; i < fileNt->FileHeader.NumberOfSections; ++i)
        if (kCallbackRva >= sections[i].VirtualAddress &&
            kCallbackRva + sizeof(kCallback) <= sections[i].VirtualAddress + sections[i].SizeOfRawData)
            actual = disk.data() + sections[i].PointerToRawData + kCallbackRva - sections[i].VirtualAddress;
    Expect(actual && !std::memcmp(actual, kCallback, sizeof(kCallback)), "Installed callback signature mismatch");

    auto* image = static_cast<unsigned char*>(VirtualAlloc(nullptr, kImageSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    Expect(image != nullptr, "Test image allocation failed");
    testModule = reinterpret_cast<HMODULE>(image);
    std::memcpy(image, disk.data(), fileNt->OptionalHeader.SizeOfHeaders);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(image + fileDos->e_lfanew);
    std::memcpy(image + kCallbackRva, actual, sizeof(kCallback));
    std::strcpy(reinterpret_cast<char*>(image + 0x3dd4c08), "r_HDRPipeline");
    cvarTable[0x10 / 8] = reinterpret_cast<void*>(&GetInt);
    cvarTable[0x38 / 8] = reinterpret_cast<void*>(&SetInt);
    consoleTable[0xb8 / 8] = reinterpret_cast<void*>(&FindCvar);
    rendererTable[0x40 / 8] = reinterpret_cast<void*>(&SupportsHdr);
    void* console = consoleTable.data();
    *reinterpret_cast<void**>(image + 0x492d8a8) = &console;
    Jump(image + 0x4e8bb0, reinterpret_cast<void*>(&GetService));
    Jump(image + 0x8612dc, reinterpret_cast<void*>(&GetService));
    DWORD old = 0;
    for (auto rva : { kCallbackRva, DWORD(0x4e8bb0), DWORD(0x8612dc) })
        Expect(VirtualProtect(image + rva, 256, PAGE_EXECUTE_READ, &old) != 0, "Test code protection failed");
    FlushInstructionCache(GetCurrentProcess(), image, kImageSize);
    auto callback = reinterpret_cast<void(*)(Cvar*)>(image + kCallbackRva);
    callback(&hdr);
    Expect(pipeline.value == 1, "Original callback must reproduce the scRGB override");

    // Rejected images stay untouched, including when another mod already changed this instruction.
    ++nt->FileHeader.TimeDateStamp;
    Expect(!PatchCallback(testModule), "Unknown game build accepted");
    --nt->FileHeader.TimeDateStamp;
    --nt->OptionalHeader.SizeOfImage;
    Expect(!PatchCallback(testModule), "Unknown image size accepted");
    ++nt->OptionalHeader.SizeOfImage;
    VirtualProtect(image + kCallbackRva, sizeof(kCallback), PAGE_EXECUTE_READWRITE, &old);
    image[kCallbackRva] ^= 1;
    Expect(!PatchCallback(testModule), "Modified callback accepted");
    image[kCallbackRva] ^= 1;
    VirtualProtect(image + kCallbackRva, sizeof(kCallback), PAGE_EXECUTE_READ, &old);

    auto& state = State::Instance();
    state.activeFgOutput = FGOutput::DLSSG;
    Kcd2Hdr::ApplyQuirk();
    state.gameQuirks.enabled = true; state.activeFgOutput = FGOutput::NoFG;
    Kcd2Hdr::ApplyQuirk();
    state.activeFgOutput = FGOutput::DLSSG; state.activeFgNvngx = FGNvngxReplacement::Other;
    Kcd2Hdr::ApplyQuirk();
    Expect(moduleQueries == 0, "Quirk touched another game/backend");
    state.activeFgNvngx = FGNvngxReplacement::None;
    Kcd2Hdr::ApplyQuirk();
    for (size_t i = 0; i < sizeof(kCallback); ++i)
        Expect(image[kCallbackRva + i] == (i == kSelectionOffset ? 2 : kCallback[i]), "Patch changed unexpected bytes");
    MEMORY_BASIC_INFORMATION memory {};
    VirtualQuery(image + kCallbackRva, &memory, sizeof(memory));
    Expect(memory.Protect == PAGE_EXECUTE_READ, "Patch left code writable");
    Kcd2Hdr::ApplyQuirk(); // Repeated swapchain creation does not modify it again.

    for (bool available : { false, true })
        for (bool support : { false, true })
            for (int enabled : { 0, 1 })
            {
                haveRenderer = available; supported = support;
                hdr.value = enabled; pipeline.value = 1; pipeline.writes = 0;
                callback(&hdr);
                const bool on = available && support && enabled;
                Expect(pipeline.value == (on ? 2 : -1), "Patched HDR selection incorrect");
                Expect(hdr.value == (on ? 1 : 0) && pipeline.writes == 1, "HDR-off/support behavior changed");
            }
    havePipeline = false; pipeline.writes = 0;
    callback(&hdr);
    Expect(pipeline.writes == 0, "Missing CVar behavior changed");
    VirtualFree(image, 0, MEM_RELEASE);
    std::cout << "PASS: real callback signature; original override; HDR10/on/off/support; quirk/backend guards; "
                 "unknown/modified builds rejected; one-byte patch; page protection restored; repeated initialization\n";
    return 0;
}
catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
