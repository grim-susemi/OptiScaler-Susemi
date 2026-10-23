// Actual Run, finished composer, publisher and Present bodies, extracted by the
// scoped runner. Only model/initialization services are adapters. WARP executes
// owned lists and shipped finished-color bytecode; no NVIDIA/game claim.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include "../OptiScaler/dlssnr/DlssNr_Status.h"
#include "../OptiScaler/dlssnr/DlssNr_StreamlinePicture.h"
#include "../OptiScaler/dlssnr/DlssNr_FinishedReady.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_Guides.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_SeamClock.h"
#include "../OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.h"

using Microsoft::WRL::ComPtr;
static void Check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("T5_D3D12"); }
static void Expect(bool value, const char* assertion) { if (!value) throw std::runtime_error(assertion); }
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#ifdef T5_DEFERRED_R1
#include "nr_deferred_outcome_support.h"
#else
constexpr int NVSDK_NGX_Result_Success = 1;
#endif
template <class T> struct Setting
{
    T stored {};
    T value_or_default() const { return stored; }
    T value() const { return stored; }
    bool has_value() const { return false; }
    T value_or(T fallback) const { return has_value() ? stored : fallback; }
};
class Config
{
  public:
    Setting<bool> DlssNrEnabled { true }, DlssNrFinishedPicture { true }, DlssNrApplyModel { true };
    Setting<bool> DlssNrRunBeforeSr, DlssNrDeferredDlss, DlssNrResidualAcrossRr, DlssNrHoldFrame, DlssNrHdrTransfer;
    Setting<bool> RestoreComputeSignature, RestoreGraphicSignature, DlssNrUnlockPasses;
    Setting<unsigned> ColorResourceBarrier, OutputResourceBarrier, DlssNrTransfer, DlssNrPasses { 1 };
    Setting<float> DlssNrWorkingScale { 1 }, DlssNrMaxRatio { 8 };
#ifdef T5_DEFERRED_R1
    Setting<unsigned> DlssNrDebugView, DlssNrCompare, DlssNrPrivateUpscaler, ExposureResourceBarrier;
    Setting<bool> DlssNrShowSkinMask;
    Setting<float> DlssNrResidualAcrossRrBlend { .08f }, DlssNrResidualConfidenceSensitivity;
    Setting<float> FsrCameraNear { .1f }, FsrCameraFar { 1000 }, FsrVerticalFov, FsrHorizontalFov;
#endif
    static Config* Instance() { static Config c; return &c; }
};
enum class API { DX11, DX12 };
enum class SwapchainInteropApi { None, Dx11wDx12 };
enum class GameQuirk { Kcd2NrBeforeFg };
enum class FGNvngxReplacement { None };
struct Fg { bool IsActive() const { return false; } bool IsPaused() const { return false; } };
struct State
{
    struct Quirks { bool operator[](GameQuirk) const { return false; } } gameQuirks;
    FGNvngxReplacement activeFgNvngx = FGNvngxReplacement::None;
    bool isShuttingDown = false;
    API swapchainApi = API::DX12;
    SwapchainInteropApi swapchainInteropApi = SwapchainInteropApi::None;
    uint64_t frameCount = 100;
    Fg* currentFG = nullptr;
#ifdef T5_DEFERRED_R1
    ID3D12CommandQueue* currentCommandQueue = nullptr;
#endif
    static State& Instance() { static State s; return s; }
};
namespace Util
{
bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; }
std::filesystem::path DllPath() { throw std::runtime_error("T5_PRESENT_FILE_IO"); }
}
namespace D3D12Hooks { bool CanRestoreRootSignature(ID3D12GraphicsCommandList*) { return true; } }
namespace ResTrack_Dx12 { void HookLateNrQueue(ID3D12Device*) {} }
namespace NVNGXProxy { bool IsDx12Inited() { return true; } bool InitDx12(ID3D12Device*) { return true; } }
namespace DlssNr
{
constexpr unsigned MaxPassCount = 2, DefaultMaxPassCount = 2;
struct XeFGCapture
{
    bool exists = false, submitted = false, sameQueue = false, ready = false;
    uint64_t serial = 0;
    FinishedIdentity identity;
};
namespace Proxy
{
struct Frame
{
    ID3D12Resource *color = nullptr, *output = nullptr, *depth = nullptr, *motion = nullptr;
    GuideExtent size {};
    GuideRegions guides {};
    bool depthInverted = false, reset = false;
    float mvScaleX = 0, mvScaleY = 0;
};
struct Context { static bool Available() { return true; } };
}
void ApplyToStreamlinePicture(IDXGISwapChain*, ID3D12Resource*, ID3D12CommandQueue*);
void SkipFinishedPicture(IDXGISwapChain*);
}
static int PassSettings(const Config&, unsigned) { return 0; }
struct LifetimeService
{
    void Record(ID3D12CommandList*) {}
    void Collect() {}
    void ResetRecording(ID3D12CommandList*) {}
    void Submitted(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*) {}
#ifdef T5_DEFERRED_R1
    void BeginGeneration() {}
    template <class F> void Retire(F f) { f(); } // called only after owned tail completion
#endif
};
struct CaptureService : LifetimeService
{
    bool isActive() const { return false; }
    std::string write(const std::filesystem::path&) { throw std::runtime_error("T5_PRESENT_FILE_IO"); }
    void record(ID3D12GraphicsCommandList*, ID3D12Device*, ID3D12Resource*, D3D12_RESOURCE_STATES,
                ID3D12Resource*, D3D12_RESOURCE_STATES) {}
};
struct DlssNrGpuTime : LifetimeService
{
    explicit DlssNrGpuTime(ID3D12Device*) {}
    void Start(ID3D12GraphicsCommandList*) {}
    void End(ID3D12GraphicsCommandList*) {}
    void ClearLast() {}
};
struct ModelService : LifetimeService
{
    unsigned evaluations = 0;
    bool ready = true, fail = false;
    void Collect() {}
    bool Ready(uint64_t) const { return ready; }
    int Run(ID3D12GraphicsCommandList*, ID3D12Device*, const DlssNr::Proxy::Frame&, int, uint64_t, bool* evaluated)
    {
        ++evaluations;
        *evaluated = ready;
        return fail ? 0 : NVSDK_NGX_Result_Success;
    }
};
struct ScalerService { bool DispatchResources(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*) { return false; } };
struct Dx11FinishedPictureBridge {};
struct NVSDK_NGX_Parameter;
static bool injectClose = false, injectSignal = false, injectFinalEncode = false, injectCompose = false, injectResidual = false;
static unsigned closeCalls = 0, signalCalls = 0;
static HRESULT ComposeClose(ID3D12GraphicsCommandList* cmd)
{
    ++closeCalls;
    const auto hr = cmd->Close();
    return injectClose && SUCCEEDED(hr) ? E_FAIL : hr;
}
static HRESULT ComposeSignal(ID3D12CommandQueue* queue, ID3D12Fence* fence, uint64_t value)
{
    ++signalCalls;
    return injectSignal ? E_FAIL : queue->Signal(fence, value);
}
static HRESULT ProducerSignal(ID3D12CommandQueue* queue, ID3D12Fence* fence, uint64_t value)
{ return injectSignal ? E_FAIL : queue->Signal(fence, value); }

