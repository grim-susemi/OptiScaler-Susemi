#include "pch.h"
#include <dlssnr/DlssNr_StreamlinePicture.h>
#include "DlssNr_Dx12_State.h"
#include "DlssNr_NativeProbe.h"
#include <atomic>
#include <list>
#include "precompile/DlssNr_Shader.h"
#include "precompile/dlssnr_residual_Shader.h"
#include "precompile/dlssnr_finished_color_Shader.h"

namespace
{
std::recursive_mutex nrOwnersMutex;
std::vector<DlssNr_Dx12*> nrOwners;
std::atomic_uint nrCaptureOutstanding { 0 };
// Only unresolved work at process teardown is intentionally retained. During the session
// retired owners stay registered for submission/reset callbacks until they can be reclaimed.
auto& RetiredNrOwners()
{
    static auto* owners = new std::list<std::unique_ptr<DlssNr_Dx12>>;
    return *owners;
}
unsigned nrNotificationDepth = 0;
void CollectRetiredNrOwners()
{
    static bool collecting = false;
    if (collecting || nrNotificationDepth) return;
    collecting = true;
    auto& owners = RetiredNrOwners();
    for (auto it = owners.begin(); it != owners.end();)
    {
        if (!(*it)->ReadyToDestroy()) { ++it; continue; }
        auto finished = std::move(*it);
        it = owners.erase(it);
        finished.reset(); // May enqueue a child codec; list iterators remain valid.
        LOG_INFO("DLSS-NR: reclaimed retired GPU owner; {} waiting", owners.size());
    }
    collecting = false;
}
struct NrNotificationScope
{
    NrNotificationScope() { ++nrNotificationDepth; }
    ~NrNotificationScope() { --nrNotificationDepth; CollectRetiredNrOwners(); }
};
DlssNr_Dx12* activeNrOwner = nullptr;
void ActivateNrOwner(DlssNr_Dx12* owner)
{
    if (std::find(nrOwners.begin(), nrOwners.end(), owner) == nrOwners.end())
        nrOwners.push_back(owner);
    activeNrOwner = owner;
}
} // namespace



// ---------------------------------------------------------------------------------------------
// The pass itself. Everything above is what it is made of; everything below is the shape the rest
// of OptiScaler sees.
// ---------------------------------------------------------------------------------------------

DlssNr_Dx12::DlssNr_Dx12(std::string InName, ID3D12Device* InDevice)
    : Shader_Dx12(InName, InDevice), _state(std::make_unique<State>(*this))
{
    if (InDevice == nullptr)
    {
        LOG_ERROR("InDevice is nullptr!");
        return;
    }

    LOG_DEBUG("{0} start!", _name);

    // Five inputs, two outputs, one constant buffer, and a clamped linear sampler.
    //
    // The sampler exists because the model may be run below full resolution, in which case its answer
    // has to be read back at a different size from the frame it is being transferred onto.
    D3D12_STATIC_SAMPLER_DESC sampler {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    if (!SetupRootSignature(InDevice, kSrvCount, kUavCount, 1, 0, 0, 1, &sampler))
    {
        LOG_ERROR("[{0}] Failed to setup root signature", _name);
        return;
    }

    D3D12_RESOURCE_DESC desc = CD3DX12_RESOURCE_DESC::Buffer(sizeof(DlssNrConstants));
    auto heapProps = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_UPLOAD);

    for (uint32_t i = 0; i < DLSSNR_NUM_OF_HEAPS; ++i)
    {
        auto result = InDevice->CreateCommittedResource(&heapProps, D3D12_HEAP_FLAG_NONE, &desc,
                                                        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                                                        IID_PPV_ARGS(&_constantBuffers[i]));

        if (result != S_OK)
        {
            LOG_ERROR("[{0}] CreateCommittedResource error {1:x}", _name, (unsigned int) result);
            return;
        }
    }

    // Precompiled, with no source fallback. The shader used to be compiled at runtime from a string,
    // which would have meant no shader at all for anyone leaving UsePrecompiledShaders at its
    // default.
    if (!CreateComputePipeline(InDevice, &_pipelineState, DlssNr_cso, sizeof(DlssNr_cso), nullptr))
    {
        LOG_ERROR("[{0}] Failed to create the compute pipeline", _name);
        return;
    }

    // Second PSO for the ResidualAcrossRR v2 accumulator (its own blob, same root signature).
    // A failure here is not fatal to the class -- only that experimental mode goes unavailable.
    if (!CreateComputePipeline(InDevice, &_residualPipelineState, dlssnr_residual_cso, sizeof(dlssnr_residual_cso),
                               nullptr))
    {
        _residualPipelineState = nullptr;
        LOG_WARN("[{0}] ResidualAcrossRR compute pipeline unavailable", _name);
    }

    _init = InitHeaps(InDevice, _frameHeaps, DLSSNR_NUM_OF_HEAPS);
    if (_init)
        ResTrack_Dx12::HookLateNrQueue(InDevice); // Observe feature-creation submissions too, before the first Run.
    // Codec-only instances never call Dispatch/ProcessSeam, but still record GPU work.
    std::lock_guard lock(nrOwnersMutex);
    nrOwners.push_back(this);
}

bool DlssNr_Dx12::DispatchPass(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                               ID3D12Resource* InSource, ID3D12Resource* InModel, ID3D12Resource* InOriginal,
                               ID3D12Resource* InMotion, ID3D12Resource* InPrevEdit, ID3D12Resource* OutTarget,
                               ID3D12Resource* OutKeep, uint32_t* immutableSlot)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard stateLock(_state->mutex);
    return DispatchCompute(InCmdList, InConstants, _pipelineState, InSource, InModel, InOriginal,
                           InMotion, InPrevEdit, OutTarget, OutKeep, immutableSlot);
}

