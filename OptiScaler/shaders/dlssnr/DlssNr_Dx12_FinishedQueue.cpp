#include "pch.h"
#include "DlssNr_Dx12_State.h"
#include <dlssnr/DlssNr_StreamlinePicture.h>

auto DlssNr_Dx12::State::FinishedPictureResetCommandList(ID3D12CommandList* cmd) -> void
{
    std::lock_guard<std::recursive_mutex> lock(mutex);
    lifetime.ResetRecording(cmd);
    deferredSr.lifetime.ResetRecording(cmd);
    captureFrames.ResetRecording(cmd);
    if (enlarger) enlarger->lifetime.ResetRecording(cmd);
    for (auto& old : retiredEnlargers) old->lifetime.ResetRecording(cmd);
    CollectEnlargers();
    ID3D12CommandList* real = nullptr;
    const bool proxied = Util::CheckForRealObject(__FUNCTION__, cmd, (IUnknown**)&real);
    auto* identity = proxied ? real : cmd;
    if (enlarger && !enlarger->submitted && enlarger->creation == identity)
    {
        enlarger->failed = true;
        enlargementStatus = "DLSS enlargement initialization was discarded; use Retry.";
    }
    for (auto& model : nr.models) model.ResetRecording(cmd);
    if (inputHold.captureCommands == cmd)
    {
        inputHold.active = false; // recording was discarded before submission
        inputHold.captureCommands = nullptr;
        nr.heldActive = false;
    }
    if (gpuTime)
        gpuTime->ResetRecording(cmd);
    if (ngxTime)
        ngxTime->ResetRecording(cmd);
    if (!late.tracking.load())
        return;
    for (auto& slot : late.slots)
        if (slot.owned && !slot.submitted && !slot.promisePending &&
            DlssNr::SameRecordedCommandIdentity(slot.producer, cmd, proxied ? real : nullptr))
        {
            // Proven discard: the game reset this producer list, so its recorded copies
            // can never execute and no signal was ever owed for this arm. Ownership is
            // resolved without touching the watermark - Arm never advanced `done` for an
            // unpromised recording, so there is nothing to roll back (DlssNr_LateSlot.h).
            // A list whose execution is already promised is not discarded here.
            DlssNr::DiscardLateSlot(slot.pending, slot.owned);
            LOG_DEBUG("NR late slot {} discarded (producer reset owned unpromised)", slot.serial);
            late.reset = true;
        }
}

auto DlssNr_Dx12::State::WaitForFinishedPicture() -> bool
{
    if (!late.tracking.load())
        return true;
    std::lock_guard<std::recursive_mutex> lock(mutex);
    late.Cancel();
    for (auto& slot : late.slots)
    {
        if (!slot.submitted || late.Finished(slot))
            continue;
        if (slot.fence->GetCompletedValue() == UINT64_MAX)
            return false; // Device removal is not a completed submission.
        HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event)
            return false;
        const auto hr = slot.fence->SetEventOnCompletion(slot.done, event);
        const bool finished = SUCCEEDED(hr) && WaitForSingleObject(event, 5000) == WAIT_OBJECT_0;
        CloseHandle(event);
        if (!finished || !late.Finished(slot))
            return false;
    }
    return late.dx11.Drain();
}

auto DlssNr_Dx12::State::FinishedPictureStatus() -> std::string
{
    std::lock_guard<std::recursive_mutex> lock(mutex);
    return late.status;
}

