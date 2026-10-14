#pragma once
#include "../../OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h"
#include "../../OptiScaler/dlssnr/DlssNr_Exposure.h"

// State storage and services, not model/filter/reference policy.
struct FilterIntegrationShader
{
    bool IsInit() const { return true; }
    bool DispatchPass(ID3D12GraphicsCommandList*, const DlssNrConstants& c, ID3D12Resource* src,
                      ID3D12Resource* model, ID3D12Resource* original, ID3D12Resource*, ID3D12Resource*,
                      ID3D12Resource* out, ID3D12Resource* keep, uint32_t* = nullptr)
    {
        if (!FilterFixture::dispatchReady) return false;
        FilterFixture::Record(0, src, model, original, out, keep, c);
        return true;
    }
};
struct DlssNr_Dx12
{
    struct State
    {
        struct ModelState
        {
            DlssNr::Proxy::Context models[30];
            DlssNr::ModelSettings builtSettings[30];
            bool passCreateFailed[30] {};
            unsigned width = 0, height = 0, workWidth = 0, workHeight = 0, effectiveInputFilter = 0;
            unsigned effectiveSignalEncoding = 0;
            bool beforeUpscale = false, finishedPicture = false, rayReconstruction = false, reset = true;
            bool passScratchFailed = false, failed = false;
            const char* reason = "";
            ID3D12Resource *output = nullptr, *passScratch = nullptr, *passClamp = nullptr,
                *colorCopy = nullptr, *hdrCopy = nullptr, *colorSmall = nullptr, *outputNative = nullptr,
                *activeColor = nullptr, *depthClone = nullptr, *motionClone = nullptr,
                *heldColor = nullptr, *exposure = nullptr, *exposureMeter = nullptr;
            bool heldActive = false, exposureReadable = false;
            unsigned heldWidth = 0, heldHeight = 0, exposureSource = 0;
            DXGI_FORMAT heldFormat = 0;
            float heldWhitePoint = 1, exposurePreExposure = 1;
            OS_Dx12 *superUp = nullptr, *superDown = nullptr;
            Scaler nrScaler = Scaler::Count;
            unsigned long long successfulDispatches = 0;
        } nr;
        FilterIntegrationShader shader;
        DlssNr::OutputStatus outputStatus;
        DlssNr::ModelFacts modelFacts;
        struct { DlssNr::FinishedIdentity consumer; } late;
        DlssNr::GpuLifetime lifetime;
        std::recursive_mutex mutex;
        ID3D12CommandList* outputCommands = nullptr;
        struct PipelineCaptureBoundary
        {
            uint32_t resolvedPreExposureBits = 0, exposureStateRaw = 0, exposureMode = 0;
            uintptr_t exposureResource = 0;
            bool exposureProvenanceKnown = false;
            void Copy(ID3D12GraphicsCommandList*, ID3D12Device*, const char*, ID3D12Resource*, unsigned, bool = true)
            { throw std::runtime_error("Unexpected pipeline capture in signal contracts"); }
        };
        std::shared_ptr<PipelineCaptureBoundary> pipelineCapture;
        bool modelRunning = false, warnedSuper = false, reportedHdr = false,
             reportedHdrValue = false, reportedBefore = false;
        unsigned loggedConfigured = 0, loggedEffective = 0, lastSuper = 0;
        unsigned long long frames = 0, resets = 0;
        std::string enlargementStatus;
        DlssNrReconstruction reconstruction;
        std::unique_ptr<DlssNrGpuTime> gpuTime, ngxTime;
        struct Capture
        {
            bool isActive() const { return false; }
            std::string write(const std::filesystem::path&) { return {}; }
            template<class... T> void record(T...) {}
        } captureFrames;
        struct ScopedNrStateEnvelope { explicit ScopedNrStateEnvelope(ID3D12GraphicsCommandList*) {} };
        struct Enlarger
        {
            Microsoft::WRL::ComPtr<ID3D12Resource> input;
#ifdef NR_SIGNAL_CARRIER
            unsigned w=0,h=0,outW=0,outH=0;
            bool depthInverted=false,structural=false,failed=false,submitted=false,readable=false,reset=true;
            unsigned long long lastFrame=0;
            Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
            Microsoft::WRL::ComPtr<ID3D12Resource> output,depth,motion,exposure;
            ID3D12GraphicsCommandList* creation=nullptr;
            std::unique_ptr<DlssNr::PrivateUpscalerDx12> dlss;
            DlssNr::GpuLifetime lifetime;
#endif
        };
        std::unique_ptr<Enlarger> enlarger;
#ifdef NR_SIGNAL_CARRIER
        std::vector<std::unique_ptr<Enlarger>> retiredEnlargers;
        bool collectingEnlargers=false;
#endif
        struct GuideReport
        {
            bool valid, depthInverted;
            float mvScaleX, mvScaleY;
            unsigned guideW, guideH, frameW, frameH;
            bool operator==(const GuideReport&) const = default;
        } loggedGuides {};
        struct ComposeReport
        {
            bool valid;
            float whitePoint, transfer, colour, maxRatio;
            unsigned passthrough, debugView, compareMode, residual, workW, workH, passes;
            bool operator==(const ComposeReport&) const = default;
        } loggedCompose {};
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
            DlssNrConstants exposureConstants {};
        };
        std::vector<std::unique_ptr<ID3D12Resource>> scratch;
        unsigned parked = 0, privateCalls = 0;
        void ReleaseSurfacesIfFormatChanged(unsigned) {}
        void ParkNrResource(ID3D12Resource*& resource) { if (resource) ++parked; resource = nullptr; }
        ID3D12Resource* CreateScratch(ID3D12Device* device, unsigned format, unsigned w, unsigned h)
        {
            scratch.push_back(std::make_unique<ID3D12Resource>(w, h));
            scratch.back()->device = device; scratch.back()->desc.Format = format;
            return scratch.back().get();
        }
        void ReleaseSupersamplers()
        { delete nr.superUp; delete nr.superDown; nr.superUp = nr.superDown = nullptr; }
        void Barrier(ID3D12GraphicsCommandList*, ID3D12Resource*, unsigned, unsigned) {}
        ID3D12Resource* ReadableGuide(ID3D12Device*, ID3D12GraphicsCommandList*, ID3D12Resource* r,
                                    ID3D12Resource**) { return r; }
        void ReportSkipOnce(const char*) {}
        void CheckCaptureTrigger() {}
        void EndGpuTiming(ID3D12GraphicsCommandList*) {}
#ifdef NR_SIGNAL_CARRIER
        void ReleaseEnlarger();
        void CollectEnlargers();
        ID3D12Resource* EnlargeMatchedResidual(ID3D12GraphicsCommandList*, ID3D12Device*, ID3D12Resource*,
            ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, const DlssNrFrameInfo&,
            const DlssNrConstants&, bool, ID3D12CommandQueue*);
#else
        void ReleaseEnlarger() { enlarger.reset(); }
        ID3D12Resource* EnlargeMatchedResidual(ID3D12GraphicsCommandList*, ID3D12Device*, ID3D12Resource*,
            ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, const DlssNrFrameInfo&,
            const DlssNrConstants&, bool, ID3D12CommandQueue*)
        { ++privateCalls; return nullptr; } // Boundary only; private runtime is not claimed.
#endif
        bool PrepareRunModels(ID3D12GraphicsCommandList*, ID3D12Device*, const DlssNrFrameInfo&,
                              const D3D12_RESOURCE_DESC&, DlssNr::ColorExtent, DlssNr::ColorExtent,
                              float, unsigned);
        const char* NgxResultName(unsigned);
        bool TuningMatchesFeature(const Config&, unsigned, unsigned, unsigned, unsigned);
        void EncodeInput(EncodeContext&);
        DlssNrConstants MakeResolveConstants(const EncodeContext&, unsigned);
        void Run(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*, ID3D12Resource*,
                 ID3D12Resource*, const DlssNrFrameInfo&, ID3D12CommandQueue*);
        ~State() { ReleaseSupersamplers(); }
    };
};
