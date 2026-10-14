#include "pch.h"
#include "DlssNr_Dx12_State.h"
#include <dlssnr/DlssNr_FinishedConsumer.h>

void DlssNr_Dx12::State::EvaluateInternal(ID3D12GraphicsCommandList* cmd, NVSDK_NGX_Parameter* params,
                                         bool beforeUpscale, ID3D12CommandQueue* queue, bool rayReconstruction,
                                         unsigned long long submissionEpoch, bool interop)
{
    std::lock_guard lock(mutex);
    const auto& cfg = *Config::Instance();
    const auto placement = DlssNr::ResolvePlacement(
        cfg.DlssNrRunBeforeSr.value_or_default(), cfg.DlssNrDeferredDlss.value_or_default(),
        cfg.DlssNrResidualAcrossRr.value_or_default(), cfg.DlssNrFinishedPicture.value_or_default());
    const unsigned finishedMode = !placement.finished ? 0u : placement.deferred ? 2u : 1u;
    if (lastFinishedMode != finishedMode)
    {
        nr.reset = true;
        if (gpuTime) gpuTime->ClearLast();
        if (ngxTime) ngxTime->ClearLast();
        lastGpuTime.reset();
        lastNgxTime.reset();
        late.Cancel();
        deferredSr.Cancel();
        lastFinishedMode = finishedMode;
    }
    if (!cfg.DlssNrEnabled.value_or_default())
    {
        deferredSr.Cancel();
        late.Cancel();
        return;
    }
    if (placement.finished)
    {
        const bool dx11 = ::State::Instance().swapchainApi == API::DX11 ||
                          ::State::Instance().swapchainInteropApi == SwapchainInteropApi::Dx11wDx12;
        if ((interop || ::State::Instance().swapchainInteropApi != SwapchainInteropApi::None) && !dx11)
        {
            deferredSr.Cancel();
            late.Cancel();
            late.Say("This finished-picture route requires DirectX 12 or the DirectX 11 bridge.");
            return;
        }
        if (!placement.deferred)
        {
            deferredSr.Cancel();
            if (beforeUpscale)
            {
                outputStatus.ResetOutcome();
                outputStatus.state = DlssNr::OutputState::Capturing;
                outputStatus.requested = outputStatus.effective = placement;
                outputStatus.consumer = DlssNr::CurrentFinishedConsumer();
                // Native tokens advance only at the application reconstruction seam.
                if (!late.consumer.applicationKnown)
                {
                    late.consumer.application = seamClock.AtSeam(true, interop, interop ? submissionEpoch : 0);
                    late.consumer.applicationKnown = true;
                }
                late.Capture(cmd, params, rayReconstruction, interop);
                outputStatus.application = late.consumer.application;
                outputStatus.generation = late.consumer.generation;
                for (const auto& slot : late.slots)
                    if (slot.pending && slot.identity.SameConsumer(late.consumer) &&
                        slot.identity.application == late.consumer.application &&
                        slot.serial > outputStatus.captureSerial)
                    {
                        outputStatus.captureSerial = slot.serial;
                        outputStatus.guidesValid = slot.guidesValid;
                    }
                if (!outputStatus.guidesValid)
                {
                    outputStatus.state = DlssNr::OutputState::Skipped;
                    outputStatus.reason = DlssNr::OutputReason::Admission;
                }
            }
            return;
        }
    }
    else
        late.Cancel();

    // The game's SR or RR+SR consumes untouched Color. A separate private upscaler reconstructs
    // the NR edit, then applies it after the matching evaluation or saves it for presentation.
    if (!cmd || !params)
    {
        deferredSr.Cancel();
        return;
    }
    const auto submitted = interop ? submissionEpoch : ::State::Instance().frameCount;
    const auto epoch = seamClock.AtSeam(beforeUpscale, interop, submitted);
    if (beforeUpscale)
        deferredSr.Before(cmd, params, epoch, submitted, queue, interop, rayReconstruction);
    else
        deferredSr.After(cmd, params, epoch);
}
