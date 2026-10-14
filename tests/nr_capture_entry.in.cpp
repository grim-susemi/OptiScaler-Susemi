#include <nvsdk_ngx.h>
#include <atomic>
#include <bit>
#include <cstdio>
#include <cstring>
#include <thread>
#include <stdexcept>
#define PipelineCaptureSession CaptureWorkerSession
#include <dlssnr/DlssNr_PipelineCapture.h>
#undef PipelineCaptureSession
static void require(bool value, const char* id) { if (!value) throw std::runtime_error(id); }
struct BoolOption { bool value = false; bool value_or_default() const { return value; } };
struct Config { BoolOption DlssNrEnabled; static Config* Instance() { static Config value; return &value; } };
namespace Util { inline std::filesystem::path path; inline auto DllPath() { return path; } }
static bool focused = true, controlDown = false, f8 = false, f9 = false;
static HWND Foreground() { return reinterpret_cast<HWND>(1); }
static DWORD ForegroundProcess(HWND, DWORD* id) { *id = GetCurrentProcessId() + !focused; return 1; }
static SHORT Key(int key) { return (key == VK_CONTROL ? controlDown : key == VK_F8 ? f8 : key == VK_F9 ? f9 : false) ? SHORT(-32768) : 0; }
#define GetForegroundWindow Foreground
#define GetWindowThreadProcessId ForegroundProcess
#define GetAsyncKeyState Key
namespace DlssNr
{
struct Consumer { const void* consumer = reinterpret_cast<void*>(2); uint64_t generation = 3, application = 1; bool applicationKnown = true; };
namespace MfgObserver
{
inline unsigned begins = 0, stops = 0, observations = 0;
inline void Begin(const void*, unsigned) { ++begins; }
inline void Stop(const void*) { ++stops; }
inline void Nr(const void*, const Consumer&, unsigned, ID3D12Resource*) { ++observations; }
}
namespace NgxDiagnostics
{
struct Request { LUID adapter; std::filesystem::path directory; std::string label; unsigned run; };
enum class MfgQueueResult { Submitted };
inline std::vector<Request> requests;
inline Request CopyMfgRequest(LUID adapter, std::filesystem::path directory, const char* label, unsigned run)
{ return { adapter, std::move(directory), label, run }; }
inline MfgQueueResult EnqueueMfgPreflight(Request request) { requests.push_back(std::move(request)); return MfgQueueResult::Submitted; }
}
class PipelineCaptureSession
{
  public:
    inline static bool active = false;
    bool canceled = false;
    std::filesystem::path directory;
    std::shared_ptr<CaptureBudget> budget = std::make_shared<CaptureBudget>();
    static bool Busy() { return active; }
    static std::shared_ptr<PipelineCaptureSession> Begin(const std::filesystem::path& directory)
    {
        active = true;
        auto value = std::make_shared<PipelineCaptureSession>(); value->directory = directory; return value;
    }
    void Cancel() { canceled = true; active = false; }
    std::shared_ptr<PipelineCaptureFrame> Admit(const CaptureIdentity& identity, GpuLifetime&, ID3D12GraphicsCommandList*)
    {
        if (canceled) return {};
        auto value = std::make_shared<PipelineCaptureFrame>(); value->identity = identity; value->budget = budget;
        value->directory = directory / "frame-0"; value->completion = std::make_shared<CaptureCompletion>(); return value;
    }
};
}
static std::recursive_mutex nrOwnersMutex;
static std::atomic_uint nrCaptureOutstanding { 0 };
struct EntryState
{
    std::mutex mutex;
    unsigned pipelineCaptureRemaining = 0;
    struct Late { DlssNr::Consumer consumer; } late;
    DlssNr::GpuLifetime lifetime;
    std::shared_ptr<DlssNr::PipelineCaptureSession> pipelineSession;
    std::shared_ptr<DlssNr::PipelineCaptureFrame> pipelineCapture;
    std::filesystem::path pipelineCaptureDirectory;
};
struct DeviceIdentity { LUID GetAdapterLuid() { return { 17, 19 }; } };
struct DlssNr_Dx12
{
    std::unique_ptr<EntryState> _state = std::make_unique<EntryState>();
    DeviceIdentity identity;
    DeviceIdentity* _device = &identity;
    void DiagnosePipeline(unsigned, ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, ID3D12Resource*, uint32_t, bool, bool);
};
@PRODUCTION_ENTRY@
struct Parameters final : NVSDK_NGX_Parameter
{
    mutable unsigned floatReads = 0, resourceReads = 0;
    unsigned writes = 0;
    bool succeeds = true;
    uint32_t raw = 0x7fc12345;
    ID3D12Resource* resource = reinterpret_cast<ID3D12Resource*>(uintptr_t(0xfeed));
#define SET(T) void Set(const char*, T) override { ++writes; }
    SET(unsigned long long) SET(float) SET(double) SET(unsigned int) SET(int)
    SET(ID3D11Resource*) SET(ID3D12Resource*) SET(void*)
#undef SET
#define GET(T) NVSDK_NGX_Result Get(const char*, T*) const override { return NVSDK_NGX_Result_FAIL_InvalidParameter; }
    GET(unsigned long long) GET(double) GET(unsigned int) GET(int) GET(ID3D11Resource*) GET(void*)
#undef GET
    NVSDK_NGX_Result Get(const char* name, float* value) const override
    { require(!std::strcmp(name, NVSDK_NGX_Parameter_DLSS_Pre_Exposure), "T21_RAW_PARAMETER_NAME"); ++floatReads;
      *value = std::bit_cast<float>(raw); return succeeds ? NVSDK_NGX_Result_Success : NVSDK_NGX_Result_FAIL_InvalidParameter; }
    NVSDK_NGX_Result Get(const char* name, ID3D12Resource** value) const override
    { require(!std::strcmp(name, NVSDK_NGX_Parameter_ExposureTexture), "T21_EXPOSURE_PARAMETER_NAME"); ++resourceReads;
      *value = resource; return succeeds ? NVSDK_NGX_Result_Success : NVSDK_NGX_Result_FAIL_InvalidParameter; }
    void Reset() override { ++writes; }
};
struct CpuFence final : ID3D12Fence
{
    std::atomic_ulong refs { 1 };
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override
    { if (!value) return E_POINTER; *value = nullptr; if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12Fence)) return E_NOINTERFACE;
      *value = static_cast<ID3D12Fence*>(this); AddRef(); return S_OK; }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { auto count = --refs; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void**) override { return E_NOTIMPL; }
    UINT64 STDMETHODCALLTYPE GetCompletedValue() override { return 1; }
    HRESULT STDMETHODCALLTYPE SetEventOnCompletion(UINT64, HANDLE) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Signal(UINT64) override { return E_NOTIMPL; }
};
static void RunObservation(const std::shared_ptr<DlssNr::PipelineCaptureFrame>& pipelineCapture)
{
    struct Frame { float PreExposure = 1; void* ExposureTexture = reinterpret_cast<void*>(uintptr_t(0xbaad)); unsigned ExposureState = 73; } frame;
    struct Encoded { struct Constants { unsigned ExposureMode = 2; } exposureConstants; } encoded;
    ID3D12GraphicsCommandList* cmdList = nullptr;
    ID3D12Device* device = nullptr;
    ID3D12Resource* modelInput = nullptr; ID3D12Resource* depthIn = nullptr; ID3D12Resource* motionIn = nullptr;
    struct Nr { ID3D12Resource* depthClone = nullptr; ID3D12Resource* motionClone = nullptr; } nr;
@PRODUCTION_RUN_OBSERVATION@
}
int main(int argc, char** argv) try
{
    require(argc == 2, "T21_ENTRY_ARGUMENTS");
    const std::filesystem::path root = argv[1]; Util::path = root / "fixture.dll";
    DlssNr_Dx12 owner; Parameters parameters;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    require(DlssNr::NgxDiagnostics::requests.empty() && !owner._state->pipelineCapture && !parameters.floatReads,
            "T21_DISABLED_NO_CAPTURE_OR_PARAMETER_READ");
    Config::Instance()->DlssNrEnabled.value = true;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    require(DlssNr::NgxDiagnostics::requests.empty() && !owner._state->pipelineSession, "T21_NO_SHORTCUT_DEFAULT_OFF");
    controlDown = f8 = true; focused = false;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    require(DlssNr::NgxDiagnostics::requests.empty(), "T21_UNFOCUSED_NO_CAPTURE"); focused = true;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    auto captured = owner._state->pipelineCapture;
    require(captured && captured->preExposureReadAttempted && captured->preExposureReadSucceeded &&
            captured->preExposureBits == parameters.raw && captured->exposureReadSucceeded &&
            captured->images[3].provenance == uintptr_t(parameters.resource), "T21_RAW_EXPOSURE_EXACT_BITS_SUCCESS");
    require(parameters.floatReads == 1 && parameters.resourceReads == 1 && !parameters.writes,
            "T21_OBSERVATION_READ_ONLY_EXACT_CALLS");
    RunObservation(captured);
    require(captured->preExposureBits == parameters.raw && captured->resolvedPreExposureBits == std::bit_cast<uint32_t>(1.f) &&
            captured->exposureStateRaw == 73 && captured->exposureMode == 2 && captured->exposureResource == 0xbaad,
            "T21_RAW_AND_RESOLVED_PROVENANCE_DISTINCT");
    owner.DiagnosePipeline(2, nullptr, &parameters, parameters.resource, 0, false, false);
    require(captured->sealed && !owner._state->pipelineCapture, "T21_STAGE_TWO_SEAL");
    auto point = std::make_shared<DlssNr::CaptureCompletion::Point>(); point->resolved = true;
    point->fence.Attach(new CpuFence); captured->completion->points[captured->completion->count++] = point;
    captured->completion->Close();
    require(!captured->Write(), "T21_ENTRY_THREAD_CANNOT_WRITE");
    bool wrote = false;
    std::thread writer([&] { require(WaitForSingleObject(captured->completion->event, 10000) == WAIT_OBJECT_0,
                                     "T21_SCHEMA_WORKER_EVENT"); captured->workerThread = GetCurrentThreadId(); wrote = captured->Write(); });
    writer.join(); require(wrote && captured->writeThread != GetCurrentThreadId(), "T21_SCHEMA_OWNED_WRITER");
    std::ifstream input(captured->directory / "capture.json");
    std::string json((std::istreambuf_iterator<char>(input)), {});
    require(json.find("\"preExposureRawBits\":" + std::to_string(parameters.raw)) != std::string::npos &&
            json.find("\"resolvedPreExposureBits\":1065353216") != std::string::npos &&
            json.find("\"phaseKnown\":false") != std::string::npos &&
            json.find("\"displayTimingAvailable\":false") != std::string::npos &&
            json.find("\"imageAvailable\":true") == std::string::npos, "T21_SHARED_SCHEMA_NO_FABRICATED_IMAGE_OR_PHASE");
    Config::Instance()->DlssNrEnabled.value = false;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    Config::Instance()->DlssNrEnabled.value = true; controlDown = f8 = false;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    controlDown = f9 = true; parameters.succeeds = false;
    owner.DiagnosePipeline(0, nullptr, &parameters, parameters.resource, 0, false, false);
    auto failed = owner._state->pipelineCapture;
    require(failed && failed->preExposureReadAttempted && !failed->preExposureReadSucceeded &&
            failed->preExposureBits == 0 && !failed->exposureReadSucceeded, "T21_FAILED_READ_NOT_REPORTED_RAW");
    require(DlssNr::NgxDiagnostics::requests.size() == 2 && DlssNr::NgxDiagnostics::requests[0].label == "gameplay" &&
            DlssNr::NgxDiagnostics::requests[1].label == "photomode" && !parameters.writes,
            "T21_EXISTING_F8_F9_ENTRY_ONLY");
    require(captured->budget->inFlight == 0 && failed->budget->inFlight == 0, "T21_UNKNOWN_STATE_ZERO_GPU_ALLOCATION");
    owner._state->pipelineCapture.reset(); owner._state->pipelineSession->Cancel(); owner._state->pipelineSession.reset();
    captured.reset(); failed.reset(); point.reset();
    std::puts("PASS current entry and Run observation bodies/raw-read-success-failure/schema; typed admission/input/fence services; metadata only/GPU0/feature incomplete");
    return 0;
}
catch (const std::exception& error) { std::fprintf(stderr, "FAIL %s\n", error.what()); return 1; }
