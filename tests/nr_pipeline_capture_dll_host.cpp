#include <windows.h>
#include <tlhelp32.h>
#include <cstdio>
#include <string>
static unsigned Threads()
{
    unsigned count = 0;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 entry {}; entry.dwSize = sizeof(entry);
    if (Thread32First(snapshot, &entry)) do
    {
        if (entry.th32OwnerProcessID == GetCurrentProcessId()) ++count;
    } while (Thread32Next(snapshot, &entry));
    CloseHandle(snapshot);
    return count;
}
int main(int argc, char** argv)
{
    if (argc != 4) return 2;
    const HMODULE module = LoadLibraryA(argv[1]);
    if (!module) { std::fprintf(stderr, "FAIL T21_DLL_LOAD %lu\n", GetLastError()); return 1; }
    using Run = int (*)(const char*, const char*);
    const auto run = reinterpret_cast<Run>(GetProcAddress(module, "RunCaptureScenario"));
    if (!run) { FreeLibrary(module); return 1; }
    DWORD before = 0, after = 0;
    GetProcessHandleCount(GetCurrentProcess(), &before);
    const auto threads = Threads();
    const int result = run(argv[2], argv[3]);
    GetProcessHandleCount(GetCurrentProcess(), &after);
    const auto remainingThreads = Threads();
    const BOOL released = FreeLibrary(module);
    const auto name = std::string(argv[1]).substr(std::string(argv[1]).find_last_of("/\\") + 1);
    const bool unloaded = GetModuleHandleA(name.c_str()) == nullptr;
    std::printf("T21_DLL result=%d handles=%lu/%lu threads=%u/%u released=%d unloaded=%d\n",
                result, before, after, threads, remainingThreads, released, unloaded);
    if (result || !released || !unloaded) return 1;
    if (std::string(argv[2]) == "cpu-readiness" && (before != after || threads != remainingThreads))
    { std::fprintf(stderr, "FAIL T21_DLL_OWNED_RESOURCE_CLOSURE\n"); return 1; }
    return 0;
}
