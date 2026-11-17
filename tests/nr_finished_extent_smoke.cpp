// CPU only: real preparation header and verbatim admission/claim/apply-preparation
// bodies. Resource/device accessors are POD doubles; no D3D device is created.
#include <shaders/dlssnr/DlssNr_FinishedPicture.h>
#include <dlssnr/DlssNr_FinishedConsumer.h>
#include <dlssnr/DlssNr_FinishedReady.h>
#include <dlssnr/DlssNr_FinishedLag.h>
#include <shaders/dlssnr/DlssNr_LateSlot.h>
#include <atomic>
#include <cstdio>
#include <stdexcept>

static void Expect(bool value, const char* message)
{
    if (!value) throw std::runtime_error(message);
}
static D3D12_RESOURCE_DESC Texture(unsigned width, unsigned height)
{
    D3D12_RESOURCE_DESC desc {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width; desc.Height = height;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    return desc;
}
struct CpuDevice {};
template<class T> struct CpuPtr
{
    T* value = nullptr;
    T* Get() const { return value; }
    T* operator->() const { return value; }
    T** operator&() { return &value; }
    explicit operator bool() const { return value != nullptr; }
    bool operator!=(std::nullptr_t) const { return value != nullptr; }
};
struct CpuResource
{
    D3D12_RESOURCE_DESC desc;
    CpuDevice* device;
    D3D12_RESOURCE_DESC GetDesc() const { return desc; }
    HRESULT GetDevice(CpuDevice** result) { *result = device; return S_OK; }
};
struct CpuQueue
{
    CpuDevice* device;
    HRESULT GetDevice(CpuDevice** result) { *result = device; return S_OK; }
};
struct CpuFence { uint64_t GetCompletedValue() const { return 0; } };
namespace DlssNr
{
struct XeFGCapture
{
    bool exists = false, submitted = false, sameQueue = false, ready = false;
    uint64_t serial = 0;
    FinishedIdentity identity;
};
namespace StreamlinePicture
{
bool SameDevice(CpuDevice* a, CpuDevice* b) { return a && a == b; }
}
}
namespace Util
{
bool CheckForRealObject(const char*, CpuQueue*, IUnknown**) { return false; }
}
#define ID3D12Resource CpuResource
#define ID3D12CommandQueue CpuQueue
#define ID3D12Device CpuDevice
#undef IID_PPV_ARGS
#define IID_PPV_ARGS(value) value
template<class... T> void CpuLog(const char*, T&&...) {}
#define LOG_INFO(...) CpuLog(__VA_ARGS__)
#define LOG_DEBUG(...) CpuLog(__VA_ARGS__)

class DlssNr_Dx12
{
  public:
    struct State
    {
        DlssNr_Dx12& shader;
        struct LateContext
        {
            State& owner;
            explicit LateContext(State& state) : owner(state) {}
            template<class T> using ComPtr = CpuPtr<T>;
            struct Slot
            {
                bool pending = true, residualOnly = false, pinned = false, submitted = true;
                bool promisePending = false, guidesValid = true;
                bool owned = false;
                CpuPtr<void> commands;
                uint64_t serial = 1, ready = 1;
                DlssNr::FinishedIdentity identity;
                DlssNrFrameInfo frame;
                void* consumerOwner = nullptr;
                CpuPtr<CpuDevice> consumerDevice;
                CpuPtr<CpuQueue> producerQueue;
                CpuPtr<CpuResource> depth, motion;
                CpuPtr<CpuFence> fence;
            } slots[2];
            CpuPtr<CpuDevice> device;
            DlssNr::FinishedIdentity claimed;
            uint64_t claimedSerial = 0;
#include "finished_lag_member.inc"
            bool reset = false;
            void Cancel();
            void CapturedReset(bool value)
            {
                auto& frame = slots[0].frame;
                unsigned gameReset = value ? 1u : 0u;
#include "finished_capture_reset.inc"
            }
        } late { *this };
        void FinishedPictureResetCommandList(void*) {}
        bool AdmitFinishedCapture(CpuResource*, CpuQueue*, const DlssNr::FinishedIdentity&,
                                  DlssNr::XeFGCapture&, bool, uint64_t);
    };
};
#include "finished_admission.inc"
#include "finished_cancel.inc"

static bool ActualApplyPreparation(DlssNr_Dx12::State::LateContext::Slot& slot,
                                   const D3D12_RESOURCE_DESC& desc, DlssNrFrameInfo& result)
{
    const bool legacyBridge = false;
#include "finished_apply_prepare.inc"
#include "finished_apply_frame.inc"
    result = frame;
    return true;
}
struct Fixture
{
    CpuDevice device;
    CpuQueue queue { &device };
    CpuResource picture { Texture(2560, 1440), &device };
    CpuResource depth { Texture(1212, 681), &device };
    CpuResource motion { Texture(2064, 1160), &device };
    CpuFence fence;
    DlssNr_Dx12 shader;
    DlssNr_Dx12::State state { shader };
    DlssNr::FinishedIdentity consumer { &shader, &picture, 8, 468, true };
    Fixture()
    {
        auto& slot = state.late.slots[0];
        state.late.device.value = slot.consumerDevice.value = &device;
        slot.consumerOwner = &picture;
        slot.producerQueue.value = &queue;
        slot.depth.value = &depth; slot.motion.value = &motion; slot.fence.value = &fence;
        slot.identity = consumer;
        auto& f = slot.frame;
        f.FinishedPicture = f.IndependentCommands = f.DepthInverted = true;
        f.OutputWidth = 2048; f.OutputHeight = 1152;
        f.RenderSubrectWidth = 1204; f.RenderSubrectHeight = 677;
        f.DepthSubrectBaseX = 8; f.DepthSubrectBaseY = 4;
        f.MotionSubrectBaseX = 16; f.MotionSubrectBaseY = 8;
        f.MvScaleX = 2048; f.MvScaleY = -1152;
    }
    bool Admit(DlssNr::XeFGCapture& facts, bool claim = false)
    {
        return state.AdmitFinishedCapture(&picture, &queue, consumer, facts, claim, state.late.slots[0].serial);
    }
};
static void Adapted(bool lowResolution)
{
    Fixture f;
    auto& slot = f.state.late.slots[0];
    if (lowResolution)
    {
        slot.frame.MotionVectorsLowResolution = true;
        slot.frame.MvScaleX = 1204; slot.frame.MvScaleY = -677;
        f.motion.desc = Texture(1220, 685);
    }
    DlssNr::XeFGCapture facts;
    Expect(f.Admit(facts) && facts.ready && facts.sameQueue, "BF_EXTENT_ADMISSION");
    DlssNrFrameInfo prepared;
    Expect(ActualApplyPreparation(slot, f.picture.desc, prepared), "BF_EXTENT_APPLY_PREPARE");
    Expect(prepared.MvScaleX == (lowResolution ? 1505.0f : 2560.0f) &&
           prepared.MvScaleY == (lowResolution ? -846.25f : -1440.0f), "BF_EXTENT_MV_SCALE");
    Expect(prepared.OutputWidth == 2048 && prepared.OutputHeight == 1152 &&
           slot.frame.OutputWidth == 2048 && slot.frame.MvScaleX == (lowResolution ? 1204.0f : 2048.0f),
           "BF_EXTENT_SOURCE_METADATA");
    const auto regions = DlssNr::ResolveGuideRegions(
        {1212,681}, lowResolution ? DlssNr::GuideExtent{1220,685} : DlssNr::GuideExtent{2064,1160},
        {prepared.RenderSubrectWidth,prepared.RenderSubrectHeight}, {prepared.OutputWidth,prepared.OutputHeight},
        prepared.MotionVectorsLowResolution, prepared.DepthSubrectBaseX, prepared.DepthSubrectBaseY,
        prepared.MotionSubrectBaseX, prepared.MotionSubrectBaseY);
    Expect(regions.depth.x == 8 && regions.depth.y == 4 && regions.depth.width == 1204 &&
           regions.depth.height == 677 && regions.motion.x == 16 && regions.motion.y == 8 &&
           regions.motion.width == (lowResolution ? 1204u : 2048u) &&
           regions.motion.height == (lowResolution ? 677u : 1152u) && prepared.DepthInverted,
           "BF_EXTENT_GUIDE_COORDINATES");
    Expect(f.Admit(facts, true) && facts.ready && !slot.pending, "BF_EXTENT_CLAIM");
}
static void SameSize(unsigned width, unsigned height)
{
    Fixture f;
    auto& source = f.state.late.slots[0].frame;
    source.OutputWidth = width; source.OutputHeight = height;
    source.MvScaleX = float(width); source.MvScaleY = -float(height);
    f.picture.desc = Texture(width, height);
    f.motion.desc = Texture(width + 16, height + 8);
    DlssNr::XeFGCapture facts;
    DlssNrFrameInfo prepared;
    Expect(f.Admit(facts) && facts.ready &&
           ActualApplyPreparation(f.state.late.slots[0], f.picture.desc, prepared), "BF_EXTENT_SAME_SIZE");
    Expect(prepared.MvScaleX == float(width) && prepared.MvScaleY == -float(height), "BF_EXTENT_SAME_SIZE_MV");
}
static void SizeTransitions()
{
    Fixture f;
    const DlssNr::GuideExtent sizes[] {{2048,1152}, {2560,1440}, {1600,900}, {2048,1152}};
    for (const auto size : sizes)
    {
        f.picture.desc = Texture(size.width, size.height);
        DlssNr::XeFGCapture facts;
        DlssNrFrameInfo prepared;
        Expect(f.Admit(facts) && facts.ready &&
               ActualApplyPreparation(f.state.late.slots[0], f.picture.desc, prepared), "BF_EXTENT_TRANSITION");
        Expect(prepared.MvScaleX == float(size.width) && prepared.MvScaleY == -float(size.height) &&
               f.state.late.slots[0].frame.MvScaleX == 2048, "BF_EXTENT_TRANSITION_UNITS");
    }
}
static void StaleIdentities()
{
    for (unsigned kind = 0; kind < 3; ++kind)
    {
        Fixture f;
        auto& identity = f.state.late.slots[0].identity;
        if (kind == 0) identity.owner = &f.device;
        if (kind == 1) ++f.consumer.generation;
        if (kind == 2) ++f.consumer.application;
        DlssNr::XeFGCapture facts;
        Expect(!f.Admit(facts) && !facts.exists, "BF_EXTENT_STALE_IDENTITY");
    }
}
static void Refuse(unsigned scenario)
{
    Fixture f;
    auto& slot = f.state.late.slots[0];
    const char* names[] = {"BF_EXTENT_ASPECT_REFUSAL", "BF_EXTENT_MOTION_BOUNDS", "BF_EXTENT_DEPTH_BOUNDS",
                           "BF_EXTENT_METADATA_REQUIRED", "BF_EXTENT_MULTISAMPLE", "BF_EXTENT_NONFINITE"};
    switch (scenario)
    {
    case 0: f.picture.desc.Height = 1600; break;
    case 1: --f.motion.desc.Width; break;
    case 2: --f.depth.desc.Height; break;
    case 3: slot.frame.RenderSubrectWidth = 0; break;
    case 4: f.picture.desc.SampleDesc.Count = 4; break;
    case 5: slot.frame.MvScaleX = std::numeric_limits<float>::infinity(); break;
    default: throw std::runtime_error("Invalid test scenario");
    }
    DlssNr::XeFGCapture facts;
    DlssNrFrameInfo prepared;
    Expect(f.Admit(facts) && facts.exists && !facts.ready &&
           !ActualApplyPreparation(slot, f.picture.desc, prepared), names[scenario]);
}
#include "nr_finished_lag_cases.h"
int main()
{
    try
    {
        Adapted(false); Adapted(true); SameSize(2048,1152); SameSize(2560,1440);
        SizeTransitions(); StaleIdentities();
        LagCases();
        for (unsigned i = 0; i < 6; ++i) Refuse(i);
        std::puts("PASS BF_EXTENT: production admission/claim/apply; high/low MV; two native sizes; up/down transitions; stale identities; six refusals; CPU only");
        return 0;
    }
    catch (const std::exception& e) { std::printf("FAIL %s\n", e.what()); return 1; }
}
