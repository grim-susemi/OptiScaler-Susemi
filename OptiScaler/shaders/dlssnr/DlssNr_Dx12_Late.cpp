#include "pch.h"
#include "DlssNr_Dx12_State.h"
#include <dlssnr/DlssNr_StreamlinePicture.h>

auto DlssNr_Dx12::State::LateContext::Say(const char* message) -> void
{
    if (status != message)
    {
        status = message;
        LOG_INFO("DLSS-NR finished picture: {}", message);
    }
}

auto DlssNr_Dx12::State::LateContext::Finished(const Slot& slot) -> bool
{
    return !slot.fence || DlssNr::LateFenceReached(slot.done, slot.fence->GetCompletedValue());
}

auto DlssNr_Dx12::State::LateContext::Cancel() -> void
{
    for (auto& slot : slots)
    {
        // Presentation invalidation only. The game command list that recorded into the
        // slot can still execute afterwards, so ownership, the watermark and the pin stay
        // as they are (the ownership rule in DlssNr_LateSlot.h).
        if (slot.pending && !slot.submitted)
            slot.frame.OutputWidth = 0;
        if (slot.pending && slot.owned)
            LOG_DEBUG("NR late slot {} cancelled while owned (recording unresolved)", slot.serial);
        DlssNr::ClearLateSlotSelection(slot.pending);
        // NR always resets these owned lists before recording another picture. Once cancelled,
        // they cannot be replayed. Keep submitted fences, but do not pin later model generations
        // to dormant presentation lists. The game's producer recording remains untouched.
        if (slot.commands)
            owner.FinishedPictureResetCommandList(slot.commands.Get());
    }
    reset = true;
}

auto DlssNr_Dx12::State::LateContext::Clone(ComPtr<ID3D12Resource>& copy, ID3D12Resource* source) -> bool
{
    const auto want = source->GetDesc();
    if (want.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || want.SampleDesc.Count != 1 ||
        want.DepthOrArraySize != 1 || want.MipLevels != 1)
        return false;
    if (copy)
    {
        const auto have = copy->GetDesc();
        if (have.Width != want.Width || have.Height != want.Height ||
            have.Format != owner.TypedGuideFormat(want.Format))
            copy.Reset(); // caller checked the previous GPU fence
    }
    if (!copy)
        copy.Attach(owner.CreateGuideClone(device.Get(), source));
    return copy != nullptr;
}

auto DlssNr_Dx12::State::LateContext::Acquire(ID3D12GraphicsCommandList* cmd) -> Slot*
{
    if (!cmd)
    {
        Say("Waiting for the DirectX 12 bridge commands.");
        return nullptr;
    }
    ComPtr<ID3D12Device> currentDevice;
    if (FAILED(cmd->GetDevice(IID_PPV_ARGS(&currentDevice))))
        return nullptr;
    if (device && device != currentDevice)
    {
        Say("The graphics device changed. Restart the game to use this option.");
        return nullptr;
    }
    device = currentDevice;
    tracking.store(true);
    // Only the lightweight submission hook is needed, including when FG is disabled.
    ResTrack_Dx12::HookLateNrQueue(device.Get());
    Slot* next = nullptr;
    for (auto& slot : slots)
        if (DlssNr::LateSlotReusable(slot.pending, slot.owned, slot.pinned, slot.promisePending,
                                     slot.fence != nullptr, slot.done,
                                     slot.fence ? slot.fence->GetCompletedValue() : 0))
        {
            next = &slot;
            break;
        }
    if (!next)
    {
        Say("Waiting for the previous picture to finish.");
        return nullptr;
    }
    auto& slot = *next;
    if (!Config::Instance()->DlssNrHdrTransfer.value_or_default())
    {
        // Acquire has verified this slot's fence; never release an in-flight reference.
        slot.cleanScene.Reset();
        slot.response[0].Reset();
        slot.response[1].Reset();
        slot.responseValid = slot.cleanSceneValid = false;
    }
    if (!slot.commands)
    {
        if (FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&slot.fence))) ||
            FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                  IID_PPV_ARGS(&slot.allocator))) ||
            FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, slot.allocator.Get(), nullptr,
                                             IID_PPV_ARGS(&slot.commands))) ||
            FAILED(slot.commands->Close()))
        {
            slot.commands.Reset();
            slot.allocator.Reset();
            slot.fence.Reset();
            Say("Could not prepare the finished-picture option.");
            return nullptr;
        }
    }
    return next;
}

