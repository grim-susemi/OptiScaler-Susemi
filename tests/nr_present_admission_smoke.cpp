// Production bodies are extracted verbatim by run_nr_streamline_hooks.ps1.
// WARP owns every resource/queue/fence. Run is a counted, visible fixture edit;
// no NVIDIA provider or game is loaded, and no NR image-quality claim is made.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <nvsdk_ngx_params.h>
#include <nvsdk_ngx_defs.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <variant>
#include <vector>
#include "../OptiScaler/dlssnr/DlssNr_StreamlinePicture.h"
#include "../OptiScaler/dlssnr/DlssNr_Placement.h"
#include "../OptiScaler/dlssnr/DlssNr_XeFGHandoff.h"
#include "../OptiScaler/dlssnr/DlssNr_FinishedReady.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_Common.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_SeamClock.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_NativeProbe.h"

using Microsoft::WRL::ComPtr;
static void Check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("D3D12 call failed"); }
static void Expect(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define LOG_WARN(...) ((void)0)
template <typename T> struct Setting
{
    T stored {};
    bool present = false;
    T value_or_default() const { return stored; }
    T value_or(T fallback) const { return present ? stored : fallback; }
    T value() const { return stored; }
    bool has_value() const { return present; }
};
struct Config
{
    Setting<bool> DlssNrEnabled { true }, DlssNrFinishedPicture { true }, DlssNrApplyModel { true };
    Setting<bool> DlssNrRunBeforeSr, DlssNrDeferredDlss, DlssNrResidualAcrossRr, DlssNrHoldFrame, DlssNrHdrTransfer;
    Setting<float> DlssNrMaxRatio { 8.0f };
    Setting<unsigned> ColorResourceBarrier, DepthResourceBarrier, MVResourceBarrier, ExposureResourceBarrier,
                      OutputResourceBarrier;
    unsigned passes = 2;
    static Config* Instance() { static Config cfg; return &cfg; }
};
enum class GameQuirk { Kcd2NrBeforeFg, ForceUnrealEngine };
enum class FGNvngxReplacement { None, Other };
enum class GameEngineType { Other, Unreal };
enum class API { DX11, DX12 };
enum class SwapchainInteropApi { None, Dx11wDx12, Other };
struct Quirks
{
    bool enabled = false;
    bool operator[](GameQuirk) const { return enabled; }
    bool operator&(GameQuirk) const { return false; }
};
struct Fg
{
    uint64_t application = 1;
    bool IsActive() const { return false; }
    bool IsPaused() const { return false; }
    uint64_t FrameCount() const { return application; }
};
struct State
{
    bool isShuttingDown = false;
    Quirks gameQuirks;
    FGNvngxReplacement activeFgNvngx = FGNvngxReplacement::None;
    API swapchainApi = API::DX12;
    SwapchainInteropApi swapchainInteropApi = SwapchainInteropApi::None;
    unsigned NVNGX_Engine = 0;
    GameEngineType gameEngine = GameEngineType::Other;
    uint64_t frameCount = 9000;
    IDXGISwapChain* currentSwapchain = nullptr;
    IDXGISwapChain* currentFGSwapchain = nullptr;
    Fg* currentFG = nullptr;
    static State& Instance() { static State s; return s; }
};
namespace Util { bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; } }
namespace ResTrack_Dx12 { void HookLateNrQueue(ID3D12Device*) {} }
namespace DlssNr
{
struct InputStates_Dx12 { D3D12_RESOURCE_STATES color, depth, motion, exposure; };
struct XeFGCapture
{
    bool exists = false, submitted = false, ready = false, sameQueue = false;
    uint64_t serial = 0;
    FinishedIdentity identity {};
};
inline constexpr GUID FinishedColorSpaceKey = {
    0x34a31e7b, 0x84c5, 0x44ef, { 0xa7, 0x4d, 0x6b, 0xd3, 0x60, 0x8c, 0xe5, 0x22 }
};
InputStates_Dx12 ResolveInputStates_Dx12(bool);
void ApplyToStreamlinePicture(IDXGISwapChain*, ID3D12Resource*, ID3D12CommandQueue*);
void ApplyToFinishedPicture(IDXGISwapChain*, ID3D12CommandQueue*);
void SkipFinishedPicture(IDXGISwapChain*);
void FinishedPicturePromise(LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
void FinishedPictureSubmitted(LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
StreamlinePicture::ConsumerSnapshot CaptureFinishedConsumer();
bool XeFGPendingCapture(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, XeFGCapture&,
                        const FinishedIdentity& = {});
bool ApplyXeFGPicture(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, const XeFGCapture& = {});
void XeFGCloseCaptures(uint64_t);
}
struct Params : NVSDK_NGX_Parameter
{
    using Value = std::variant<unsigned long long, float, double, unsigned, int, ID3D11Resource*, ID3D12Resource*, void*>;
    std::map<std::string, Value> values;
#define PARAMETER(Type) \
    void Set(const char* key, Type value) override { values[key] = value; } \
    NVSDK_NGX_Result Get(const char* key, Type* value) const override \
    { auto it = values.find(key); if (it == values.end() || !std::holds_alternative<Type>(it->second)) \
        return NVSDK_NGX_Result_Fail; *value = std::get<Type>(it->second); return NVSDK_NGX_Result_Success; }
    PARAMETER(unsigned long long)
    PARAMETER(float)
    PARAMETER(double)
    PARAMETER(unsigned)
    PARAMETER(int)
    PARAMETER(ID3D11Resource*)
    PARAMETER(ID3D12Resource*)
    PARAMETER(void*)
#undef PARAMETER
    void Reset() override { values.clear(); }
};
// Unasserted feature/model/capture services. The asserted late recording state,
// submission tokens, fences, guide copies, admission and compositor are production.
struct LifetimeService
{
    void Record(ID3D12CommandList*) {}
    void ResetRecording(ID3D12CommandList*) {}
    void Submitted(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*) {}
};
struct ModelService : LifetimeService {};
struct TimerService : LifetimeService { void ClearLast() {} };
struct Dx11FinishedPictureBridge { bool Drain() { return true; } };
class DlssNr_Dx12
{
  public:
    struct State
    {
        DlssNr_Dx12& shader;
        std::recursive_mutex mutex;
        uint32_t featureFlags = 0;
        struct Nr { uint64_t successfulDispatches = 0; bool reset = true, heldActive = false;
                    std::array<ModelService, 2> models; } nr;
        LifetimeService lifetime, captureFrames;
        struct Deferred : LifetimeService
        {
            LifetimeService lifetime;
            void Cancel() {}
            void Before(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, uint64_t, uint64_t,
                        ID3D12CommandQueue*, bool, bool) {}
            void After(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, uint64_t) {}
        } deferredSr;
        struct Enlarger { LifetimeService lifetime; bool submitted = false, failed = false;
                          ID3D12CommandList* creation = nullptr; ComPtr<ID3D12CommandQueue> queue; };
        std::unique_ptr<Enlarger> enlarger;
        std::vector<std::unique_ptr<Enlarger>> retiredEnlargers;
        std::string enlargementStatus;
        struct Hold { bool active = false; uint64_t generation = 0; ID3D12CommandList* captureCommands = nullptr; } inputHold;
        std::unique_ptr<TimerService> gpuTime, ngxTime;
        std::optional<double> lastGpuTime, lastNgxTime;
        unsigned lastFinishedMode = 0;
        DlssNrSeamClock seamClock;
#include "present_late_context.inc"
        LateContext late { *this };
        unsigned runs = 0;
        uint64_t lastRunSerial = 0;
        std::vector<ComPtr<ID3D12DescriptorHeap>> rtvs;
        explicit State(DlssNr_Dx12& s) : shader(s) {}
        void ConsumeControls() {}
        void Publish() {}
        void CollectEnlargers() {}
        static bool SameHoldShape(const D3D12_RESOURCE_DESC& a, const D3D12_RESOURCE_DESC& b)
        { return a.Width == b.Width && a.Height == b.Height && a.Format == b.Format; }
        DXGI_FORMAT TypedGuideFormat(DXGI_FORMAT format) { return format; }
        ID3D12Resource* CreateGuideClone(ID3D12Device* device, ID3D12Resource* source)
        {
            auto desc = source->GetDesc(); D3D12_HEAP_PROPERTIES heap {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
            ID3D12Resource* result = nullptr;
            Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&result)));
            return result;
        }
        ID3D12Resource* CreateScratch(ID3D12Device* device, DXGI_FORMAT format, unsigned w, unsigned h)
        {
            D3D12_RESOURCE_DESC desc {}; desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
            desc.Width = w; desc.Height = h; desc.DepthOrArraySize = desc.MipLevels = 1; desc.SampleDesc.Count = 1;
            desc.Format = format; desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
            D3D12_HEAP_PROPERTIES heap {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT; ID3D12Resource* result = nullptr;
            Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&result)));
            return result;
        }
        void Barrier(ID3D12GraphicsCommandList* cmd, ID3D12Resource* resource,
                     D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to)
        {
            if (from == to) return;
            D3D12_RESOURCE_BARRIER barrier {}; barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            barrier.Transition = { resource, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, from, to };
            cmd->ResourceBarrier(1, &barrier);
        }
        ID3D12Resource* GetResource(NVSDK_NGX_Parameter* params, const char* a, const char* b)
        { ID3D12Resource* result = nullptr; params->Get(a, &result); if (!result) params->Get(b, &result); return result; }
        void Run(ID3D12GraphicsCommandList* cmd, ID3D12Resource* color, ID3D12Resource* depth,
                 ID3D12Resource* motion, ID3D12Resource*, const DlssNrFrameInfo& frame, ID3D12CommandQueue*)
        {
            ++runs; nr.successfulDispatches += Config::Instance()->passes;
            Expect(frame.FinishedPicture, "T4_RUN_ROLE");
            auto found = std::find_if(late.slots.begin(), late.slots.end(), [&](const auto& slot) {
                return slot.depth.Get() == depth && slot.motion.Get() == motion;
            });
            Expect(found != late.slots.end() && found->guidesValid, "T4_REAL_GUIDES");
            lastRunSerial = found->serial;
            ComPtr<ID3D12DescriptorHeap> heap; D3D12_DESCRIPTOR_HEAP_DESC hd {};
            hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 1;
            Check(late.device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&heap)));
            auto rtv = heap->GetCPUDescriptorHandleForHeapStart();
            late.device->CreateRenderTargetView(color, nullptr, rtv);
            Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
            const float edit[] = { 0, 1, 0, 1 }; cmd->ClearRenderTargetView(rtv, edit, 0, nullptr);
            Barrier(cmd, color, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
            rtvs.push_back(heap);
        }
        void EvaluateInternal(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, ID3D12CommandQueue*,
                              bool, uint64_t, bool);
        void FinishedPictureResetCommandList(ID3D12CommandList*);
        void FinishedPicturePromised(DlssNr::LatePromiseBatch&, DlssNr_Dx12*, ID3D12CommandQueue*, UINT,
                                     ID3D12CommandList* const*);
        void FinishedPictureSubmitted(DlssNr::LatePromiseBatch&, DlssNr_Dx12*, ID3D12CommandQueue*, UINT,
                                      ID3D12CommandList* const*);
        void CloseFinishedCaptures(uint64_t, const DlssNr::FinishedIdentity& = {});
        bool AdmitFinishedCapture(ID3D12Resource*, ID3D12CommandQueue*, const DlssNr::FinishedIdentity&,
                                  DlssNr::XeFGCapture&, bool, uint64_t = 0);
        bool PendingFinishedCapture(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE,
                                    DlssNr::XeFGCapture&, const DlssNr::FinishedIdentity& = {});
        bool ApplyFinishedColor(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, bool = false,
                                const DlssNr::FinishedIdentity& = {}, uint64_t = 0);
    };
    std::unique_ptr<State> _state = std::make_unique<State>(*this);
    bool ProcessSeam(ID3D12GraphicsCommandList*, NVSDK_NGX_Parameter*, bool, ID3D12CommandQueue*, bool,
                     uint64_t, bool, uint32_t, const DlssNr::StreamlinePicture::ConsumerSnapshot&);
    bool ApplyFinished(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE, bool = false,
                       const DlssNr::FinishedIdentity& = {}, uint64_t = 0);
    bool PendingFinishedCapture(ID3D12Resource*, ID3D12CommandQueue*, DXGI_COLOR_SPACE_TYPE,
                                DlssNr::XeFGCapture&, const DlssNr::FinishedIdentity& = {});
    void CloseFinishedCaptures(uint64_t serial, const DlssNr::FinishedIdentity& consumer = {})
    { _state->CloseFinishedCaptures(serial, consumer); }
    bool DispatchResidualPass(ID3D12GraphicsCommandList*, const DlssNrConstants&, ID3D12Resource*, ID3D12Resource*,
                              ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, bool) { return false; }
    void PromiseFinishedCommands(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                                 ID3D12CommandList* const* lists)
    { _state->FinishedPicturePromised(batch, this, queue, count, lists); }
    void SubmitFinishedCommands(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                                ID3D12CommandList* const* lists)
    { _state->FinishedPictureSubmitted(batch, this, queue, count, lists); }
};
static std::recursive_mutex nrOwnersMutex;
static std::vector<DlssNr_Dx12*> nrOwners;
static DlssNr_Dx12* activeNrOwner = nullptr;
static void ActivateNrOwner(DlssNr_Dx12* owner)
{
    if (std::find(nrOwners.begin(), nrOwners.end(), owner) == nrOwners.end()) nrOwners.push_back(owner);
    activeNrOwner = owner;
}
struct NrNotificationScope { NrNotificationScope() {} ~NrNotificationScope() {} };
static std::function<void()> betweenPromiseAndExecute;
static void RealExecute(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists)
{
    if (betweenPromiseAndExecute) betweenPromiseAndExecute();
    queue->ExecuteCommandLists(count, lists);
}
static auto o_ExecuteCommandLists = &RealExecute;
namespace FGHooks
{
struct FGColorSpaceCarrier
{
    bool valid = false;
    IDXGISwapChain3* proxy = nullptr;
    HRESULT result = S_OK;
    DXGI_COLOR_SPACE_TYPE colorSpace = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    bool current() const { return false; }
};
static unsigned records = 0;
bool GetFGColorSpaceCarrier(FGColorSpaceCarrier&) { return false; }
void RecordXeFGHandoff(uint64_t, uint64_t, void*) { ++records; }
}
enum class NrXefgGate { ShutdownOrNull, NotOwner, ConfigOff };
static std::string lastXefgSkip;
static void LogNrXefgGate(NrXefgGate, ...) {}
static void LogNrXefgSkip(uint64_t, uint64_t, const char* reason) { lastXefgSkip = reason; }
class XeFG_Dx12
{
  public:
    IDXGISwapChain* _swapChain = nullptr;
    ID3D12CommandQueue* _gameCommandQueue = nullptr;
    void* _swapChainContext = nullptr;
    uint64_t _nrGeneration = 1, _lastDispatchedFrame = 1;
    DXGI_FORMAT _proxyFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
    DlssNr::XeFGHandoff::Tracker _nrHandoff;
    bool IsActive() const { return true; }
    bool IsPaused() const { return false; }
    uint64_t FrameCount() const { return ::State::Instance().currentFG->FrameCount(); }
    bool OwnsFinishedConsumer() const;
    bool ClaimsFinishedConsumer() const;
    void ResetNrHandoff();
    void OwnedNrHandoff();
};
#include "present_production.inc"
#include "StreamlinePicture.cpp"