bool DlssNr_Dx12::DispatchCompute(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                                 ID3D12PipelineState* pipeline, ID3D12Resource* InSource,
                                 ID3D12Resource* InModel, ID3D12Resource* InOriginal,
                                 ID3D12Resource* InMotion, ID3D12Resource* InPrevEdit,
                                 ID3D12Resource* OutTarget, ID3D12Resource* OutKeep, uint32_t* immutableSlot)
{
    _state->lifetime.Record(InCmdList);
    if (!_init || !pipeline || !InCmdList || !_device || !InSource || !OutTarget)
        return false;

    const bool reuse = immutableSlot && *immutableSlot != UINT32_MAX;
    const uint32_t slot = reuse ? *immutableSlot : _heapIndex;
    if (!reuse)
        _heapIndex = (_heapIndex + 1) % DLSSNR_NUM_OF_HEAPS;

    FrameDescriptorHeap& currentHeap = _frameHeaps[slot];
    if (!reuse)
    {

        // Every slot in the table gets a view, whether the mode reads it or not. An unbound descriptor is
        // not an empty read; it is a read from nothing, and the source stands in wherever a mode has
        // nothing of its own to put there.
        ID3D12Resource* const srvs[kSrvCount] = {
            InSource,
            InModel != nullptr ? InModel : InSource,
            InOriginal != nullptr ? InOriginal : InSource,
            InMotion != nullptr ? InMotion : InSource,
            InPrevEdit != nullptr ? InPrevEdit : InSource,
        };

        for (uint32_t i = 0; i < kSrvCount; ++i)
        {
            // Copied depth guides already use an SRV format; the upstream translator maps it back to a DSV.
            const bool translate = srvs[i]->GetDesc().Format != DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS;
            CreateShaderResourceView(_device, srvs[i], currentHeap.GetSrvCPU(i), DXGI_FORMAT_UNKNOWN, translate);
        }

        ID3D12Resource* const uavs[kUavCount] = {
            OutTarget,
            OutKeep != nullptr ? OutKeep : OutTarget,
        };

        for (uint32_t i = 0; i < kUavCount; ++i)
            CreateUnorderedAccessView(_device, uavs[i], currentHeap.GetUavCPU(i), 0);

        if (!CreateConstantsBuffer(_device, _constantBuffers[slot], InConstants, currentHeap.GetCbvCPU(0)))
        {
            LOG_ERROR("[{0}] Failed to create a constants buffer", _name);
            return false;
        }

        if (immutableSlot)
            *immutableSlot = slot;
    }

    ID3D12DescriptorHeap* heaps[] = { currentHeap.GetHeapCSU() };
    InCmdList->SetDescriptorHeaps(_countof(heaps), heaps);
    InCmdList->SetComputeRootSignature(_rootSignature);
    InCmdList->SetPipelineState(pipeline);
    InCmdList->SetComputeRootDescriptorTable(0, currentHeap.GetTableGPUStart());

    // Sized from the constants rather than from a resource, because the pass that shrinks the proxy
    // writes fewer pixels than its source has.
    const UINT dispatchWidth = InConstants.Mode == DlssNrMode_Meter
                                   ? InConstants.Width
                                   : (InConstants.Width + _numThreadsX - 1) / _numThreadsX;
    const UINT dispatchHeight = InConstants.Mode == DlssNrMode_Meter
                                    ? InConstants.Height
                                    : (InConstants.Height + _numThreadsY - 1) / _numThreadsY;
    InCmdList->Dispatch(dispatchWidth, dispatchHeight, 1);

    return true;
}

void DlssNr_Dx12::Retire(std::unique_ptr<DlssNr_Dx12> owner)
{
    if (!owner) return;
    if (::State::Instance().isShuttingDown)
    {
        owner.release(); // No locks, GPU calls or destructors under the loader lock.
        return;
    }
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner == owner.get()) activeNrOwner = nullptr;
    DlssNr::ClearStatus(owner.get());
    {
        std::lock_guard stateLock(owner->_state->mutex);
        owner->_state->late.Cancel();
    }
    RetiredNrOwners().push_back(std::move(owner));
    LOG_INFO("DLSS-NR: retaining retired GPU owner until recordings finish; {} waiting", RetiredNrOwners().size());
}

bool DlssNr_Dx12::ReadyToDestroy()
{
    std::lock_guard lock(_state->mutex);
    _state->CollectEnlargers();
    if (_state->collectingEnlargers) return false;
    if (!_state->retiredEnlargers.empty() || (_state->enlarger && !_state->enlarger->lifetime.Idle())) return false;
    if (!_state->lifetime.Idle() || !_state->deferredSr.lifetime.Idle()) return false;
    for (auto& model : _state->nr.models)
        if (!model.Idle()) return false;
    for (const auto& slot : _state->late.slots)
        if (slot.promisePending) return false; // an unresolved promise still owns its slot
    for (const auto& slot : _state->late.slots)
        if (slot.submitted && !_state->late.Finished(slot)) return false;
    return _state->late.dx11.Idle();
}

void DlssNr_Dx12::FinishSubmitted()
{
    std::lock_guard lock(_state->mutex);
    _state->lifetime.FinishSubmitted();
    _state->deferredSr.lifetime.FinishSubmitted();
    _state->captureFrames.FinishSubmitted();
    if (_state->enlarger)
        _state->enlarger->lifetime.FinishSubmitted();
    for (auto& old : _state->retiredEnlargers)
        old->lifetime.FinishSubmitted();
    for (auto& model : _state->nr.models)
        model.FinishSubmitted();
}

DlssNr_Dx12::~DlssNr_Dx12()
{
    if (::State::Instance().isShuttingDown)
    {
        _state.release();
        for (auto& heap : _frameHeaps)
            heap.Abandon();
        GpuTime.release();
        return;
    }
    std::lock_guard lock(nrOwnersMutex);
    std::erase(nrOwners, this);
    if (activeNrOwner == this)
        activeNrOwner = nullptr;
    DlssNr::ClearStatus(this);
    const bool finished = _state->WaitForFinishedPicture();
    if (!finished || !_state->lifetime.Idle())
    {
        LOG_WARN("DLSS-NR: abandoning GPU ownership with unresolved command recordings at teardown");
        _state.release();
        for (auto& heap : _frameHeaps)
            heap.Abandon();
        _rootSignature = nullptr;
        _pipelineState = nullptr;
        _constantBuffer = nullptr;
        GpuTime.release();
        return;
    }
    _state.reset();
    for (auto& heap : _frameHeaps)
        heap.ReleaseHeaps();
    if (_finishedColorPipelineState)
        _finishedColorPipelineState->Release();
    for (auto& buffer : _constantBuffers)
    {
        if (buffer != nullptr)
        {
            buffer->Release();
            buffer = nullptr;
        }
    }

    if (_residualPipelineState != nullptr)
    {
        _residualPipelineState->Release();
        _residualPipelineState = nullptr;
    }
}

bool DlssNr_Dx12::DispatchResidualPass(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                                       ID3D12Resource* InSource, ID3D12Resource* InModel, ID3D12Resource* InOriginal,
                                       ID3D12Resource* InMotion, ID3D12Resource* OutTarget, bool finishedColor)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard stateLock(_state->mutex);
    if (finishedColor && !_finishedColorPipelineState && _init)
        CreateComputePipeline(_device, &_finishedColorPipelineState, dlssnr_finished_color_cso,
                              sizeof(dlssnr_finished_color_cso), nullptr);
    auto* pipeline = finishedColor ? _finishedColorPipelineState : _residualPipelineState;
    return DispatchCompute(InCmdList, InConstants, pipeline, InSource, InModel, InOriginal,
                           InMotion, nullptr, OutTarget, nullptr, nullptr);
}

