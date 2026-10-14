#include "pch.h"
#include "DlssNr_Dx12_State.h"
#include <dlssnr/DlssNr_StreamlinePicture.h>

bool DlssNr_Dx12::State::AdmitFinishedCapture(ID3D12Resource* color, ID3D12CommandQueue* queue,
                                            const DlssNr::FinishedIdentity& consumer, DlssNr::XeFGCapture& facts,
                                            bool claim, uint64_t captureSerial)
{
    facts = {};
    if (!color || !queue || !consumer.Known() || !late.device)
        return false;
    LateContext::ComPtr<ID3D12Device> queueDevice, pictureDevice;
    if (FAILED(queue->GetDevice(IID_PPV_ARGS(&queueDevice))) ||
        FAILED(color->GetDevice(IID_PPV_ARGS(&pictureDevice))) ||
        !DlssNr::StreamlinePicture::SameDevice(late.device.Get(), queueDevice.Get()) ||
        !DlssNr::StreamlinePicture::SameDevice(late.device.Get(), pictureDevice.Get()))
        return false;
    ID3D12CommandQueue* realQueue = nullptr;
    if (!Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**) &realQueue))
        realQueue = queue;
    LateContext::Slot* newest = nullptr;
    for (auto& slot : late.slots)
        if (slot.pending && !slot.residualOnly && slot.identity.owner == &shader &&
            slot.identity.SameConsumer(consumer) &&
            (!consumer.applicationKnown || (slot.identity.applicationKnown &&
                                            slot.identity.application == consumer.application)) &&
            (!newest || slot.serial > newest->serial))
            newest = &slot;
    if (!newest)
        return false;
    auto& slot = *newest;
    const auto desc = color->GetDesc();
    facts.exists = true;
    facts.serial = slot.serial;
    facts.identity = slot.identity;
    facts.submitted = DlssNr::LateCaptureEnqueued(slot.submitted, slot.promisePending);
    facts.sameQueue = facts.submitted && slot.producerQueue.Get() == realQueue;
    facts.ready = DlssNr::LateCaptureSelectable(slot.pending, slot.pinned, slot.submitted, slot.promisePending) &&
                  slot.guidesValid && slot.consumerOwner && slot.consumerDevice &&
                  DlssNr::StreamlinePicture::SameDevice(late.device.Get(), slot.consumerDevice.Get()) &&
                  slot.frame.OutputWidth == desc.Width && slot.frame.OutputHeight == desc.Height &&
                  slot.fence && DlssNr::FinishedInputReady(facts.sameQueue, slot.fence->GetCompletedValue(), slot.ready);
    if (!claim)
        return true;
    // Closing presentation eligibility never resolves producer/GPU ownership.
    for (auto& other : late.slots)
        if (other.pending && other.identity.SameConsumer(slot.identity) && other.serial <= slot.serial)
            DlssNr::ClearLateSlotSelection(other.pending);
    if (!facts.ready || (captureSerial && (captureSerial != slot.serial ||
        consumer.owner != slot.identity.owner || consumer.application != slot.identity.application)) ||
        (late.claimed.owner == slot.identity.owner && late.claimed.SameConsumer(slot.identity) &&
         (slot.identity.application <= late.claimed.application || slot.serial <= late.claimedSerial)))
        return false;
    late.claimed = slot.identity;
    late.claimedSerial = slot.serial;
    return true;
}

