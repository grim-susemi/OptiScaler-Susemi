#pragma once
// SDK types are real. Only provider/application services and CPU pixel storage
// are controlled here; no NVIDIA provider, COM resource or GPU is impersonated.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <nvsdk_ngx.h>
#include <vulkan/vulkan.h>
#include <nvsdk_ngx_vk.h>
#include <sl.h>
#include <map>
#include <variant>
#include <vector>
#include <array>
#include <memory>
#include <shared_mutex>
#include <thread>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <dlssnr/DlssNr_MfgObserverNgx.h>
#include <dlssnr/DlssNr_MfgObserverStreamline.h>
#include <dlssnr/DlssNr_NgxDiagnostics.h>
#include <dlssnr/DlssNr_StreamlinePicture.h>
#include <dlssnr/DlssNr_Placement.h>
#include <inputs/NgxFeatureRegistry.h>
inline void Require(bool value, const char* assertion)
{
    if (!value) { std::printf("ASSERTION_FAILED %s\n", assertion); std::exit(41); }
}
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
template<class T> struct Setting { T value {}; T value_or_default() const { return value; } };
struct Config
{
    Setting<bool> DLSSEnabled {true}, NvngxFGDisableHudless, DlssNrEnabled {true},
        DlssNrRunBeforeSr {true}, DlssNrDeferredDlss, DlssNrResidualAcrossRr, DlssNrFinishedPicture;
    Setting<float> FGHudCutoff;
    static Config* Instance() { static Config config; return &config; }
};
enum class FGNvngxReplacement { None, Other };
enum class FGInput { DLSSG, NvngxFG, FSRFG };
enum class GameQuirk { FSRFGHudlessMismatchFixup, CyberpunkHudlessState, Kcd2NrBeforeFg };
struct Quirks
{
    bool operator[](GameQuirk) const { return false; }
    bool operator&(GameQuirk) const { return false; }
};
struct TagSink
{
    unsigned calls = 0;
    void reportResource(const sl::ResourceTag&, ID3D12GraphicsCommandList*, uint32_t) { ++calls; }
};
struct State
{
    FGNvngxReplacement activeFgNvngx = FGNvngxReplacement::None;
    FGInput activeFgInput = FGInput::DLSSG;
    Quirks gameQuirks;
    ID3D12Device* currentD3D12Device = nullptr;
    int dlssgDetectedInterpolationCount = 0;
    bool isShuttingDown = false;
    TagSink slFGInputs;
    static State& Instance() { static State state; return state; }
};
// Exact production Parameter conversion operators, extracted and bound by the runner.
#include "observer-parameter.inc"
struct Params : NVSDK_NGX_Parameter
{
    using Value = std::variant<unsigned long long, float, double, unsigned int, int,
                               ID3D11Resource*, ID3D12Resource*, void*>;
    std::map<std::string, Value> values;
    std::map<std::string, Parameter> m_values;
    mutable std::mutex m_mutex;
    mutable std::map<std::string, unsigned> gets;
    template<class T> void setT(const char*, T&);
    template<class T> NVSDK_NGX_Result getT(const char*, T*) const;
#define PARAM(Type) \
    void Set(const char* key, Type value) override { values[key] = value; setT(key, value); } \
    NVSDK_NGX_Result Get(const char* key, Type* value) const override \
    { ++gets[key]; return getT(key, value); }
    PARAM(unsigned long long)
    PARAM(float)
    PARAM(double)
    PARAM(unsigned int)
    PARAM(int)
    PARAM(ID3D11Resource*)
    PARAM(ID3D12Resource*)
    PARAM(void*)
#undef PARAM
    void Reset() override { values.clear(); m_values.clear(); }
};
struct Pixels { std::array<uint32_t, 4> values {}; };
inline ID3D12Resource* PixelResource(Pixels& pixels) { return reinterpret_cast<ID3D12Resource*>(&pixels); }
inline unsigned evaluateCalls = 0;
inline std::vector<std::string> order;
inline ID3D12GraphicsCommandList* expectedCommands = reinterpret_cast<ID3D12GraphicsCommandList*>(0x100);
inline const NVSDK_NGX_Handle* expectedHandle = nullptr;
inline NVSDK_NGX_Parameter* expectedParameters = nullptr;
inline PFN_NVSDK_NGX_ProgressCallback expectedCallback = nullptr;
inline uint32_t expectedIndex = 7;
inline NVSDK_NGX_Result providerResult = NVSDK_NGX_Result_Success;
inline NVSDK_NGX_Result Provider(ID3D12GraphicsCommandList* commands, const NVSDK_NGX_Handle* handle,
                                  NVSDK_NGX_Parameter* parameters, PFN_NVSDK_NGX_ProgressCallback callback)
{
    Require(commands == expectedCommands && handle == expectedHandle && parameters == expectedParameters &&
            callback == expectedCallback, "T20_FORWARDED_ARGUMENT_IDENTITIES");
    uint32_t index = 0;
    Require(parameters->Get("DLSSG.MultiFrameIndex", &index) == NVSDK_NGX_Result_Success &&
            index == expectedIndex, "T20_FORWARDED_PARAMETERS");
    ++evaluateCalls;
    order.push_back("evaluate");
    ID3D12Resource* input = nullptr;
    ID3D12Resource* real = nullptr;
    ID3D12Resource* generated = nullptr;
    parameters->Get("DLSSG.Backbuffer", &input);
    parameters->Get("DLSSG.OutputReal", &real);
    parameters->Get("DLSSG.OutputInterpolated", &generated);
    if (input && real) *reinterpret_cast<Pixels*>(real) = *reinterpret_cast<Pixels*>(input);
    if (generated) reinterpret_cast<Pixels*>(generated)->values.fill(index + 100);
    return providerResult;
}
struct NVNGXProxy { static auto D3D12_EvaluateFeature() { return &Provider; }
    static std::wstring NVNGXModule_Path() { return L"fixture-dispatcher"; } };
