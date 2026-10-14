#define main CaptureScenarioMain
#include "nr_pipeline_capture_smoke.cpp"
#undef main
extern "C" __declspec(dllexport) int RunCaptureScenario(const char* scenario, const char* directory)
{
    char executable[] = "capture-dll";
    char* arguments[] { executable, const_cast<char*>(scenario), const_cast<char*>(directory) };
    return CaptureScenarioMain(3, arguments);
}