auto DlssNr_Dx12::State::FinishedPicturePromised(DlssNr::LatePromiseBatch& batch, DlssNr_Dx12* owner,
                                                 ID3D12CommandQueue* queue, UINT count,
                                                 ID3D12CommandList* const* lists) -> void
{
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!late.tracking.load())
        return;
    ID3D12CommandQueue* realQueue = nullptr;
    const bool proxiedQueue = Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**) &realQueue);
    const void* queueIdentity = DlssNr::NormalizedCommandIdentity(queue, proxiedQueue ? realQueue : nullptr);
    for (unsigned index = 0; index < late.slots.size(); ++index)
    {
        auto& slot = late.slots[index];
        // Ownership, not presentation eligibility: a capture that already left selection
        // still has a recording that can execute, and its promise must be recorded.
        if (!slot.owned || slot.submitted || slot.promisePending)
            continue;
        for (UINT i = 0; i < count; ++i)
        {
            ID3D12CommandList* realList = nullptr;
            const bool proxiedList = Util::CheckForRealObject(__FUNCTION__, lists[i], (IUnknown**) &realList);
            if (!DlssNr::SameRecordedCommandIdentity(slot.producer, lists[i], proxiedList ? realList : nullptr))
                continue;
            // Record the intent and this call's token only. The slot stays owned and NOT
            // enqueued, so a consumer that acquires the NR locks while this producer is
            // suspended before its real ExecuteCommandLists cannot compose, fence or reuse it.
            DlssNr::RecordLateSlotPromise(slot.ready, slot.promisedValue, slot.promisePending);
            slot.promisedQueue = queue;
            DlssNr::LatePromiseEntry entry {};
            entry.owner = owner;
            entry.slot = index;
            entry.serial = slot.serial;
            entry.token = slot.promisedValue;
            entry.queue = queueIdentity;
            entry.producer = DlssNr::NormalizedCommandIdentity(lists[i], proxiedList ? realList : nullptr);
            batch.push_back(entry);
            LOG_DEBUG("NR late slot {} promise recorded ready={} queue={}", slot.serial, entry.token,
                      (const void*) queueIdentity);
            break;
        }
    }
}

auto DlssNr_Dx12::State::FinishedPictureSubmitted(DlssNr::LatePromiseBatch& batch, DlssNr_Dx12* owner,
                                                  ID3D12CommandQueue* queue, UINT count,
                                                  ID3D12CommandList* const* lists) -> void
{
    std::lock_guard<std::recursive_mutex> lock(mutex);
    lifetime.Submitted(queue, count, lists);
    deferredSr.lifetime.Submitted(queue, count, lists);
    captureFrames.Submitted(queue, count, lists);
    if (enlarger) enlarger->lifetime.Submitted(queue, count, lists);
    for (auto& old : retiredEnlargers) old->lifetime.Submitted(queue, count, lists);
    CollectEnlargers();
    if (enlarger && !enlarger->submitted)
    {
        ID3D12CommandQueue* real = nullptr;
        auto* identity = Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**)&real) ? real : queue;
        for (UINT i = 0; i < count; ++i)
        {
            ID3D12CommandList* realList = nullptr;
            auto* list = Util::CheckForRealObject(__FUNCTION__, lists[i], (IUnknown**)&realList) ? realList : lists[i];
            if (list == enlarger->creation)
            {
                enlarger->queue = identity;
                enlarger->submitted = true;
                LOG_INFO("NR DLSS enlargement initialization submitted on producer queue {}", (void*)identity);
            }
        }
    }
    for (auto& model : nr.models) model.Submitted(queue, count, lists);
    for (UINT i = 0; i < count; ++i)
        if (lists[i] == inputHold.captureCommands)
            inputHold.captureCommands = nullptr;
    if (gpuTime)
        gpuTime->Submitted(queue, count, lists);
    if (ngxTime)
        ngxTime->Submitted(queue, count, lists);
    if (!late.tracking.load())
        return;
    ID3D12CommandQueue* realQueue = nullptr;
    const bool proxiedQueue = Util::CheckForRealObject(__FUNCTION__, queue, (IUnknown**) &realQueue);
    const void* queueIdentity = DlssNr::NormalizedCommandIdentity(queue, proxiedQueue ? realQueue : nullptr);
    for (const auto& entry : batch)
    {
        // Resolve ONLY this call's own tokens: matching on the queue alone would let an
        // unrelated list submitted on the same queue consume another list's promise.
        if (entry.owner != owner || entry.slot >= late.slots.size())
            continue;
        auto& slot = late.slots[entry.slot];
        if (!DlssNr::LatePromiseEntryMatches(entry, owner, entry.slot, slot.serial, slot.promisePending,
                                             slot.promisedValue, queueIdentity, slot.producer))
            continue;
        // The real ExecuteCommandLists returned on the promised queue: the token becomes a
        // submission. Consume the token's own value, never the slot's mutable `ready`, and
        // only now clear ownership so the fence at that value is what gates reuse.
        const uint64_t promised = entry.token;
        slot.promisedQueue = nullptr;
        slot.producerQueue = (ID3D12CommandQueue*) queueIdentity;
        late.producerQueue = queue;
        DlssNr::EnqueueLateSlotPromise(promised, slot.done, slot.submitted, slot.owned, slot.promisePending);
        LOG_DEBUG("NR late slot {} enqueued promised={} done={}", slot.serial, promised, slot.done);
        if (FAILED(queue->Signal(slot.fence.Get(), promised)))
        {
            // The copy executed but no signal will ever prove completion. Pin the slot:
            // unknown abandonment is pinned and logged, never released.
            slot.pinned = true;
            LOG_DEBUG("NR late slot {} pinned (producer signal failed)", slot.serial);
            late.Say("The graphics queue stopped. Restart the game to retry.");
        }
    }
}