bool DlssNr_Dx12::CreateBufferResource(ID3D12Device* device, ID3D12Resource* source, D3D12_RESOURCE_STATES state)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard stateLock(_state->mutex);
    if (device == nullptr || source == nullptr)
        return false;
    auto desc = source->GetDesc();
    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || desc.SampleDesc.Count != 1 ||
        desc.DepthOrArraySize != 1)
        return false;
    desc.MipLevels = 1;
    desc.Alignment = 0;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags = (desc.Flags | D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) & ~D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;
    if (_state->buffer != nullptr)
    {
        const auto previous = _state->buffer->GetDesc();
        if (previous.Width == desc.Width && previous.Height == desc.Height && previous.Format == desc.Format &&
            previous.Flags == desc.Flags)
            return true;
        _state->ParkNrResource(_state->buffer);
    }
    const auto heap = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_DEFAULT);
    if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr,
                                               IID_PPV_ARGS(&_state->buffer))))
        return false;
    _state->bufferState = state;
    return true;
}

void DlssNr_Dx12::SetBufferState(ID3D12GraphicsCommandList* cmdList, D3D12_RESOURCE_STATES state)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard stateLock(_state->mutex);
    _state->lifetime.Record(cmdList);
    Shader_Dx12::SetBufferState(cmdList, state, _state->buffer, &_state->bufferState);
}

ID3D12Resource* DlssNr_Dx12::Buffer() { return _state->buffer; }
bool DlssNr_Dx12::CanRender() const { return _init && _state->buffer != nullptr; }

bool DlssNr_Dx12::Dispatch(ID3D12GraphicsCommandList* cmd, ID3D12Resource* colour, ID3D12Resource* depth,
                           ID3D12Resource* motion, ID3D12Resource* output, const DlssNrFrameInfo& frame,
                           ID3D12CommandQueue* queue)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    ActivateNrOwner(this);
    std::lock_guard stateLock(_state->mutex);
    _state->ConsumeControls();
    struct Publish
    {
        State& s;
        ~Publish() { s.Publish(); }
    } publish { *_state };
    if (!_init || !cmd || !colour || !depth || !motion || !output)
        return false;
    auto info = frame;
    info.PipelineManagedStates = true;
    info.PrivateColorCopy = true;
    if (!info.RenderSubrectWidth)
        info.RenderSubrectWidth = info.Width;
    if (!info.RenderSubrectHeight)
        info.RenderSubrectHeight = info.Height;
    if (colour != output)
    {
        const auto source = colour->GetDesc(), target = output->GetDesc();
        if (source.Width != target.Width || source.Height != target.Height || source.Format != target.Format)
            return false;
        _state->Barrier(cmd, colour, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_SOURCE);
        _state->Barrier(cmd, output, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
        DlssNr::CopyActiveColor(cmd, output, colour, { (unsigned)target.Width, target.Height });
        _state->Barrier(cmd, colour, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        _state->Barrier(cmd, output, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    }
    const auto before = _state->nr.successfulDispatches;
    _state->Run(cmd, output, depth, motion, output, info, queue);
    return _state->nr.successfulDispatches != before;
}

void DlssNr_Dx12::BeginInputHold(ID3D12GraphicsCommandList* cmd, NVSDK_NGX_Parameter* params,
                                const D3D12_RESOURCE_STATES* inputStates)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard lock(_state->mutex);
    _state->BeginInputHold(cmd, params, inputStates);
}

void DlssNr_Dx12::EndInputHold(NVSDK_NGX_Parameter* params)
{
    std::lock_guard lock(_state->mutex);
    _state->inputHold.parameters.Restore(params);
}

bool DlssNr_Dx12::ProcessSeam(ID3D12GraphicsCommandList* cmd, NVSDK_NGX_Parameter* params, bool beforeUpscale,
                              ID3D12CommandQueue* queue, bool rayReconstruction, unsigned long long submissionEpoch,
                              bool interop, uint32_t featureFlags)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    ActivateNrOwner(this);
    std::lock_guard stateLock(_state->mutex);
    _state->ConsumeControls();
    _state->featureFlags = featureFlags;
    const auto& cfg = *Config::Instance();
    // Both seams reach this scheduler; ordinary passes remain in the shared shader pipeline.
    const auto placement = DlssNr::ResolvePlacement(
        cfg.DlssNrRunBeforeSr.value_or_default(), cfg.DlssNrDeferredDlss.value_or_default(),
        cfg.DlssNrResidualAcrossRr.value_or_default(), cfg.DlssNrFinishedPicture.value_or_default());
    const bool special = placement.finished || placement.deferred;
    if (special)
        _state->EvaluateInternal(cmd, params, beforeUpscale, queue, rayReconstruction, submissionEpoch, interop);
    else
    {
        if (_state->lastFinishedMode != 0)
        {
            _state->lastFinishedMode = 0;
            _state->nr.reset = true;
            if (_state->gpuTime)
                _state->gpuTime->ClearLast();
            if (_state->ngxTime)
                _state->ngxTime->ClearLast();
            _state->lastGpuTime.reset();
            _state->lastNgxTime.reset();
        }
        _state->late.Cancel();
        _state->deferredSr.Cancel();
    }
    _state->Publish();
    return special;
}
void DlssNr_Dx12::DiagnosePipeline(unsigned stage, ID3D12GraphicsCommandList* cmd,
                                  NVSDK_NGX_Parameter* params, ID3D12Resource* color,
                                  uint32_t flags, bool rr, bool success)
{
    std::lock_guard ownersLock(nrOwnersMutex);
    std::lock_guard stateLock(_state->mutex);
    auto& state = *_state;
    if (stage == 0)
    {
        state.lifetime.Collect();
        static bool previousGameplay = false, previousPhoto = false;
        static unsigned runs = 0;
        DWORD foregroundProcess = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), &foregroundProcess);
        const bool control = foregroundProcess == GetCurrentProcessId() &&
                             (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
        const bool gameplay = control && (GetAsyncKeyState(VK_F8) & 0x8000) != 0;
        const bool photo = control && (GetAsyncKeyState(VK_F9) & 0x8000) != 0;
        const char* label = gameplay && !previousGameplay ? "gameplay" :
                            photo && !previousPhoto ? "photomode" : nullptr;
        previousGameplay = gameplay; previousPhoto = photo;
        if (label && !state.pipelineCaptureRemaining && !nrCaptureOutstanding)
        {
            if (runs >= 2)
                LOG_WARN("NR pipeline capture: two-run limit reached; restart to capture again");
            else
            {
                ++runs;
                SYSTEMTIME time {}; GetLocalTime(&time);
                char folder[100];
                std::snprintf(folder, sizeof(folder), "%04u%02u%02u-%02u%02u%02u-%03u-%s-%u",
                    time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
                    time.wMilliseconds, label, runs);
                state.pipelineCaptureDirectory = Util::DllPath().parent_path() / "nr-pipeline-captures" / folder;
                state.pipelineCaptureRemaining = 4;
                LOG_INFO("NR pipeline capture armed: {} (four frames)", state.pipelineCaptureDirectory.string());
            }
        }
        if (!state.pipelineCaptureRemaining || state.pipelineCapture) return;
        auto job = std::make_unique<DlssNr::PipelineCaptureFrame>();
        if (!job->Init(_device))
        { state.pipelineCaptureRemaining = 0; LOG_ERROR("NR pipeline capture allocation failed"); return; }
        job->directory = state.pipelineCaptureDirectory / std::to_string(4 - state.pipelineCaptureRemaining);
        job->metadata << "stage_semantics before_nr=scene_linear_input after_nr=NR_composed_RR_input "
                         "after_rr=upscaler_output_before_postprocessing\n"
                      << "game_frame " << ::State::Instance().frameCount << " command_list " << cmd
                      << " parameters " << params << " rr " << rr << " feature_flags " << flags << '\n';
        const auto& cfg = *Config::Instance();
        job->metadata << "nr_passes " << cfg.DlssNrPasses.value_or_default()
                      << " working_scale " << cfg.DlssNrWorkingScale.value_or_default()
                      << " nr_history_reset " << state.nr.reset
                      << " hold " << cfg.DlssNrHoldFrame.value_or_default() << '\n';
        for (const char* key : { NVSDK_NGX_Parameter_Reset, NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width,
             NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, NVSDK_NGX_Parameter_OutWidth,
             NVSDK_NGX_Parameter_OutHeight, NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X,
             NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X,
             NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y })
        {
            unsigned value = 0; auto result = params->Get(key, &value);
            job->metadata << key << ' ' << value << " get_result " << unsigned(result) << '\n';
        }
        for (const char* key : { NVSDK_NGX_Parameter_MV_Scale_X, NVSDK_NGX_Parameter_MV_Scale_Y,
             NVSDK_NGX_Parameter_Jitter_Offset_X, NVSDK_NGX_Parameter_Jitter_Offset_Y,
             NVSDK_NGX_Parameter_DLSS_Pre_Exposure, NVSDK_NGX_Parameter_DLSS_Exposure_Scale,
             NVSDK_NGX_Parameter_FrameTimeDeltaInMsec })
        {
            float value = 0; auto result = params->Get(key, &value);
            job->metadata << key << ' ' << value << " get_result " << unsigned(result) << '\n';
        }
        // Record descriptors of optional RR inputs without assuming their presence.
        for (const char* key : { "DLSS.Input.DiffuseAlbedo", "DLSS.Input.SpecularAlbedo", "GBuffer.Normals",
             "GBuffer.Roughness", "MotionVectorsReflection", "DLSSD.SpecularHitDistance",
             "DLSS.Input.ColorBeforeParticles", "DLSSD.DiffuseHitDistance" })
        {
            auto* resource = state.GetResource(params, key, key);
            job->metadata << key << " resource " << resource;
            if (resource)
            { auto desc = resource->GetDesc(); job->metadata << " width " << desc.Width << " height " << desc.Height
                                                           << " format " << desc.Format; }
            job->metadata << '\n';
        }
        state.pipelineCapture = job.release();
        ++nrCaptureOutstanding;
        state.lifetime.Record(cmd);
        const auto inputs = DlssNr::ResolveInputStates_Dx12(false);
        state.pipelineCapture->Copy(cmd, _device, "before_nr", color, inputs.color);
        state.pipelineCapture->Copy(cmd, _device, "motion", state.GetResource(params,
            NVSDK_NGX_Parameter_MotionVectors, "DLSSD.MotionVectors"), inputs.motion);
        state.pipelineCapture->Copy(cmd, _device, "depth", state.GetResource(params,
            NVSDK_NGX_Parameter_Depth, "DLSSD.Depth"), inputs.depth);
        state.pipelineCapture->Copy(cmd, _device, "exposure", state.GetResource(params,
            NVSDK_NGX_Parameter_ExposureTexture, "DLSSD.ExposureTexture"), inputs.exposure);
        return;
    }
    auto* job = state.pipelineCapture;
    if (!job) return;
    job->metadata << "stage " << stage << " success " << success << '\n';
    if (stage == 1)
    {
        job->metadata << "nr_model_evaluated " << state.modelRunning << '\n';
        job->Copy(cmd, _device, "after_nr", color, DlssNr::ResolveInputStates_Dx12(false).color);
        return;
    }
    if (success) job->Copy(cmd, _device, "after_rr", color, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    job->End(cmd);
    state.pipelineCapture = nullptr;
    --state.pipelineCaptureRemaining;
    state.lifetime.Retire([job]
    {
        if (job->Write()) LOG_INFO("NR pipeline capture saved: {}", job->directory.string());
        else LOG_WARN("NR pipeline capture discarded or write failed: {}", job->directory.string());
        delete job;
        --nrCaptureOutstanding;
    });
}