struct Plugin
{
    inline static unsigned forwards = 0;
    inline static bool handled = true;
    static UINT Index(IDXGISwapChain*, bool& skip) { skip = handled; return 0; }
    static HRESULT Buffer(IDXGISwapChain* chain, UINT index, REFIID iid, void** out, bool& skip)
    { skip = handled; return chain->GetBuffer(index, iid, out); }
    static HRESULT Present(IDXGISwapChain*, UINT, UINT, bool&) { ++forwards; return S_OK; }
    static HRESULT Present1(IDXGISwapChain* sc, UINT i, UINT f, const DXGI_PRESENT_PARAMETERS*, bool& s)
    { return Present(sc, i, f, s); }
    static void* Get(const char* name)
    {
        if (!strcmp(name, "slHookPresent")) return &Present;
        if (!strcmp(name, "slHookPresent1")) return &Present1;
        if (!strcmp(name, "slHookGetCurrentBackBufferIndex")) return &Index;
        if (!strcmp(name, "slHookGetBuffer")) return &Buffer;
        return nullptr;
    }
};

struct Fixture
{
    ComPtr<IDXGIFactory4> factory;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue, crossQueue;
    ComPtr<IDXGISwapChain1> chain, foreignChain;
    ComPtr<ID3D12Resource> depth, motion, output;
    ComPtr<ID3D12Fence> drainFence;
    std::vector<ComPtr<ID3D12CommandAllocator>> allocators;
    std::vector<ComPtr<ID3D12GraphicsCommandList>> producers;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    uint64_t drainValue = 0;
    DlssNr_Dx12 owner;
    Params params;
    using PresentHook = HRESULT (*)(IDXGISwapChain*, UINT, UINT, bool&);
    using Present1Hook = HRESULT (*)(IDXGISwapChain*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*, bool&);
    PresentHook present = nullptr;
    Present1Hook present1 = nullptr;

