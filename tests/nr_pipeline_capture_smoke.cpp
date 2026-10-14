#include <windows.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <fstream>
#include <dlssnr/DlssNr_PipelineCapture.h>
using Microsoft::WRL::ComPtr;
static void require(bool value, const char* id) { if (!value) throw std::runtime_error(id); }
static void check(HRESULT value) { require(SUCCEEDED(value), "T21_D3D12_API"); }
// Installed only after the real copy is recorded. Map still calls the actual WARP resource.
struct MapCounterResource final : ID3D12Resource
{
    std::atomic_ulong refs { 1 };
    ComPtr<ID3D12Resource> real;
    std::atomic_uint& maps;
    MapCounterResource(ID3D12Resource* resource, std::atomic_uint& counter) : real(resource), maps(counter) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override
    {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12Object) &&
            iid != __uuidof(ID3D12DeviceChild) && iid != __uuidof(ID3D12Pageable) &&
            iid != __uuidof(ID3D12Resource)) return E_NOINTERFACE;
        *result = static_cast<ID3D12Resource*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { auto left = --refs; if (!left) delete this; return left; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID id, UINT* size, void* data) override { return real->GetPrivateData(id, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID id, UINT size, const void* data) override { return real->SetPrivateData(id, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID id, const IUnknown* value) override { return real->SetPrivateDataInterface(id, value); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override { return real->SetName(name); }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void** result) override { return real->GetDevice(iid, result); }
    HRESULT STDMETHODCALLTYPE Map(UINT subresource, const D3D12_RANGE* range, void** data) override
    { ++maps; return real->Map(subresource, range, data); }
    void STDMETHODCALLTYPE Unmap(UINT subresource, const D3D12_RANGE* range) override { real->Unmap(subresource, range); }
    D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc() override { return real->GetDesc(); }
    D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE GetGPUVirtualAddress() override { return real->GetGPUVirtualAddress(); }
    HRESULT STDMETHODCALLTYPE WriteToSubresource(UINT subresource, const D3D12_BOX* box, const void* data, UINT row, UINT depth) override
    { return real->WriteToSubresource(subresource, box, data, row, depth); }
    HRESULT STDMETHODCALLTYPE ReadFromSubresource(void* data, UINT row, UINT depth, UINT subresource, const D3D12_BOX* box) override
    { return real->ReadFromSubresource(data, row, depth, subresource, box); }
    HRESULT STDMETHODCALLTYPE GetHeapProperties(D3D12_HEAP_PROPERTIES* properties, D3D12_HEAP_FLAGS* flags) override
    { return real->GetHeapProperties(properties, flags); }
};
static void CountMaps(DlssNr::PipelineCaptureFrame& frame, std::atomic_uint& maps)
{
    for (auto& image : frame.images)
        if (image.readback)
        {
            ComPtr<ID3D12Resource> observer;
            observer.Attach(new MapCounterResource(image.readback.Get(), maps));
            image.readback = std::move(observer);
        }
}
struct ControlledFence final : ID3D12Fence
{
    std::atomic_ulong refs { 1 };
    UINT64 completed = 1;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override
    {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12Fence)) return E_NOINTERFACE;
        *result = static_cast<ID3D12Fence*>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { auto left = --refs; if (!left) delete this; return left; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void**) override { return E_NOTIMPL; }
    UINT64 STDMETHODCALLTYPE GetCompletedValue() override { return completed; }
    HRESULT STDMETHODCALLTYPE SetEventOnCompletion(UINT64, HANDLE) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Signal(UINT64) override { return E_NOTIMPL; }
};
struct FailedSignalQueue final : ID3D12CommandQueue
{
    std::atomic_ulong refs { 1 };
    ComPtr<ID3D12CommandQueue> real;
    unsigned signals = 0;
    explicit FailedSignalQueue(ID3D12CommandQueue* value) : real(value) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override
    { if (!result) return E_POINTER; *result = nullptr;
      if (iid != __uuidof(IUnknown) && iid != __uuidof(ID3D12CommandQueue) && iid != __uuidof(ID3D12Pageable) &&
          iid != __uuidof(ID3D12DeviceChild) && iid != __uuidof(ID3D12Object)) return E_NOINTERFACE;
      *result = static_cast<ID3D12CommandQueue*>(this); AddRef(); return S_OK; }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { auto count = --refs; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID id, UINT* size, void* data) override { return real->GetPrivateData(id, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID id, UINT size, const void* data) override { return real->SetPrivateData(id, size, data); }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID id, const IUnknown* value) override { return real->SetPrivateDataInterface(id, value); }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR name) override { return real->SetName(name); }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid, void** device) override { return real->GetDevice(iid, device); }
    void STDMETHODCALLTYPE UpdateTileMappings(ID3D12Resource* resource, UINT regions, const D3D12_TILED_RESOURCE_COORDINATE* starts,
        const D3D12_TILE_REGION_SIZE* sizes, ID3D12Heap* heap, UINT ranges, const D3D12_TILE_RANGE_FLAGS* flags,
        const UINT* offsets, const UINT* tiles, D3D12_TILE_MAPPING_FLAGS mapping) override
    { real->UpdateTileMappings(resource, regions, starts, sizes, heap, ranges, flags, offsets, tiles, mapping); }
    void STDMETHODCALLTYPE CopyTileMappings(ID3D12Resource* destination, const D3D12_TILED_RESOURCE_COORDINATE* destinationStart,
        ID3D12Resource* source, const D3D12_TILED_RESOURCE_COORDINATE* sourceStart,
        const D3D12_TILE_REGION_SIZE* size, D3D12_TILE_MAPPING_FLAGS flags) override
    { real->CopyTileMappings(destination, destinationStart, source, sourceStart, size, flags); }
    void STDMETHODCALLTYPE ExecuteCommandLists(UINT count, ID3D12CommandList* const* lists) override { real->ExecuteCommandLists(count, lists); }
    void STDMETHODCALLTYPE SetMarker(UINT metadata, const void* data, UINT size) override { real->SetMarker(metadata, data, size); }
    void STDMETHODCALLTYPE BeginEvent(UINT metadata, const void* data, UINT size) override { real->BeginEvent(metadata, data, size); }
    void STDMETHODCALLTYPE EndEvent() override { real->EndEvent(); }
    HRESULT STDMETHODCALLTYPE Signal(ID3D12Fence*, UINT64) override { ++signals; return E_FAIL; }
    HRESULT STDMETHODCALLTYPE Wait(ID3D12Fence* fence, UINT64 value) override { return real->Wait(fence, value); }
    HRESULT STDMETHODCALLTYPE GetTimestampFrequency(UINT64* value) override { return real->GetTimestampFrequency(value); }
    HRESULT STDMETHODCALLTYPE GetClockCalibration(UINT64* gpu, UINT64* cpu) override { return real->GetClockCalibration(gpu, cpu); }
    D3D12_COMMAND_QUEUE_DESC STDMETHODCALLTYPE GetDesc() override { return real->GetDesc(); }
};
static void CpuReadiness(const std::filesystem::path& root, bool idle = true)
{
    using Completion = DlssNr::CaptureCompletion;
    Completion empty; empty.Close();
    require(empty.Readiness() == Completion::Result::Discarded, "T21_UNSUBMITTED_DISCARDED");
    Completion ticket;
    auto point = std::make_shared<Completion::Point>();
    auto* fence = new ControlledFence;
    point->fence.Attach(fence);
    ticket.points[ticket.count++] = point;
    point->resolved = true;
    require(ticket.Readiness() == Completion::Result::Pending, "T21_RECORDING_OPEN");
    point->resolved = false;
    ticket.Close();
    require(ticket.discarded && ticket.Readiness() == Completion::Result::Pending, "T21_PROMISED_RESET_RETAINED");
    point->resolved = true;
    require(ticket.Readiness() == Completion::Result::Discarded, "T21_PROMISED_RESET_NEVER_CAPTURED");
    Completion failed;
    failed.points[failed.count++] = point;
    point->failed = true;
    failed.Close();
    require(failed.Readiness() == Completion::Result::Pending, "T21_FAILED_SIGNAL_RETAINED");
    point->failed = false; fence->completed = UINT64_MAX;
    require(failed.Readiness() == Completion::Result::Pending, "T21_UINT64_MAX_NOT_READY");
    fence->completed = 0;
    require(failed.Readiness() == Completion::Result::Pending, "T21_UNREADY_RETAINED");
    fence->completed = 1;
    require(failed.Readiness() == Completion::Result::Ready, "T21_EXACT_COMPLETION_READY");
    failed.failed = true;
    require(failed.Readiness() == Completion::Result::Pending, "T21_REPLAY_OVERFLOW_RETAINED");
    failed.failed = false;
    auto second = std::make_shared<Completion::Point>();
    auto* secondFence = new ControlledFence;
    second->fence.Attach(secondFence); second->resolved = true; secondFence->completed = 0;
    failed.points[failed.count++] = second;
    require(failed.Readiness() == Completion::Result::Pending, "T21_ALL_REPLAY_COMPLETIONS");
    secondFence->completed = 1;
    require(failed.Readiness() == Completion::Result::Ready, "T21_ALL_REPLAYS_READY");
    for (unsigned i = 0; idle && i < 2; ++i)
    {
        auto session = DlssNr::PipelineCaptureSession::Begin(root / ("idle-" + std::to_string(i)));
        require(bool(session), "T21_IDLE_WORKER_START");
        require(!DlssNr::PipelineCaptureSession::Begin("unused"), "T21_AGGREGATE_IDLE_SESSION");
        session->Stop();
        require(WaitForSingleObject(session->Exited(), 10000) == WAIT_OBJECT_0, "T21_IDLE_WORKER_EXIT");
        require(!session->TimedOut() && !DlssNr::PipelineCaptureSession::Busy(), "T21_IDLE_WORKER_STATUS");
    }
    std::printf("PASS cpu-readiness typed ControlledFence; no device/GPU; promise-reset/failed/MAX/unready\n");
}
struct Warp
{
    ComPtr<IDXGIFactory4> factory;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue, second;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> cmd;
    ComPtr<ID3D12Resource> texture;
    ComPtr<ID3D12DescriptorHeap> descriptors;
    DlssNr::GpuLifetime lifetime;
    Warp()
    {
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)));
        D3D12_COMMAND_QUEUE_DESC q {};
        check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)));
        check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&second)));
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
        D3D12_RESOURCE_DESC d {};
        d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; d.Width = 512; d.Height = 512;
        d.DepthOrArraySize = d.MipLevels = 1; d.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
        d.SampleDesc.Count = 1; d.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        D3D12_HEAP_PROPERTIES h {}; h.Type = D3D12_HEAP_TYPE_DEFAULT;
        check(device->CreateCommittedResource(&h, D3D12_HEAP_FLAG_NONE, &d,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&texture)));
        D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.NumDescriptors = 1;
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&descriptors)));
        device->CreateUnorderedAccessView(texture.Get(), nullptr, nullptr, descriptors->GetCPUDescriptorHandleForHeapStart());
    }
    void Clear(float value)
    {
        ID3D12DescriptorHeap* heaps[] { descriptors.Get() }; cmd->SetDescriptorHeaps(1, heaps);
        float color[] { value, value, value, 1 };
        cmd->ClearUnorderedAccessViewFloat(descriptors->GetGPUDescriptorHandleForHeapStart(),
            descriptors->GetCPUDescriptorHandleForHeapStart(), texture.Get(), color, 0, nullptr);
        D3D12_RESOURCE_BARRIER barrier {}; barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
        barrier.UAV.pResource = texture.Get(); cmd->ResourceBarrier(1, &barrier);
    }
    void Submit(ID3D12CommandQueue* target = nullptr)
    {
        if (!target) target = queue.Get();
        ID3D12CommandList* lists[] { cmd.Get() };
        auto resolve = lifetime.PrepareCapture(target, 1, lists);
        target->ExecuteCommandLists(1, lists);
        if (resolve) resolve();
        lifetime.Submitted(target, 1, lists);
    }
    void Done(ID3D12CommandQueue* target = nullptr)
    {
        if (!target) target = queue.Get();
        ComPtr<ID3D12Fence> fence;
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)));
        HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        check(fence->SetEventOnCompletion(1, event));
        check(target->Signal(fence.Get(), 1));
        require(WaitForSingleObject(event, 10000) == WAIT_OBJECT_0, "T21_GPU_EVENT_TIMEOUT");
        CloseHandle(event);
    }
    void Reset()
    {
        check(allocator->Reset());
        check(cmd->Reset(allocator.Get(), nullptr));
        lifetime.ResetRecording(cmd.Get());
    }
};
static DlssNr::CaptureIdentity Identity(unsigned frame) { return { 1, 2, 3, frame, true }; }
static void Finish(const std::shared_ptr<DlssNr::PipelineCaptureSession>& session)
{
    session->Stop();
    require(WaitForSingleObject(session->Exited(), 10000) == WAIT_OBJECT_0, "T21_WORKER_EXIT");
    require(!session->TimedOut(), "T21_NO_QUARANTINE");
    require(session->Budget()->inFlight == 0, "T21_READBACK_RELEASED");
}
static void Pixels(const std::filesystem::path& file, float value)
{
    std::ifstream stream(file, std::ios::binary);
    std::vector<float> pixels(256 * 256 * 4);
    stream.read(reinterpret_cast<char*>(pixels.data()), std::streamsize(pixels.size() * sizeof(float)));
    require(stream.gcount() == std::streamsize(pixels.size() * sizeof(float)), "T21_ROI_BYTES");
    for (size_t i = 0; i < pixels.size(); i += 4)
        require(pixels[i] == value && pixels[i+1] == value && pixels[i+2] == value && pixels[i+3] == 1,
                "T21_ACTUAL_PIXELS");
}
int main(int argc, char** argv) try
{
    require(argc == 3, "T21_ARGUMENTS");
    const std::string test = argv[1];
    const std::filesystem::path root = argv[2];
    if (test == "cpu-readiness") { CpuReadiness(root); return 0; }
    if (test == "cpu-readiness-no-idle") { CpuReadiness(root, false); return 0; }
    Warp gpu;
    if (test == "device-origin" || test == "device-origin-copy" || test == "device-origin-removed")
    {
        ComPtr<ID3D12DeviceFactory> factory;
        constexpr GUID factoryClass { 0x114863bf, 0xc386, 0x4aee, { 0xb3, 0x9d, 0x8f, 0x0b, 0xbb, 0x06, 0x29, 0x55 } };
        check(D3D12GetInterface(factoryClass, IID_PPV_ARGS(&factory)));
        check(factory->SetFlags(D3D12_DEVICE_FACTORY_FLAG_DISALLOW_STORING_NEW_DEVICE_AS_SINGLETON));
        ComPtr<ID3D12Device> foreignDevice;
        check(factory->CreateDevice(gpu.adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&foreignDevice)));
        ComPtr<IUnknown> firstIdentity, foreignIdentity;
        check(gpu.device.As(&firstIdentity)); check(foreignDevice.As(&foreignIdentity));
        require(firstIdentity.Get() != foreignIdentity.Get(), "T21_TWO_ACTUAL_WARP_DEVICES");
        if (test != "device-origin-copy")
        {
            ComPtr<ID3D12CommandQueue> foreignQueue;
            D3D12_COMMAND_QUEUE_DESC description {};
            check(foreignDevice->CreateCommandQueue(&description, IID_PPV_ARGS(&foreignQueue)));
            gpu.lifetime.Record(gpu.cmd.Get());
            auto completion = gpu.lifetime.SubscribeCapture(gpu.cmd.Get());
            ID3D12CommandList* lists[] { gpu.cmd.Get() };
            auto submitted = gpu.lifetime.PrepareCapture(foreignQueue.Get(), 1, lists);
            require(completion && completion->count == 1 && completion->points[0]->failed &&
                    !completion->points[0]->fence, "T21_QUEUE_DEVICE_ORIGIN_REFUSAL");
            check(gpu.cmd->Close()); gpu.Reset();
            if (test == "device-origin-removed")
            {
                ComPtr<ID3D12Device5> removal;
                check(foreignDevice.As(&removal)); removal->RemoveDevice();
                require(FAILED(foreignDevice->GetDeviceRemovedReason()) &&
                        SUCCEEDED(gpu.device->GetDeviceRemovedReason()), "T21_FOREIGN_ONLY_DEVICE_REMOVAL");
                completion->points[0]->resolved = true;
                std::printf("T21_ORIGIN_REMOVAL injected foreign WARP removal; controlled resolved transition; Execute=0\n");
            }
            require(completion->Readiness() == DlssNr::CaptureCompletion::Result::Pending,
                    "T21_FOREIGN_QUEUE_NEVER_READY");
            submitted = {}; completion.reset();
        }
        else
        {
            DlssNr::PipelineCaptureFrame frame;
            frame.budget = std::make_shared<DlssNr::CaptureBudget>();
            frame.Copy(gpu.cmd.Get(), foreignDevice.Get(), "foreign-device", gpu.texture.Get(),
                       D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            require(frame.imageCount == 1 && !frame.images[0].readback && !frame.allocation &&
                    frame.images[0].unavailable == "device_origin_unestablished",
                    "T21_COPY_DEVICE_ORIGIN_REFUSAL");
            frame.Copy(gpu.cmd.Get(), gpu.device.Get(), "unknown-state", gpu.texture.Get(),
                       D3D12_RESOURCE_STATE_UNORDERED_ACCESS, false);
            require(!frame.images[1].readback && !frame.allocation &&
                    frame.images[1].unavailable == "state_queue_or_ownership_unestablished",
                    "T21_UNKNOWN_STATE_NO_GPU_COPY");
        }
        check(gpu.cmd->Close());
        require(gpu.lifetime.Idle(), "T21_ORIGIN_RECORDING_CLOSURE");
        std::printf("PASS %s two actual WARP devices; invalid ExecuteCommandLists calls=0\n", test.c_str());
        return 0;
    }
    if (test == "session-cap")
    {
        require(root.is_absolute() && root == root.lexically_normal(), "T21_SESSION_CAP_ABSOLUTE_OWNED_ROOT");
        for (auto parent = root.parent_path(); !parent.empty();)
        {
            const auto attributes = GetFileAttributesW(parent.c_str());
            require(attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
                    !(attributes & FILE_ATTRIBUTE_REPARSE_POINT), "T21_SESSION_CAP_NORMAL_ROOT_PARENT");
            const auto next = parent.parent_path();
            if (next == parent) break;
            parent = next;
        }
        require(std::filesystem::create_directory(root), "T21_SESSION_CAP_FRESH_CASE_ROOT");
    }
#ifdef T16_R63_CAPS_HANDOFF
    auto r54Gate = (test == "caps" || test == "ring") ? std::make_shared<DlssNr::R54Gate>() : nullptr;
    if (r54Gate) require(r54Gate->startRelease && r54Gate->entered && r54Gate->release &&
                         r54Gate->resetDone && r54Gate->resume, "R54_EVENT_CREATION");
    auto session = DlssNr::PipelineCaptureSession::Begin(root, r54Gate);
    // Installed immediately after Begin; construction only copies owned handles/references.
    struct R54SessionScope
    {
        const std::shared_ptr<DlssNr::PipelineCaptureSession>& session;
        std::shared_ptr<DlssNr::R54Gate> gate;
        DlssNr::GpuLifetime& lifetime;
        ID3D12GraphicsCommandList* commands;
        bool joined = false;
#ifdef T16_R63_CAPS_HANDOFF
        std::array<std::shared_ptr<DlssNr::R54Gate>, 64> gates {};
        bool testCaps = false;
#endif
        ~R54SessionScope()
        {
            if (!gate) return;
            if (!session || joined) return;
            BOOL released = SetEvent(gate->release);
#ifdef T16_R63_CAPS_HANDOFF
            // Release every cause and RESUME gate before Stop/ResetRecording/Cancel.
            for (const auto& owned : gates) if (owned)
            {
                if (!SetEvent(owned->release)) released = FALSE;
                if (!SetEvent(owned->startRelease)) released = FALSE;
                if (!SetEvent(owned->resume)) released = FALSE;
            }
#endif
            const BOOL started = SetEvent(gate->startRelease);
            session->Stop();
            bool cleanupOk = true;
            // Caps never submits GPU work. Close any partial bootstrap recording.
            try { lifetime.ResetRecording(commands); }
            catch (...) { cleanupOk = false; std::fprintf(stderr, "R54_EXCEPTION_RECORDING_CLEANUP_FAILURE\n"); }
            try { session->Cancel(); }
            catch (...) { cleanupOk = false; std::fprintf(stderr, "R54_EXCEPTION_CANCEL_FAILURE\n"); }
            const DWORD wait = WaitForSingleObject(session->Exited(), 10000);
            DWORD result = STILL_ACTIVE;
            const BOOL known = wait == WAIT_OBJECT_0 && GetExitCodeThread(session->Exited(), &result);
            std::fprintf(stderr, "R54_EXCEPTION_JOIN started=%u released=%u wait=%lu workerExitKnown=%u workerExit=%lu\n",
                unsigned(started), unsigned(released), wait, unsigned(known), result);
            if (!cleanupOk || !started || !released || wait != WAIT_OBJECT_0 || !known || result != 0)
                std::fprintf(stderr, "R54_EXCEPTION_CLOSURE_FAILURE\n");
#ifdef T16_R63_CAPS_HANDOFF
            if (testCaps && known && result == 0)
                for (unsigned i = 0; i < gates.size(); ++i)
                    if (gates[i] && gates[i]->slotReset)
                        std::fprintf(stderr, "R63_EXCEPTION_GATE index=%u startWait=%lu releaseWait=%lu "
                                     "resumeWait=%lu slotReset=%u unlocked=%u\n", i, gate->startWait,
                            gates[i]->releaseWait, gates[i]->resumeWait, gates[i]->slotReset, gates[i]->unlocked);
            if (testCaps)
                std::fprintf(stderr, "R63_EXCEPTION_CLOSURE clean=%u\n",
                    unsigned(cleanupOk && started && released && wait == WAIT_OBJECT_0 && known && result == 0 &&
                    !session->TimedOut() && !DlssNr::PipelineCaptureSession::Busy() && lifetime.Idle()));
#endif
            // The original exception still reaches main's FAIL/exit1. Worker State/frame ownership
            // keeps gate handles live through every worker access even when this join fails.
        }
    } r54Scope { session, r54Gate, gpu.lifetime, gpu.cmd.Get() };
#ifdef T16_R63_CAPS_HANDOFF
    if (test == "caps")
    {
        r54Scope.testCaps = true;
        r54Scope.gates[0] = r54Gate;
        require(r54Gate->resume, "R63_RESUME_EVENT_CREATION");
        r54Gate->handoff = true;
    }
#endif
#else
    auto session = DlssNr::PipelineCaptureSession::Begin(root);
#endif
    require(bool(session), "T21_WORKER_START");
    require(!DlssNr::PipelineCaptureSession::Begin(root / "second"), "T21_AGGREGATE_SESSION");
    if (test == "pixels" || test == "replay" || test == "off-on")
    {
        std::atomic_uint maps { 0 };
        if (test == "off-on")
        {
            std::filesystem::create_directories(root);
            DlssNr::ReadbackImage baseline;
            require(baseline.AllocateRoi(gpu.device.Get(), gpu.texture->GetDesc(), DlssNr::CaptureBudget::ReadbackCap),
                    "T21_OFF_BASELINE_ALLOCATION");
            gpu.Clear(.75f); baseline.Copy(gpu.cmd.Get(), gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            check(gpu.cmd->Close()); gpu.Submit(); gpu.Done(); gpu.Reset();
            require(baseline.Write(root / "off.raw"), "T21_OFF_BASELINE_READBACK");
        }
        auto frame = session->Admit(Identity(1), gpu.lifetime, gpu.cmd.Get());
        require(bool(frame), "T21_FRAME_ADMITTED");
        gpu.Clear(.25f);
        frame->Copy(gpu.cmd.Get(), gpu.device.Get(), "nr_input", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        gpu.Clear(.75f);
        frame->Copy(gpu.cmd.Get(), gpu.device.Get(), "nr_output", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        CountMaps(*frame, maps);
        frame->Unavailable("provider_generated_output", gpu.texture.Get());
        frame->Seal();
        require(frame->images[0].roi.right == 256 && frame->images[0].roi.bottom == 256, "T21_ROI_CAP");
        require(!frame->Write(), "T21_CALLBACK_MAP_WRITE_FORBIDDEN");
        check(gpu.cmd->Close());
        ComPtr<ID3D12Fence> gate; check(gpu.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
        check(gpu.queue->Wait(gate.Get(), 1));
        gpu.Submit();
        require(frame->completion->count == 1 && !session->Writes() && !std::filesystem::exists(root / "frame-0"),
                "T21_UNREADY_NO_IO");
        require(frame->completion->Readiness() == DlssNr::CaptureCompletion::Result::Pending, "T21_RECORDING_OPEN");
        check(gate->Signal(1));
        gpu.Done();
        require(!session->Writes(), "T21_REPLAYABLE_NO_MAP");
        if (test == "replay")
        {
            check(gpu.second->Wait(gate.Get(), 2));
            gpu.Submit(gpu.second.Get());
            require(frame->completion->count == 2, "T21_EVERY_REPLAY_QUEUE");
            gpu.lifetime.ResetRecording(gpu.cmd.Get());
            require(frame->completion->Readiness() == DlssNr::CaptureCompletion::Result::Pending,
                    "T21_SECOND_QUEUE_UNREADY");
            check(gate->Signal(2));
            gpu.Done(gpu.second.Get());
        }
        gpu.Reset();
        Finish(session);
        require(session->Writes() == 1, "T21_SINGLE_CAPTURE");
        require(maps == 2 && session->QuarantinedBy() == DlssNr::PipelineCaptureSession::QuarantineCause::None,
                "T21_ACTUAL_MAP_POSITIVE_CONTROL");
        std::printf("T21_MAP_CONTROL case=%s actualMapCalls=%u writes=%u inFlight=%llu\n",
                    test.c_str(), maps.load(), session->Writes(), session->Budget()->inFlight);
        require(frame->writeThread != GetCurrentThreadId(), "T21_OWNED_WORKER");
        Pixels(root / "frame-0/nr_input.raw", .25f);
        Pixels(root / "frame-0/nr_output.raw", .75f);
        if (test == "off-on")
        {
            DlssNr::ReadbackImage after;
            require(after.AllocateRoi(gpu.device.Get(), gpu.texture->GetDesc(), DlssNr::CaptureBudget::ReadbackCap),
                    "T21_ON_OUTPUT_ALLOCATION");
            after.Copy(gpu.cmd.Get(), gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            check(gpu.cmd->Close()); gpu.Submit(); gpu.Done(); gpu.Reset();
            require(after.Write(root / "on.raw"), "T21_ON_OUTPUT_READBACK");
            std::ifstream off(root / "off.raw", std::ios::binary), on(root / "on.raw", std::ios::binary);
            std::string before((std::istreambuf_iterator<char>(off)), {}), result((std::istreambuf_iterator<char>(on)), {});
            require(before == result && before.size() == 256 * 256 * 16, "T21_OFF_ON_EXACT_OUTPUT_PIXELS");
            Pixels(root / "on.raw", .75f);
        }
        std::ifstream manifest(root / "frame-0/capture.json"); std::string text((std::istreambuf_iterator<char>(manifest)), {});
        require(text.find("\"imageAvailable\":false") != std::string::npos &&
                !std::filesystem::exists(root / "frame-0/provider_generated_output.raw"), "T21_UNKNOWN_NO_GPU_COPY");
    }
    else if (test == "promised-reset")
    {
        auto frame = session->Admit(Identity(1), gpu.lifetime, gpu.cmd.Get());
        require(bool(frame), "T21_PROMISED_RESET_ADMIT");
        gpu.Clear(.5f);
        frame->Copy(gpu.cmd.Get(), gpu.device.Get(), "image", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        frame->Seal(); check(gpu.cmd->Close());
        ID3D12CommandList* lists[] { gpu.cmd.Get() };
        auto pending = gpu.lifetime.PrepareCapture(gpu.queue.Get(), 1, lists);
        require(bool(pending) && frame->completion->count == 1, "T21_PROMISED_POINT_CREATED");
        gpu.Reset();
        require(frame->completion->Readiness() == DlssNr::CaptureCompletion::Result::Pending,
                "T21_PROMISED_RESET_RETAINED");
        pending(); pending();
        gpu.Done();
        Finish(session);
        require(session->Writes() == 0 && session->Discarded() == 1 && !std::filesystem::exists(root / "frame-0"),
                "T21_PROMISED_RESET_NEVER_CAPTURED");
    }
    else if (test == "multi-list")
    {
        ComPtr<ID3D12CommandAllocator> allocator;
        ComPtr<ID3D12GraphicsCommandList> commands;
        check(gpu.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
        check(gpu.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
                                          IID_PPV_ARGS(&commands)));
        auto first = session->Admit(Identity(1), gpu.lifetime, gpu.cmd.Get());
        auto second = session->Admit(Identity(2), gpu.lifetime, commands.Get());
        require(first && second, "T21_MULTILIST_ADMITTED");
        gpu.Clear(.5f);
        first->Copy(gpu.cmd.Get(), gpu.device.Get(), "image", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        second->Copy(commands.Get(), gpu.device.Get(), "image", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        first->Seal(); second->Seal(); check(gpu.cmd->Close()); check(commands->Close());
        ID3D12CommandList* lists[] { gpu.cmd.Get(), commands.Get() };
        auto pending = gpu.lifetime.PrepareCapture(gpu.queue.Get(), 2, lists);
        require(first->completion->count == 1 && second->completion->count == 1, "T21_MULTILIST_PREARM");
        gpu.queue->ExecuteCommandLists(2, lists);
        pending(); pending(); gpu.lifetime.Submitted(gpu.queue.Get(), 2, lists); gpu.Done();
        require(first->completion->points[0]->resolved && second->completion->points[0]->resolved,
                "T21_MULTILIST_CLOSURE_ONCE");
        gpu.Reset(); check(allocator->Reset()); check(commands->Reset(allocator.Get(), nullptr));
        gpu.lifetime.ResetRecording(commands.Get());
        Finish(session);
        require(session->Writes() == 2, "T21_MULTILIST_WORKER_IMAGES");
        Pixels(root / "frame-0/image.raw", .5f); Pixels(root / "frame-1/image.raw", .5f);
        first.reset(); second.reset(); check(commands->Close()); commands.Reset(); allocator.Reset();
    }
    else if (test == "discard" || test == "cancel" || test == "ring")
    {
        std::vector<std::shared_ptr<DlssNr::PipelineCaptureFrame>> frames;
        const unsigned count = test == "ring" ? 4 : 1;
        for (unsigned i = 0; i < count; ++i)
        {
            auto frame = session->Admit(Identity(i), gpu.lifetime, gpu.cmd.Get());
            require(bool(frame), "T21_RING_ADMISSION");
            gpu.Clear(.5f);
            frame->Copy(gpu.cmd.Get(), gpu.device.Get(), "image", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            frame->Seal(); frames.push_back(frame);
        }
        if (test == "ring")
        {
            require(!session->Admit(Identity(5), gpu.lifetime, gpu.cmd.Get()) && session->Budget()->ringDrops == 1,
                    "T21_RING_FULL_DROP");
            require(!session->Admit(Identity(0), gpu.lifetime, gpu.cmd.Get()), "T21_UNIQUE_APPLICATION");
        }
        if (test == "cancel") session->Cancel();
        check(gpu.cmd->Close());
        if (test == "cancel") { gpu.Submit(); gpu.Done(); }
        gpu.Reset();
#ifdef T16_R63_CAPS_HANDOFF
        // Ring admission tests capacity, not contention with the worker's slot snapshot.
        // The preinstalled bootstrap event holds the worker outside both mutexes.
        if (test == "ring") require(SetEvent(r54Gate->startRelease), "T21_RING_WORKER_RELEASE");
#endif
        Finish(session);
        require(session->Writes() == 0 && session->Discarded() == count && !std::filesystem::exists(root / "frame-0"),
                "T21_DISCARD_CANCEL_NO_IMAGE");
#ifdef T16_R63_CAPS_HANDOFF
        if (test == "ring")
        {
            DWORD workerExit = STILL_ACTIVE;
            require(GetExitCodeThread(session->Exited(), &workerExit) && workerExit == 0 &&
                    r54Gate->startWait == WAIT_OBJECT_0 && !DlssNr::PipelineCaptureSession::Busy(),
                    "T21_RING_WORKER_CLOSURE");
            r54Scope.joined = true;
        }
#endif
    }
    else if (test == "signal-failure" || test == "replay-overflow")
    {
        const unsigned count = test == "signal-failure" ? 4 : 1;
        std::vector<std::shared_ptr<DlssNr::PipelineCaptureFrame>> frames;
        for (unsigned i = 0; i < count; ++i)
        {
            auto frame = session->Admit(Identity(i), gpu.lifetime, gpu.cmd.Get());
            require(bool(frame), "T21_FAILED_WORK_ADMITTED"); gpu.Clear(.5f);
            const unsigned images = test == "signal-failure" ? 8 : 1;
            for (unsigned image = 0; image < images; ++image)
            {
                const auto name = "image-" + std::to_string(image);
                frame->Copy(gpu.cmd.Get(), gpu.device.Get(), name.c_str(), gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            }
            frame->Seal(); frames.push_back(frame);
        }
        check(gpu.cmd->Close());
        ComPtr<FailedSignalQueue> proxy;
        if (test == "signal-failure")
        {
            proxy.Attach(new FailedSignalQueue(gpu.queue.Get())); gpu.Submit(proxy.Get()); gpu.Done();
            require(proxy->signals == 5, "T21_REAL_EXECUTE_TYPED_SIGNAL_FAILURE");
            for (const auto& frame : frames)
                require(frame->completion->count == 1 && frame->completion->points[0]->failed &&
                        frame->completion->points[0]->resolved, "T21_FAILED_SIGNAL_POINT_RETAINED");
        }
        else
        {
            for (unsigned replay = 0; replay < 9; ++replay) gpu.Submit();
            gpu.Done();
            require(frames[0]->completion->count == 8 && frames[0]->completion->failed,
                    "T21_NINTH_REAL_EXECUTE_REJECTED_RETAINED");
        }
        gpu.Reset(); session->Cancel();
        require(WaitForSingleObject(session->Exited(), 35000) == WAIT_OBJECT_0 && session->TimedOut(),
                "T21_UNRESOLVED_OWNERSHIP_BOUNDED_QUARANTINE");
        require(session->Writes() == 0 && !std::filesystem::exists(root / "frame-0") &&
                session->Budget()->inFlight == session->Budget()->peak && session->Budget()->inFlight > 0,
                "T21_FAILED_TICKETS_NEVER_MAP_OR_RELEASE");
        require(!DlssNr::PipelineCaptureSession::Begin(root / "second"), "T21_QUARANTINED_AGGREGATE_SESSION_REFUSAL");
        if (test == "signal-failure") require(session->Budget()->inFlight == DlssNr::CaptureBudget::ReadbackCap,
                                             "T21_QUARANTINED_32MIB_RETAINED_BUDGET");
        std::printf("PASS %s retainedReadbacks=%llu workerExited=1 captured=0 secondSession=refused; generic retention remains; fixture process exit reclaims test ownership\n",
                    test.c_str(), session->Budget()->inFlight);
        return 0;
    }
    else if (test == "device-removal")
    {
        std::atomic_uint maps { 0 };
        auto frame = session->Admit(Identity(1), gpu.lifetime, gpu.cmd.Get());
        require(bool(frame), "T21_REMOVAL_FRAME_ADMITTED"); gpu.Clear(.5f);
        frame->Copy(gpu.cmd.Get(), gpu.device.Get(), "image", gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        auto* const nativeReadback = frame->images[0].readback.Get();
        CountMaps(*frame, maps);
        auto* const readback = frame->images[0].readback.Get();
        auto* const source = frame->images[0].source.Get();
        auto* const completion = frame->completion.get();
        const auto allocation = frame->allocation;
        auto budget = session->Budget();
        const auto reservation = budget->retained;
        std::weak_ptr<DlssNr::PipelineCaptureFrame> retainedFrame = frame;
        std::weak_ptr<DlssNr::CaptureBudget> retainedBudget = budget;
        frame->Seal(); check(gpu.cmd->Close());
        ComPtr<ID3D12Fence> gate; check(gpu.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
        check(gpu.queue->Wait(gate.Get(), 1)); gpu.Submit();
        require(frame->completion->count == 1 && frame->completion->points[0]->resolved &&
                !frame->completion->points[0]->failed &&
                frame->completion->points[0]->fence->GetCompletedValue() == 0,
                "T21_REAL_PENDING_CAPTURE_COPY_BEFORE_REMOVAL");
        HANDLE removalEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        require(removalEvent != nullptr, "T21_REMOVAL_EVENT_CREATED");
        check(frame->completion->points[0]->fence->SetEventOnCompletion(1, removalEvent));
        ComPtr<ID3D12Device5> removal; check(gpu.device.As(&removal)); removal->RemoveDevice();
        const auto removalWait = WaitForSingleObject(removalEvent, 10000);
        CloseHandle(removalEvent);
        require(removalWait == WAIT_OBJECT_0 &&
                frame->completion->points[0]->fence->GetCompletedValue() == UINT64_MAX,
                "T21_GENUINE_REMOVAL_MAX_EVENT");
        require(FAILED(gpu.device->GetDeviceRemovedReason()), "T21_NATIVE_INJECTED_DEVICE_REMOVED");
        const auto removalVector = [&](const char* phase)
        {
            const bool nativeIdle = gpu.lifetime.Idle();
            auto& capture = *frame->completion;
            std::lock_guard lock(capture.mutex);
            const auto& point = capture.points[0];
            ComPtr<ID3D12Device> queueDevice;
            const auto queueDeviceResult = point->queue->GetDevice(IID_PPV_ARGS(&queueDevice));
            const auto queueRemoved = queueDevice ? queueDevice->GetDeviceRemovedReason() : E_FAIL;
            std::printf("T21_REMOVAL_VECTOR phase=%s closed=%u count=%u globalFailed=%u discarded=%u resolved=%u pointFailed=%u fence=%llu deviceRemoved=%08lx queueDeviceResult=%08lx nativeLifetimeIdle=%u\n",
                phase, unsigned(capture.closed), capture.count, unsigned(capture.failed), unsigned(capture.discarded),
                unsigned(point->resolved), unsigned(point->failed), point->fence->GetCompletedValue(),
                static_cast<unsigned long>(queueRemoved), static_cast<unsigned long>(queueDeviceResult), unsigned(nativeIdle));
        };
        removalVector("before-FinishSubmitted");
        gpu.lifetime.FinishSubmitted();
        removalVector("after-FinishSubmitted");
        gpu.cmd.Reset();
        removalVector("after-owned-command-release");
        require(frame->completion->closed, "T21_ACTUAL_RECORDING_RELEASE_CLOSED");
        session->Stop();
        require(WaitForSingleObject(session->Exited(), 10000) == WAIT_OBJECT_0, "T21_REMOVAL_WORKER_EXIT");
        require(!session->TimedOut() &&
                session->QuarantinedBy() == DlssNr::PipelineCaptureSession::QuarantineCause::DeviceRemovedUnprovenRetirement,
                "T21_TYPED_REMOVAL_QUARANTINE_NOT_TIMEOUT");
        require(!session->Admit(Identity(2), gpu.lifetime, nullptr) &&
                !DlssNr::PipelineCaptureSession::Begin(root / "second"),
                "T21_REMOVAL_ADMISSION_AND_SESSION_REFUSED");
        require(session->Writes() == 0 && !std::filesystem::exists(root / "frame-0") &&
                frame->completion->Readiness() == DlssNr::CaptureCompletion::Result::DeviceRemoved,
                "T21_REMOVED_DEVICE_NOT_CAPTURE_COMPLETION");
        require(maps == 0 && !frame->writeThread && !frame->written &&
                WaitForSingleObject(frame->retired, 0) == WAIT_TIMEOUT &&
                frame->allocation == allocation && budget->inFlight == allocation &&
                budget->retained == reservation && allocation > 0 &&
                allocation <= DlssNr::CaptureBudget::ReadbackCap &&
                reservation <= DlssNr::CaptureBudget::SessionCap,
                "T21_REMOVAL_NO_MAP_WRITE_RETIRE_OR_BUDGET_SUBTRACTION");
        frame.reset(); budget.reset(); session.reset();
        auto held = retainedFrame.lock();
        auto charged = retainedBudget.lock();
        require(held && charged && held->images[0].readback.Get() == readback &&
                static_cast<MapCounterResource*>(held->images[0].readback.Get())->real.Get() == nativeReadback &&
                held->images[0].source.Get() == source && held->completion.get() == completion &&
                held->allocation == allocation && charged->inFlight == allocation &&
                charged->retained == reservation && maps == 0 && DlssNr::PipelineCaptureSession::Busy() &&
                !DlssNr::PipelineCaptureSession::Begin(root / "after-destruction"),
                "T21_ORIGINAL_OWNERS_CHARGED_AFTER_CALLER_AND_SESSION_DROP");
        std::printf("T21_REMOVAL_STATUS {\"cause\":\"device_removed_unproven_retirement\",\"timedOut\":false,"
                    "\"workerExited\":true,\"actualMapCalls\":%u,\"writes\":0,\"inFlight\":%llu,"
                    "\"retained\":%llu,\"originalOwnersRetained\":true,\"gpuQuiescenceProven\":false}\n",
                    maps.load(), charged->inFlight, charged->retained);
        held.reset(); charged.reset();
        std::puts("PASS device-removal real pending WARP copy; original owners quarantined until process exit; worker exit is not GPU retirement");
        return 0;
    }
    else if (test == "readback-cap")
    {
        UINT64 actual = 0;
        std::vector<std::shared_ptr<DlssNr::PipelineCaptureFrame>> frames;
        for (unsigned i = 0; i < 4; ++i)
        {
            auto frame = session->Admit(Identity(i), gpu.lifetime, gpu.cmd.Get());
            require(bool(frame), "T21_ALIGNED_RING_ADMIT");
            gpu.Clear(.5f);
            for (unsigned image = 0; image < 8; ++image)
            {
                const auto name = "image-" + std::to_string(image);
                frame->Copy(gpu.cmd.Get(), gpu.device.Get(), name.c_str(), gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                require(bool(frame->images[image].readback), "T21_ALIGNED_READBACK_ALLOCATED");
                const auto description = frame->images[image].readback->GetDesc();
                const auto info = gpu.device->GetResourceAllocationInfo(0, 1, &description);
                require(info.SizeInBytes == frame->images[image].allocationBytes, "T21_NATIVE_ALLOCATION_ACCOUNTING");
                actual += info.SizeInBytes;
            }
            frame->Seal(); frames.push_back(frame);
        }
        require(actual == DlssNr::CaptureBudget::ReadbackCap && session->Budget()->inFlight == actual &&
                session->Budget()->peak == actual, "T21_32MIB_EXACT_ALIGNED_AGGREGATE");
        DlssNr::ReadbackImage rejected;
        require(!rejected.AllocateRoi(gpu.device.Get(), gpu.texture->GetDesc(),
                DlssNr::CaptureBudget::ReadbackCap - actual) && !rejected.readback, "T21_ALIGNED_BUDGET_REFUSAL");
        session->Cancel(); check(gpu.cmd->Close()); gpu.Submit(); gpu.Done(); gpu.Reset();
        Finish(session);
        require(session->Writes() == 0 && session->Discarded() == 4 && session->Budget()->inFlight == 0,
                "T21_ALIGNED_CANCEL_RELEASE");
        frames.clear();
    }
    else if (test == "session-cap")
    {
        // Sampled synthetic fixture evidence, not a complete analysis-input dataset.
        // Keep complete first/latest nonempty payloads and all original JSON. Never refund the budget.
        struct RawFile
        {
            std::filesystem::path path;
            UINT64 bytes;
            DlssNr::CaptureIdentity capture;
            BY_HANDLE_FILE_INFORMATION identity {};
        };
        std::vector<RawFile> firstPayload, latestPayload;
        UINT64 prunedBytes = 0, peakLiveBytes = 0;
        constexpr UINT64 liveBound = 3 * 8 * 1024ull * 1024 + 65 * DlssNr::CaptureBudget::MetadataReservation;
        const auto actualFiles = [&]
        {
            UINT64 bytes = 0;
            const auto rootAttributes = GetFileAttributesW(root.c_str());
            require(rootAttributes != INVALID_FILE_ATTRIBUTES && (rootAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
                    !(rootAttributes & FILE_ATTRIBUTE_REPARSE_POINT), "T21_SESSION_CAP_NORMAL_WORKING_ROOT");
            for (const auto& file : std::filesystem::recursive_directory_iterator(root))
            {
                const auto attributes = GetFileAttributesW(file.path().c_str());
                require(attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_REPARSE_POINT),
                        "T21_SESSION_CAP_NORMAL_WORKING_FILES");
                if (file.is_regular_file()) bytes += file.file_size();
            }
            peakLiveBytes = (std::max)(peakLiveBytes, bytes);
            require(bytes <= liveBound && liveBound < DlssNr::CaptureBudget::ReadbackCap,
                    "T21_SESSION_CAP_LIVE_FIXTURE_BOUND");
            return bytes;
        };
        const auto validateRaw = [&](RawFile& raw, const char* disposition, bool prune)
        {
            require(raw.path.parent_path().parent_path() == root && raw.path.extension() == ".raw",
                    "T21_SESSION_CAP_EXACT_OWNED_RAW_PATH");
            for (auto parent = raw.path.parent_path(); !parent.empty();)
            {
                const auto attributes = GetFileAttributesW(parent.c_str());
                require(attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
                        !(attributes & FILE_ATTRIBUTE_REPARSE_POINT), "T21_SESSION_CAP_NORMAL_RAW_PARENT");
                const auto next = parent.parent_path();
                if (next == parent) break;
                parent = next;
            }
            const auto handle = CreateFileW(raw.path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                                           OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            require(handle != INVALID_HANDLE_VALUE, "T21_SESSION_CAP_OWNED_RAW_OPEN");
            std::unique_ptr<void, decltype(&CloseHandle)> owned(handle, CloseHandle);
            BY_HANDLE_FILE_INFORMATION identity {};
            require(GetFileInformationByHandle(handle, &identity) &&
                    !(identity.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
                    identity.nNumberOfLinks == 1 &&
                    ((UINT64(identity.nFileSizeHigh) << 32) | identity.nFileSizeLow) == raw.bytes,
                    "T21_SESSION_CAP_EXACT_NORMAL_RAW_BYTES");
            if (prune)
                require(identity.dwVolumeSerialNumber == raw.identity.dwVolumeSerialNumber &&
                        identity.nFileIndexHigh == raw.identity.nFileIndexHigh &&
                        identity.nFileIndexLow == raw.identity.nFileIndexLow &&
                        CompareFileTime(&identity.ftCreationTime, &raw.identity.ftCreationTime) == 0 &&
                        CompareFileTime(&identity.ftLastWriteTime, &raw.identity.ftLastWriteTime) == 0,
                        "T21_SESSION_CAP_SAME_VALIDATED_RAW_IDENTITY");
            Pixels(raw.path, .5f);
            raw.identity = identity;
            std::printf("T21_SESSION_CAP_FILE file=%s bytes=%llu owner=%llu consumer=%llu generation=%llu "
                        "application=%llu volume=%lu index=%lu:%lu validation=exact-length-and-pixels "
                        "disposition=%s\n", raw.path.lexically_relative(root).generic_string().c_str(), raw.bytes,
                        raw.capture.owner, raw.capture.consumer, raw.capture.generation, raw.capture.application,
                        identity.dwVolumeSerialNumber, identity.nFileIndexHigh, identity.nFileIndexLow, disposition);
            if (prune)
            {
                // Pixels opens its own read stream. Acquire DELETE only after that stream and the read lock close.
                owned.reset();
                const auto deleteHandle = CreateFileW(raw.path.c_str(), DELETE | FILE_READ_ATTRIBUTES, 0, nullptr,
                                                     OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
                require(deleteHandle != INVALID_HANDLE_VALUE, "T21_SESSION_CAP_EXACT_RAW_DELETE_OPEN");
                std::unique_ptr<void, decltype(&CloseHandle)> deletion(deleteHandle, CloseHandle);
                BY_HANDLE_FILE_INFORMATION current {};
                require(GetFileInformationByHandle(deleteHandle, &current) &&
                        !(current.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
                        current.nNumberOfLinks == 1 && current.dwVolumeSerialNumber == identity.dwVolumeSerialNumber &&
                        current.nFileIndexHigh == identity.nFileIndexHigh && current.nFileIndexLow == identity.nFileIndexLow &&
                        current.nFileSizeHigh == identity.nFileSizeHigh && current.nFileSizeLow == identity.nFileSizeLow &&
                        CompareFileTime(&current.ftCreationTime, &identity.ftCreationTime) == 0 &&
                        CompareFileTime(&current.ftLastWriteTime, &identity.ftLastWriteTime) == 0,
                        "T21_SESSION_CAP_DELETE_SAME_VALIDATED_RAW");
                std::fflush(stdout);
                FILE_DISPOSITION_INFO removal { TRUE };
                require(SetFileInformationByHandle(deleteHandle, FileDispositionInfo, &removal, sizeof(removal)),
                        "T21_SESSION_CAP_REMOVE_EXACT_VALIDATED_RAW");
                prunedBytes += raw.bytes;
            }
        };
        std::puts("T21_SESSION_CAP_RETENTION sampled-synthetic-fixture; first-complete/latest-nonempty-complete; "
                  "all-original-JSON; not-complete-analysis-input-dataset; retained-budget-no-refund");
        unsigned admitted = 0;
        bool rejected = false;
        for (unsigned i = 0; i < 64; ++i)
        {
            auto frame = session->Admit(Identity(i), gpu.lifetime, gpu.cmd.Get());
            if (!frame) { rejected = true; break; }
            require(frame->directory == root / ("frame-" + std::to_string(frame->number)) &&
                    !std::filesystem::exists(frame->directory), "T21_SESSION_CAP_FRESH_FRAME_FILES");
            std::vector<RawFile> payload;
            ++admitted; gpu.Clear(.5f);
            for (unsigned image = 0; image < 8; ++image)
            {
                const auto name = "image-" + std::to_string(image);
                frame->Copy(gpu.cmd.Get(), gpu.device.Get(), name.c_str(), gpu.texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
                if (frame->images[image].readback)
                {
                    require(frame->images[image].bytes == 256 * 256 * 16, "T21_SESSION_CAP_SYNTHETIC_ROI_BYTES");
                    payload.push_back({ frame->directory / (name + ".raw"), frame->images[image].bytes, frame->identity });
                }
            }
            frame->Seal(); check(gpu.cmd->Close()); gpu.Submit(); gpu.Done(); gpu.Reset();
            require(WaitForSingleObject(frame->retired, 10000) == WAIT_OBJECT_0, "T21_SESSION_CAP_WORKER_EVENT");
            require(frame->written && !frame->canceled && !session->TimedOut() &&
                    session->QuarantinedBy() == DlssNr::PipelineCaptureSession::QuarantineCause::None,
                    "T21_SESSION_CAP_NORMAL_COMPLETE_WRITE");
            require(session->Budget()->inFlight == 0 && session->Budget()->retained <= DlssNr::CaptureBudget::SessionCap,
                    "T21_SESSION_CAP_RUNNING_ACCOUNTING");
            for (auto& raw : payload)
                validateRaw(raw, firstPayload.empty() ? "first-complete-payload" : "latest-nonempty-complete-payload", false);
            frame.reset(); // Retention bookkeeping contains only filenames, counters and value identities.
            actualFiles(); // Includes first, previous latest and newly written files before any pruning.
            if (!payload.empty())
            {
                if (firstPayload.empty()) firstPayload = std::move(payload);
                else
                {
                    for (auto& raw : latestPayload) validateRaw(raw, "validated-pruned-synthetic-working-file", true);
                    latestPayload = std::move(payload);
                }
            }
            require(actualFiles() + prunedBytes <= DlssNr::CaptureBudget::SessionCap,
                    "T21_SESSION_CAP_CUMULATIVE_PRODUCED_FILES");
        }
        require(rejected && admitted < 64 && session->Budget()->budgetDrops &&
                session->Budget()->retained == DlssNr::CaptureBudget::SessionCap,
                "T21_256MIB_RETAINED_EXACT_REFUSAL");
        Finish(session);
        const auto bytes = actualFiles();
        const auto producedFilesBytes = bytes + prunedBytes;
        require(bytes <= DlssNr::CaptureBudget::SessionCap, "T21_WHOLE_SESSION_IMAGES_METADATA_BOUNDED");
        require(session->Writes() == admitted && !firstPayload.empty() &&
                producedFilesBytes <= DlssNr::CaptureBudget::SessionCap &&
                std::filesystem::is_regular_file(root / "capture-session.json"),
                "T21_SESSION_CAP_CUMULATIVE_PRODUCED_FILES");
        for (unsigned i = 0; i < admitted; ++i)
            require(std::filesystem::is_regular_file(root / ("frame-" + std::to_string(i)) / "capture.json"),
                    "T21_SESSION_CAP_ALL_ORIGINAL_FRAME_JSON");
        std::printf("T21_SESSION_CAP admitted=%u retained=%llu actualFiles=%llu producedFilesBytes=%llu "
                    "validatedPrunedRawBytes=%llu peakLiveBytes=%llu liveBound=%llu drops=%u\n", admitted,
                    session->Budget()->retained, bytes, producedFilesBytes, prunedBytes, peakLiveBytes, liveBound,
                    session->Budget()->budgetDrops);
    }
    else if (test == "caps")
    {
        DlssNr::CaptureIdentity unknown {};
        require(!session->Admit(unknown, gpu.lifetime, gpu.cmd.Get()), "T21_UNKNOWN_APPLICATION");
        for (unsigned i = 0; i < 64; ++i)
        {
#ifdef T16_R63_CAPS_HANDOFF
            // Gate creation and ownership precede admission and Seal for every frame.
            if (i) r54Scope.gates[i] = std::make_shared<DlssNr::R54Gate>();
            auto currentGate = r54Scope.gates[i];
            require(currentGate->entered && currentGate->release && currentGate->resetDone &&
                    currentGate->resume, "R63_EVENT_CREATION");
            currentGate->handoff = true;
#endif
            auto frame = session->Admit(Identity(i), gpu.lifetime, gpu.cmd.Get());
#ifdef T16_R63_CAPS_HANDOFF
            // The previous snapshot decision is fixed; resume after one original Admit.
            if (i) require(SetEvent(r54Scope.gates[i - 1]->resume), "R63_RESUME_SIGNAL");
#endif
            if (!frame)
            {
                auto previous = session->Budget()->frames;
                require(previous == i, "T21_FRAME_COUNT");
                throw std::runtime_error("T21_FIXTURE_MUST_RETIRE_SLOT_BY_EVENT");
            }
#ifdef T16_R63_CAPS_HANDOFF
            frame->r54Gate = currentGate; // shared ownership installed before publication
#endif
            frame->Seal(); check(gpu.cmd->Close()); gpu.Reset();
#ifdef T16_R63_CAPS_HANDOFF
            if (!i) require(SetEvent(r54Gate->startRelease), "R63_START_SIGNAL");
#endif
            require(WaitForSingleObject(frame->retired, 10000) == WAIT_OBJECT_0, "T21_DISCARD_EVENT");
#ifdef T16_R63_CAPS_HANDOFF
            require(WaitForSingleObject(currentGate->entered, 10000) == WAIT_OBJECT_0,
                    "R63_CAUSE_ENTERED");
            if (!i)
                std::printf("R63_CAUSE boundary=0-to-1 previousWait=0 enteredWait=0 "
                            "resourceRelease=%u retiredSignal=%u lockOwned=%u slots=%d frames=%u "
                            "unknownIdentityDrops=%u stagedLockOwnedSamples=1\n",
                    currentGate->resourceRelease, currentGate->retiredSignal, currentGate->lockOwned,
                    currentGate->slots, currentGate->frames, currentGate->unknownDrops);
            require(SetEvent(currentGate->release), "R63_CAUSE_RELEASE_SIGNAL");
            require(WaitForSingleObject(currentGate->resetDone, 10000) == WAIT_OBJECT_0,
                    "R63_RESET_UNLOCK_READY");
            require(currentGate->slotReset == 4 && currentGate->unlocked == 5 &&
                    currentGate->releaseWait == WAIT_OBJECT_0, "R63_RESET_UNLOCK_RESULT");
            require(currentGate->snapshotExit == int(i == 63), "R66_SNAPSHOT_EXIT_DECISION");
#endif
        }
        require(!session->Admit(Identity(65), gpu.lifetime, gpu.cmd.Get()) && session->Budget()->frames == 64,
                "T21_FRAME_CAP");
#ifdef T16_R63_CAPS_HANDOFF
        require(SetEvent(r54Scope.gates[63]->resume), "R63_FINAL_RESUME_SIGNAL");
#endif
        Finish(session);
#ifdef T16_R63_CAPS_HANDOFF
        DWORD workerExit = STILL_ACTIVE;
        require(GetExitCodeThread(session->Exited(), &workerExit) && workerExit == 0 &&
                r54Gate->startWait == WAIT_OBJECT_0, "R63_WORKER_EXIT_RESULT");
        for (const auto& owned : r54Scope.gates)
            require(owned && owned->releaseWait == WAIT_OBJECT_0 && owned->resumeWait == WAIT_OBJECT_0,
                    "R63_ALL_HANDOFF_RESULTS");
        require(session->Budget()->frames == 64 && session->Writes() == 0 && session->Discarded() == 64 &&
                session->Budget()->unknownDrops == 1 && session->Budget()->ringDrops == 0 &&
                session->Budget()->budgetDrops == 0 && session->Budget()->duplicateDrops == 0 &&
                session->Budget()->retained == 4259840 && session->Budget()->peak == 0 &&
                session->Budget()->inFlight == 0 && !DlssNr::PipelineCaptureSession::Busy(),
                "R63_CAPS_COUNTS");
        r54Scope.joined = true;
        std::printf("R63_GREEN frames=64 discarded=64 writes=0 unknownIdentityDrops=1 retained=4259840 "
                    "inFlight=0 peak=0 workerExit=0 handoffs=64 capRefusal=1\n");
#endif
        require(session->Budget()->retained <= DlssNr::CaptureBudget::SessionCap &&
                session->Budget()->peak <= DlssNr::CaptureBudget::ReadbackCap, "T21_MEMORY_CAPS");
    }
    else throw std::runtime_error("T21_UNKNOWN_CASE");
    session.reset();
    check(gpu.cmd->Close());
    require(gpu.lifetime.Idle(), "T21_LIFETIME_CLOSURE");
    std::printf("PASS %s worker/fence/pixels native process=%lu\n", test.c_str(), GetCurrentProcessId());
    return 0;
}
catch (const std::exception& error) { std::fprintf(stderr, "FAIL %s\n", error.what()); return 1; }