void DlssNr_Dx12::ResetFinishedCommands(ID3D12CommandList* cmd) { _state->FinishedPictureResetCommandList(cmd); }
void DlssNr_Dx12::PromiseFinishedCommands(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                                          ID3D12CommandList* const* lists)
{
    _state->FinishedPicturePromised(batch, this, queue, count, lists);
}
void DlssNr_Dx12::SubmitFinishedCommands(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                                         ID3D12CommandList* const* lists)
{
    _state->FinishedPictureSubmitted(batch, this, queue, count, lists);
}
bool DlssNr_Dx12::WaitFinished() { return _state->WaitForFinishedPicture(); }
bool DlssNr_Dx12::ApplyFinished(ID3D12Resource* picture, ID3D12CommandQueue* queue, DXGI_COLOR_SPACE_TYPE space,
                                bool gameFrameHandoff)
{
    std::lock_guard lock(_state->mutex);
    bool ran = false;
    if (!Config::Instance()->DlssNrFinishedPicture.value_or_default() ||
        !Config::Instance()->DlssNrEnabled.value_or_default())
        _state->late.Cancel();
    else if (picture && queue)
        ran = _state->ApplyFinishedColor(picture, queue, space, gameFrameHandoff);
    _state->Publish();
    return ran;
}
bool DlssNr_Dx12::PendingFinishedCapture(ID3D12Resource* picture, ID3D12CommandQueue* queue,
                                         DXGI_COLOR_SPACE_TYPE space, DlssNr::XeFGCapture& facts)
{
    std::lock_guard lock(_state->mutex);
    return _state->PendingFinishedCapture(picture, queue, space, facts);
}
void DlssNr_Dx12::CloseFinishedCaptures(uint64_t throughSerial)
{
    std::lock_guard lock(_state->mutex);
    _state->CloseFinishedCaptures(throughSerial);
}
void DlssNr_Dx12::ApplyFinishedDx11(IDXGISwapChain* swapchain)
{
    _state->ApplyToFinishedPictureDx11(swapchain);
    _state->Publish();
}
std::string DlssNr_Dx12::FinishedStatus() { return _state->FinishedPictureStatus(); }
std::string DlssNr_Dx12::DeferredStatus() { return _state->DeferredDlssStatus(); }

