#pragma once

#include <d3d12.h>
#include <functional>
#include <memory>
#include <wrl/client.h>
#include <array>
#include <mutex>

namespace DlssNr
{
struct CaptureCompletion
{
    struct Point
    {
        Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
        Microsoft::WRL::ComPtr<ID3D12Fence> fence;
        bool resolved = false, failed = false;
    };
    std::mutex mutex;
    Microsoft::WRL::ComPtr<IUnknown> deviceIdentity;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    std::array<std::shared_ptr<Point>, 8> points {};
    unsigned count = 0;
    bool closed = false, failed = false, discarded = false;
    ~CaptureCompletion() { if (event) CloseHandle(event); }
    void Close()
    {
        std::lock_guard lock(mutex);
        for (unsigned i = 0; i < count; ++i) discarded |= !points[i]->resolved;
        closed = true;
        if (event) SetEvent(event);
    }
    enum class Result { Pending, Discarded, Ready, DeviceRemoved };
    Result Readiness()
    {
        std::lock_guard lock(mutex);
        if (!closed) return Result::Pending;
        if (!count) return failed ? Result::Pending : Result::Discarded;
        bool complete = !failed, removed = false;
        for (unsigned i = 0; i < count; ++i)
        {
            const auto& point = points[i];
            if (!point->resolved) { complete = false; continue; }
            Microsoft::WRL::ComPtr<ID3D12Device> device;
            if (point->queue && SUCCEEDED(point->queue->GetDevice(IID_PPV_ARGS(&device))) &&
                FAILED(device->GetDeviceRemovedReason())) { removed = true; continue; }
            const auto value = point->fence ? point->fence->GetCompletedValue() : 0;
            complete &= !point->failed && value != UINT64_MAX && value >= 1;
        }
        return complete ? (removed ? Result::DeviceRemoved : discarded ? Result::Discarded : Result::Ready)
                        : Result::Pending;
    }
};
// NR-local lifetime tracking. Record/submit/reset/retire/collect calls are serialized internally.
// Owners must still guard their resources and outlive all calls. Lock order when owned by NR:
// owner registry -> NR state -> tracker; retirement callbacks may re-enter on the calling thread.
class GpuLifetime
{
    struct Impl;
    std::unique_ptr<Impl> impl;

  public:
    GpuLifetime();
    ~GpuLifetime();
    GpuLifetime(const GpuLifetime&) = delete;
    GpuLifetime& operator=(const GpuLifetime&) = delete;
    void Record(ID3D12GraphicsCommandList* commands);
    // Tracker must outlive the probe; discarded work never satisfies it.
    std::function<bool()> CompletionProbe(ID3D12GraphicsCommandList* commands);
    std::shared_ptr<CaptureCompletion> SubscribeCapture(ID3D12GraphicsCommandList* commands);
    // Return this call's resolution closure. Invoke once AFTER its real ExecuteCommandLists.
    // Every dedicated event/fence is armed here, BEFORE that actual submission.
    std::function<void()> PrepareCapture(ID3D12CommandQueue* queue, UINT count,
                                         ID3D12CommandList* const* lists);
    // One reusable monotonic fence per queue; aliases are normalized at every notification.
    // Only call after the real ExecuteCommandLists or a successful command-list Reset.
    void Submitted(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists);
    void ResetRecording(ID3D12CommandList* commands);
    // Start tracking a replacement resource set. Older recordings still receive submit/reset
    // notifications, but only recordings used again belong to the new generation.
    void BeginGeneration();
    // Unresolved callbacks, including their captured ownership, are retained at destruction.
    void Retire(std::function<void()> destroy);
    void Collect();
    bool Idle();
    // Retired owners only: completed submissions can no longer be replayed by this owner.
    // Unsubmitted recordings and failed/removed-device fences remain unresolved.
    void FinishSubmitted();
};
}