class DlssNr_Dx12
{
  public:
    struct State
    {
        DlssNr_Dx12& shader;
        std::recursive_mutex mutex;
        DlssNr::OutputStatus outputStatus;
        ID3D12CommandList* outputCommands = nullptr;
        struct Nr
        {
            uint64_t successfulDispatches = 0;
            bool failed = false, reset = true, heldActive = false;
            const char* reason = "";
            ModelService models[2];
            ID3D12Resource *activeColor = nullptr, *output = nullptr, *hdrCopy = nullptr, *colorCopy = nullptr,
                *passScratch = nullptr, *passClamp = nullptr, *outputNative = nullptr, *depthClone = nullptr,
                *motionClone = nullptr, *colorSmall = nullptr;
            ScalerService* superDown = nullptr;
        } nr;
        struct Enlarger
        {
            ComPtr<ID3D12Resource> input;
            LifetimeService lifetime;
            bool submitted = false, failed = false;
            ID3D12CommandList* creation = nullptr;
            ComPtr<ID3D12CommandQueue> queue;
        };
        std::unique_ptr<Enlarger> enlarger;
        std::vector<std::unique_ptr<Enlarger>> retiredEnlargers;
        std::string enlargementStatus;
        DlssNrReconstruction reconstruction;
        std::set<std::string> seen;
        LifetimeService lifetime;
        CaptureService captureFrames;
        std::unique_ptr<DlssNrGpuTime> gpuTime, ngxTime;
        std::optional<double> lastGpuTime;
        std::optional<double> lastNgxTime;
        unsigned lastFinishedMode = 0;
        DlssNrSeamClock seamClock;
#ifdef T5_DEFERRED_R1
#include "deferred_context.inc"
        DeferredSrContext deferredSr { *this };
        unsigned featureFlags = 0;
        ID3D12Resource* GetResource(NVSDK_NGX_Parameter* p, const char* key, const char*)
        { return GetUpscalerResource_Dx12(p, key); }
#else
        struct DeferredService
        {
            LifetimeService lifetime;
            void Cancel() {}
            void Before(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, uint64_t, uint64_t, ID3D12CommandQueue*, bool, bool) {}
            void After(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, uint64_t) {}
        } deferredSr;
#endif
        unsigned long long frames = 0, resets = 0;
        unsigned loggedConfigured = 0, loggedEffective = 0, lastSuper = 0;
        bool reportedHdr = false, reportedHdrValue = false, reportedBefore = false, modelRunning = false;
        struct GuideReport
        {
            bool valid, inverted;
            float x, y;
            unsigned gw, gh, w, h;
            bool operator==(const GuideReport&) const = default;
        } loggedGuides {};
        struct ScopedNrStateEnvelope { explicit ScopedNrStateEnvelope(ID3D12GraphicsCommandList*) {} };
        struct Hold
        {
            bool active = false;
            uint64_t generation = 0;
            ID3D12CommandList* captureCommands = nullptr;
        } inputHold;
#include "finished_context.inc"
        LateContext late { *this };
        std::vector<ComPtr<ID3D12Resource>> resources;
        explicit State(DlssNr_Dx12& s) : shader(s) {}
        void ConsumeControls() {}
        void CollectEnlargers() {}
        void Publish();
        void ReportSkipOnce(const char*);
        void ReleaseEnlarger() { enlarger.reset(); }
        bool allowCaptureTrigger = false;
        void CheckCaptureTrigger() { if (!allowCaptureTrigger) throw std::runtime_error("T5_PRESENT_FILE_IO"); }
        void EndGpuTiming(ID3D12GraphicsCommandList*) {}
        const char* NgxResultName(unsigned) { return "fixture"; }
        static bool SameHoldShape(const D3D12_RESOURCE_DESC& a, const D3D12_RESOURCE_DESC& b)
        { return a.Width == b.Width && a.Height == b.Height && a.Format == b.Format; }
        static void Barrier(ID3D12GraphicsCommandList* cmd, ID3D12Resource* r,
                            D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to)
        {
            if (from == to) return;
            D3D12_RESOURCE_BARRIER b {}; b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            b.Transition = { r, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, from, to }; cmd->ResourceBarrier(1, &b);
        }
        ID3D12Resource* CreateScratch(ID3D12Device* device, DXGI_FORMAT format, unsigned w, unsigned h)
        {
            D3D12_RESOURCE_DESC d {}; d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
            d.Width = w; d.Height = h; d.DepthOrArraySize = d.MipLevels = 1; d.SampleDesc.Count = 1;
            d.Format = format; d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
            D3D12_HEAP_PROPERTIES heap {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
            ID3D12Resource* result = nullptr;
            Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &d,
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&result)));
            return result;
        }
        ID3D12Resource* ReadableGuide(ID3D12Device*, ID3D12GraphicsCommandList*, ID3D12Resource* r, ID3D12Resource**) { return r; }
        bool PrepareRunModels(ID3D12GraphicsCommandList*, ID3D12Device* d, const DlssNrFrameInfo&,
                              const D3D12_RESOURCE_DESC& desc, DlssNr::ColorExtent, DlssNr::ColorExtent, float, unsigned)
        {
            if (!nr.output)
                for (auto** r : { &nr.output, &nr.hdrCopy, &nr.colorCopy })
                {
                    ComPtr<ID3D12Resource> owned;
                    owned.Attach(CreateScratch(d, desc.Format, unsigned(desc.Width), desc.Height));
                    *r = owned.Get(); resources.push_back(owned);
                }
            return true;
        }
        struct EncodeContext
        {
            ID3D12GraphicsCommandList* cmdList;
            ID3D12Device* device;
            ID3D12Resource* target;
            D3D12_RESOURCE_STATES targetState;
            const DlssNrFrameInfo& frame;
            float workScale;
            bool targetSupportsUav;
            float whitePoint = 1;
            ID3D12Resource* modelInput = nullptr;
            ID3D12Resource* exposure = nullptr;
        };
        void EncodeInput(EncodeContext& c)
        {
            c.modelInput = nr.colorCopy;
            Barrier(c.cmdList, nr.colorCopy, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(c.cmdList, nr.hdrCopy, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        }
        DlssNrConstants MakeResolveConstants(const EncodeContext& c, unsigned)
        {
            DlssNrConstants p {}; p.Width = unsigned(c.target->GetDesc().Width); p.Height = c.target->GetDesc().Height;
            p.ApplyModel = Config::Instance()->DlssNrApplyModel.value_or_default(); return p;
        }
        ID3D12Resource* EnlargeMatchedResidual(ID3D12GraphicsCommandList*, ID3D12Device*, ID3D12Resource*, ID3D12Resource*,
            ID3D12Resource*, ID3D12Resource*, const DlssNrFrameInfo&, const DlssNrConstants&, bool, ID3D12CommandQueue*) { return nullptr; }
        bool AdmitFinishedCapture(ID3D12Resource*, ID3D12CommandQueue*, const DlssNr::FinishedIdentity&, DlssNr::XeFGCapture&, bool, uint64_t = 0);
        bool ApplyFinishedColor(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, bool = false,
                                const DlssNr::FinishedIdentity& = {}, uint64_t = 0);
        void Run(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, ID3D12Resource*,
                 const DlssNrFrameInfo&, ID3D12CommandQueue*);
        void EvaluateInternal(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, ID3D12CommandQueue*, bool, uint64_t, bool);
        void FinishedPictureResetCommandList(ID3D12CommandList*);
        void FinishedPictureSubmitted(DlssNr::LatePromiseBatch&, DlssNr_Dx12*, ID3D12CommandQueue*, UINT,
                                      ID3D12CommandList* const*);
    };
    std::unique_ptr<State> _state = std::make_unique<State>(*this);
    std::vector<ComPtr<ID3D12DescriptorHeap>> heaps;
    std::vector<ComPtr<ID3D12Resource>> constants;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    bool IsInit() const { return true; }
#ifdef T5_DEFERRED_R1
    DlssNr_Dx12() = default;
    DlssNr_Dx12(const char*, ID3D12Device*) {}
    static void Retire(std::unique_ptr<DlssNr_Dx12> s) { s.reset(); }
#endif
    bool ApplyFinished(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, bool = false,
                       const DlssNr::FinishedIdentity& = {}, uint64_t = 0);
    bool DispatchPass(ID3D12GraphicsCommandList* cmd, const DlssNrConstants& p, ID3D12Resource*, ID3D12Resource*,
                      ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, ID3D12Resource* target, ID3D12Resource*, uint32_t* = nullptr)
    {
#ifdef T5_DEFERRED_R1
        if (injectDeferredComposition && p.Mode == DlssNrMode_ApplyResidual) return false;
#endif
        if (injectCompose) return false;
        ComPtr<ID3D12Device> d; Check(target->GetDevice(IID_PPV_ARGS(&d)));
        D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        hd.NumDescriptors = 1; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        ComPtr<ID3D12DescriptorHeap> visible; Check(d->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&visible)));
        hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        ComPtr<ID3D12DescriptorHeap> cpu; Check(d->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&cpu)));
        d->CreateUnorderedAccessView(target, nullptr, nullptr, visible->GetCPUDescriptorHandleForHeapStart());
        d->CreateUnorderedAccessView(target, nullptr, nullptr, cpu->GetCPUDescriptorHandleForHeapStart());
        ID3D12DescriptorHeap* table[] { visible.Get() }; cmd->SetDescriptorHeaps(1, table);