// XeFG owned application-frame handoff, State side (todo 10). Under the owner mutex
// (the class wrappers above hold it): the pending-capture facts for a finished
// application picture, and interval closure for refused/skipped captures.
bool DlssNr_Dx12::State::PendingFinishedCapture(ID3D12Resource* color, ID3D12CommandQueue* queue,
                                                DXGI_COLOR_SPACE_TYPE colorSpace, DlssNr::XeFGCapture& facts)
{
    facts = DlssNr::XeFGCapture {};
    if (color == nullptr || queue == nullptr)
        return false;
    if (!late.tracking.load())
        return false;
    LateContext::ComPtr<ID3D12Device> currentDevice;
    const HRESULT currentDeviceHr = queue->GetDevice(IID_PPV_ARGS(&currentDevice));
    if (FAILED(currentDeviceHr) || currentDevice != late.device)
    {
        // Diagnostic-only (nr-xefg R9): this guard is silent and the R8 NR_XEFG_NOMATCH below is
        // reached only once it passes, so a device-gate refusal has no fact anywhere in the log.
        // Name which half refused - GetDevice itself failed, or the queue's device is a different
        // identity than late.device - and, when both handles are valid, the canonical IUnknown
        // identity of each device. same_iu=1 proves the two handles are the SAME COM object reached
        // through two different interface pointers; same_iu=0 proves only that they are NOT one COM
        // object - it does not by itself separate a proxy/real pair for one logical device from a
        // genuinely second device. queue= (the actual parameter pointer) is the field that makes
        // that call: correlate it with the normalized "NR late slot N promise recorded ... queue=0x.."
        // producer token, and current/late with same_iu, in a single owner run. Edge-triggered (a
        // classification change always logs) plus the NR_XEFG_NOMATCH budget (first 8, then every
        // 512th), so the steady state cannot flood the owner log; queue is logged but kept OUT of
        // the edge signature so a cycling queue cannot defeat the bound. Static atomics only, no
        // GPU work, no decision change, no dereference of an invalid handle; the guard and its
        // return are byte-for-byte unchanged, matching FinishedCompose's ApplyFinishedColor guard.
        const bool getDeviceFailed = FAILED(currentDeviceHr);
        LateContext::ComPtr<IUnknown> currentCanonical, lateCanonical;
        if (!getDeviceFailed && currentDevice.Get() != nullptr)
            currentDevice->QueryInterface(IID_PPV_ARGS(&currentCanonical));
        if (late.device.Get() != nullptr)
            late.device->QueryInterface(IID_PPV_ARGS(&lateCanonical));
        const bool sameCanonical =
            currentCanonical.Get() != nullptr && currentCanonical.Get() == lateCanonical.Get();
        const uint32_t signature = (getDeviceFailed ? 1u : 0u) | (currentDevice ? 2u : 0u) |
                                   (late.device ? 4u : 0u) | (sameCanonical ? 8u : 0u);
        static std::atomic<uint32_t> deviceGateLines {0};
        static std::atomic<uint32_t> lastDeviceGateSignature {0xFFFFFFFFu};
        const uint32_t seq = deviceGateLines.fetch_add(1, std::memory_order_relaxed);
        const bool edge = lastDeviceGateSignature.exchange(signature, std::memory_order_relaxed) != signature;
        if (edge || seq < 8 || (seq % 512) == 0)
        {
            LOG_DEBUG("NR_XEFG_DEVICE_GATE seq={} reason={} hr={:X} tracking={} queue={:p} current={:p} late={:p} "
                      "current_iu={:p} late_iu={:p} same_iu={} edge={}",
                      seq + 1, getDeviceFailed ? "get_device_failed" : "device_mismatch",
                      (unsigned) currentDeviceHr, late.tracking.load() ? 1 : 0, (void*) queue,
                      (void*) currentDevice.Get(), (void*) late.device.Get(),
                      (void*) currentCanonical.Get(), (void*) lateCanonical.Get(), sameCanonical ? 1 : 0,
                      edge ? 1 : 0);
        }
        if (edge || seq < 8)
        {
            // NR_XEFG_NATIVE_GATE (nr-xefg R10/v4): the safe half of what the R9 DEVICE_GATE line
            // cannot give, under a strict process-lifetime probe budget. The facts recorded, and
            // what each one does NOT prove:
            //   - late_dev / late_iu: late.device, whose single origin is the command list GetDevice
            //     in DlssNr_Dx12_Late.cpp:72 (Acquire), and its canonical IUnknown.
            //   - gate_dev / gate_iu: the device of this gate's own queue parameter (XeFG's
            //     _gameCommandQueue) and its canonical IUnknown.
            //   - gate_luid / late_luid with gate_luid_present / late_luid_present:
            //     ID3D12Device::GetAdapterLuid() of each handle. Compare the two LUIDs ONLY when
            //     both *_luid_present are 1; a difference then excludes one adapter, and an
            //     equality proves nothing about logical-device identity (two distinct ID3D12Device
            //     objects on one adapter share that adapter's LUID). With either present=0 the LUID
            //     is 0:0 and means UNKNOWN - never "a different adapter". LUID must not be used to
            //     "canonicalize" an IUnknown mismatch.
            //   - kind=producer: the raw ID3D12CommandQueue::GetDevice identity of the retained
            //     producer queues - the queue pointer stored in each slot by
            //     DlssNr_Dx12_FinishedQueue.cpp:178 and logged at :116, plus late.producerQueue
            //     (:179). NOTE: the legacy SL1 detector Util::CheckForRealObject never fired in this
            //     title, so those tokens are the raw hook queue pointer with NO proof of being
            //     de-proxied or unwrapped; that provenance stays a hypothesis this line cannot
            //     settle.
            //   - dev_iu / match_late_iu / match_gate_iu: canonical IUnknown comparisons. Two
            //     canonical identities may be compared only when both were acquired (non-null): a
            //     match then proves the SAME COM OBJECT, and a mismatch proves they are DIFFERENT
            //     COM OBJECTS. When GetDevice failed or a QueryInterface was not acquired (dev_iu
            //     null) both flags read 0 and mean NO ESTABLISHED MATCH - never "proved different".
            //     In no case does any of this prove two logical devices or invalid cross-device
            //     composition: an SDK or other wrapper may still map both identities onto one
            //     logical device.
            //
            // No Streamline API is called here, and this line makes NO claim about the game's own
            // Streamline state - not whether a game interposer is loaded, and not whether a native
            // unwrap is available. sl_callable=0 sl_reason=not_thread_safe is this diagnostic's own
            // fixed decision for this site: external/streamline/sl_core_api.h:289 documents
            // slGetNativeInterface as "NOT thread safe" with no AddRef/ownership contract for the
            // returned base interface, and the gate runs on the XeFG present path under the NR
            // owner and state locks, a placement whose thread compatibility cannot be proven here.
            // A native conversion therefore needs a quiesced device-creation-time hook, not this
            // site. (v3's OptiScaler-local presence reads are gone: they were unsynchronized with
            // their writers, and a zero did not describe the game's Streamline state anyway.)
            //
            // Every pointer dereferenced below is a live COM object the gate already owns or has
            // AddRef'd (queue, the slot producerQueue ComPtrs, late.device, late.producerQueue); no
            // returned pointer is dereferenced or Released, and no handle is dereferenced when null.
            //
            // BUDGET (R10 review H1): one strict saturating process-lifetime latch (dlssnr/
            // DlssNr_NativeProbe.h) admits at most kBudget probes whatever the classification word
            // does; the transitions in the condition above only choose which refusals consume the
            // remaining budget, can never bypass exhaustion, and the counter saturates instead of
            // wrapping. Once exhausted this block performs no COM call and emits nothing. The R9
            // DEVICE_GATE log policy above is unchanged, this is diagnostic-only, and the guard and
            // its return are unchanged.
            static DlssNr::NativeProbeAdmission nrNativeProbeAdmission;
            if (nrNativeProbeAdmission.Admit())
            {
                const uint32_t probe = nrNativeProbeAdmission.Admitted(); // 1-based index
                // GetAdapterLuid returns LUID and has no HRESULT; the out-parameter is the literal
                // queried/not-queried marker of the header comment - no call result is invented.
                const auto adapterLuid = [](ID3D12Device* device, bool& present) -> LUID
                {
                    if (device == nullptr)
                    {
                        present = false; // no handle: no query ran
                        return {};
                    }
                    present = true; // non-null handle was queried
                    return device->GetAdapterLuid();
                };
                bool gateLuidPresent = false;
                const LUID gateLuid = adapterLuid(currentDevice.Get(), gateLuidPresent);
                bool lateLuidPresent = false;
                const LUID lateLuid = adapterLuid(late.device.Get(), lateLuidPresent);
                LOG_DEBUG("NR_XEFG_NATIVE_GATE seq={} probe={}/{} sl_callable=0 sl_reason=not_thread_safe "
                          "gate_queue={:p} gate_hr={:X} gate_dev={:p} gate_iu={:p} gate_luid_present={} "
                          "gate_luid={:08X}:{:08X} late_dev={:p} late_iu={:p} late_luid_present={} "
                          "late_luid={:08X}:{:08X}",
                          seq + 1, probe, DlssNr::NativeProbeAdmission::kBudget, (void*) queue,
                          (unsigned) currentDeviceHr, (void*) currentDevice.Get(), (void*) currentCanonical.Get(),
                          gateLuidPresent ? 1u : 0u, (unsigned) gateLuid.HighPart, (unsigned) gateLuid.LowPart,
                          (void*) late.device.Get(), (void*) lateCanonical.Get(), lateLuidPresent ? 1u : 0u,
                          (unsigned) lateLuid.HighPart, (unsigned) lateLuid.LowPart);
                // NR_XEFG_PICTURE (nr-xefg R11): the device of the `color` argument - the picture
                // the XeFG SDK swapchain GetBuffer (framegen/xefg/XeFG_Dx12.cpp:1674-1682) handed
                // here; its own GetDevice was never logged before. Inside the R10 latch (<= 8 per
                // process): no GPU work, no Streamline API, no extra per-frame call, nothing feeds
                // acceptance/facts/composition, and color/queue are non-null by the entry guard.
                // match_gate_iu / match_late_iu are 1 only when BOTH canonical identities are
                // non-null and equal (same COM object); 0 = no established match, never "different".
                // Equal LUID proves one adapter only - never a logical device or proxy/real alias;
                // luid_present=0 prints 0:0 and means unknown. qi_state is not_called = no device
                // handle (no synthetic HRESULT is emitted anywhere in this line), else ok/failed.
                LateContext::ComPtr<ID3D12Device> pictureDevice;
                const HRESULT pictureHr = color->GetDevice(IID_PPV_ARGS(&pictureDevice));
                LateContext::ComPtr<IUnknown> pictureCanonical;
                const char* pictureQiState = "not_called";
                if (SUCCEEDED(pictureHr) && pictureDevice.Get() != nullptr)
                    pictureQiState = SUCCEEDED(pictureDevice->QueryInterface(IID_PPV_ARGS(&pictureCanonical)))
                                         ? "ok"
                                         : "failed";
                const bool pictureMatchGate = pictureCanonical.Get() != nullptr &&
                                              currentCanonical.Get() != nullptr &&
                                              pictureCanonical.Get() == currentCanonical.Get();
                const bool pictureMatchLate = pictureCanonical.Get() != nullptr &&
                                              lateCanonical.Get() != nullptr &&
                                              pictureCanonical.Get() == lateCanonical.Get();
                bool pictureLuidPresent = false;
                const LUID pictureLuid = adapterLuid(pictureDevice.Get(), pictureLuidPresent);
                LOG_DEBUG("NR_XEFG_PICTURE seq={} probe={}/{} picture={:p} hr={:X} dev={:p} qi_state={} "
                          "dev_iu={:p} match_gate_iu={} match_late_iu={} luid_present={} luid={:08X}:{:08X}",
                          seq + 1, probe, DlssNr::NativeProbeAdmission::kBudget, (void*) color,
                          (unsigned) pictureHr, (void*) pictureDevice.Get(), pictureQiState,
                          (void*) pictureCanonical.Get(), pictureMatchGate ? 1 : 0, pictureMatchLate ? 1 : 0,
                          pictureLuidPresent ? 1u : 0u, (unsigned) pictureLuid.HighPart,
                          (unsigned) pictureLuid.LowPart);
                DlssNr::NativeProbeProducerSelection producers;
                const auto probeProducer = [&](const char* source, ID3D12CommandQueue* producer)
                {
                    if (!producers.Consider((const void*) producer))
                        return;
                    LateContext::ComPtr<ID3D12Device> producerDevice;
                    const HRESULT producerHr = producer->GetDevice(IID_PPV_ARGS(&producerDevice));
                    LateContext::ComPtr<IUnknown> producerCanonical;
                    if (SUCCEEDED(producerHr) && producerDevice.Get() != nullptr)
                        producerDevice->QueryInterface(IID_PPV_ARGS(&producerCanonical));
                    bool producerLuidPresent = false;
                    const LUID producerLuid = adapterLuid(producerDevice.Get(), producerLuidPresent);
                    LOG_DEBUG("NR_XEFG_NATIVE_GATE seq={} kind=producer src={} queue={:p} hr={:X} dev={:p} "
                              "dev_iu={:p} match_late_iu={} match_gate_iu={} luid_present={} luid={:08X}:{:08X}",
                              seq + 1, source, (void*) producer, (unsigned) producerHr, (void*) producerDevice.Get(),
                              (void*) producerCanonical.Get(),
                              producerCanonical.Get() != nullptr && producerCanonical.Get() == lateCanonical.Get() ? 1 : 0,
                              producerCanonical.Get() != nullptr && producerCanonical.Get() == currentCanonical.Get() ? 1 : 0,
                              producerLuidPresent ? 1u : 0u, (unsigned) producerLuid.HighPart,
                              (unsigned) producerLuid.LowPart);
                };
                for (unsigned i = 0; i < late.slots.size(); ++i)
                {
                    char source[16];
                    std::snprintf(source, sizeof(source), "slot%u", i);
                    probeProducer(source, late.slots[i].producerQueue.Get());
                }
                probeProducer("late.submit", late.producerQueue.Get());
            }
        }
        return false;
    }
    // The colour gate mirrors ApplyFinishedColor: an unsupported space never becomes a capture.
    const bool pq = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
    const bool scrgb = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709;
    const bool sdr = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    if (!sdr && !pq && !scrgb)
        return false;
    ID3D12CommandQueue* realQueue = nullptr;
    if (!Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**) &realQueue))
        realQueue = queue;
    const auto desc = color->GetDesc();
    const auto& cfg = *Config::Instance();
    const bool residualOnly = DlssNr::ResolvePlacement(cfg.DlssNrRunBeforeSr.value_or_default(),
                                                      cfg.DlssNrDeferredDlss.value_or_default(),
                                                      cfg.DlssNrResidualAcrossRr.value_or_default(), true)
                                 .deferred;
    // The capture IDENTITY for this finished picture is the newest matching slot, chosen by
    // serial BEFORE any eligibility test: an older enqueued capture must never be
    // substituted for a newer unresolved one (the wrong-frame regression). The epoch rule
    // does not apply (gameFrameHandoff semantics: the accepted application frame is not the
    // display-frame clock); staleness is closed by the handoff wiring.
    DlssNr::LateSelection selection;
    LateContext::Slot* match = nullptr;
    // Diagnostic-only (nr-xefg R8): the newest pending slot overall. Selection itself never
    // needs it - serial order alone picks match - but the refusal below must be able to name
    // the extent and lifecycle flags of the newest candidate even when nothing matched.
    LateContext::Slot* newestPending = nullptr;
    for (auto& slot : late.slots)
    {
        // Candidate filter = picture identity only: the slot is still armed for this picture
        // (pending) and matches its placement/extent. Eligibility (pinned, unresolved,
        // zero-extent extent equality) is NEVER a prefilter - LateSelection decides after the
        // newest serial is chosen, so a pinned newest capture refuses the frame instead of
        // letting an older capture win.
        if (!slot.pending)
            continue;
        if (newestPending == nullptr || slot.serial > newestPending->serial)
            newestPending = &slot;
        if (slot.residualOnly != residualOnly || slot.frame.OutputWidth != desc.Width ||
            slot.frame.OutputHeight != desc.Height)
            continue;
        if (selection.Consider(slot.serial,
                               DlssNr::LateCaptureSelectable(slot.pending, slot.pinned, slot.submitted,
                                                             slot.promisePending)))
            match = &slot;
    }
    // The newest candidate is unresolved or otherwise unusable: refuse the handoff for this
    // frame. It must not fall back to an older matching capture (they belong to older
    // application frames).
    if (!selection.Usable())
    {
        // Diagnostic-only (nr-xefg R8): name the refusing branch and the offered picture's
        // extent, so one re-run separates an identity mismatch (residualOnly/extent) from an
        // unusable newest capture (pinned/promisePending/not submitted). The 6880
        // reason=no_current_capture skips of capture-20260926-1410 carry no such fact, which is
        // exactly the gap. Budgeted like LogNrXefgSkip (first 8, then every 512th) so the
        // steady-state no-match cannot flood the owner log; static atomic only, no GPU work.
        static std::atomic<uint32_t> noMatchLines {0};
        const uint32_t seq = noMatchLines.fetch_add(1, std::memory_order_relaxed);
        if (seq < 8 || (seq % 512) == 0)
        {
            const LateContext::Slot* candidate = selection.have ? match : newestPending;
            const char* reason = "no_pending_slot";
            if (candidate != nullptr)
            {
                if (selection.have && !selection.selectable)
                {
                    if (candidate->pinned)
                        reason = "pinned";
                    else if (candidate->promisePending)
                        reason = "promise_pending";
                    else if (!candidate->submitted)
                        reason = "not_submitted";
                    else
                        reason = "unselectable";
                }
                else if (candidate->residualOnly != residualOnly)
                    reason = "residual_only_mismatch";
                else if (candidate->frame.OutputWidth != desc.Width)
                    reason = "width_mismatch";
                else if (candidate->frame.OutputHeight != desc.Height)
                    reason = "height_mismatch";
                else
                    reason = "extent_mismatch";
            }
            LOG_DEBUG("NR_XEFG_NOMATCH seq={} reason={} requested={}x{} residualOnly={} candidate_serial={} "
                      "candidate={}x{} pending={} submitted={} pinned={} promisePending={} owned={}",
                      seq + 1, reason, desc.Width, desc.Height, residualOnly ? 1 : 0,
                      candidate ? candidate->serial : 0, candidate ? candidate->frame.OutputWidth : 0,
                      candidate ? candidate->frame.OutputHeight : 0, candidate ? (candidate->pending ? 1 : 0) : 0,
                      candidate ? (candidate->submitted ? 1 : 0) : 0, candidate ? (candidate->pinned ? 1 : 0) : 0,
                      candidate ? (candidate->promisePending ? 1 : 0) : 0, candidate ? (candidate->owned ? 1 : 0) : 0);
        }
        return false;
    }
    facts.exists = true;
    facts.serial = match->serial;
    facts.submitted = DlssNr::LateCaptureEnqueued(match->submitted, match->promisePending);
    facts.sameQueue = match->submitted && match->producerQueue.Get() == realQueue;
    facts.ready = match->submitted &&
                  DlssNr::FinishedInputReady(match->producerQueue.Get() == realQueue,
                                             match->fence->GetCompletedValue(), match->ready);
    return true;
}

