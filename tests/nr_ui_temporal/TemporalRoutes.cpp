// The runner supplies current production FGPresent and LocalPresent bodies.
// COM/service doubles expose CPU callback order, not GPU or SDK ordering.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_5.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

enum class API { DX11, DX12, Vulkan };
static constexpr API DX11 = API::DX11, DX12 = API::DX12;
static double fixtureClock = 100.0;
static std::vector<std::string> events;
static unsigned uiCalls = 0;
static unsigned originalCalls = 0;
static uint64_t application = 1, generation = 1;
static std::function<void()> nrCallback;
static void Record(const char* event);

#define main ExistingOwnerRoutingMain
#include "TemporalAdapters.inc"
#undef main

static void Record(const char* event)
{
    events.emplace_back(event);
    if (std::strcmp(event, "NR.generic") == 0 && nrCallback)
        nrCallback();
}

namespace Dx11wDx12Sync
{
std::shared_mutex& PresentResizeMutex() { static std::shared_mutex mutex; return mutex; }
}
namespace D3D12Hooks { void HookDevice(ID3D12Device*) {} }
namespace ReflexHooks { void update(bool, bool) {} }
namespace XellHooks { void update() {} }
namespace Util
{
bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; }
void GetDeviceRemovedReason(ID3D11Device*) {}
}
namespace DlssNr
{
void ApplyToFinishedPictureDx11(IDXGISwapChain*) { Record("NR.dx11"); }
}
namespace MenuOverlayDx
{
void Present(IDXGISwapChain*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*, IUnknown*, HWND, bool)
{
    ++uiCalls;
    Record("UI");
}
}
namespace fakenvapi
{
void reportFGPresent(IDXGISwapChain*, bool, bool generated)
{
    Record(generated ? "Classification.generated" : "Classification.application");
}
}
static uint64_t _frameCounter = 0;
static double _lastFrameTime = 0;
static bool _dx11Device = false, _dx12Device = false;
#include "TemporalLocalPresent.inc"

struct CpuQueue final : ID3D12CommandQueue
{
    ULONG refs = 1;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
    {
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12CommandQueue)) return E_NOINTERFACE;
        *out = this; AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void** out) override { *out = nullptr; return E_NOINTERFACE; }
    void STDMETHODCALLTYPE UpdateTileMappings(ID3D12Resource*, UINT, const D3D12_TILED_RESOURCE_COORDINATE*,
        const D3D12_TILE_REGION_SIZE*, ID3D12Heap*, UINT, const D3D12_TILE_RANGE_FLAGS*, const UINT*,
        const UINT*, D3D12_TILE_MAPPING_FLAGS) override {}
    void STDMETHODCALLTYPE CopyTileMappings(ID3D12Resource*, const D3D12_TILED_RESOURCE_COORDINATE*,
        ID3D12Resource*, const D3D12_TILED_RESOURCE_COORDINATE*, const D3D12_TILE_REGION_SIZE*,
        D3D12_TILE_MAPPING_FLAGS) override {}
    void STDMETHODCALLTYPE ExecuteCommandLists(UINT, ID3D12CommandList* const*) override { Record("Queue.fixture"); }
    void STDMETHODCALLTYPE SetMarker(UINT, const void*, UINT) override {}
    void STDMETHODCALLTYPE BeginEvent(UINT, const void*, UINT) override {}
    void STDMETHODCALLTYPE EndEvent() override {}
    HRESULT STDMETHODCALLTYPE Signal(ID3D12Fence*, UINT64) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Wait(ID3D12Fence*, UINT64) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetTimestampFrequency(UINT64*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetClockCalibration(UINT64*, UINT64*) override { return E_NOTIMPL; }
    D3D12_COMMAND_QUEUE_DESC STDMETHODCALLTYPE GetDesc() override { return {}; }
};