#ifdef T5_DEFERRED_R1
        // ApplyResidual consumes a previously evaluated edit; the real shader
        // does not gate this mode on the Run-only ApplyModel resolve constant.
        const float edit[] { (p.ApplyModel || p.Mode == DlssNrMode_ApplyResidual) ? 1.0f : 0.0f, 0, 0, 1 };
#else
        const float edit[] { p.ApplyModel ? 1.0f : 0.0f, 0, 0, 1 };
#endif
        cmd->ClearUnorderedAccessViewFloat(visible->GetGPUDescriptorHandleForHeapStart(),
            cpu->GetCPUDescriptorHandleForHeapStart(), target, edit, 0, nullptr);
        heaps.push_back(visible); heaps.push_back(cpu); return true;
    }
    bool DispatchResidualPass(ID3D12GraphicsCommandList*, const DlssNrConstants&, ID3D12Resource*, ID3D12Resource*,
                              ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, bool = false);
};

// The only injected production expressions are Close and Signal call results.
// The positive bodies remain unchanged; fault controls are external services.
#include "finished_production.inc"

void DlssNr_Dx12::State::LateContext::Say(const char* message) { status = message; }
bool DlssNr_Dx12::State::LateContext::Finished(const Slot& s)
{ return !s.fence || DlssNr::LateFenceReached(s.done, s.fence->GetCompletedValue()); }
void DlssNr_Dx12::State::LateContext::Cancel()
{ for (auto& s : slots) DlssNr::ClearLateSlotSelection(s.pending); reset = true; }
// Capture service supplies the already owned fixture packet. Its producer
// admission/copy logic is prerequisite Task4 evidence, not re-proven here.
void DlssNr_Dx12::State::LateContext::Capture(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, bool)
{
    slots[0].pending = true;
    slots[0].identity = consumer;
}