void DlssNr_Dx12::State::CloseFinishedCaptures(uint64_t throughSerial)
{
    // Closed here means never selected again - presentation invalidation only. The game
    // command list that recorded into the slot can still execute afterwards, so ownership,
    // the watermark and the pin are preserved and only a fenced promise or a proven discard
    // resolves the recording (the ownership rule in DlssNr_LateSlot.h). This is the path
    // XeFGCloseCaptures takes at a generation reset with the max serial.
    if (!late.tracking.load())
        return;
    for (auto& slot : late.slots)
        if (slot.pending && slot.serial <= throughSerial)
        {
            if (slot.owned)
                LOG_DEBUG("NR late slot {} closed while owned (recording unresolved)", slot.serial);
            DlssNr::ClearLateSlotSelection(slot.pending);
        }
}

namespace DlssNr
{
void FinishedPictureResetCommandList(ID3D12CommandList* cmd)
{
    if (::State::Instance().isShuttingDown)
        return;
    std::lock_guard lock(nrOwnersMutex);
    NrNotificationScope notification;
    const auto owners = nrOwners;
    for (auto* owner : owners)
        owner->ResetFinishedCommands(cmd);
}
void FinishedPicturePromise(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                            ID3D12CommandList* const* lists)
{
    if (::State::Instance().isShuttingDown)
        return;
    std::lock_guard lock(nrOwnersMutex);
    NrNotificationScope notification;
    const auto owners = nrOwners;
    for (auto* owner : owners)
        owner->PromiseFinishedCommands(batch, queue, count, lists);
}
void FinishedPictureSubmitted(DlssNr::LatePromiseBatch& batch, ID3D12CommandQueue* queue, UINT count,
                              ID3D12CommandList* const* lists)
{
    if (::State::Instance().isShuttingDown)
        return;
    std::lock_guard lock(nrOwnersMutex);
    NrNotificationScope notification;
    const auto owners = nrOwners;
    for (auto* owner : owners)
        owner->SubmitFinishedCommands(batch, queue, count, lists);
}
bool WaitForFinishedPicture()
{
    if (::State::Instance().isShuttingDown)
        return false;
    std::lock_guard lock(nrOwnersMutex);
    NrNotificationScope notification;
    bool ready = true;
    const auto owners = nrOwners;
    for (auto* owner : owners)
        ready = owner->WaitFinished() && ready;
    return ready;
}
static DXGI_COLOR_SPACE_TYPE ReadFinishedSpace(IDXGISwapChain* swapchain, ID3D12Resource* picture)
{
    auto space = picture->GetDesc().Format == DXGI_FORMAT_R16G16B16A16_FLOAT ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709
                                                                             : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    UINT size = sizeof(space);
    swapchain->GetPrivateData(FinishedColorSpaceKey, &size, &space);
    return space;
}
void ApplyToFinishedPicture(IDXGISwapChain* swapchain, ID3D12CommandQueue* queue)
{
    if (::State::Instance().isShuttingDown)
        return;
    Microsoft::WRL::ComPtr<IDXGISwapChain3> chain;
    Microsoft::WRL::ComPtr<ID3D12Resource> picture;
    auto space = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    const auto& config = *Config::Instance();
    // Swapchain calls must precede NR locks: FG Present can submit commands while holding its own lock.
    if (swapchain && queue && config.DlssNrEnabled.value_or_default() &&
        config.DlssNrFinishedPicture.value_or_default())
    {
        if (StreamlinePicture::RenderQueue(swapchain) || FAILED(swapchain->QueryInterface(IID_PPV_ARGS(&chain))) ||
            FAILED(chain->GetBuffer(chain->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&picture))))
            return;
        space = ReadFinishedSpace(swapchain, picture.Get());
    }
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner)
        activeNrOwner->ApplyFinished(picture.Get(), queue, space);
}
void ApplyToStreamlinePicture(IDXGISwapChain* swapchain, ID3D12Resource* picture, ID3D12CommandQueue* queue)
{
    if (::State::Instance().isShuttingDown)
        return;
    if (!swapchain || !picture || !queue)
        return;
    const auto space = ReadFinishedSpace(swapchain, picture);
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner)
        activeNrOwner->ApplyFinished(picture, queue, space, true);
}