auto DlssNr_Dx12::State::ApplyFinishedColor(ID3D12Resource* color, ID3D12CommandQueue* queue, DXGI_COLOR_SPACE_TYPE colorSpace,
                                          bool gameFrameHandoff, const DlssNr::FinishedIdentity& consumer,
                                          uint64_t captureSerial) -> bool
{
    modelFacts.ValidateCurrent(DlssNr::Backend::Dx12, consumer);
    outputStatus.ResetOutcome();
    outputStatus.state = DlssNr::OutputState::Skipped;
    outputStatus.reason = DlssNr::OutputReason::Admission;
    outputStatus.application = consumer.applicationKnown ? consumer.application : 0;
    outputStatus.generation = consumer.Known() ? consumer.generation : 0;
    const auto& requested = *Config::Instance();
    outputStatus.requested = DlssNr::ResolvePlacement(requested.DlssNrRunBeforeSr.value_or_default(),
        requested.DlssNrDeferredDlss.value_or_default(), requested.DlssNrResidualAcrossRr.value_or_default(), true);
    outputStatus.effective = outputStatus.requested;
    outputStatus.consumer = DlssNr::CurrentFinishedConsumer();
    outputStatus.hidden = !requested.DlssNrApplyModel.value_or_default();
    outputCommands = nullptr;
    if (!Config::Instance()->DlssNrFinishedPicture.value_or_default() ||
        !Config::Instance()->DlssNrEnabled.value_or_default())
    {
        outputStatus = {};
        late.Cancel();
        return false;
    }
    LateContext::ComPtr<ID3D12Device> currentDevice;
    if (FAILED(queue->GetDevice(IID_PPV_ARGS(&currentDevice))) || currentDevice != late.device)
        return false;
    ID3D12CommandQueue* realQueue = nullptr;
    if (!Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**) &realQueue))
        realQueue = queue;
    const auto desc = color->GetDesc();
    const bool pq = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
    const bool scrgb = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709;
    const bool sdr = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    if ((!sdr && !pq && !scrgb) || (scrgb && desc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT) ||
        (!scrgb && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM && desc.Format != DXGI_FORMAT_R10G10B10A2_UNORM))
    {
        late.Cancel();
        late.Say("This screen colour format is not supported.");
        return false;
    }
    // The capture IDENTITY for this picture is the newest matching slot, chosen by serial
    // BEFORE any eligibility test: if the newest capture is unresolved or not ready, the
    // composition refuses. It must never fall back to an older matching capture, which
    // belongs to an older application frame (wrong-frame substitution).
    DlssNr::LateSelection selection;
    LateContext::Slot* newest = nullptr;
    const auto epoch = ::State::Instance().frameCount;
    const auto& cfg = *Config::Instance();
    const bool residualOnly = DlssNr::ResolvePlacement(
        cfg.DlssNrRunBeforeSr.value_or_default(), cfg.DlssNrDeferredDlss.value_or_default(),
        cfg.DlssNrResidualAcrossRr.value_or_default(), true).deferred;
    const bool legacyBridge = ::State::Instance().swapchainApi == API::DX11 ||
                              ::State::Instance().swapchainInteropApi == SwapchainInteropApi::Dx11wDx12;
    LateContext::Slot* latest = nullptr;
    if (!residualOnly && !legacyBridge)
    {
        DlssNr::XeFGCapture facts;
        if (!AdmitFinishedCapture(color, queue, consumer, facts, true, captureSerial))
            return false;
        for (auto& slot : late.slots)
            if (slot.serial == facts.serial)
                latest = &slot;
    }
    else
    {
    for (auto& slot : late.slots)
    {
        // Candidate filter = picture identity only (pending + placement/extent). Eligibility
        // is never a prefilter: a pinned or unresolved newest capture must win the serial
        // identity and then refuse the frame, not let an older capture be substituted.
        if (!slot.pending)
            continue;
        // Native FG's internal Present counter includes generated frames and is not an app-frame identity.
        if (!gameFrameHandoff && (epoch < slot.frame.SubmissionEpoch || epoch - slot.frame.SubmissionEpoch > 1))
        {
            slot.pending = false;
            late.reset = true;
            continue;
        }
        if (slot.residualOnly != residualOnly || slot.frame.OutputWidth != desc.Width ||
            slot.frame.OutputHeight != desc.Height)
            continue;
        if (selection.Consider(slot.serial,
                               DlssNr::LateCaptureSelectable(slot.pending, slot.pinned, slot.submitted,
                                                             slot.promisePending)))
            newest = &slot;
    }
    if (DlssNr::LateCompositionRefuses(selection))
        return false; // the newest capture exists but is unusable: refuse, never the held edit
    if (selection.have)
    {
        // A queued producer signal can depend on this presentation, regardless of FG provider.
        if (!DlssNr::FinishedInputReady(newest->producerQueue.Get() == realQueue,
                                        newest->fence->GetCompletedValue(), newest->ready))
            return false; // the newest capture is not ready: refuse, never substitute an older one
        latest = newest;
    }
    // A tuning change may need a few model warm-up frames. Keep displaying the last
    // held edit in that gap rather than exposing live/rotating game backbuffers - but only
    // when no capture matches this picture at all (an existing but unusable capture refuses
    // above and is never replaced by the held edit either).
    if (DlssNr::LateCompositionMayUseHeld(selection) && residualOnly && Config::Instance()->DlssNrHoldFrame.value_or_default() && inputHold.active &&
        late.heldValid && late.heldGeneration == inputHold.generation && late.heldSlot &&
        late.heldSlot->serial == late.heldSlotSerial && !late.heldSlot->pending &&
        late.heldSlot->frame.OutputWidth == desc.Width && late.heldSlot->frame.OutputHeight == desc.Height)
    {
        auto& held = *late.heldSlot;
        if (late.Finished(held))
            latest = &held;
    }
    }
    if (!latest)
        return false; // loading screen, another swapchain, or this real frame was already consumed
    auto& slot = *latest;
    const bool holdFinished = slot.residualOnly && Config::Instance()->DlssNrHoldFrame.value_or_default() &&
                              inputHold.active;
    if (!holdFinished)
        late.heldValid = false;
    if (holdFinished)
    {
        if (late.heldFailed)
            return false;
        if (late.heldFinished && !SameHoldShape(late.heldFinished->GetDesc(), desc))
        {
            // Defer replacement rather than blocking a presentation needed by the old work.
            if (late.heldFence && !DlssNr::FinishedInputReady(false, late.heldFence->GetCompletedValue(), late.heldReady))
                return false;
            late.heldFinished.Reset();
            late.heldValid = false;
        }
        if (!late.heldFinished)
        {
            late.heldFinished.Attach(CreateScratch(late.device.Get(), desc.Format, (unsigned) desc.Width, desc.Height));
            late.heldState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
        }
        if (late.heldFence && !DlssNr::FinishedInputReady(late.heldQueue.Get() == realQueue,
                                                        late.heldFence->GetCompletedValue(), late.heldReady))
            return false;
        if (!late.heldFinished)
        {
            late.Say("Could not hold the finished frame.");
            return false;
        }
    }
    // Drop other submitted evaluates from this picture, not their in-flight resources.
    for (auto& other : late.slots)
        if (other.submitted && other.serial <= slot.serial &&
            (residualOnly || legacyBridge || other.identity.SameConsumer(slot.identity)))
            other.pending = false;
    // The selected input is complete or ordered before composition on this queue.
    if (FAILED(slot.allocator->Reset()) ||
        FAILED(slot.commands->Reset(slot.allocator.Get(), nullptr)))
    {
        late.reset = true;
        late.Say("Could not prepare the finished picture.");
        return false;
    }
    auto* cmd = slot.commands.Get();
    if (holdFinished)
    {
        const bool capture = !late.heldValid || late.heldGeneration != inputHold.generation ||
                             late.heldSpace != colorSpace;
        if (capture)
        {
            Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_SOURCE);
            Barrier(cmd, late.heldFinished.Get(), late.heldState, D3D12_RESOURCE_STATE_COPY_DEST);
            cmd->CopyResource(late.heldFinished.Get(), color);
            Barrier(cmd, late.heldFinished.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE);
            Barrier(cmd, color, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
            late.heldState = D3D12_RESOURCE_STATE_COPY_SOURCE;
            late.heldGeneration = inputHold.generation;
            late.heldSpace = colorSpace;
            late.heldValid = true;
        }
        else
        {
            Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST);
            cmd->CopyResource(color, late.heldFinished.Get());
            Barrier(cmd, color, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT);
        }
    }
    bool finalCopyBack = false;
    bool appliedResidual = false;
    bool matchedResponse = false;
    if (slot.residualOnly)
    {
        // This packet carries the already evaluated pre-SR edit; Present only
        // composes its residual and must not evaluate the model again.
        outputStatus.evaluated = true;
        if (slot.encoded &&
            (slot.encoded->GetDesc().Width != desc.Width || slot.encoded->GetDesc().Height != desc.Height ||
             slot.encoded->GetDesc().Format != desc.Format))
            slot.encoded.Reset();
        if (!slot.encoded)
            slot.encoded.Attach(CreateScratch(late.device.Get(), desc.Format, (unsigned) desc.Width, desc.Height));
        if (!slot.encoded)
        {
            outputStatus.state = DlssNr::OutputState::Failed;
            outputStatus.reason = DlssNr::OutputReason::Resource;
        }
        if (slot.encoded && Config::Instance()->DlssNrApplyModel.value_or_default())
        {
            Barrier(cmd, slot.residual.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            DlssNrConstants apply {};
            apply.Mode = pq ? 4 : scrgb ? 3 : 2;
            apply.Width = (unsigned) desc.Width;
            apply.Height = desc.Height;
            apply.WhitePoint = slot.frame.PreExposure;
            apply.TransferStrength = slot.sceneLinear ? 1.0f : 0.0f;
            apply.MaxRatio = std::clamp(Config::Instance()->DlssNrMaxRatio.value_or_default(), 1.0f, 8.0f);
            const bool measure = Config::Instance()->DlssNrHdrTransfer.value_or_default() && slot.cleanSceneValid &&
                                 slot.sceneLinear && (pq || scrgb);
            if (measure)
            {
                Barrier(cmd, slot.cleanScene.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                        D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                for (auto& curve : slot.response)
                {
                    if (!curve)
                    {
                        curve.Attach(CreateScratch(late.device.Get(), DXGI_FORMAT_R32G32B32A32_FLOAT,
                                                   kDlssNrHdrCurveBins, 1));
                        if (curve)
                            Barrier(cmd, curve.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                        slot.responseValid = false;
                    }
                }
                if (slot.response[0] && slot.response[1])
                {
                    const unsigned next = slot.responseIndex ^ 1u;
                    DlssNrConstants fit {};
                    fit.Mode = pq ? 7 : 6;
                    fit.Width = kDlssNrHdrCurveBins;
                    fit.Height = 1;
                    fit.WhitePoint = slot.frame.PreExposure;
                    fit.ColourStrength = 0.35f; // new weight, only for fits that agree with their history
                    fit.DebugView = slot.responseValid && !slot.frame.Reset && !late.reset &&
                                    slot.responseWidth == desc.Width && slot.responseHeight == desc.Height &&
                                    slot.responseSpace == colorSpace && epoch >= slot.responseEpoch &&
                                    epoch - slot.responseEpoch <= 8 &&
                                    slot.frame.PreExposure >= slot.responseExposure * 0.8f &&
                                    slot.frame.PreExposure <= slot.responseExposure * 1.25f;
                    Barrier(cmd, slot.response[next].Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                            D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                    matchedResponse = shader.DispatchResidualPass(cmd, fit, color, slot.cleanScene.Get(),
                                                                  slot.response[slot.responseIndex].Get(), nullptr,
                                                                  slot.response[next].Get(), true);
                    Barrier(cmd, slot.response[next].Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                    slot.responseValid = matchedResponse;
                    if (matchedResponse)
                    {
                        slot.responseIndex = next;
                        slot.responseWidth = (unsigned) desc.Width;
                        slot.responseHeight = desc.Height;
                        slot.responseSpace = colorSpace;
                        slot.responseExposure = slot.frame.PreExposure;
                        slot.responseEpoch = epoch;
                        apply.Mode = pq ? 9 : 8;
                    }
                }
            }
            else
                slot.responseValid = false;
            appliedResidual = shader.DispatchResidualPass(
                cmd, apply, color, matchedResponse ? slot.cleanScene.Get() : nullptr, slot.residual.Get(),
                matchedResponse ? slot.response[slot.responseIndex].Get() : nullptr, slot.encoded.Get(), true);
            if (measure)
                Barrier(cmd, slot.cleanScene.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                        D3D12_RESOURCE_STATE_COPY_DEST);
            if (!appliedResidual)
            {
                slot.responseValid = false;
                outputStatus.state = DlssNr::OutputState::Failed;
                outputStatus.reason = DlssNr::OutputReason::Composition;
            }
            if (appliedResidual)
            {
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                        D3D12_RESOURCE_STATE_COPY_SOURCE);
                Barrier(cmd, color, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
                cmd->CopyResource(color, slot.encoded.Get());
                finalCopyBack = true;
                Barrier(cmd, color, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                        D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            }
            Barrier(cmd, color, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PRESENT);
            Barrier(cmd, slot.residual.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_COPY_DEST);
        }
    }
    else
    {
        auto frame = slot.frame;
        frame.ColourIsLinearHdr = pq || scrgb;
        // Absolute display encodings: 203-nit reference white, in 80-nit scRGB units.
        frame.WhitePointOverride = (pq || scrgb) ? 203.0f / 80.0f : 0.0f;
        frame.Reset |= late.reset;
        frame.SubmissionEpoch = legacyBridge ? epoch : slot.identity.application;
        Barrier(cmd, slot.depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        Barrier(cmd, slot.motion.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        ID3D12Resource* nrColor = color;
        bool colorReady = true;
        DlssNrConstants conversion {};
        conversion.Width = (unsigned) desc.Width;
        conversion.Height = desc.Height;
        if (pq)
        {
            auto ensure = [&](LateContext::ComPtr<ID3D12Resource>& resource, DXGI_FORMAT format)
            {
                if (resource && (resource->GetDesc().Width != desc.Width ||
                                 resource->GetDesc().Height != desc.Height || resource->GetDesc().Format != format))
                    resource.Reset();
                if (!resource)
                    resource.Attach(CreateScratch(late.device.Get(), format, (unsigned) desc.Width, desc.Height));
                return resource != nullptr;
            };
            colorReady = ensure(slot.linear, DXGI_FORMAT_R16G16B16A16_FLOAT) && ensure(slot.encoded, desc.Format);
            if (colorReady)
            {
                Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT,
                        D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                colorReady = shader.DispatchResidualPass(cmd, conversion, color, nullptr, nullptr, nullptr,
                                                         slot.linear.Get(), true);
                Barrier(cmd, color, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                        D3D12_RESOURCE_STATE_PRESENT);
                // Dispatch reads the converted colour; its transition out of UAV orders the conversion.
                nrColor = slot.linear.Get();
                frame.OutputArrivalState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            }
        }
        if (colorReady)
            Run(cmd, nrColor, slot.depth.Get(), slot.motion.Get(), nrColor, frame, queue);
        finalCopyBack = !pq && outputStatus.composed && outputStatus.copyBack;
        if (pq && colorReady && outputStatus.composed && outputStatus.copyBack &&
            Config::Instance()->DlssNrApplyModel.value_or_default())
        {
            conversion.Mode = 1;
            Barrier(cmd, slot.linear.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(cmd, color, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            if (shader.DispatchResidualPass(cmd, conversion, slot.linear.Get(), nullptr, color, nullptr,
                                            slot.encoded.Get(), true))
            {
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                        D3D12_RESOURCE_STATE_COPY_SOURCE);
                Barrier(cmd, color, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                        D3D12_RESOURCE_STATE_COPY_DEST);
                cmd->CopyResource(color, slot.encoded.Get());
                finalCopyBack = true;
                Barrier(cmd, color, D3D12_RESOURCE_STATE_COPY_DEST,
                        D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                        D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            }
            Barrier(cmd, color, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PRESENT);
            Barrier(cmd, slot.linear.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            if (!finalCopyBack)
            {
                outputStatus.state = DlssNr::OutputState::Failed;
                outputStatus.reason = DlssNr::OutputReason::FinalEncode;
            }
        }
        if (!colorReady)
        {
            outputStatus.state = DlssNr::OutputState::Failed;
            outputStatus.reason = DlssNr::OutputReason::FinalEncode;
        }
        Barrier(cmd, slot.motion.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                D3D12_RESOURCE_STATE_COPY_DEST);
        Barrier(cmd, slot.depth.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                D3D12_RESOURCE_STATE_COPY_DEST);
    }
    outputStatus.application = slot.identity.application;
    outputStatus.generation = slot.identity.generation;
    outputStatus.captureSerial = slot.serial;
    outputStatus.consumer = DlssNr::CurrentFinishedConsumer();
    outputStatus.guidesValid = slot.guidesValid;
    outputStatus.hidden = !Config::Instance()->DlssNrApplyModel.value_or_default();
    outputStatus.copyBack = finalCopyBack;
    outputStatus.composed = slot.residualOnly ? appliedResidual : outputStatus.composed;
    outputCommands = nullptr; // this owned list is submitted below, not by the producer hook
    if (FAILED(cmd->Close()))
    {
        late.heldFailed |= holdFinished;
        late.Say("Could not finish the picture. Restart the game to retry.");
        // The producer promise (submitted/done/ready) stays intact - rolling it back would
        // re-issue a watermark whose signal is already queued. Pin the slot instead: it is
        // never reused, and nothing about the promise changes (DlssNr_LateSlot.h).
        slot.pinned = true;
        outputStatus.state = DlssNr::OutputState::Failed;
        outputStatus.reason = DlssNr::OutputReason::Close;
        LOG_DEBUG("NR late slot {} pinned (composition close failed)", slot.serial);
        return false;
    }
    ID3D12CommandList* lists[] = { cmd };
    queue->ExecuteCommandLists(1, lists);
    outputStatus.executed = true;
    // Monotonic allocation: the composition signal is a fresh value above every watermark
    // this slot has ever carried, so a later arm can never be satisfied by an older signal.
    slot.ready = (slot.ready > slot.done ? slot.ready : slot.done) + 1;
    slot.done = slot.ready;
    if (FAILED(queue->Signal(slot.fence.Get(), slot.ready)))
    {
        slot.pinned = true;
        outputStatus.state = DlssNr::OutputState::Failed;
        outputStatus.reason = DlssNr::OutputReason::Signal;
        outputStatus.completionUnknown = true;
        LOG_DEBUG("NR late slot {} pinned (composition signal failed)", slot.serial);
        late.heldFailed |= holdFinished;
        late.Say("The graphics queue stopped. Restart the game to retry.");
        return false;
    }
    outputStatus.submitted = true;
    if (holdFinished)
    {
        late.heldFence = slot.fence;
        late.heldQueue = realQueue;
        late.heldReady = slot.done;
        late.heldSlot = &slot;
        late.heldSlotSerial = slot.serial;
    }
    const bool ran = finalCopyBack && !outputStatus.hidden &&
                     outputStatus.state != DlssNr::OutputState::Failed;
    if (ran)
    {
        outputStatus.state = DlssNr::OutputState::Submitted;
        outputStatus.reason = DlssNr::OutputReason::None;
    }
    else if (outputStatus.hidden && (outputStatus.evaluated || slot.residualOnly) &&
             outputStatus.state != DlssNr::OutputState::Failed)
    {
        outputStatus.state = DlssNr::OutputState::EvaluatedHidden;
        outputStatus.reason = DlssNr::OutputReason::None;
    }
    // Hiding output must not reset an otherwise composed model history every
    // frame. Final transport failure still requests a fresh history.
    late.reset = outputStatus.state == DlssNr::OutputState::Failed ||
                 (slot.residualOnly ? !appliedResidual : !outputStatus.composed);
    late.Say(outputStatus.state == DlssNr::OutputState::Failed        ? "NR final output failed."
             : outputStatus.hidden                                   ? "NR changes are hidden."
             : ran                                                    ? (slot.residualOnly
                                                                             ? (matchedResponse
                                                                                    ? "Applying pre-SR changes with HDR brightness matching (local fallback enabled)."
                                                                                    : "Applying the pre-SR changes to the finished picture.")
                                                                             : "Applying NR to the finished picture.")
                                                                      : "Preparing NR for the finished picture.");
    if (ran && (++late.successes == 1 || late.successes % 300 == 0))
        LOG_INFO("DLSS-NR finished picture: {} frames, {}x{}, OptiScaler FG {}, same producer queue {}, game-frame handoff {}", late.successes, desc.Width, desc.Height,
                 ::State::Instance().currentFG && ::State::Instance().currentFG->IsActive() &&
                     !::State::Instance().currentFG->IsPaused(), slot.producerQueue.Get() == realQueue, gameFrameHandoff);
    return ran;
}