bool DlssNr_Dx12::DispatchResidualPass(ID3D12GraphicsCommandList* cmd, const DlssNrConstants& p,
    ID3D12Resource* source, ID3D12Resource* reference, ID3D12Resource* original,
    ID3D12Resource* response, ID3D12Resource* target, bool)
{
    if (injectFinalEncode && p.Mode == 1) return false;
    if (injectResidual && p.Mode == 2) return false;
    ComPtr<ID3D12Device> d; Check(target->GetDevice(IID_PPV_ARGS(&d)));
    if (!root)
    {
        D3D12_DESCRIPTOR_RANGE ranges[3] {};
        ranges[0] = { D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 4, 0, 0, 0 };
        ranges[1] = { D3D12_DESCRIPTOR_RANGE_TYPE_UAV, 1, 0, 0, 4 };
        ranges[2] = { D3D12_DESCRIPTOR_RANGE_TYPE_CBV, 1, 0, 0, 5 };
        D3D12_ROOT_PARAMETER param {}; param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        param.DescriptorTable = { 3, ranges };
        D3D12_ROOT_SIGNATURE_DESC desc {}; desc.NumParameters = 1; desc.pParameters = &param;
        ComPtr<ID3DBlob> bytes, error;
        Check(D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &bytes, &error));
        Check(d->CreateRootSignature(0, bytes->GetBufferPointer(), bytes->GetBufferSize(), IID_PPV_ARGS(&root)));
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd {}; pd.pRootSignature = root.Get();
        pd.CS = { dlssnr_finished_color_cso, sizeof(dlssnr_finished_color_cso) };
        Check(d->CreateComputePipelineState(&pd, IID_PPV_ARGS(&pipeline)));
    }
    D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = 6; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    ComPtr<ID3D12DescriptorHeap> heap; Check(d->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)));
    auto cpu = heap->GetCPUDescriptorHandleForHeapStart();
    const auto step = d->GetDescriptorHandleIncrementSize(hd.Type);
    ID3D12Resource* inputs[] { source, reference ? reference : source, original ? original : source, response ? response : source };
    for (auto* input : inputs)
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC view {}; view.Format = input->GetDesc().Format;
        view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; view.Texture2D.MipLevels = 1;
        view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        d->CreateShaderResourceView(input, &view, cpu); cpu.ptr += step;
    }
    d->CreateUnorderedAccessView(target, nullptr, nullptr, cpu); cpu.ptr += step;
    D3D12_RESOURCE_DESC bd {}; bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = 256;
    bd.Height = 1; bd.DepthOrArraySize = bd.MipLevels = 1; bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_UPLOAD;
    ComPtr<ID3D12Resource> cb;
    Check(d->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&cb)));
    float* data = nullptr; Check(cb->Map(0, nullptr, reinterpret_cast<void**>(&data)));
    std::memset(data, 0, 256);
    auto* ints = reinterpret_cast<unsigned*>(data);
    ints[0] = p.Mode; data[1] = p.WhitePoint; ints[2] = p.Width; ints[3] = p.Height;
    data[4] = p.TransferStrength; data[5] = p.ColourStrength; ints[6] = p.DebugView; data[7] = p.MaxRatio;
    cb->Unmap(0, nullptr);
    D3D12_CONSTANT_BUFFER_VIEW_DESC cbv { cb->GetGPUVirtualAddress(), 256 }; d->CreateConstantBufferView(&cbv, cpu);
    ID3D12DescriptorHeap* tables[] { heap.Get() }; cmd->SetDescriptorHeaps(1, tables);
    cmd->SetComputeRootSignature(root.Get()); cmd->SetPipelineState(pipeline.Get());
    cmd->SetComputeRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
    cmd->Dispatch((p.Width + 7) / 8, (p.Height + 7) / 8, 1);
    heaps.push_back(heap); constants.push_back(cb); return true;
}

static DlssNr_Dx12* activeOwner = nullptr;
static DlssNr::FinishedIdentity identity;
static DXGI_COLOR_SPACE_TYPE colorSpace;
static bool returned = false;
namespace DlssNr
{
void ApplyToStreamlinePicture(IDXGISwapChain*, ID3D12Resource* picture, ID3D12CommandQueue* queue)
{ returned = activeOwner->ApplyFinished(picture, queue, colorSpace, false, identity, 1); }
void SkipFinishedPicture(IDXGISwapChain*) { activeOwner->_state->late.Cancel(); }
}
#include "finished_streamline.inc"
struct Plugin
{
    static inline unsigned forwards = 0;
    static UINT Index(IDXGISwapChain*, bool& skip) { skip = true; return 0; }
    static HRESULT Buffer(IDXGISwapChain* sc, UINT index, REFIID iid, void** out, bool& skip)
    { skip = true; return sc->GetBuffer(index, iid, out); }
    static HRESULT Present(IDXGISwapChain*, UINT, UINT, bool&) { ++forwards; return S_OK; }
    static HRESULT Present1(IDXGISwapChain* sc, UINT i, UINT f, const DXGI_PRESENT_PARAMETERS*, bool& skip)
    { return Present(sc, i, f, skip); }
    static void* Get(const char* name)
    {
        if (!strcmp(name, "slHookPresent")) return &Present;
        if (!strcmp(name, "slHookPresent1")) return &Present1;
        if (!strcmp(name, "slHookGetCurrentBackBufferIndex")) return &Index;
        if (!strcmp(name, "slHookGetBuffer")) return &Buffer;
        return nullptr;
    }
};