namespace ReflexHooks { inline void setDlssgFrameCount(int) { order.push_back("reflex"); } }
enum class Upscaler { DLSSD, Other };
struct Feature { Upscaler GetUpscalerType() const { return Upscaler::Other; } };
struct Context { std::unique_ptr<Feature> feature; };
inline std::map<uint32_t, Context> Dx12Contexts;
inline NgxFeatureRegistry HandleToFeature;
inline constexpr uint32_t DLSS_MOD_ID_OFFSET = 1000, NVNGX_PROVIDER_ID_OFFSET = 2000;
inline NVSDK_NGX_Result TryEvaluateOptiFeature(ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*,
                                              NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback)
{ return NVSDK_NGX_Result_FAIL_FeatureNotFound; }
struct ProviderBoundary
{
    virtual ~ProviderBoundary() = default;
    virtual NVSDK_NGX_Result D3D12_EvaluateFeature(ID3D12GraphicsCommandList* commands,
        const NVSDK_NGX_Handle* handle, NVSDK_NGX_Parameter* parameters, PFN_NVSDK_NGX_ProgressCallback callback)
    { return Provider(commands, handle, parameters, callback); }
    virtual NVSDK_NGX_Result VULKAN_EvaluateFeature(VkCommandBuffer commands,
        const NVSDK_NGX_Handle* handle, NVSDK_NGX_Parameter* parameters, PFN_NVSDK_NGX_ProgressCallback callback)
    { return Provider(reinterpret_cast<ID3D12GraphicsCommandList*>(commands), handle, parameters, callback); }
};
struct HudCopy_Dx12
{
    HudCopy_Dx12(const char*, ID3D12Device*) {}
    bool IsInit() const { return false; }
    template<class... T> void Dispatch(T...) { Require(false, "T20_NO_FIXTURE_GPU_WORK"); }
};
struct HudCopy_Vk
{
    template<class... T> void Dispatch(T...) { Require(false, "T20_NO_FIXTURE_GPU_WORK"); }
    bool IsInit() const { return false; }
};
struct Nvngx_FG
{
    struct Nvngx_FG_Handle { uint32_t id; NVSDK_NGX_Handle* nativeHandle; std::shared_mutex handleMutex; };
    inline static ProviderBoundary boundary;
    inline static std::unique_ptr<HudCopy_Dx12> _hudCopyDx12;
    inline static std::unique_ptr<HudCopy_Vk> _hudCopyVk;
    static ProviderBoundary* getProvider() { return &boundary; }
    static NVSDK_NGX_Result D3D12_EvaluateFeature(ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*,
                                                  NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
    static NVSDK_NGX_Result VULKAN_EvaluateFeature(VkCommandBuffer, const NVSDK_NGX_Handle*,
                                                   NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
};
struct FfxResource { void* resource; uint32_t state; };
inline constexpr uint32_t FFX_API_RESOURCE_STATE_UNORDERED_ACCESS = 1, FFX_API_RESOURCE_STATE_COMPUTE_READ = 2;
inline FfxResource ffxApiGetResourceDX12(ID3D12Resource* resource, uint32_t state) { return {resource, state}; }
struct Nvngx_Combo
{
    struct Nvngx_Combo_Handle { uint32_t id; NVSDK_NGX_Handle* ffxHandle; NVSDK_NGX_Handle* artursHandle; };
    ProviderBoundary ffx, arturs;
    ProviderBoundary* ffxProvider = &ffx;
    ProviderBoundary* artursProvider = &arturs;
    void CopyTexture(ID3D12GraphicsCommandList*, const FfxResource* destination, const FfxResource* source)
    {
        order.push_back("copy-real");
        *static_cast<Pixels*>(destination->resource) = *static_cast<Pixels*>(source->resource);
    }
    NVSDK_NGX_Result D3D12_EvaluateFeature(ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*,
                                           NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
};
inline PFun_slEvaluateFeature* o_slEvaluateFeature = nullptr;
struct StreamlineHooks
{
    static sl::Result hkslEvaluateFeature(sl::Feature, const sl::FrameToken&,
                                         const sl::BaseStructure**, uint32_t, sl::CommandBuffer*);
};
inline std::recursive_mutex nrOwnersMutex;
inline std::atomic_uint nrCaptureOutstanding {0};
struct EntryDevice { LUID GetAdapterLuid() { return {17, 19}; } };
struct DlssNr_Dx12
{
    struct State
    {
        std::mutex mutex;
        unsigned pipelineCaptureRemaining = 0, featureFlags = 0, lastFinishedMode = 0;
        struct Late
        {
            DlssNr::FinishedIdentity consumer;
            Microsoft::WRL::ComPtr<IUnknown> consumerOwner;
            Microsoft::WRL::ComPtr<ID3D12Device> consumerDevice;
            void Cancel() {}
        } late;
        struct Deferred { void Cancel() {} } deferredSr;
        struct Nr { bool reset = false; } nr;
        struct Timing { void ClearLast() {} };
        std::unique_ptr<Timing> gpuTime, ngxTime;
        std::optional<double> lastGpuTime, lastNgxTime;
        void ConsumeControls() {}
        void Publish() {}
        void EvaluateInternal(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, ID3D12CommandQueue*,
                               bool, unsigned long long, bool) {}
    };
    std::unique_ptr<State> _state = std::make_unique<State>();
    EntryDevice device;
    EntryDevice* _device = &device;
    bool ProcessSeam(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, ID3D12CommandQueue*, bool,
                      unsigned long long, bool, uint32_t, const DlssNr::StreamlinePicture::ConsumerSnapshot&);
    void DiagnosePipeline(unsigned, ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, ID3D12Resource*,
                          uint32_t, bool, bool);
};
inline void ActivateNrOwner(DlssNr_Dx12*) {}
inline bool keyControl = true, keyF8 = true, keyF9 = false, focused = true;
inline HWND FixtureForeground() { return reinterpret_cast<HWND>(1); }
inline DWORD FixtureProcess(HWND, DWORD* process) { *process = GetCurrentProcessId() + (focused ? 0 : 1); return 1; }
inline SHORT FixtureKey(int key)
{ return (key == VK_CONTROL ? keyControl : key == VK_F8 ? keyF8 : keyF9) ? SHORT(-32768) : 0; }
inline void FixtureTime(SYSTEMTIME* time) { *time = {}; time->wYear = 2026; }
#define GetForegroundWindow FixtureForeground
#define GetWindowThreadProcessId FixtureProcess
#define GetAsyncKeyState FixtureKey
#define GetLocalTime FixtureTime
namespace Util
{
inline std::filesystem::path fixtureRoot;
inline std::filesystem::path DllPath() { return fixtureRoot / "fixture.dll"; }
inline bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; }
}
namespace MfgUnlock { inline TemporalMethod ConfiguredTemporalMethod() { return TemporalMethod::None; } }
namespace DlssNr::NgxDiagnostics
{
inline unsigned submissions = 0;
inline MfgQueueResult submittedResult = MfgQueueResult::Submitted;
inline MfgQueueResult EnqueueMfgPreflight(MfgPreflightRequest)
{ ++submissions; return submittedResult; }
}
namespace DlssNr
{
inline void SkipFinishedPicture(IDXGISwapChain*) {}
inline void ApplyToStreamlinePicture(IDXGISwapChain*, ID3D12Resource*, ID3D12CommandQueue*)
{ Require(false, "T20_NO_FIXTURE_COM_WORK"); }
}
