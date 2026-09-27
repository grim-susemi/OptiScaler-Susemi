// Production capture + lifetime tracking on WARP. No game or NVIDIA runtime.
#include <windows.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <stdexcept>
#include "../OptiScaler/dlssnr/DlssNr_PipelineCapture.h"
#include "../OptiScaler/dlssnr/DlssNr_GpuLifetime.h"
#include "../OptiScaler/dlssnr/DlssNr_Capture.h"
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("D3D12 failure"); }
static void expect(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() try
{
    ComPtr<IDXGIFactory4> factory; ComPtr<IDXGIAdapter> adapter; ComPtr<ID3D12Device> device;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&factory))); check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
    check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)));
    ComPtr<ID3D12CommandQueue> queue; D3D12_COMMAND_QUEUE_DESC q {};
    check(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)));
    ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)));
    check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&cmd)));
    ComPtr<ID3D12Resource> texture;
    D3D12_RESOURCE_DESC desc {}; desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = 16; desc.Height = 8; desc.DepthOrArraySize = desc.MipLevels = 1;
    desc.Format = DXGI_FORMAT_R32G32B32A32_FLOAT; desc.SampleDesc.Count = 1;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    D3D12_HEAP_PROPERTIES heap {}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
        D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&texture)));
    ComPtr<ID3D12DescriptorHeap> descriptors;
    D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.NumDescriptors = 1;
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    check(device->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&descriptors)));
    device->CreateUnorderedAccessView(texture.Get(), nullptr, nullptr, descriptors->GetCPUDescriptorHandleForHeapStart());
    ID3D12DescriptorHeap* heaps[] { descriptors.Get() }; cmd->SetDescriptorHeaps(1, heaps);
    auto clear = [&](float value)
    {
        const float color[] { value, value, value, 1 };
        cmd->ClearUnorderedAccessViewFloat(descriptors->GetGPUDescriptorHandleForHeapStart(),
            descriptors->GetCPUDescriptorHandleForHeapStart(), texture.Get(), color, 0, nullptr);
    };
    const auto root = std::filesystem::temp_directory_path() /
        ("nr-pipeline-test-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64()));
    DlssNr::GpuLifetime lifetime;
    auto* frame = new DlssNr::PipelineCaptureFrame;
    expect(frame->Init(device.Get()), "capture init"); frame->directory = root / "submitted";
    lifetime.Record(cmd.Get());
    clear(.25f); frame->Copy(cmd.Get(), device.Get(), "before_nr", texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    clear(.75f); frame->Copy(cmd.Get(), device.Get(), "after_nr", texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    clear(.5f); frame->Copy(cmd.Get(), device.Get(), "after_rr", texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    frame->End(cmd.Get()); check(cmd->Close());
    bool written = false;
    lifetime.Retire([&] { written = frame->Write(); delete frame; });
    ComPtr<ID3D12Fence> gate, done; check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gate)));
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&done)));
    check(queue->Wait(gate.Get(), 1));
    ID3D12CommandList* lists[] { cmd.Get() }; queue->ExecuteCommandLists(1, lists);
    lifetime.Submitted(queue.Get(), 1, lists); lifetime.Collect();
    expect(!written && !std::filesystem::exists(root), "capture wrote before GPU completion");
    check(gate->Signal(1)); check(queue->Signal(done.Get(), 1));
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(done->SetEventOnCompletion(1, event));
    expect(WaitForSingleObject(event, 10000) == WAIT_OBJECT_0, "GPU timeout"); CloseHandle(event);
    check(allocator->Reset()); check(cmd->Reset(allocator.Get(), nullptr)); lifetime.ResetRecording(cmd.Get());
    expect(written && lifetime.Idle(), "completed capture was not written/reclaimed");
    const char* names[] { "before_nr", "after_nr", "after_rr" }; const float values[] { .25f, .75f, .5f };
    for (int i = 0; i < 3; ++i)
    {
        std::ifstream file(root / "submitted" / (std::string(names[i]) + ".raw"), std::ios::binary);
        float actual = 0; file.read(reinterpret_cast<char*>(&actual), sizeof(actual));
        expect(file.good() && actual == values[i], "stage order or resource state mismatch");
    }
    auto* discarded = new DlssNr::PipelineCaptureFrame;
    expect(discarded->Init(device.Get()), "discard init"); discarded->directory = root / "discarded";
    lifetime.Record(cmd.Get()); discarded->Copy(cmd.Get(), device.Get(), "image", texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    discarded->End(cmd.Get()); check(cmd->Close());
    bool rejected = false;
    lifetime.Retire([&] { rejected = !discarded->Write(); delete discarded; });
    check(allocator->Reset()); check(cmd->Reset(allocator.Get(), nullptr)); lifetime.ResetRecording(cmd.Get());
    expect(rejected && !std::filesystem::exists(root / "discarded"), "discarded capture wrote garbage");
    capture::FrameCapture sequence;
    sequence.request(20); // Clamp to eight; later record calls must not index past the run.
    clear(.5f); // The old sparse byte heuristic incorrectly discarded this valid grey float image.
    for (unsigned i = 0; i < 12; ++i)
        sequence.record(cmd.Get(), device.Get(), texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                        texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    check(cmd->Close());
    check(queue->Wait(gate.Get(), 2));
    queue->ExecuteCommandLists(1, lists);
    sequence.Submitted(queue.Get(), 1, lists);
    const auto sequenceDir = root / "sequence";
    for (unsigned frameNumber = 0; frameNumber < 100; ++frameNumber)
        expect(sequence.write(sequenceDir).empty(), "CPU progress released an unfinished capture");
    expect(!std::filesystem::exists(sequenceDir), "unfinished sequence wrote images");
    check(gate->Signal(2)); check(queue->Signal(done.Get(), 2));
    event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(done->SetEventOnCompletion(2, event));
    expect(WaitForSingleObject(event, 10000) == WAIT_OBJECT_0, "sequence GPU timeout"); CloseHandle(event);
    expect(sequence.write(sequenceDir).empty(), "replayable capture was released");
    check(allocator->Reset()); check(cmd->Reset(allocator.Get(), nullptr));
    sequence.ResetRecording(cmd.Get());
    expect(sequence.write(sequenceDir) == sequenceDir.string() && !sequence.isActive(), "sequence did not finish");
    for (unsigned i = 0; i < 8; ++i)
        for (const char* side : { "before", "after" })
        {
            char name[32]; std::snprintf(name, sizeof(name), "%s_%02u.raw", side, i);
            std::ifstream file(sequenceDir / name, std::ios::binary);
            float actual = 0; file.read(reinterpret_cast<char*>(&actual), sizeof(actual));
            expect(file.good() && actual == .5f, "sequence pixels or filenames changed");
        }
    expect(!std::filesystem::exists(sequenceDir / "before_08.raw"), "sequence exceeded its frame limit");
    std::ifstream manifest(sequenceDir / "manifest.txt");
    std::string firstLine; std::getline(manifest, firstLine);
    expect(firstLine == "frames 8", "sequence manifest changed");

    sequence.request(1);
    sequence.record(cmd.Get(), device.Get(), texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    texture.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    check(cmd->Close());
    check(allocator->Reset()); check(cmd->Reset(allocator.Get(), nullptr));
    sequence.ResetRecording(cmd.Get());
    const auto discardedSequence = root / "discarded-sequence";
    expect(sequence.write(discardedSequence).empty() && !std::filesystem::exists(discardedSequence),
           "discarded sequence wrote uninitialized images");
    expect(sequence.isActive(), "discarded sequence did not re-arm");
    sequence.release();
    check(cmd->Close());
    std::printf("PASS: stage/sequence pixels, frame limits, GPU-gated readback, retirement, discarded recordings. %s\n", root.string().c_str());
    return 0;
}
catch (const std::exception& error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