struct CpuChain final : IDXGISwapChain1
{
    ULONG refs = 1;
    HRESULT result = static_cast<HRESULT>(0x08765432);
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
    {
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IDXGISwapChain) &&
            iid != __uuidof(IDXGISwapChain1)) return E_NOINTERFACE;
        *out = this; AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { return --refs; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetParent(REFIID, void**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Present(UINT, UINT) override { ++originalCalls; Record("Original"); return result; }
    HRESULT STDMETHODCALLTYPE GetBuffer(UINT, REFIID, void**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetFullscreenState(BOOL, IDXGIOutput*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetFullscreenState(BOOL*, IDXGIOutput**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDesc(DXGI_SWAP_CHAIN_DESC* desc) override { *desc = {}; return S_OK; }
    HRESULT STDMETHODCALLTYPE ResizeBuffers(UINT, UINT, UINT, DXGI_FORMAT, UINT) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE ResizeTarget(const DXGI_MODE_DESC*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetContainingOutput(IDXGIOutput**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetFrameStatistics(DXGI_FRAME_STATISTICS*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetLastPresentCount(UINT*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDesc1(DXGI_SWAP_CHAIN_DESC1*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetFullscreenDesc(DXGI_SWAP_CHAIN_FULLSCREEN_DESC*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetHwnd(HWND*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetCoreWindow(REFIID, void**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Present1(UINT sync, UINT flags, const DXGI_PRESENT_PARAMETERS*) override
    { return Present(sync, flags); }
    BOOL STDMETHODCALLTYPE IsTemporaryMonoSupported() override { return FALSE; }
    HRESULT STDMETHODCALLTYPE GetRestrictToOutput(IDXGIOutput**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetBackgroundColor(const DXGI_RGBA*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetBackgroundColor(DXGI_RGBA*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetRotation(DXGI_MODE_ROTATION) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetRotation(DXGI_MODE_ROTATION*) override { return E_NOTIMPL; }
};

static CpuQueue* renderQueue;
static HRESULT __stdcall NestedPresent(IDXGISwapChain* chain, UINT sync, UINT flags)
{
    return LocalPresent(chain, sync, flags, nullptr, renderQueue, nullptr, false);
}
static HRESULT __stdcall NestedPresent1(IDXGISwapChain1* chain, UINT sync, UINT flags,
                                        const DXGI_PRESENT_PARAMETERS* parameters)
{
    return LocalPresent(chain, sync, flags, parameters, renderQueue, nullptr, false);
}
struct RouteFeature final : IFGFeature
{
    bool active = true, paused = false;
    bool IsActive() override { return active; }
    bool IsPaused() override { return paused; }
    uint64_t FrameCount() override { return application; }
    void Present() override { Record("Feature.Present.adapter"); }
    unsigned GetInterpolatedFrameCount() override { return 0; }
};

namespace PipelineUi
{
enum class TimingSource { Wrapped, FgPresent, Vulkan };
static double selectedInterval = 0;
static TimingSource selectedSource = TimingSource::Wrapped;
TimingSource IntervalSource(bool vulkan, bool fg)
{ return vulkan ? TimingSource::Vulkan : fg ? TimingSource::FgPresent : TimingSource::Wrapped; }
void DrawTimingBar(double, double interval, TimingSource source)
{ selectedInterval = interval; selectedSource = source; }
}
static void SelectActualMenuInterval()
{
    std::optional<double> ms = 1.0;
#include "TemporalTimingSelection.inc"
}

static void Expect(bool ok, const char* assertion)
{
    if (!ok) { std::printf("TASK3_ASSERTION=%s\n", assertion); throw std::runtime_error(assertion); }
}
static void Trace(const char* route, const char* state, const CpuChain& chain)
{
    SelectActualMenuInterval();
    std::printf("TASK3_ROUTE route=%s state=%s consumer=%p generation=%llu application=%llu "
                "queue=%p ui=%u originals=%u fg_interval=%.3f wrapped_interval=%.3f selected=%.3f events=",
                route, state, &chain, static_cast<unsigned long long>(generation),
                static_cast<unsigned long long>(application), renderQueue, uiCalls, originalCalls,
                State::Instance().lastFGFrameTime, State::Instance().presentFrameTime,
                PipelineUi::selectedInterval);
    for (const auto& event : events) std::printf("%s;", event.c_str());
    std::puts("");
}

int main() try
{
    Expect(ExistingOwnerRoutingMain() == 0, "ExistingOwnerRouting");
    CpuQueue queue;
    CpuChain owner, stale;
    renderQueue = &queue;
    RouteFeature feature;
    auto& state = State::Instance();
    state.currentFeature = nullptr;
    state.currentCommandQueue = &queue;
    state.currentFGSwapchain = &owner;
    state.swapchainInteropApi = SwapchainInteropApi::None;
    state.swapchainApi = API::DX12;
    state.reflexLimitsFps = true;
    FGHooks::o_FGSCPresent = NestedPresent;
    FGHooks::o_FGSCPresent1 = NestedPresent1;
    DXGI_PRESENT_PARAMETERS parameters {};
    for (const auto output : {FGOutput::DLSSG, FGOutput::XeFG})
    {
        state.activeFgOutput = output;
        state.currentFG = &feature;
        for (unsigned mode = 0; mode < 3; ++mode)
        {
            feature.active = mode != 1;
            feature.paused = mode == 2;
            for (unsigned one = 0; one < 2; ++one)
            {
                events.clear(); uiCalls = originalCalls = 0;
                fixtureClock += 16.0; ++application;
                const auto hr = FGHooks::FGPresent(&owner, 0, 0, one ? &parameters : nullptr);
                Expect(hr == owner.result && originalCalls == 1, "OriginalHRESULTAndOnce");
                Expect(uiCalls == 1, "AcceptedCallbackUiOnce");
                const auto ui = std::find(events.begin(), events.end(), "UI");
                const auto nr = std::find(events.begin(), events.end(), "NR.generic");
                if (output == FGOutput::DLSSG || mode != 0)
                    Expect(nr != events.end() && nr < ui, "TemporalCallBeforeOverlay");
                Expect(queue.refs == 1, "QueueReferenceLifetime");
                Trace(output == FGOutput::DLSSG ? "DLSS" : "XeFG",
                      mode == 0 ? "active" : mode == 1 ? "inactive" : "paused", owner);
            }
        }
    }
    state.activeFgOutput = FGOutput::XeFG;
    feature.active = true; feature.paused = false;
    events.clear(); uiCalls = originalCalls = 0;
    const auto beforeWriter = state.lastFGFrameTime;
    fixtureClock += 19.0;
    const auto staleResult = FGHooks::FGPresent(&stale, 0, 0, nullptr);
    Expect(staleResult == stale.result && originalCalls == 1, "StaleOriginalHRESULTAndOnce");
    Expect(state.lastFGFrameTime == beforeWriter, "RefusedOwnerDoesNotWriteFgTimer");
    Expect(std::find(events.begin(), events.end(), "Feature.Present.adapter") == events.end(),
           "RefusedOwnerDoesNotDriveFeature");
    Trace("XeFG", "stale-hook-forwarded-to-lower-wrapper-fixture", stale);
    std::printf("TASK3_BOUNDARY lower_wrapper_ui=%u sdk_nested_owner_mapping=UNPROVEN\n", uiCalls);

    // Source-matched lower callback, not a claim that a supported SDK bypasses its FG hook.
    events.clear(); uiCalls = originalCalls = 0;
    feature.active = false;
    fixtureClock += 23.0;
    const auto bypassResult = LocalPresent(&owner, 0, 0, nullptr, &queue, nullptr, false);
    Expect(bypassResult == owner.result && originalCalls == 1, "WrappedOriginalHRESULTAndOnce");
    SelectActualMenuInterval();
    Expect(state.lastFGFrameTime == beforeWriter, "WrappedRetainedFeatureDoesNotWriteFgTimer");
    Expect(state.presentFrameTime != beforeWriter, "WrappedTimerWriterObserved");
    Trace("XeFG", "conditional-retained-feature-hook-bypass", owner);
    std::puts("TASK3_TIMER supported_callback_bypass=UNPROVEN pointer_existence_is_not_freshness=1");
    state.currentFG = nullptr;
    state.currentCommandQueue = nullptr;
    state.currentFGSwapchain = nullptr;
    std::puts("TASK3_CPU_TRACE_COMPLETE gpu=NOT_RUN nvidia=NOT_RUN");
    return 0;
}
catch (const std::exception& error)
{
    std::printf("TASK3_CPU_FAILURE=%s\n", error.what());
    return 1;
}