auto DlssNr_Dx12::State::LateContext::Arm(Slot& slot, ID3D12GraphicsCommandList* cmd) -> void
{
    owner.lifetime.Record(cmd);
    ID3D12GraphicsCommandList* real = nullptr;
    const bool proxied = Util::CheckForRealObject(__FUNCTION__, cmd, (IUnknown**) &real);
    // Record the de-proxied identity once. Submission and reset normalize their own
    // hook argument the same way (DlssNr::SameRecordedCommandIdentity), so an executed
    // list always matches the slot it armed.
    slot.producer = (ID3D12CommandList*) DlssNr::NormalizedCommandIdentity(cmd, proxied ? real : nullptr);
    slot.serial = ++serial;
    slot.promisePending = false;
    slot.promisedQueue = nullptr;
    DlssNr::ArmLateSlot(slot.ready, slot.done, slot.pending, slot.submitted, slot.owned);
    LOG_DEBUG("NR late slot {} armed owned=1 pending=1 ready={} done={}", slot.serial, slot.ready, slot.done);
}

auto DlssNr_Dx12::State::LateContext::Capture(ID3D12GraphicsCommandList* cmd, NVSDK_NGX_Parameter* params,
                                             bool rr, bool interop) -> void
{
    if (!cmd || !params)
    {
        Cancel();
        return;
    }
    // Per-pool consumer invariant: a capture armed while the route's consumer is known to
    // be unavailable stays owned with nothing to resolve it (the live starvation), so no
    // capture in this pool may be armed - the residual route below enforces the same rule
    // through the same production predicate.
    if (!DlssNr::FinishedConsumerAdmitsCapture())
        return;
    const bool legacyBridge = ::State::Instance().swapchainApi == API::DX11 ||
                              ::State::Instance().swapchainInteropApi == SwapchainInteropApi::Dx11wDx12;
    if (!legacyBridge && (!consumer.Known() || !consumer.applicationKnown || !consumerOwner || !consumerDevice))
    {
        Cancel();
        Say("The application picture consumer is not known.");
        return;
    }
    auto* depth = owner.GetResource(params, NVSDK_NGX_Parameter_Depth, "DLSSD.Depth");
    auto* motion = owner.GetResource(params, NVSDK_NGX_Parameter_MotionVectors, "DLSSD.MotionVectors");
    auto* output = owner.GetResource(params, NVSDK_NGX_Parameter_Output, "DLSSD.Output");
    if (!depth || !motion || !output)
    {
        Cancel();
        Say("Waiting for the game's depth and movement data.");
        return;
    }
    if (!legacyBridge && std::any_of(slots.begin(), slots.end(), [&](const auto& slot) {
            return slot.pending && !slot.identity.SameConsumer(consumer);
        }))
        Cancel();
    auto* next = Acquire(cmd);
    if (!next)
        return;
    auto& slot = *next;
    slot.identity = consumer;
    slot.consumerOwner = consumerOwner;
    slot.consumerDevice = consumerDevice;
    slot.guidesValid = false;
    slot.residualOnly = false;
    slot.responseValid = slot.cleanSceneValid = false;
    slot.frame = {};
    auto& frame = slot.frame;
    unsigned flags = owner.featureFlags, gameReset = 0;
    params->Get(NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags, &flags);
    params->Get(NVSDK_NGX_Parameter_Reset, &gameReset);
    frame.Reset = gameReset != 0;
    params->Get(NVSDK_NGX_Parameter_FrameTimeDeltaInMsec, &frame.FrameTimeMs);
    frame.DepthInverted = (flags & NVSDK_NGX_DLSS_Feature_Flags_DepthInverted) != 0;
    frame.MotionVectorsLowResolution = (flags & NVSDK_NGX_DLSS_Feature_Flags_MVLowRes) != 0;
    frame.RayReconstruction = rr;
    frame.OutputWidth = (unsigned) output->GetDesc().Width;
    frame.OutputHeight = output->GetDesc().Height;
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, &frame.RenderSubrectWidth);
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, &frame.RenderSubrectHeight);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, &frame.DepthSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y, &frame.DepthSubrectBaseY);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X, &frame.MotionSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, &frame.MotionSubrectBaseY);
    params->Get(NVSDK_NGX_Parameter_MV_Scale_X, &frame.MvScaleX);
    params->Get(NVSDK_NGX_Parameter_MV_Scale_Y, &frame.MvScaleY);
    frame.ColourIsLinearHdr = false;
    frame.IndependentCommands = true;
    frame.FinishedPicture = true;
    frame.OutputArrivalState = D3D12_RESOURCE_STATE_PRESENT;
    frame.SubmissionEpoch = legacyBridge ? ::State::Instance().frameCount : slot.identity.application;
    // Even unusable current metadata identifies the newest producer packet. Its
    // recording remains owned until actual submission or a proven Reset.
    Arm(slot, cmd);
    ComPtr<ID3D12Device> depthDevice, motionDevice, outputDevice;
    const auto states = DlssNr::ResolveInputStates_Dx12(interop);
    const auto knownState = [](D3D12_RESOURCE_STATES state)
    {
        return state == D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE ||
               state == (D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE) ||
               state == D3D12_RESOURCE_STATE_UNORDERED_ACCESS || state == D3D12_RESOURCE_STATE_COPY_SOURCE ||
               state == D3D12_RESOURCE_STATE_DEPTH_READ;
    };
    const auto fits = [](const D3D12_RESOURCE_DESC& allocation, unsigned x, unsigned y, unsigned w, unsigned h)
    {
        return allocation.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && allocation.SampleDesc.Count == 1 &&
               allocation.DepthOrArraySize == 1 && allocation.MipLevels == 1 &&
               x < allocation.Width && y < allocation.Height &&
               (!w || w <= allocation.Width - x) && (!h || h <= allocation.Height - y);
    };
    const auto motionW = frame.MotionVectorsLowResolution ? frame.RenderSubrectWidth : frame.OutputWidth;
    const auto motionH = frame.MotionVectorsLowResolution ? frame.RenderSubrectHeight : frame.OutputHeight;
    if (FAILED(depth->GetDevice(IID_PPV_ARGS(&depthDevice))) ||
        FAILED(motion->GetDevice(IID_PPV_ARGS(&motionDevice))) ||
        FAILED(output->GetDevice(IID_PPV_ARGS(&outputDevice))) ||
        !DlssNr::StreamlinePicture::SameDevice(device.Get(), depthDevice.Get()) ||
        !DlssNr::StreamlinePicture::SameDevice(device.Get(), motionDevice.Get()) ||
        !DlssNr::StreamlinePicture::SameDevice(device.Get(), outputDevice.Get()) ||
        (!legacyBridge && !DlssNr::StreamlinePicture::SameDevice(device.Get(), slot.consumerDevice.Get())) ||
        !knownState(states.depth) || !knownState(states.motion) ||
        !fits(depth->GetDesc(), frame.DepthSubrectBaseX, frame.DepthSubrectBaseY,
              frame.RenderSubrectWidth, frame.RenderSubrectHeight) ||
        !fits(motion->GetDesc(), frame.MotionSubrectBaseX, frame.MotionSubrectBaseY, motionW, motionH) ||
        !frame.OutputWidth || !frame.OutputHeight || !std::isfinite(frame.FrameTimeMs) || frame.FrameTimeMs <= 0 ||
        !std::isfinite(frame.MvScaleX) || frame.MvScaleX == 0 ||
        !std::isfinite(frame.MvScaleY) || frame.MvScaleY == 0 ||
        !Clone(slot.depth, depth) || !Clone(slot.motion, motion))
    {
        Say("The current depth, movement region or resource state is not usable.");
        return;
    }
    for (auto pair : { std::pair { depth, slot.depth.Get() }, std::pair { motion, slot.motion.Get() } })
    {
        const auto arrival = pair.first == depth ? states.depth : states.motion;
        owner.Barrier(cmd, pair.first, arrival, D3D12_RESOURCE_STATE_COPY_SOURCE);
        cmd->CopyResource(pair.second, pair.first);
        owner.Barrier(cmd, pair.first, D3D12_RESOURCE_STATE_COPY_SOURCE, arrival);
    }
    slot.guidesValid = true;
}