// XeFG owned application-frame handoff (todo 10). The wiring in XeFG_Dx12::Present()
// queries the capture facts first and composes only after the handoff core accepted the
// frame; a refused or skipped capture is closed through XeFGCloseCaptures so it can
// never become a later frame's NR input. All three take the NR locks; the caller queries
// swapchain/buffer/colour space BEFORE calling (ApplyToFinishedPicture ordering).
bool XeFGPendingCapture(ID3D12Resource* picture, ID3D12CommandQueue* queue, DXGI_COLOR_SPACE_TYPE space,
                        XeFGCapture& facts)
{
    if (::State::Instance().isShuttingDown)
        return false;
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner == nullptr)
        return false;
    return activeNrOwner->PendingFinishedCapture(picture, queue, space, facts);
}

bool ApplyXeFGPicture(ID3D12Resource* picture, ID3D12CommandQueue* queue, DXGI_COLOR_SPACE_TYPE space)
{
    if (::State::Instance().isShuttingDown)
        return false;
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner == nullptr)
        return false;
    // Real-game-frame semantics: ApplyFinishedColor consumes the pending capture without
    // the display-frame epoch rule (DlssNr_Dx12_FinishedCompose.cpp gameFrameHandoff).
    return activeNrOwner->ApplyFinished(picture, queue, space, /*gameFrameHandoff=*/true);
}