struct FixtureEvent
{
    HANDLE value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    operator HANDLE() const { return value; }
    void Close() { if (value) { CloseHandle(value); value = nullptr; } }
    ~FixtureEvent() { Close(); }
};
struct Fixture
{
    ComPtr<IDXGIFactory4> factory;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<IDXGISwapChain1> chain;
    ComPtr<ID3D12Fence> drain;
    FixtureEvent event;
    uint64_t watermark = 0;
    DlssNr_Dx12 owner;
    explicit Fixture(bool pq, bool residual = false)
    {
        *Config::Instance() = {};
        injectClose = injectSignal = injectFinalEncode = injectCompose = injectResidual = false;
        closeCalls = signalCalls = 0;
        Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)));
        D3D12_COMMAND_QUEUE_DESC q {}; Check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)));
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&drain)));
        Expect(event != nullptr, "T5_EVENT");
        DXGI_SWAP_CHAIN_DESC1 desc {}; desc.Width = desc.Height = 8;
        desc.Format = pq ? DXGI_FORMAT_R10G10B10A2_UNORM : DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.BufferCount = 2; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.SampleDesc.Count = 1; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        Check(factory->CreateSwapChainForComposition(queue.Get(), &desc, nullptr, &chain));
        Check(chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey, queue.Get()));
        activeOwner = &owner;
        identity = { &owner, chain.Get(), 7, 42, true };
        colorSpace = pq ? DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
        auto& s = owner._state->late.slots[0];
        owner._state->late.device = device; s.identity = identity; s.serial = 1;
        s.guidesValid = s.pending = s.submitted = true;
        s.consumerOwner = chain; s.consumerDevice = device; s.producerQueue = queue;
        s.ready = s.done = 1;
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&s.fence)));
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&s.allocator)));
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, s.allocator.Get(), nullptr, IID_PPV_ARGS(&s.commands)));
        s.depth.Attach(owner._state->CreateScratch(device.Get(), DXGI_FORMAT_R32_FLOAT, 8, 8));
        s.motion.Attach(owner._state->CreateScratch(device.Get(), DXGI_FORMAT_R32G32_FLOAT, 8, 8));
        s.frame.FinishedPicture = s.frame.IndependentCommands = true;
        s.frame.Width = s.frame.Height = s.frame.OutputWidth = s.frame.OutputHeight = 8;
        s.frame.RenderSubrectWidth = s.frame.RenderSubrectHeight = 8;
        s.frame.OutputArrivalState = D3D12_RESOURCE_STATE_PRESENT;
        if (residual)
        {
            Config::Instance()->DlssNrRunBeforeSr.stored = true;
            s.residualOnly = s.sceneLinear = true;
            s.frame.SubmissionEpoch = State::Instance().frameCount;
            s.frame.PreExposure = 1;
            s.residual.Attach(owner._state->CreateScratch(device.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT, 8, 8));
            D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
            hd.NumDescriptors = 1; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
            ComPtr<ID3D12DescriptorHeap> visible; Check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&visible)));
            hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
            ComPtr<ID3D12DescriptorHeap> cpu; Check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&cpu)));
            device->CreateUnorderedAccessView(s.residual.Get(), nullptr, nullptr, visible->GetCPUDescriptorHandleForHeapStart());
            device->CreateUnorderedAccessView(s.residual.Get(), nullptr, nullptr, cpu->GetCPUDescriptorHandleForHeapStart());
            ID3D12DescriptorHeap* table[] { visible.Get() }; s.commands->SetDescriptorHeaps(1, table);
            const float carrier[] { 0.625f, 0.625f, 0.625f, 1 };
            s.commands->ClearUnorderedAccessViewFloat(visible->GetGPUDescriptorHandleForHeapStart(),
                cpu->GetCPUDescriptorHandleForHeapStart(), s.residual.Get(), carrier, 0, nullptr);
            owner.heaps.push_back(visible); owner.heaps.push_back(cpu);
            owner._state->Barrier(s.commands.Get(), s.residual.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
        }
        owner._state->Barrier(s.commands.Get(), s.depth.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
        owner._state->Barrier(s.commands.Get(), s.motion.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
        ComPtr<ID3D12Resource> picture; Check(chain->GetBuffer(0, IID_PPV_ARGS(&picture)));
        D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 1;
        ComPtr<ID3D12DescriptorHeap> heap; Check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)));
        auto rtv = heap->GetCPUDescriptorHandleForHeapStart(); device->CreateRenderTargetView(picture.Get(), nullptr, rtv);
        owner._state->Barrier(s.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
        const float original = residual ? 0.25f : 0.0f;
        const float black[] { original, original, original, 1 }; s.commands->ClearRenderTargetView(rtv, black, 0, nullptr);
        owner._state->Barrier(s.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        Check(s.commands->Close()); ID3D12CommandList* lists[] { s.commands.Get() };
        Check(s.fence->SetEventOnCompletion(1, event));
        queue->ExecuteCommandLists(1, lists); Check(queue->Signal(s.fence.Get(), 1));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T5_PRODUCER_COMPLETION");
    }
    void Drain()
    {
        ++watermark;
        Check(drain->SetEventOnCompletion(watermark, event));
        Check(queue->Signal(drain.Get(), watermark));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T5_DRAIN_TIMEOUT");
    }
    DlssNr::OutputStatus Present(bool one = false)
    {
        const auto before = Plugin::forwards;
        bool skip = false;
        if (one)
        {
            auto hook = reinterpret_cast<HRESULT (*)(IDXGISwapChain*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*, bool&)>(
                DlssNr::StreamlinePicture::Wrap("slHookPresent1", Plugin::Get));
            Check(hook(chain.Get(), 0, 0, nullptr, skip));
        }
        else
        {
            auto hook = reinterpret_cast<HRESULT (*)(IDXGISwapChain*, UINT, UINT, bool&)>(
                DlssNr::StreamlinePicture::Wrap("slHookPresent", Plugin::Get));
            Check(hook(chain.Get(), 0, 0, skip));
        }
        Expect(Plugin::forwards == before + 1, "T5_ORIGINAL_PRESENT_ONCE");
        return DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
    }
    uint32_t Pixel(ID3D12Resource* texture = nullptr, D3D12_RESOURCE_STATES arrival = D3D12_RESOURCE_STATE_PRESENT)
    {
        ComPtr<ID3D12Resource> picture;
        if (texture) picture = texture;
        else Check(chain->GetBuffer(0, IID_PPV_ARGS(&picture)));
        auto desc = picture->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {}; UINT64 bytes = 0;
        device->GetCopyableFootprints(&desc, 0, 1, 0, &fp, nullptr, nullptr, &bytes);
        D3D12_RESOURCE_DESC b {}; b.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; b.Width = bytes;
        b.Height = 1; b.DepthOrArraySize = b.MipLevels = 1; b.SampleDesc.Count = 1; b.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
        ComPtr<ID3D12Resource> readback;
        Check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &b, D3D12_RESOURCE_STATE_COPY_DEST,
            nullptr, IID_PPV_ARGS(&readback)));
        ComPtr<ID3D12CommandAllocator> a; ComPtr<ID3D12GraphicsCommandList> c;
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&a)));
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, a.Get(), nullptr, IID_PPV_ARGS(&c)));
        owner._state->Barrier(c.Get(), picture.Get(), arrival, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION from {}, to {};
        from.pResource = picture.Get(); from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource = readback.Get(); to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; to.PlacedFootprint = fp;
        c->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
        owner._state->Barrier(c.Get(), picture.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, arrival);
        Check(c->Close()); ID3D12CommandList* lists[] { c.Get() };
        ++watermark; Check(drain->SetEventOnCompletion(watermark, event));
        queue->ExecuteCommandLists(1, lists); Check(queue->Signal(drain.Get(), watermark));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T5_READBACK_COMPLETION");
        uint32_t* data = nullptr; Check(readback->Map(0, nullptr, reinterpret_cast<void**>(&data)));
        const uint32_t result = *data; readback->Unmap(0, nullptr); return result;
    }
    ~Fixture()
    {
        // Independent tail fence closes even an intentionally unsignaled submission.
        // Never rewrite its production watermark/pin to manufacture safe reuse.
        try { Drain(); } catch (...) { std::terminate(); }
        DlssNr::ClearStatus(&owner);
        activeOwner = nullptr;
        event.Close();
        std::puts("T5_RETIREMENT_PROOF=queue_tail_complete event_closed");
    }
};