    Fixture()
    {
        Expect(event != nullptr, "T4_EVENT");
        Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        Check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)));
        D3D12_COMMAND_QUEUE_DESC q {};
        Check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)));
        Check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&crossQueue)));
        Check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&drainFence)));
        DXGI_SWAP_CHAIN_DESC1 desc {}; desc.Width = desc.Height = 8; desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.BufferCount = 2; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.SampleDesc.Count = 1; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        Check(factory->CreateSwapChainForComposition(queue.Get(), &desc, nullptr, &chain));
        Check(factory->CreateSwapChainForComposition(queue.Get(), &desc, nullptr, &foreignChain));
        Check(chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey, queue.Get()));
        Check(foreignChain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey, queue.Get()));
        D3D12_RESOURCE_DESC td {}; td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; td.Width = td.Height = 8;
        td.DepthOrArraySize = td.MipLevels = 1; td.SampleDesc.Count = 1; td.Format = DXGI_FORMAT_R32_FLOAT;
        D3D12_HEAP_PROPERTIES heap {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(&depth)));
        td.Format = DXGI_FORMAT_R32G32_FLOAT;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(&motion)));
        td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        td.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        Check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&output)));
        InitializeGuides();
        params.Set(NVSDK_NGX_Parameter_Depth, depth.Get());
        params.Set(NVSDK_NGX_Parameter_MotionVectors, motion.Get());
        params.Set(NVSDK_NGX_Parameter_Output, output.Get());
        params.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, 8u);
        params.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, 8u);
        params.Set(NVSDK_NGX_Parameter_MV_Scale_X, 1.0f);
        params.Set(NVSDK_NGX_Parameter_MV_Scale_Y, 1.0f);
        params.Set(NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags,
                   unsigned(NVSDK_NGX_DLSS_Feature_Flags_MVLowRes));
        State::Instance().currentSwapchain = chain.Get();
        ActivateNrOwner(&owner);
        present = reinterpret_cast<PresentHook>(DlssNr::StreamlinePicture::Wrap("slHookPresent", Plugin::Get));
        present1 = reinterpret_cast<Present1Hook>(DlssNr::StreamlinePicture::Wrap("slHookPresent1", Plugin::Get));
        Expect(present && present1, "T4_WRAPPERS");
    }
    void Drain(ID3D12CommandQueue* submittedQueue = nullptr)
    {
        if (!submittedQueue) submittedQueue = queue.Get();
        ++drainValue;
        Check(drainFence->SetEventOnCompletion(drainValue, event));
        Check(submittedQueue->Signal(drainFence.Get(), drainValue));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T4_DRAIN_TIMEOUT");
    }
    void InitializeGuides()
    {
        ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
        std::vector<ComPtr<ID3D12Resource>> uploads;
        for (auto* guide : { depth.Get(), motion.Get() })
        {
            const auto td = guide->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {}; UINT64 bytes = 0;
            device->GetCopyableFootprints(&td, 0, 1, 0, &fp, nullptr, nullptr, &bytes);
            D3D12_RESOURCE_DESC bd {}; bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = bytes;
            bd.Height = 1; bd.DepthOrArraySize = bd.MipLevels = 1; bd.SampleDesc.Count = 1;
            bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_UPLOAD;
            ComPtr<ID3D12Resource> upload;
            Check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_GENERIC_READ,
                nullptr, IID_PPV_ARGS(&upload)));
            unsigned char* data = nullptr; Check(upload->Map(0, nullptr, reinterpret_cast<void**>(&data)));
            for (unsigned y = 0; y != 8; ++y)
            {
                auto* row = reinterpret_cast<float*>(data + fp.Offset + y * fp.Footprint.RowPitch);
                for (unsigned x = 0; x != 8; ++x)
                    if (guide == depth.Get())
                        row[x] = 0.25f + float(x) / 32.0f + float(y) / 64.0f; // fixture plane depth
                    else { row[2*x] = 1.0f; row[2*x+1] = -0.5f; } // fixture plane motion, pixels
            }
            upload->Unmap(0, nullptr);
            owner._state->Barrier(cmd.Get(), guide, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                                  D3D12_RESOURCE_STATE_COPY_DEST);
            D3D12_TEXTURE_COPY_LOCATION source {}, target {};
            source.pResource = upload.Get(); source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            source.PlacedFootprint = fp; target.pResource = guide; target.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            cmd->CopyTextureRegion(&target, 0, 0, 0, &source, nullptr);
            owner._state->Barrier(cmd.Get(), guide, D3D12_RESOURCE_STATE_COPY_DEST,
                                  D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            uploads.push_back(upload);
        }
        Check(cmd->Close()); ID3D12CommandList* lists[] { cmd.Get() };
        ++drainValue; Check(drainFence->SetEventOnCompletion(drainValue, event));
        queue->ExecuteCommandLists(1, lists); Check(queue->Signal(drainFence.Get(), drainValue));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T4_GUIDE_INIT_TIMEOUT");
    }
    void VerifyGuideCopies()
    {
        auto& slot = owner._state->late.slots[0];
        for (auto* guide : { slot.depth.Get(), slot.motion.Get() })
        {
            const auto td = guide->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {}; UINT64 bytes = 0;
            device->GetCopyableFootprints(&td, 0, 1, 0, &fp, nullptr, nullptr, &bytes);
            D3D12_RESOURCE_DESC bd {}; bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = bytes;
            bd.Height = 1; bd.DepthOrArraySize = bd.MipLevels = 1; bd.SampleDesc.Count = 1;
            bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
            ComPtr<ID3D12Resource> readback;
            Check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST,
                nullptr, IID_PPV_ARGS(&readback)));
            ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
            Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
            Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
            owner._state->Barrier(cmd.Get(), guide, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
            D3D12_TEXTURE_COPY_LOCATION source {}, target {};
            source.pResource = guide; source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            target.pResource = readback.Get(); target.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            target.PlacedFootprint = fp; cmd->CopyTextureRegion(&target, 0, 0, 0, &source, nullptr);
            owner._state->Barrier(cmd.Get(), guide, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
            Check(cmd->Close()); ID3D12CommandList* lists[] { cmd.Get() };
            ++drainValue; Check(drainFence->SetEventOnCompletion(drainValue, event));
            queue->ExecuteCommandLists(1, lists); Check(queue->Signal(drainFence.Get(), drainValue));
            Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T4_GUIDE_READBACK_TIMEOUT");
            float* data = nullptr; Check(readback->Map(0, nullptr, reinterpret_cast<void**>(&data)));
            const bool valid = guide == slot.depth.Get() ? data[0] == 0.25f : data[0] == 1.0f && data[1] == -0.5f;
            readback->Unmap(0, nullptr); Expect(valid, "T4_PRODUCTION_GUIDE_COPY");
        }
    }
    ID3D12GraphicsCommandList* Capture(bool submit = true, ID3D12CommandQueue* producerQueue = nullptr,
                                     bool knownApplication = false, uint64_t application = 0)
    {
        if (!producerQueue) producerQueue = queue.Get();
        ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
        auto consumer = DlssNr::CaptureFinishedConsumer();
        if (knownApplication)
        {
            consumer.identity.application = application;
            consumer.identity.applicationKnown = true;
        }
        const auto before = owner._state->runs;
        Expect(owner.ProcessSeam(cmd.Get(), &params, true, producerQueue, false, application, false, 0, consumer),
               "T4_BEFORE_SCHEDULER");
        Expect(owner.ProcessSeam(cmd.Get(), &params, false, producerQueue, false, application, false, 0, consumer),
               "T4_AFTER_SCHEDULER");
        Expect(owner._state->runs == before, "T4_RECONSTRUCTION_EVALUATED");
        Check(cmd->Close()); allocators.push_back(allocator); producers.push_back(cmd);
        if (submit)
        {
            ID3D12CommandList* lists[] { cmd.Get() };
            hkNrExecuteCommandLists(producerQueue, 1, lists);
        }
        return cmd.Get();
    }
    void Present(bool one = false, UINT flags = 0, bool skipped = false, IDXGISwapChain* sc = nullptr)
    {
        if (!sc) sc = chain.Get();
        bool skip = skipped; const auto before = Plugin::forwards;
        Check(one ? present1(sc, 0, flags, nullptr, skip) : present(sc, 0, flags, skip));
        Expect(Plugin::forwards == before + 1, "T4_FORWARD_ONCE");
    }
    void Discard(ID3D12GraphicsCommandList* cmd)
    {
        const auto at = std::find_if(producers.begin(), producers.end(), [&](const auto& p) { return p.Get() == cmd; });
        Expect(at != producers.end(), "T4_DISCARD_IDENTITY");
        auto index = size_t(at - producers.begin());
        Check(cmd->Reset(allocators[index].Get(), nullptr));
        owner._state->FinishedPictureResetCommandList(cmd);
        Check(cmd->Close());
    }
    void VisibleEdit()
    {
        ComPtr<ID3D12Resource> picture; Check(chain->GetBuffer(0, IID_PPV_ARGS(&picture)));
        const auto td = picture->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {}; UINT64 bytes = 0;
        device->GetCopyableFootprints(&td, 0, 1, 0, &fp, nullptr, nullptr, &bytes);
        D3D12_RESOURCE_DESC bd {}; bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = bytes;
        bd.Height = 1; bd.DepthOrArraySize = bd.MipLevels = 1; bd.SampleDesc.Count = 1;
        bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
        ComPtr<ID3D12Resource> readback;
        Check(device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST,
            nullptr, IID_PPV_ARGS(&readback)));
        ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
        Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        Check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
        owner._state->Barrier(cmd.Get(), picture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION source {}, target {};
        source.pResource = picture.Get(); source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        target.pResource = readback.Get(); target.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        target.PlacedFootprint = fp; cmd->CopyTextureRegion(&target, 0, 0, 0, &source, nullptr);
        owner._state->Barrier(cmd.Get(), picture.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
        Check(cmd->Close()); ID3D12CommandList* lists[] { cmd.Get() };
        ++drainValue; Check(drainFence->SetEventOnCompletion(drainValue, event));
        queue->ExecuteCommandLists(1, lists); Check(queue->Signal(drainFence.Get(), drainValue));
        Expect(WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "T4_READBACK_TIMEOUT");
        unsigned char* data = nullptr; Check(readback->Map(0, nullptr, reinterpret_cast<void**>(&data)));
        const bool green = data[0] == 0 && data[1] == 255 && data[2] == 0 && data[3] == 255;
        readback->Unmap(0, nullptr); Expect(green, "T4_VISIBLE_FIXTURE_EDIT");
    }
    ~Fixture()
    {
        betweenPromiseAndExecute = {};
        try
        {
            Drain(queue.Get()); Drain(crossQueue.Get());
            for (auto& cmd : producers)
                owner._state->FinishedPictureResetCommandList(cmd.Get());
            owner._state->late.Cancel();
            for (auto& slot : owner._state->late.slots)
                Expect(!slot.owned && !slot.promisePending && owner._state->late.Finished(slot), "T4_OWNED_CLOSURE");
        }
        catch (...) { std::puts("T4_CLEANUP_FAILURE"); std::terminate(); }
        activeNrOwner = nullptr; nrOwners.clear(); State::Instance().currentSwapchain = nullptr;
        State::Instance().currentFG = nullptr; State::Instance().currentFGSwapchain = nullptr;
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
        CloseHandle(event); event = nullptr;
    }
};