void XeFGCloseCaptures(uint64_t throughSerial)
{
    if (::State::Instance().isShuttingDown)
        return;
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner == nullptr)
        return;
    activeNrOwner->CloseFinishedCaptures(throughSerial);
}
void ApplyToFinishedPictureDx11(IDXGISwapChain* swapchain)
{
    if (::State::Instance().isShuttingDown)
        return;
    std::lock_guard lock(nrOwnersMutex);
    if (activeNrOwner)
        activeNrOwner->ApplyFinishedDx11(swapchain);
}
void FinishedPictureColorSpace(IDXGISwapChain* swapchain, DXGI_COLOR_SPACE_TYPE colorSpace)
{
    if (swapchain)
        swapchain->SetPrivateData(FinishedColorSpaceKey, sizeof(colorSpace), &colorSpace);
}
std::string FinishedPictureStatus()
{
    std::lock_guard lock(nrOwnersMutex);
    return activeNrOwner ? activeNrOwner->FinishedStatus() : "Waiting for a finished picture.";
}
std::string DeferredDlssStatus()
{
    std::lock_guard lock(nrOwnersMutex);
    return activeNrOwner ? activeNrOwner->DeferredStatus() : "not started";
}
bool Shutdown()
{
    if (::State::Instance().isShuttingDown)
        return false;
    const auto deadline = GetTickCount64() + 1000;
    do
    {
        {
            std::lock_guard lock(nrOwnersMutex);
            // Callbacks may retire a child codec. Defer owner destruction until traversal ends.
            {
                NrNotificationScope notification;
                for (auto& owner : RetiredNrOwners())
                    owner->FinishSubmitted();
            }
            if (nrOwners.empty())
                return true;
        }
        // Submission/reset hooks must be able to make progress while we drain.
        Sleep(1);
    } while (GetTickCount64() < deadline);
    LOG_WARN("NR shutdown deferred: owners or GPU recordings remain; keeping the NGX runtime alive");
    return false;
}
} // namespace DlssNr