int main(int argc, char** argv) try
{
    const char* selected = argc == 3 && !strcmp(argv[1], "--case") ? argv[2] : nullptr;
    const bool residualDelta = argc == 2 && !strcmp(argv[1], "--residual-delta");
    unsigned cases = 0;
    for (const char* name : { "success", "pq-success", "hidden", "pq-hidden", "final-pq-failure", "close-failure",
                            "signal-failure", "composition-failure", "model-failure", "model-waiting", "duplicate",
                            "capturing", "disabled", "resource-skip", "external-submission", "external-discard",
                            "producer-signal-failure", "residual-success", "residual-failure" })
    {
        if (selected && strcmp(name, selected)) continue;
        if (residualDelta && strcmp(name, "residual-success") && strcmp(name, "residual-failure")) continue;
        ++cases;
        const std::string test = name;
        const bool pq = test.find("pq") != std::string::npos;
        {
        Fixture f(pq, test.find("residual") != std::string::npos);
        Config::Instance()->DlssNrApplyModel.stored = test.find("hidden") == std::string::npos;
        injectFinalEncode = test == "final-pq-failure";
        injectClose = test == "close-failure"; injectSignal = test == "signal-failure";
        injectCompose = test == "composition-failure";
        injectResidual = test == "residual-failure";
        f.owner._state->nr.models[0].fail = test == "model-failure";
        f.owner._state->nr.models[0].ready = test != "model-waiting";
        auto& slot = f.owner._state->late.slots[0];
        DlssNr::OutputStatus o;
        ComPtr<ID3D12Resource> external;
        if (test == "external-submission" || test == "external-discard")
        {
            Config::Instance()->DlssNrFinishedPicture.stored = false;
            f.owner._state->allowCaptureTrigger = true;
            external.Attach(f.owner._state->CreateScratch(f.device.Get(), DXGI_FORMAT_R8G8B8A8_UNORM, 8, 8));
            f.owner._state->resources.push_back(external);
            Check(slot.allocator->Reset()); Check(slot.commands->Reset(slot.allocator.Get(), nullptr));
            DlssNrConstants black {};
            Expect(f.owner.DispatchPass(slot.commands.Get(), black, nullptr, nullptr, nullptr, nullptr, nullptr,
                                       external.Get(), nullptr), "T5_EXTERNAL_INITIALIZE");
            Check(slot.commands->Close()); ID3D12CommandList* lists[] { slot.commands.Get() };
            f.queue->ExecuteCommandLists(1, lists); f.Drain();
            Check(slot.allocator->Reset()); Check(slot.commands->Reset(slot.allocator.Get(), nullptr));
            auto frame = slot.frame; frame.FinishedPicture = false; frame.PipelineManagedStates = true;
            frame.SubmissionEpoch = 42;
            f.owner._state->Run(slot.commands.Get(), external.Get(), slot.depth.Get(), slot.motion.Get(),
                                external.Get(), frame, f.queue.Get());
            f.owner._state->Publish();
            const auto recorded = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            Expect(recorded.evaluated && recorded.composed && recorded.copyBack && !recorded.executed &&
                   !recorded.submitted && !recorded.Applied(), "T5_RECORDED_NOT_APPLIED");
            Check(slot.commands->Close());
            if (test == "external-discard")
                f.owner._state->FinishedPictureResetCommandList(slot.commands.Get());
            else
            {
                ComPtr<ID3D12CommandAllocator> otherAllocator;
                ComPtr<ID3D12GraphicsCommandList> other;
                Check(f.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&otherAllocator)));
                Check(f.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, otherAllocator.Get(), nullptr,
                                                IID_PPV_ARGS(&other)));
                Check(other->Close());
                DlssNr::LatePromiseBatch batch;
                ID3D12CommandList* unrelated[] { other.Get() };
                f.owner._state->FinishedPictureSubmitted(batch, &f.owner, f.queue.Get(), 1, unrelated);
                Expect(!f.owner._state->outputStatus.Applied() && f.owner._state->outputCommands == slot.commands.Get(),
                       "T5_UNRELATED_SUBMISSION_NOT_APPLIED");
                f.queue->ExecuteCommandLists(1, lists);
                f.owner._state->FinishedPictureSubmitted(batch, &f.owner, f.queue.Get(), 1, lists);
            }
            o = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            returned = o.Applied();
            f.Present(); // configured non-Present route still forwards the original once
        }
        else if (test == "producer-signal-failure")
        {
            f.owner._state->late.consumer = identity;
            f.owner._state->lastFinishedMode = 1;
            f.owner._state->EvaluateInternal(slot.commands.Get(), nullptr, true, f.queue.Get(), false, 42, false);
            f.owner._state->late.tracking.store(true);
            Check(slot.allocator->Reset()); Check(slot.commands->Reset(slot.allocator.Get(), nullptr)); Check(slot.commands->Close());
            slot.owned = slot.promisePending = true; slot.submitted = false;
            slot.producer = slot.commands.Get(); slot.promisedQueue = f.queue.Get();
            slot.ready = slot.promisedValue = 2;
            DlssNr::LatePromiseBatch batch;
            DlssNr::LatePromiseEntry entry {};
            entry.owner = &f.owner; entry.slot = 0; entry.serial = 1; entry.token = 2;
            entry.queue = f.queue.Get(); entry.producer = slot.commands.Get(); batch.push_back(entry);
            ID3D12CommandList* lists[] { slot.commands.Get() };
            injectSignal = true;
            f.queue->ExecuteCommandLists(1, lists);
            f.owner._state->FinishedPictureSubmitted(batch, &f.owner, f.queue.Get(), 1, lists);
            o = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output; returned = false;
        }
        else if (test == "capturing" || test == "disabled")
        {
            Config::Instance()->DlssNrEnabled.stored = test != "disabled";
            f.owner._state->late.consumer = identity;
            f.owner._state->lastFinishedMode = 1;
            f.owner._state->EvaluateInternal(slot.commands.Get(), nullptr, true, f.queue.Get(), false, 42, false);
            f.owner._state->Publish();
            o = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            returned = false;
            if (test == "disabled") o = f.Present();
        }
        else if (test == "resource-skip")
        {
            f.owner._state->Run(nullptr, nullptr, nullptr, nullptr, nullptr, slot.frame, f.queue.Get());
            f.owner._state->Publish();
            o = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            returned = false;
        }
        else o = f.Present();
        const auto pixel = external ? f.Pixel(external.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS) : f.Pixel();
        std::printf("T5_FACTS case=%s state=%u reason=%u evaluated=%d hidden=%d composed=%d copyBack=%d executed=%d submitted=%d unknown=%d returned=%d pixel=%08X pinned=%d ready=%llu done=%llu completed=%llu successes=%llu\n",
            name, unsigned(o.state), unsigned(o.reason), o.evaluated, o.hidden, o.composed, o.copyBack, o.executed,
            o.submitted, o.completionUnknown, returned, pixel, slot.pinned, slot.ready, slot.done,
            slot.fence->GetCompletedValue(), f.owner._state->late.successes);
        Expect(o.uiCorrection == 1 && !o.automaticUiCorrection && o.inputFilter == 0 && o.signalEncoding == 0 &&
               !o.inputFilterOverrideSupported && !o.signalEncodingOverrideSupported, "T5_LEGACY_CURRENT_SUPPORT");
        if (test != "disabled" && test != "resource-skip" && !external)
            Expect(o.application == 42 && o.generation == 7 && o.captureSerial == 1 && o.guidesValid, "T5_VALUE_IDENTITY");
        if (test == "residual-success")
            Expect(o.Applied() && returned && o.evaluated && o.composed && o.copyBack &&
                   f.owner._state->nr.models[0].evaluations == 0 && f.owner._state->nr.successfulDispatches == 0 &&
                   (pixel & 255) > 64, "T5_RESIDUAL_APPLIED_WITHOUT_PRESENT_EVALUATE");
        else if (test == "residual-failure")
            Expect(o.state == DlssNr::OutputState::Failed && o.reason == DlssNr::OutputReason::Composition &&
                   o.evaluated && !o.composed && !o.copyBack && !o.Applied() && !returned && pixel == 0xFF404040,
                   "T5_RESIDUAL_FAILURE_NAMED");
        else if (test == "external-submission")
            Expect(o.Applied() && o.executed && o.submitted && !f.owner._state->outputCommands &&
                   pixel == 0xFF0000FF, "T5_MATCHED_EXTERNAL_SUBMISSION_APPLIED");
        else if (test == "external-discard")
            Expect(o.state == DlssNr::OutputState::Skipped && o.reason == DlssNr::OutputReason::Discarded &&
                   !o.Applied() && !o.executed && !o.submitted && !f.owner._state->outputCommands &&
                   pixel == 0xFF000000, "T5_DISCARDED_RECORDING_NOT_APPLIED");
        else if (test == "producer-signal-failure")
            Expect(o.state == DlssNr::OutputState::Failed && o.reason == DlssNr::OutputReason::Signal &&
                   o.executed && !o.submitted && o.completionUnknown && !o.Applied() && slot.pinned &&
                   slot.submitted && !slot.owned && !slot.promisePending && slot.done == 2 &&
                   slot.fence->GetCompletedValue() == 1 &&
                   !DlssNr::LateSlotReusable(slot.pending, slot.owned, slot.pinned, slot.promisePending, true,
                                            slot.done, slot.fence->GetCompletedValue()),
                   "T5_PRODUCER_SIGNAL_UNKNOWN_COMPLETION");
        else if (test == "capturing")
            Expect(o.state == DlssNr::OutputState::Capturing && !o.evaluated && !o.Applied() &&
                   f.owner._state->nr.models[0].evaluations == 0, "T5_CAPTURE_NOT_EVALUATION");
        else if (test == "disabled")
            Expect(o.state == DlssNr::OutputState::Disabled && !o.Applied() &&
                   f.owner._state->nr.models[0].evaluations == 0, "T5_DISABLED_NO_MODEL");
        else if (test == "resource-skip")
            Expect(o.state == DlssNr::OutputState::Skipped && o.reason == DlssNr::OutputReason::Resource &&
                   !o.evaluated && !o.Applied(), "T5_SKIP_NAMED_REASON");
        else if (test == "success" || test == "pq-success" || test == "duplicate")
        {
            Expect(o.Applied() && returned && o.evaluated && f.owner._state->late.successes == 1, "T5_SUCCESS_FINAL_OUTPUT");
            Expect((pixel & 0xFFFFFF) != 0, "T5_WARP_EDIT_COPIED_BACK");
        }
        else if (test.find("hidden") != std::string::npos)
        {
            Expect(o.state == DlssNr::OutputState::EvaluatedHidden && o.evaluated && !o.Applied() && !returned,
                   "T5_HIDDEN_NOT_APPLIED");
            Expect((pq ? pixel & 0x3FFFFFFF : pixel & 0xFFFFFF) == 0 && f.owner._state->late.successes == 0,
                   "T5_HIDDEN_ORIGINAL_OUTPUT");
            Expect(!f.owner._state->late.reset, "T5_HIDDEN_RETAINS_MODEL_HISTORY");
        }
        else if (test == "final-pq-failure")
        {
            Expect(o.state == DlssNr::OutputState::Failed && o.reason == DlssNr::OutputReason::FinalEncode &&
                   o.evaluated && o.composed && !o.copyBack && o.submitted && !o.Applied() && !returned &&
                   f.owner._state->late.successes == 0, "T5_FINAL_PQ_FAILURE_NOT_APPLIED");
            Expect((pixel & 0x3FFFFFFF) == 0, "T5_FINAL_PQ_ORIGINAL_OUTPUT");
            Expect(f.owner._state->late.reset, "T5_FINAL_PQ_RESETS_FAILED_TRANSPORT");
        }
        else if (test == "close-failure" || test == "signal-failure")
        {
            Expect(o.state == DlssNr::OutputState::Failed && !o.Applied() && !returned && slot.pinned &&
                   slot.submitted && !slot.promisePending && !slot.owned, "T5_FAILURE_RETAINS_PRODUCER");
            Expect(!DlssNr::LateSlotReusable(slot.pending, slot.owned, slot.pinned, slot.promisePending, true,
                                            slot.done, slot.fence->GetCompletedValue()), "T5_FAILURE_PIN_NOT_REUSABLE");
            if (test == "close-failure")
                Expect(!o.executed && !o.submitted && !o.completionUnknown && slot.done == 1 &&
                       signalCalls == 0 && (pixel & 0xFFFFFF) == 0, "T5_CLOSE_NO_EXECUTE_NO_ROLLBACK");
            else
                Expect(o.executed && !o.submitted && o.completionUnknown && slot.done > 1 &&
                       slot.fence->GetCompletedValue() == 1 && (pixel & 0xFFFFFF) != 0,
                       "T5_SIGNAL_UNKNOWN_COMPLETION");
        }
        else
        {
            Expect(!o.Applied() && !returned && (pixel & 0xFFFFFF) == 0, "T5_NO_RESULT_NOT_APPLIED");
            if (test == "model-waiting")
                Expect(!o.evaluated && o.state == DlssNr::OutputState::WaitingForModel, "T5_WAITING_NOT_EVALUATED");
            else Expect(o.state == DlssNr::OutputState::Failed, "T5_FAILURE_STATE");
        }
        if (test == "duplicate")
        {
            const auto count = f.owner._state->nr.models[0].evaluations;
            const auto duplicate = f.Present(true);
            Expect(f.owner._state->nr.models[0].evaluations == count && !returned &&
                   duplicate.state == DlssNr::OutputState::Skipped, "T5_DUPLICATE_NO_EVALUATE");
        }
        f.Drain();
        std::printf("T5_CASE_PASS=%s\n", name);
        }
        std::puts("T5_CLOSURE=owned_COM_scope_closed");
    }
    Expect(cases != 0, "T5_UNKNOWN_CASE");
    std::printf("T5_PASS cases=%u gpu=WARP nvidia=not_run\n", cases);
    return 0;
}
catch (const std::exception& error)
{
    std::puts("T5_NEGATIVE_CLOSURE=owned_COM_scope_closed");
    std::printf("T5_FAIL=%s\n", error.what()); return 1;
}