static const char* selectedCase = nullptr;
static unsigned executedCases = 0;
static void Case(const char* name, const std::function<void()>& run)
{
    if (selectedCase && std::strcmp(selectedCase, name)) return;
    ++executedCases;
    run(); std::printf("T4_CASE_PASS=%s\n", name); std::fflush(stdout);
}
int main(int argc, char** argv) try
{
    if (argc == 3 && !std::strcmp(argv[1], "--case")) selectedCase = argv[2];
    else if (argc != 1) throw std::runtime_error("T4_INVALID_ARGUMENTS");
    Case("absent_capture", [] { Fixture f; f.Present(); Expect(f.owner._state->runs == 0, "T4_ABSENT"); });
    Case("current_real_guides_duplicate_and_multipass", [] {
        Fixture f; f.Capture(); f.Present(); f.Present(true); f.Present();
        Expect(f.owner._state->runs == 1 && f.owner._state->nr.successfulDispatches == 2, "T4_DUPLICATE_MULTIPASS");
        Expect(f.owner._state->lastRunSerial == 1, "T4_PRODUCER_SERIAL"); f.VisibleEdit(); f.VerifyGuideCopies();
    });
    Case("invalid_real_guide_region", [] {
        Fixture f; f.params.Set(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, 8u);
        f.Capture(); f.Present(); Expect(f.owner._state->runs == 0, "T4_INVALID_REGION");
        f.params.Set(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, 0u);
        f.params.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, 9u);
        f.Capture(); f.Present(true); Expect(f.owner._state->runs == 0, "T4_OVERSIZED_REGION");
    });
    Case("missing_real_guide_and_unknown_state", [] {
        Fixture f; f.Capture(); f.params.Set(NVSDK_NGX_Parameter_Depth, static_cast<ID3D12Resource*>(nullptr));
        f.Capture(); f.Present(); Expect(f.owner._state->runs == 0, "T4_MISSING_GUIDE");
        f.params.Set(NVSDK_NGX_Parameter_Depth, f.depth.Get());
        Config::Instance()->DepthResourceBarrier = { 0, true };
        f.Capture(); f.Present(); Expect(f.owner._state->runs == 0, "T4_UNKNOWN_STATE");
        Config::Instance()->DepthResourceBarrier = {};
    });
    Case("equal_sized_foreign_consumer", [] {
        Fixture f; f.Capture(); f.Present(false, 0, false, f.foreignChain.Get());
        Expect(f.owner._state->runs == 0, "T4_FOREIGN_CONSUMER");
        f.Present(); Expect(f.owner._state->runs == 1, "T4_ASSOCIATED_CONSUMER");
    });
    Case("generic_streamline_dispatch_exclusivity", [] {
        Fixture f; Check(f.chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey, nullptr));
        f.Capture(); DlssNr::ApplyToFinishedPicture(f.chain.Get(), f.queue.Get());
        DlssNr::ApplyToFinishedPicture(f.chain.Get(), f.queue.Get());
        Expect(f.owner._state->runs == 1, "T4_GENERIC_ONCE"); f.VisibleEdit();
        Check(f.chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey, f.queue.Get()));
        f.Capture(); DlssNr::ApplyToFinishedPicture(f.chain.Get(), f.queue.Get());
        Expect(f.owner._state->runs == 1, "T4_DISPATCH_EXCLUSIVITY");
        f.Present(); Expect(f.owner._state->runs == 2, "T4_STREAMLINE_OWNS_HANDOFF");
    });
    Case("buffer_generation_reset", [] {
        Fixture f; f.Capture(true, nullptr, true, 17); f.Present(); f.Drain();
        const auto old = DlssNr::StreamlinePicture::Consumer(f.chain.Get());
        Check(f.chain->ResizeBuffers(0, 8, 8, DXGI_FORMAT_UNKNOWN, 0));
        const auto fresh = DlssNr::StreamlinePicture::Consumer(f.chain.Get());
        Expect(old.identity.generation != fresh.identity.generation, "T4_GENERATION_STAMP");
        f.Present(true); Expect(f.owner._state->runs == 1, "T4_OLD_GENERATION");
        f.Capture(true, nullptr, true, 17); f.Present();
        Expect(f.owner._state->runs == 2, "T4_FRESH_GENERATION_TOKEN");
    });
    Case("newest_unresolved_older_ready", [] {
        Fixture f; f.Capture(); f.Drain(); auto* unresolved = f.Capture(false);
        f.Present(); Expect(f.owner._state->runs == 0, "T4_NEWEST_UNRESOLVED");
        Expect(f.owner._state->late.slots[1].owned, "T4_OWNERSHIP_PRESERVED");
        f.Discard(unresolved); f.Capture(); f.Present(); Expect(f.owner._state->runs == 1, "T4_DISCARD_RECOVERY");
    });
    Case("newest_unusable_older_ready", [] {
        Fixture f; f.Capture(); f.Drain();
        f.params.Set(NVSDK_NGX_Parameter_MV_Scale_X, std::numeric_limits<float>::quiet_NaN());
        f.Capture(); f.Present(); Expect(f.owner._state->runs == 0, "T4_NEWEST_UNUSABLE");
    });
    Case("promise_not_submission", [] {
        Fixture f; auto* cmd = f.Capture(false);
        betweenPromiseAndExecute = [&] { f.Present(); Expect(f.owner._state->runs == 0, "T4_PROMISE_NOT_SUBMISSION"); };
        ID3D12CommandList* lists[] { cmd }; hkNrExecuteCommandLists(f.queue.Get(), 1, lists);
        betweenPromiseAndExecute = {};
        f.Present(true); Expect(f.owner._state->runs == 0, "T4_REFUSED_INTERVAL_NOT_REVIVED");
        f.Capture(); f.Present(); Expect(f.owner._state->runs == 1, "T4_ACTUAL_SUBMISSION");
    });
    Case("cross_queue_nonblocking_then_completed", [] {
        Fixture f; ComPtr<ID3D12Fence> gate; Check(f.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
        Check(f.crossQueue->Wait(gate.Get(), 1)); f.Capture(true, f.crossQueue.Get());
        f.Present(); const auto runs = f.owner._state->runs;
        Check(gate->Signal(1)); f.Drain(f.crossQueue.Get()); Expect(runs == 0, "T4_CROSS_QUEUE_FUTURE");
        f.Capture(true, f.crossQueue.Get()); f.Drain(f.crossQueue.Get()); f.Present(true);
        Expect(f.owner._state->runs == 1, "T4_CROSS_QUEUE_COMPLETED");
    });
    Case("same_queue_order_without_completion", [] {
        Fixture f; ComPtr<ID3D12Fence> gate; Check(f.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
        Check(f.queue->Wait(gate.Get(), 1)); f.Capture(); f.Present();
        const auto runs = f.owner._state->runs; Check(gate->Signal(1)); f.Drain();
        Expect(runs == 1, "T4_SAME_QUEUE_ORDER"); f.VisibleEdit();
    });
    Case("device_removal_sentinel", [] {
        Fixture f; f.Capture(); f.Drain(); auto& slot = f.owner._state->late.slots[0];
        Check(slot.fence->Signal(UINT64_MAX)); f.Present(); Expect(f.owner._state->runs == 0, "T4_REMOVAL");
        // An injected sentinel is not physical device removal; restore this owned fence for fixture closure.
        Check(slot.fence->Signal(slot.done)); f.Drain();
    });
    Case("foreign_device", [] {
        Fixture f; ComPtr<ID3D12Device> foreign; ComPtr<ID3D12CommandQueue> foreignQueue;
        ComPtr<ID3D12DeviceFactory> deviceFactory;
        Check(D3D12GetInterface(CLSID_D3D12DeviceFactory, IID_PPV_ARGS(&deviceFactory)));
        Check(deviceFactory->InitializeFromGlobalState());
        Check(deviceFactory->SetFlags(D3D12_DEVICE_FACTORY_FLAG_DISALLOW_STORING_NEW_DEVICE_AS_SINGLETON));
        Check(deviceFactory->CreateDevice(f.adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&foreign)));
        Expect(!DlssNr::StreamlinePicture::SameDevice(f.device.Get(), foreign.Get()), "T4_DISTINCT_WARP_DEVICE");
        D3D12_COMMAND_QUEUE_DESC q {}; Check(foreign->CreateCommandQueue(&q, IID_PPV_ARGS(&foreignQueue)));
        f.Capture(); ComPtr<ID3D12Resource> picture; Check(f.chain->GetBuffer(0, IID_PPV_ARGS(&picture)));
        auto consumer = DlssNr::StreamlinePicture::Consumer(f.chain.Get()); DlssNr::XeFGCapture facts;
        Expect(!f.owner._state->AdmitFinishedCapture(picture.Get(), foreignQueue.Get(), consumer.identity, facts, false),
               "T4_FOREIGN_DEVICE");
    });
    Case("test_skip_shutdown_forwarding", [] {
        Fixture f; f.Capture(); f.Present(false, DXGI_PRESENT_TEST);
        State::Instance().isShuttingDown = true; f.Present(); State::Instance().isShuttingDown = false;
        Config::Instance()->DlssNrEnabled.stored = false; f.Present(); Config::Instance()->DlssNrEnabled.stored = true;
        Config::Instance()->DlssNrFinishedPicture.stored = false; f.Present(); Config::Instance()->DlssNrFinishedPicture.stored = true;
        Plugin::handled = false; f.Present(); Plugin::handled = true;
        Expect(f.owner._state->runs == 0, "T4_GUARDS"); f.Present(true); Expect(f.owner._state->runs == 1, "T4_TEST_NOT_CONSUMED");
        f.Capture(); f.Present(true, 0, true); f.Present();
        Expect(f.owner._state->runs == 1, "T4_SKIPPED_NOT_REPLAYED");
    });
    Case("concurrent_first_read_retained_lifetime", [] {
        Fixture f; HANDLE start = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        HANDLE ready[2] { CreateEventW(nullptr, TRUE, FALSE, nullptr), CreateEventW(nullptr, TRUE, FALSE, nullptr) };
        HANDLE done[2] { CreateEventW(nullptr, TRUE, FALSE, nullptr), CreateEventW(nullptr, TRUE, FALSE, nullptr) };
        DlssNr::StreamlinePicture::ConsumerSnapshot snapshots[2];
        std::thread readers[2];
        for (unsigned i = 0; i != 2; ++i)
            readers[i] = std::thread([&, i] {
                SetEvent(ready[i]);
                if (WaitForSingleObject(start, 5000) == WAIT_OBJECT_0)
                    snapshots[i] = DlssNr::StreamlinePicture::Consumer(f.chain.Get());
                SetEvent(done[i]);
            });
        const auto prepared = WaitForMultipleObjects(2, ready, TRUE, 5000); SetEvent(start);
        const auto finished = WaitForMultipleObjects(2, done, TRUE, 5000);
        for (auto& reader : readers) reader.join();
        CloseHandle(start); for (unsigned i = 0; i != 2; ++i) { CloseHandle(ready[i]); CloseHandle(done[i]); }
        Expect(prepared == WAIT_OBJECT_0 && finished == WAIT_OBJECT_0 &&
               snapshots[0].identity.SameConsumer(snapshots[1].identity), "T4_FIRST_READ");
        f.Capture(); auto& slot = f.owner._state->late.slots[0];
        Expect(slot.consumerOwner && slot.consumerDevice, "T4_RETAINED_CONSUMER_DEVICE");
        f.owner._state->late.consumerOwner.Reset(); snapshots[0] = {}; snapshots[1] = {};
        f.chain.Reset();
        ComPtr<IDXGISwapChain> retained; Check(slot.consumerOwner.As(&retained));
        ComPtr<ID3D12Resource> buffer; Check(retained->GetBuffer(0, IID_PPV_ARGS(&buffer)));
        Check(retained.As(&f.chain)); f.Present(); Expect(f.owner._state->runs == 1, "T4_RETAINED_HANDOFF");
    });
    Case("xefg_accepted_token_duplicate_and_discontinuity", [] {
        Fixture f; Fg application; application.application = 41;
        ::State::Instance().currentFG = &application; ::State::Instance().currentFGSwapchain = f.chain.Get();
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
        XeFG_Dx12 provider; provider._swapChain = f.chain.Get(); provider._gameCommandQueue = f.queue.Get();
        provider._lastDispatchedFrame = 41; provider._nrHandoff.Reset(provider._nrGeneration);
        f.Capture(); provider.OwnedNrHandoff(); provider.OwnedNrHandoff();
        Expect(f.owner._state->runs == 1 && lastXefgSkip == "duplicate_frame", "T4_XEFG_DUPLICATE");
        ::State::Instance().frameCount += 1000; f.Capture(); provider.OwnedNrHandoff();
        Expect(f.owner._state->runs == 1, "T4_XEFG_DISPLAY_CLOCK");
        f.Drain(); provider.ResetNrHandoff();
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
        f.Capture(); provider.OwnedNrHandoff();
        Expect(f.owner._state->runs == 2, "T4_XEFG_GENERATION_RESET");
        f.VisibleEdit();
        ::State::Instance().currentFG = nullptr; ::State::Instance().currentFGSwapchain = nullptr;
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
    });
    Case("xefg_ambiguity_foreign_owner_and_packet_revalidation", [] {
        Fixture f; Fg application; application.application = 77;
        ::State::Instance().currentFG = &application; ::State::Instance().currentFGSwapchain = f.chain.Get();
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
        XeFG_Dx12 provider; provider._swapChain = f.foreignChain.Get(); provider._gameCommandQueue = f.queue.Get();
        provider._lastDispatchedFrame = 77; provider._nrHandoff.Reset(provider._nrGeneration);
        f.Capture(); provider.OwnedNrHandoff(); Expect(f.owner._state->runs == 0, "T4_XEFG_FOREIGN_OWNER");
        provider._swapChain = f.chain.Get(); application.application = 78;
        provider.OwnedNrHandoff();
        Expect(f.owner._state->runs == 0 && lastXefgSkip == "ambiguous_capture", "T4_XEFG_AMBIGUOUS_TOKEN");
        provider._lastDispatchedFrame = 78; f.Capture(); f.Drain();
        ComPtr<ID3D12Resource> picture; Check(f.chain->GetBuffer(0, IID_PPV_ARGS(&picture)));
        auto consumer = DlssNr::StreamlinePicture::Consumer(f.chain.Get());
        consumer.identity.application = 78; consumer.identity.applicationKnown = true;
        DlssNr::XeFGCapture offered;
        Expect(DlssNr::XeFGPendingCapture(picture.Get(), f.queue.Get(), DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                         offered, consumer.identity), "T4_XEFG_FACTS");
        f.Capture();
        Expect(!DlssNr::ApplyXeFGPicture(picture.Get(), f.queue.Get(), DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, offered),
               "T4_XEFG_PACKET_REVALIDATION");
        f.Capture(); provider.OwnedNrHandoff(); Expect(f.owner._state->runs == 1, "T4_XEFG_CURRENT_PACKET");
        ::State::Instance().currentFG = nullptr; ::State::Instance().currentFGSwapchain = nullptr;
        DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::Generic);
    });
    Case("skip_test_discontinuity_untracked_gpu_retention", [] {
        {
            Fixture f; ComPtr<ID3D12Fence> gate;
            Check(f.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
            Check(f.queue->Wait(gate.Get(), 1)); f.Capture(); f.Capture();
            f.Present(false, DXGI_PRESENT_TEST);
            const bool testRetained = f.owner._state->late.slots[0].pending && f.owner._state->late.slots[1].pending;
            f.Present(true, 0, true); f.Present();
            const auto& slots = f.owner._state->late.slots;
            const bool skippedClosed = !slots[0].pending && !slots[1].pending && f.owner._state->runs == 0;
            const bool gpuRetained = slots[0].submitted && slots[1].submitted && slots[0].depth && slots[1].depth &&
                !f.owner._state->late.Finished(slots[0]) && !f.owner._state->late.Finished(slots[1]);
            Check(gate->Signal(1)); f.Drain();
            Expect(testRetained && skippedClosed && gpuRetained, "T4_SKIP_MAX_UNTRACKED_GPU_RETENTION");
            f.VerifyGuideCopies();
        }
        {
            Fixture f; Fg application; application.application = 91;
            ::State::Instance().currentFG = &application; ::State::Instance().currentFGSwapchain = f.chain.Get();
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
            XeFG_Dx12 provider; provider._swapChain = f.chain.Get(); provider._gameCommandQueue = f.queue.Get();
            provider._lastDispatchedFrame = 91; provider._nrHandoff.Reset(provider._nrGeneration);
            ComPtr<ID3D12Fence> gate;
            Check(f.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
            Check(f.queue->Wait(gate.Get(), 1)); f.Capture(); application.application = 92; f.Capture();
            provider.OwnedNrHandoff(); // later token is not in accepted-frame facts; close-max must still cover it
            provider._lastDispatchedFrame = 92; provider.OwnedNrHandoff();
            const bool noReplay = f.owner._state->runs == 0 && !f.owner._state->late.slots[1].pending;
            f.Capture(); provider.ResetNrHandoff();
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
            provider.OwnedNrHandoff();
            const auto& slot = f.owner._state->late.slots[2];
            const bool resetRetained = !slot.pending && slot.submitted && slot.depth && !f.owner._state->late.Finished(slot);
            Check(gate->Signal(1)); f.Drain();
            Expect(noReplay && resetRetained && f.owner._state->runs == 0, "T4_XEFG_UNTRACKED_SKIP_RESET");
        }
    });
    Expect(executedCases != 0, "T4_UNKNOWN_CASE");
    std::printf("T4_PRODUCTION_WRAPPER_PASS cases=%u gpu=WARP nvidia=not_run owned_resources_closed=1\n", executedCases);
    return 0;
}
catch (const std::exception& error) { std::printf("T4_FAIL=%s\n", error.what()); return 1; }
