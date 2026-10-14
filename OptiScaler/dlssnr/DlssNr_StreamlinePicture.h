#pragma once
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include "DlssNr_FinishedConsumer.h"
#include <mutex>

namespace DlssNr::StreamlinePicture
{
// Streamline's before-hook ABI (sl.api/internal.h). These access the app-facing FG buffers.
using GetIndex = UINT (*)(IDXGISwapChain*, bool&);
using GetBuffer = HRESULT (*)(IDXGISwapChain*, UINT, REFIID, void**, bool&);
inline constexpr GUID renderQueueKey = { 0xc1eb6f13, 0x550c, 0x46ab, { 0xa8, 0x29, 0xf8, 0x72, 0x12, 0x69, 0x3a, 0xb1 } };
inline constexpr GUID bufferHookKey = { 0x2b9bd9c4, 0x946d, 0x42bf, { 0xb8, 0xf5, 0x27, 0xe1, 0x90, 0x75, 0x48, 0xa0 } };
inline constexpr GUID generationKey = { 0x59fe8c14, 0x7e14, 0x4d2b, { 0xb0, 0x19, 0x61, 0xcc, 0xa0, 0x46, 0x58, 0x31 } };

inline bool SameDevice(ID3D12Device* a, ID3D12Device* b)
{
    Microsoft::WRL::ComPtr<IUnknown> left, right;
    return a && b && SUCCEEDED(a->QueryInterface(IID_PPV_ARGS(&left))) &&
           SUCCEEDED(b->QueryInterface(IID_PPV_ARGS(&right))) && left == right;
}

// Buffer zero identifies the buffer set, not the current rotating/display picture.
// A stamp lives on the actual resource, so resize/recreation changes generation
// without retaining a backbuffer reference that would prevent ResizeBuffers.
struct ConsumerSnapshot
{
    FinishedIdentity identity {};
    Microsoft::WRL::ComPtr<IUnknown> retained;
    Microsoft::WRL::ComPtr<ID3D12Device> device;
};

inline ConsumerSnapshot Consumer(IDXGISwapChain* swapchain, bool resetGeneration = false)
{
    ConsumerSnapshot snapshot;
    if (!swapchain) return snapshot;
    Microsoft::WRL::ComPtr<ID3D12Resource> buffer;
    GetBuffer hook = nullptr;
    UINT size = sizeof(hook);
    swapchain->GetPrivateData(bufferHookKey, &size, &hook);
    if (hook)
    {
        bool handled = false;
        if (FAILED(hook(swapchain, 0, IID_PPV_ARGS(&buffer), handled)) || !handled) return snapshot;
    }
    else if (FAILED(swapchain->GetBuffer(0, IID_PPV_ARGS(&buffer))))
        return snapshot;
    if (!buffer || FAILED(swapchain->QueryInterface(IID_PPV_ARGS(&snapshot.retained))) ||
        FAILED(buffer->GetDevice(IID_PPV_ARGS(&snapshot.device)))) return {};
    uint64_t generation = 0;
    size = sizeof(generation);
    // Capture and Present query before NR locks. Serialize only stamp publication;
    // there is no queue/fence operation or GPU readiness wait in this critical section.
    static std::mutex generationMutex;
    std::lock_guard generationLock(generationMutex);
    if (resetGeneration || FAILED(buffer->GetPrivateData(generationKey, &size, &generation)) || !generation)
    {
        static std::atomic<uint64_t> serial { 0 };
        generation = ++serial;
        if (FAILED(buffer->SetPrivateData(generationKey, sizeof(generation), &generation))) return {};
    }
    snapshot.identity.consumer = snapshot.retained.Get();
    snapshot.identity.generation = generation;
    return snapshot;
}

inline Microsoft::WRL::ComPtr<ID3D12Resource> Read(IDXGISwapChain* swapchain, GetIndex indexHook, GetBuffer bufferHook)
{
    Microsoft::WRL::ComPtr<ID3D12Resource> picture;
    if (!swapchain || !indexHook || !bufferHook) return picture;
    bool handled = false;
    const UINT index = indexHook(swapchain, handled);
    if (!handled) return picture;
    handled = false;
    if (FAILED(bufferHook(swapchain, index, IID_PPV_ARGS(&picture), handled)) || !handled)
        picture.Reset();
    return picture; // Never substitute the asynchronous display buffer when the plugin declines.
}

inline Microsoft::WRL::ComPtr<ID3D12CommandQueue> RenderQueue(IDXGISwapChain* swapchain)
{
    Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
    UINT size = sizeof(ID3D12CommandQueue*);
    if (swapchain && FAILED(swapchain->GetPrivateData(renderQueueKey, &size, queue.GetAddressOf()))) queue.Reset();
    return queue;
}
using GetFunction = void* (*)(const char*);
void* Wrap(const char* name, GetFunction getFunction, bool local = false);
}