auto DlssNr_Dx12::State::LateContext::CaptureResidual(ID3D12GraphicsCommandList* cmd, ID3D12Resource* clean, ID3D12Resource* residual,
                             float scale, bool sceneLinear, bool reset) -> bool
{
    // Same per-pool consumer invariant as Capture: the deferred residual route fills the
    // same four slots, so it is gated by the same production predicate.
    if (!DlssNr::FinishedConsumerAdmitsCapture())
        return false;
    auto* next = Acquire(cmd);
    if (!next)
        return false;
    auto& slot = *next;
    if (!Clone(slot.residual, residual))
    {
        Say("The upscaled changes could not be saved.");
        return false;
    }
    owner.Barrier(cmd, residual, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    cmd->CopyResource(slot.residual.Get(), residual);
    owner.Barrier(cmd, residual, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    slot.cleanSceneValid = false;
    if (Config::Instance()->DlssNrHdrTransfer.value_or_default() && sceneLinear &&
        Clone(slot.cleanScene, clean))
    {
        const auto arrival = Config::Instance()->OutputResourceBarrier.has_value()
                                 ? (D3D12_RESOURCE_STATES) Config::Instance()->OutputResourceBarrier.value()
                                 : D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
        owner.Barrier(cmd, clean, arrival, D3D12_RESOURCE_STATE_COPY_SOURCE);
        cmd->CopyResource(slot.cleanScene.Get(), clean);
        owner.Barrier(cmd, clean, D3D12_RESOURCE_STATE_COPY_SOURCE, arrival);
        slot.cleanSceneValid = true;
    }
    if (!slot.cleanSceneValid)
        slot.responseValid = false;
    slot.frame = {};
    slot.frame.Reset = reset;
    slot.frame.OutputWidth = (unsigned) clean->GetDesc().Width;
    slot.frame.OutputHeight = clean->GetDesc().Height;
    slot.frame.PreExposure = scale;
    slot.frame.ExposureTexture = nullptr;
    slot.frame.SubmissionEpoch = ::State::Instance().frameCount;
    slot.residualOnly = true;
    slot.sceneLinear = sceneLinear;
    Arm(slot, cmd);
    return true;
}