auto DlssNr_Dx12::State::FinishedColorSpace(IDXGISwapChain* swapchain, DXGI_FORMAT format) -> DXGI_COLOR_SPACE_TYPE
{
    auto space = format == DXGI_FORMAT_R16G16B16A16_FLOAT ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709
                                                        : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    UINT size = sizeof(space);
    swapchain->GetPrivateData(DlssNr::FinishedColorSpaceKey, &size, &space);
    return space;
}

auto DlssNr_Dx12::State::ApplyToFinishedPictureDx11(IDXGISwapChain* swapchain) -> void
{
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!swapchain || !late.device || !late.producerQueue ||
        !Config::Instance()->DlssNrFinishedPicture.value_or_default() ||
        !Config::Instance()->DlssNrEnabled.value_or_default())
        return;
    const bool heldPicture = Config::Instance()->DlssNrHoldFrame.value_or_default() && inputHold.active &&
                             late.heldValid && late.heldGeneration == inputHold.generation;
    if (!heldPicture && std::none_of(late.slots.begin(), late.slots.end(), [](const auto& slot) {
            return DlssNr::LateCaptureSelectable(slot.pending, slot.pinned, slot.submitted, slot.promisePending);
        }))
        return;
    LateContext::ComPtr<IDXGISwapChain3> sc;
    LateContext::ComPtr<ID3D11Texture2D> picture;
    DXGI_SWAP_CHAIN_DESC desc {};
    if (FAILED(swapchain->GetDesc(&desc)))
        return;
    // Blt-model chains expose buffer zero; flip-model chains rotate the current index.
    UINT index = 0;
    if ((desc.SwapEffect == DXGI_SWAP_EFFECT_FLIP_DISCARD || desc.SwapEffect == DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL) &&
        SUCCEEDED(swapchain->QueryInterface(IID_PPV_ARGS(&sc))))
        index = sc->GetCurrentBackBufferIndex();
    if (FAILED(swapchain->GetBuffer(index, IID_PPV_ARGS(&picture))))
        return;
    auto* color = late.dx11.Begin(picture.Get(), late.device.Get(), late.producerQueue.Get());
    if (!color)
    {
        late.Say("The DirectX 11 finished-picture bridge is unavailable for this device or screen format.");
        return;
    }
    const bool ran = ApplyFinishedColor(color, late.producerQueue.Get(),
                                       FinishedColorSpace(swapchain, color->GetDesc().Format));
    if (!late.dx11.End(picture.Get(), ran))
        late.Say("The DirectX 11 finished-picture transfer failed. Restart the game to retry.");
}
