#include <pch.h>
#include "Runtime.h"
#include "RuntimeParameters.h"
#include "ForbiddenStartup.h"
#include <proxies/NVNGX_Proxy.h>
#include <proxies/XeSS_Proxy.h>
#include <proxies/FfxApi_Proxy.h>
#include <shaders/dlssnr/DlssNr_Dx12.h>
#include <dlssnr/DlssNr_PipelineCapture.h>
#include <dlssnr/DlssNr_Status.h>
#include <Util.h>
#include <proxies/KernelBase_Proxy.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <bit>
#include <set>
#include <dlssnr/DlssNr_MfgObserver.h>
#include <detours/detours.h>

namespace NrAddonHost
{
namespace
{
using Microsoft::WRL::ComPtr;
void Require(bool value, const char* error) { if (!value) throw std::runtime_error(error); }
void Hr(HRESULT value, const char* error)
{
    if (FAILED(value)) { std::fprintf(stderr, "%s HRESULT=0x%08X\n", error, unsigned(value)); throw std::runtime_error(error); }
}
void Transition(ID3D12GraphicsCommandList* commands, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    if (before == after) return;
    auto barrier = CD3DX12_RESOURCE_BARRIER::Transition(resource, before, after);
    commands->ResourceBarrier(1, &barrier);
}
LRESULT CALLBACK HostWindow(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{ return DefWindowProcW(window, message, wparam, lparam); }

struct OwnedGpu
{
    ComPtr<IDXGIFactory4> factory;
    ComPtr<IDXGIAdapter1> adapter;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    ComPtr<IDXGISwapChain3> swapchain;
    HANDLE completed = nullptr;
    HWND window = nullptr;
    UINT64 serial = 0;
    UINT width, height;
    DlssNr::GpuLifetime captureLifetime;
    std::vector<ComPtr<ID3D12Resource>> uploads;
    explicit OwnedGpu(bool warp, bool hdr = false) : width(warp ? 64 : 1920), height(warp ? 64 : 1080)
    {
        Hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "HOST_FACTORY_FAILED");
        if (warp) Hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)), "HOST_WARP_ADAPTER_FAILED");
        else
        {
            for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i)
            {
                DXGI_ADAPTER_DESC1 description {};
                Hr(adapter->GetDesc1(&description), "HOST_ADAPTER_DESCRIPTION_FAILED");
                if (description.VendorId == 0x10DE && !(description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) break;
                adapter.Reset();
            }
        }
        Require(adapter != nullptr, "HOST_NVIDIA_ADAPTER_MISSING");
        Hr(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)), "HOST_DEVICE_FAILED");
        DXGI_ADAPTER_DESC1 description {};
        Hr(adapter->GetDesc1(&description), "HOST_ADAPTER_DESCRIPTION_FAILED");
        const auto actual = device->GetAdapterLuid();
        Require(actual.LowPart == description.AdapterLuid.LowPart && actual.HighPart == description.AdapterLuid.HighPart,
                "HOST_ADAPTER_MISMATCH");
        std::printf("HOST_ADAPTER vendor=0x%04X luid=%08X:%08X device=%p warp=%u\n", description.VendorId,
            unsigned(actual.HighPart), actual.LowPart, device.Get(), unsigned(warp));
        D3D12_COMMAND_QUEUE_DESC q {};
        Hr(device->CreateCommandQueue(&q, IID_PPV_ARGS(&queue)), "HOST_QUEUE_FAILED");
        Hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)), "HOST_ALLOCATOR_FAILED");
        Hr(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
            IID_PPV_ARGS(&commands)), "HOST_COMMAND_LIST_FAILED");
        Hr(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "HOST_FENCE_FAILED");
        completed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        Require(completed != nullptr, "HOST_FENCE_EVENT_FAILED");
        WNDCLASSW klass {};
        klass.lpfnWndProc = HostWindow; klass.hInstance = GetModuleHandleW(nullptr); klass.lpszClassName = L"NRAddonHost.Runtime";
        Require(RegisterClassW(&klass) != 0, "HOST_WINDOW_CLASS_FAILED");
        window = CreateWindowExW(0, klass.lpszClassName, L"NR owned runtime fixture", WS_OVERLAPPEDWINDOW,
            0, 0, width, height, nullptr, nullptr, klass.hInstance, nullptr);
        Require(window != nullptr, "HOST_WINDOW_FAILED");
        DXGI_SWAP_CHAIN_DESC1 desc {};
        desc.Width = width; desc.Height = height;
        desc.Format = hdr ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        ComPtr<IDXGISwapChain1> chain;
        Hr(factory->CreateSwapChainForHwnd(queue.Get(), window, &desc, nullptr, nullptr, &chain), "HOST_SWAPCHAIN_FAILED");
        Hr(chain.As(&swapchain), "HOST_SWAPCHAIN_ABI_FAILED");
        Hr(swapchain->SetColorSpace1(hdr ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709 :
            DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709), "HOST_COLOR_SPACE_FAILED");
    }
    ~OwnedGpu()
    {
        commands.Reset();
        swapchain.Reset();
        if (window) DestroyWindow(window);
        UnregisterClassW(L"NRAddonHost.Runtime", GetModuleHandleW(nullptr));
        if (completed) CloseHandle(completed);
    }
    ComPtr<ID3D12Resource> Texture(DXGI_FORMAT format, D3D12_RESOURCE_STATES state, bool unordered = false)
    {
        D3D12_RESOURCE_DESC desc {};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D; desc.Width = width; desc.Height = height;
        desc.DepthOrArraySize = desc.MipLevels = 1; desc.Format = format; desc.SampleDesc.Count = 1;
        if (unordered) desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        const auto heap = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_DEFAULT);
        ComPtr<ID3D12Resource> result;
        Hr(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr,
            IID_PPV_ARGS(&result)), "HOST_TEXTURE_FAILED");
        return result;
    }
    void Upload(ID3D12Resource* target, const std::vector<unsigned char>& pixels, unsigned pixelBytes,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
    {
        const auto desc = target->GetDesc();
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout {};
        UINT64 bytes = 0;
        device->GetCopyableFootprints(&desc, 0, 1, 0, &layout, nullptr, nullptr, &bytes);
        const auto buffer = CD3DX12_RESOURCE_DESC::Buffer(bytes);
        const auto heap = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_UPLOAD);
        ComPtr<ID3D12Resource> upload;
        Hr(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ,
            nullptr, IID_PPV_ARGS(&upload)), "HOST_UPLOAD_FAILED");
        unsigned char* mapped = nullptr;
        D3D12_RANGE empty {};
        Hr(upload->Map(0, &empty, reinterpret_cast<void**>(&mapped)), "HOST_UPLOAD_MAP_FAILED");
        for (unsigned y = 0; y < height; ++y)
            std::memcpy(mapped + y * layout.Footprint.RowPitch, pixels.data() + size_t(y) * width * pixelBytes, width * pixelBytes);
        upload->Unmap(0, nullptr);
        Transition(commands.Get(), target, before, D3D12_RESOURCE_STATE_COPY_DEST);
        const CD3DX12_TEXTURE_COPY_LOCATION dst(target, 0), src(upload.Get(), layout);
        commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        Transition(commands.Get(), target, D3D12_RESOURCE_STATE_COPY_DEST, after);
        uploads.push_back(std::move(upload));
    }
    void Submit()
    {
        Hr(commands->Close(), "HOST_COMMAND_CLOSE_FAILED");
        ID3D12CommandList* lists[] = { commands.Get() };
        auto resolveCapture = captureLifetime.PrepareCapture(queue.Get(), 1, lists);
        const auto expected = ++serial;
        Hr(fence->SetEventOnCompletion(expected, completed), "HOST_FENCE_PREARM_FAILED");
        queue->ExecuteCommandLists(1, lists);
        captureLifetime.Submitted(queue.Get(), 1, lists);
        if (resolveCapture) resolveCapture();
        Hr(queue->Signal(fence.Get(), expected), "HOST_SIGNAL_FAILED");
        Require(WaitForSingleObject(completed, 30000) == WAIT_OBJECT_0, "HOST_FENCE_TIMEOUT");
        Require(fence->GetCompletedValue() >= expected && SUCCEEDED(device->GetDeviceRemovedReason()), "HOST_FENCE_NOT_COMPLETED");
        Hr(allocator->Reset(), "HOST_ALLOCATOR_RESET_FAILED");
        Hr(commands->Reset(allocator.Get(), nullptr), "HOST_COMMAND_RESET_FAILED");
        captureLifetime.ResetRecording(commands.Get());
        uploads.clear();
        std::printf("HOST_NATIVE_COMPLETION serial=%llu actual=%llu\n", expected, fence->GetCompletedValue());
    }
};

uint16_t Half(float value)
{
    // Scene values are finite, nonnegative, normal half values (or zero).
    const auto bits = std::bit_cast<uint32_t>(value);
    if (!bits) return 0;
    const auto rounded = bits + 0xfffu + ((bits >> 13) & 1u);
    return static_cast<uint16_t>(((rounded >> 13) & 0x3ffu) |
        ((((rounded >> 23) & 0xffu) - 112u) << 10));
}
float HalfValue(uint16_t value)
{
    const unsigned exponent = (value >> 10) & 31u, mantissa = value & 1023u;
    const float magnitude = exponent == 0 ? std::ldexp(float(mantissa), -24) :
        exponent == 31 ? (mantissa ? std::numeric_limits<float>::quiet_NaN() :
            std::numeric_limits<float>::infinity()) : std::ldexp(1.f + float(mantissa) / 1024.f, int(exponent) - 15);
    return value & 0x8000u ? -magnitude : magnitude;
}

void Scene(OwnedGpu& gpu, unsigned application, ID3D12Resource* color, ID3D12Resource* depth,
           ID3D12Resource* motion, bool initial)
{
    const bool hdr = color->GetDesc().Format == DXGI_FORMAT_R16G16B16A16_FLOAT;
    const unsigned colorBytes = hdr ? 8u : 4u;
    std::vector<unsigned char> colors(size_t(gpu.width) * gpu.height * colorBytes);
    std::vector<unsigned char> depths(size_t(gpu.width) * gpu.height * 4);
    std::vector<unsigned char> vectors(size_t(gpu.width) * gpu.height * 8);
    const float nearPlane = 0.1f, farPlane = 100.0f, planeZ = 2.0f;
    const float clipDepth = (planeZ - nearPlane) / (farPlane - nearPlane);
    const float halfWidth = 3.2f, halfHeight = 1.8f;
    const float translationX = 2.0f * halfWidth * 2.0f / gpu.width;
    const float translationY = -2.0f * halfHeight / gpu.height;
    const float previousMinusCurrent[2] = { -translationX * gpu.width / (2.0f * halfWidth),
                                           translationY * gpu.height / (2.0f * halfHeight) };
    for (unsigned y = 0; y < gpu.height; ++y)
    for (unsigned x = 0; x < gpu.width; ++x)
    {
        const size_t index = size_t(y) * gpu.width + x;
        const float worldX = ((x + 0.5f) / gpu.width * 2.0f - 1.0f) * halfWidth - application * translationX;
        const float worldY = (1.0f - (y + 0.5f) / gpu.height * 2.0f) * halfHeight - application * translationY;
        const float checker = (int(std::floor(worldX * 9)) + int(std::floor(worldY * 9))) & 1 ? 0.65f : 0.2f;
        const float green = 0.15f + 0.25f * (worldX + halfWidth) / (2 * halfWidth);
        if (hdr)
        {
            const uint16_t pixel[] = { Half(checker), Half(green), Half(96.f / 255.f), Half(1.f) };
            std::memcpy(colors.data() + index * 8, pixel, sizeof(pixel));
        }
        else
        {
            colors[index * 4] = static_cast<unsigned char>(255 * checker);
            colors[index * 4 + 1] = static_cast<unsigned char>(255 * green);
            colors[index * 4 + 2] = 96; colors[index * 4 + 3] = 255;
        }
        std::memcpy(depths.data() + index * 4, &clipDepth, sizeof(clipDepth));
        std::memcpy(vectors.data() + index * 8, previousMinusCurrent, sizeof(previousMinusCurrent));
    }
    gpu.Upload(color, colors, colorBytes, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_PRESENT);
    const auto arrival = initial ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    gpu.Upload(depth, depths, 4, arrival, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    gpu.Upload(motion, vectors, 8, arrival, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    std::printf("HOST_GUIDE_PROVENANCE application=%u projection=orthographic near=%.9g far=%.9g planeZ=%.9g depth=%.9g mvX=%.9g mvY=%.9g\n",
        application, nearPlane, farPlane, planeZ, clipDepth, previousMinusCurrent[0], previousMinusCurrent[1]);
}

void Configure(Config& config, const RuntimeOptions& options, OwnedGpu& gpu)
{
    config.DlssNrEnabled = true; config.DlssNrApplyModel = true; config.DlssNrFinishedPicture = true;
    config.DlssNrRunBeforeSr = false; config.DlssNrDeferredDlss = false; config.DlssNrResidualAcrossRr = false;
    config.DlssNrHdrTransfer = false; config.DlssNrPasses = 1; config.DlssNrWorkingScale = 1.0f;
    config.DlssNrTransfer = 0u; config.DlssNrSignalEncoding = DlssNr::SignalEncoding::Legacy;
    config.DlssNrAutomaticUICorrection = false;
    State::Instance().gameExe = (options.fixtureRoot / "NRAddonHost.fixture").string();
    State::Instance().NVNGX_ApplicationDataPath = options.fixtureRoot.wstring();
    State::Instance().NVNGX_FeatureInfo_Paths = { options.runtimeRoot.wstring() };
    State::Instance().swapchainApi = API::DX12;
    State::Instance().currentSwapchain = gpu.swapchain.Get();
}

void AssertUnselectedProvidersUnused()
{
    const auto& xess = XeSSProxy::OwnedObservation();
    const auto& ffx = FfxApiProxy::OwnedObservation();
    Require(!xess.module && !xess.initRequests && !xess.exportAccesses && !xess.nativeCalls && !xess.loads && !xess.liveContexts &&
        !ffx.module && !ffx.initRequests && !ffx.exportAccesses && !ffx.nativeCalls && !ffx.loads && !ffx.liveContexts,
        "HOST_UNSELECTED_VENDOR_STARTUP_WAS_CALLED");
    std::printf("HOST_UNSELECTED_PROVIDERS xessInit=0 xessAccess=0 xessTrackedCreateDestroyCalls=0 xessLoads=0 xessContexts=0 ffxInit=0 ffxAccess=0 ffxNativeCalls=0 ffxLoads=0 ffxContexts=0\n");
    XeSSProxy::CloseOwnedRuntime();
    FfxApiProxy::CloseOwnedRuntime();
}

void AssertPixels(const DlssNr::PipelineCaptureFrame& frame, unsigned application, unsigned width, unsigned height)
{
    Require(frame.written && frame.imageCount == 4, "HOST_IO_IMAGES_MISSING");
    std::ofstream receipt(frame.directory / "pixel-assertions.json", std::ios::binary);
    receipt << "{\"schema\":1,\"application\":" << application << ",\"completion\":\"native_fence_retired\",\"images\":[";
    std::vector<unsigned char> input, output;
    UINT rowPitch = 0, roiWidth = 0, roiHeight = 0;
    for (unsigned index = 0; index < frame.imageCount; ++index)
    {
        const auto& image = frame.images[index];
        Require(image.unavailable.empty() && image.boundedRoi && image.roi.right <= 256 && image.roi.bottom <= 256,
                "HOST_IO_ROI_INVALID");
        const auto path = frame.directory / (image.name + ".raw");
        std::ifstream file(path, std::ios::binary | std::ios::ate);
        Require(bool(file) && file.tellg() == std::streamoff(image.bytes), "HOST_IO_RAW_SIZE_MISMATCH");
        std::vector<unsigned char> pixels(size_t(image.bytes));
        file.seekg(0); file.read(reinterpret_cast<char*>(pixels.data()), std::streamsize(pixels.size()));
        Require(bool(file), "HOST_IO_RAW_READ_FAILED");
        uint64_t finite = 0;
        for (unsigned y = 0; y < image.roi.bottom; ++y)
        for (unsigned x = 0; x < image.roi.right; ++x)
        {
            const unsigned channels = image.name == "motion" ? 2u : image.name == "depth" ? 1u : 4u;
            const unsigned pixelBytes = image.name == "motion" ? 8u : 4u;
            const auto offset = size_t(image.layout.Offset) + size_t(y) * image.layout.Footprint.RowPitch + x * pixelBytes;
            Require(offset + pixelBytes <= pixels.size(), "HOST_IO_PIXEL_BOUNDS_INVALID");
            for (unsigned channel = 0; channel < channels; ++channel)
            {
                float value;
                if (image.name == "depth" || image.name == "motion")
                    std::memcpy(&value, pixels.data() + offset + channel * sizeof(float), sizeof(float));
                else value = float(pixels[offset + channel]) / 255.0f;
                Require(std::isfinite(value), "HOST_IO_NONFINITE_PIXEL");
                ++finite;
                if (image.name == "depth") Require(std::abs(value - (2.0f - 0.1f) / (100.0f - 0.1f)) <= 1e-7f,
                    "HOST_IO_DEPTH_PROVENANCE_MISMATCH");
                if (image.name == "motion") Require(value == (channel == 0 ? -2.0f : -1.0f),
                    "HOST_IO_MOTION_PROVENANCE_MISMATCH");
            }
            if (channels == 4) Require(pixels[offset + 3] == 255, "HOST_IO_ALPHA_MISMATCH");
            if (image.name == "application_input")
            {
                const float halfWidth = 3.2f, halfHeight = 1.8f;
                const float translationX = 2.0f * halfWidth * 2.0f / width;
                const float translationY = -2.0f * halfHeight / height;
                const float worldX = ((x + 0.5f) / width * 2.0f - 1.0f) * halfWidth - application * translationX;
                const float worldY = (1.0f - (y + 0.5f) / height * 2.0f) * halfHeight - application * translationY;
                const float checker = (int(std::floor(worldX * 9)) + int(std::floor(worldY * 9))) & 1 ? 0.65f : 0.2f;
                Require(pixels[offset] == static_cast<unsigned char>(255 * checker) &&
                    pixels[offset + 1] == static_cast<unsigned char>(255 * (0.15f + 0.25f * (worldX + halfWidth) / (2 * halfWidth))) &&
                    pixels[offset + 2] == 96, "HOST_IO_APPLICATION_PROVENANCE_MISMATCH");
            }
        }
        if (image.name == "application_input") { input = pixels; rowPitch = image.layout.Footprint.RowPitch;
            roiWidth = image.roi.right; roiHeight = image.roi.bottom; }
        if (image.name == "final_output") { output = pixels;
            Require(image.layout.Footprint.RowPitch == rowPitch && image.roi.right == roiWidth && image.roi.bottom == roiHeight,
                    "HOST_IO_COMPARE_LAYOUT_MISMATCH"); }
        if (index) receipt << ',';
        receipt << "{\"role\":\"" << image.name << "\",\"bytes\":" << image.bytes << ",\"finiteComponents\":" << finite
                << ",\"rawSha256\":\"" << FileSha256(path) << "\"}";
        std::printf("HOST_IO_PIXEL_ASSERT role=%s components=%llu rawSha256=%s\n", image.name.c_str(), finite,
                    FileSha256(path).c_str());
    }
    Require(!input.empty() && input.size() == output.size(), "HOST_IO_COMPARE_IMAGES_MISSING");
    uint64_t changed = 0;
    for (unsigned y = 0; y < roiHeight; ++y)
    for (unsigned x = 0; x < roiWidth; ++x)
    for (unsigned c = 0; c < 3; ++c)
        changed += input[size_t(y) * rowPitch + x * 4 + c] != output[size_t(y) * rowPitch + x * 4 + c];
    receipt << "],\"changedRgbComponents\":" << changed << ",\"classification\":\"" << (changed ? "changed" : "neutral") << "\"}";
    receipt.close();
    Require(!receipt.fail(), "HOST_IO_PIXEL_RECEIPT_WRITE_FAILED");
    std::printf("HOST_IO_DELTA application=%u changedRgbComponents=%llu classification=%s\n", application, changed,
                changed ? "changed" : "neutral");
}

// Test-only observation at the actual installed dispatcher/runtime export boundary.
// Every wrapper calls its original exactly once with the same arguments and result.
// Nested provider-internal forwards are not counted as additional model passes.
struct ActualCalls
{
    using Symbol = decltype(&GetProcAddress);
    inline static Symbol symbol = &GetProcAddress;
    inline static NVNGXProxy::Create create[2] {};
    inline static NVNGXProxy::Evaluate evaluate[2] {};
    inline static std::filesystem::path modules[2];
    inline static const RuntimeCase* selected = nullptr;
    inline static unsigned application = 0, evaluatedThisFrame = 0;
    inline static unsigned createCalls = 0, evaluateCalls = 0;
    inline static DWORD ownerThread = 0;
    inline static uint64_t sequence = 0, operation = 0, nextOperation = 0;
    inline static std::ofstream receipt;
    inline static bool typedValid = true;
    inline static thread_local unsigned depth = 0;
    inline static std::set<const NVSDK_NGX_Handle*> created, evaluated;
    static std::ostream& Event(const char* event)
    {
        return receipt << "{\"schema\":1,\"sequence\":" << ++sequence << ",\"fixtureApplication\":" << application
            << ",\"operation\":" << operation << ",\"event\":\"" << event << '"';
    }
    static bool Unsigned(const NVSDK_NGX_Parameter* p, const char* key, unsigned expected)
    {
        unsigned value = ~0u;
        const auto result = p->Get(key, &value);
        Event("parameterRead") << ",\"key\":\"" << key << "\",\"type\":\"unsigned\",\"attempted\":true,\"result\":"
            << unsigned(result) << ",\"success\":" << (result == NVSDK_NGX_Result_Success ? "true" : "false")
            << ",\"rawValue\":" << value << ",\"valueKnown\":" << (result == NVSDK_NGX_Result_Success ? "true" : "false")
            << ",\"expected\":" << expected << "}\n";
        std::printf("HOST_ACTUAL_UINT case=%ls application=%u key=%s result=0x%08X value=%u expected=%u\n",
            selected->id, application, key, unsigned(result), value, expected);
        return result == NVSDK_NGX_Result_Success && value == expected;
    }
    template<unsigned lane>
    static NVSDK_NGX_Result Create(ID3D12GraphicsCommandList* commands, NVSDK_NGX_Feature feature,
        NVSDK_NGX_Parameter* parameters, NVSDK_NGX_Handle** handle)
    {
        const bool observe = depth++ == 0 && unsigned(feature) == 18 && application != 0 && GetCurrentThreadId() == ownerThread;
        if (observe)
        {
            operation = ++nextOperation; ++createCalls;
            Event("createEntry") << ",\"lane\":" << lane << ",\"feature\":" << unsigned(feature)
                << ",\"commands\":" << reinterpret_cast<uintptr_t>(commands) << ",\"parameters\":"
                << reinterpret_cast<uintptr_t>(parameters) << ",\"outHandleStorage\":" << reinterpret_cast<uintptr_t>(handle) << "}\n";
            typedValid &= Unsigned(parameters, "DLSSNR.UICorrection", selected->ui);
            typedValid &= Unsigned(parameters, "DLSSNR.Width", unsigned(1920 * selected->scale));
            typedValid &= Unsigned(parameters, "DLSSNR.Height", unsigned(1080 * selected->scale));
            for (const auto key : { "DLSSNR.UI", "DLSSNR.UIAlpha", "DLSSNR.ControlMask", "DLSSNR.Backbuffer" })
            {
                ID3D12Resource* value = reinterpret_cast<ID3D12Resource*>(uintptr_t(1));
                const auto result = parameters->Get(key, &value);
                Event("parameterRead") << ",\"key\":\"" << key << "\",\"type\":\"ID3D12Resource*\",\"attempted\":true,\"result\":"
                    << unsigned(result) << ",\"success\":" << (result == NVSDK_NGX_Result_Success ? "true" : "false")
                    << ",\"rawValue\":" << reinterpret_cast<uintptr_t>(value) << ",\"valueKnown\":"
                    << (result == NVSDK_NGX_Result_Success ? "true" : "false") << "}\n";
                typedValid &= result == NVSDK_NGX_Result_Success && value == nullptr;
                std::printf("HOST_ACTUAL_RESOURCE case=%ls application=%u key=%s typed=ID3D12Resource result=0x%08X value=%p\n",
                    selected->id, application, key, unsigned(result), value);
            }
        }
        const auto result = create[lane](commands, feature, parameters, handle);
        --depth;
        if (observe)
        {
            if (result == NVSDK_NGX_Result_Success && handle && *handle) created.insert(*handle);
            Event("create") << ",\"lane\":" << lane << ",\"feature\":" << unsigned(feature) << ",\"handle\":"
                << reinterpret_cast<uintptr_t>(handle ? *handle : nullptr) << ",\"result\":" << unsigned(result)
                << ",\"commands\":" << reinterpret_cast<uintptr_t>(commands)
                << ",\"parameters\":" << reinterpret_cast<uintptr_t>(parameters)
                << ",\"forwardedExactlyOnce\":true,\"argumentsModified\":false}\n";
            std::printf("HOST_ACTUAL_CREATE case=%ls application=%u lane=%u feature=%u result=0x%08X handle=%p forwardedExactlyOnce=1\n",
                selected->id, application, lane, unsigned(feature), unsigned(result), handle ? *handle : nullptr);
        }
        return result;
    }
    template<unsigned lane>
    static NVSDK_NGX_Result Evaluate(ID3D12GraphicsCommandList* commands, const NVSDK_NGX_Handle* handle,
        const NVSDK_NGX_Parameter* parameters, PFN_NVSDK_NGX_ProgressCallback callback)
    {
        const bool observe = depth++ == 0 && application != 0 && GetCurrentThreadId() == ownerThread && created.contains(handle);
        if (observe)
        {
            operation = ++nextOperation; ++evaluateCalls;
            Event("evaluateEntry") << ",\"lane\":" << lane << ",\"commands\":" << reinterpret_cast<uintptr_t>(commands)
                << ",\"parameters\":" << reinterpret_cast<uintptr_t>(parameters) << ",\"handle\":"
                << reinterpret_cast<uintptr_t>(handle) << ",\"progressCallback\":" << reinterpret_cast<uintptr_t>(callback) << "}\n";
            typedValid &= Unsigned(parameters, "DLSSNR.Width", unsigned(1920 * selected->scale));
            typedValid &= Unsigned(parameters, "DLSSNR.Height", unsigned(1080 * selected->scale));
            for (const auto key : { "DLSSNR.Color", "DLSSNR.Depth", "DLSSNR.MVec", "DLSSNR.Output" })
            {
                ID3D12Resource* value = nullptr;
                const auto read = parameters->Get(key, &value);
                Event("parameterRead") << ",\"key\":\"" << key << "\",\"type\":\"ID3D12Resource*\",\"attempted\":true,\"result\":"
                    << unsigned(read) << ",\"success\":" << (read == NVSDK_NGX_Result_Success ? "true" : "false")
                    << ",\"rawValue\":" << reinterpret_cast<uintptr_t>(value) << ",\"valueKnown\":"
                    << (read == NVSDK_NGX_Result_Success ? "true" : "false") << "}\n";
                typedValid &= read == NVSDK_NGX_Result_Success && value != nullptr;
                std::printf("HOST_ACTUAL_EVALUATE_RESOURCE case=%ls application=%u key=%s result=0x%08X resource=%p typed=ID3D12Resource\n",
                    selected->id, application, key, unsigned(read), value);
            }
        }
        const auto result = evaluate[lane](commands, handle, parameters, callback);
        --depth;
        if (observe)
        {
            if (result == NVSDK_NGX_Result_Success) { evaluated.insert(handle); ++evaluatedThisFrame; }
            Event("evaluate") << ",\"lane\":" << lane << ",\"handle\":" << reinterpret_cast<uintptr_t>(handle)
                << ",\"result\":" << unsigned(result) << ",\"commands\":" << reinterpret_cast<uintptr_t>(commands)
                << ",\"parameters\":" << reinterpret_cast<uintptr_t>(parameters)
                << ",\"forwardedExactlyOnce\":true,\"argumentsModified\":false}\n";
            std::printf("HOST_ACTUAL_EVALUATE case=%ls application=%u lane=%u handle=%p result=0x%08X forwardedExactlyOnce=1\n",
                selected->id, application, lane, handle, unsigned(result));
        }
        return result;
    }
    static FARPROC WINAPI SymbolRead(HMODULE module, LPCSTR name)
    {
        const auto original = symbol(module, name);
        if (!original || reinterpret_cast<uintptr_t>(name) <= 65535) return original;
        if (std::strcmp(name, "NVSDK_NGX_D3D12_CreateFeature") &&
            std::strcmp(name, "NVSDK_NGX_D3D12_EvaluateFeature")) return original;
        wchar_t path[32768] {};
        const auto count = GetModuleFileNameW(module, path, std::size(path));
        if (!count || count == std::size(path)) return original;
        for (unsigned lane = 0; lane < 2; ++lane)
        {
            if (_wcsicmp(path, modules[lane].c_str())) continue;
            if (!std::strcmp(name, "NVSDK_NGX_D3D12_CreateFeature"))
            {
                create[lane] = reinterpret_cast<NVNGXProxy::Create>(original);
                return reinterpret_cast<FARPROC>(lane ? &Create<1> : &Create<0>);
            }
            evaluate[lane] = reinterpret_cast<NVNGXProxy::Evaluate>(original);
            return reinterpret_cast<FARPROC>(lane ? &Evaluate<1> : &Evaluate<0>);
        }
        return original;
    }
    ActualCalls(const RuntimeCase& candidate, const std::filesystem::path& driver,
        const std::filesystem::path& runtime, const std::filesystem::path& root)
    {
        selected = &candidate; modules[0] = driver; modules[1] = runtime;
        modules[0].make_preferred(); modules[1].make_preferred();
        created.clear(); evaluated.clear(); typedValid = true; createCalls = evaluateCalls = 0;
        sequence = operation = nextOperation = 0; ownerThread = GetCurrentThreadId();
        receipt.open(root / "actual-calls.jsonl", std::ios::binary);
        Require(bool(receipt), "HOST_ACTUAL_CALL_RECEIPT_FAILED");
        Require(DetourTransactionBegin() == NO_ERROR, "HOST_OBSERVER_TRANSACTION_FAILED");
        Require(DetourUpdateThread(GetCurrentThread()) == NO_ERROR, "HOST_OBSERVER_THREAD_FAILED");
        Require(DetourAttach(reinterpret_cast<PVOID*>(&symbol), SymbolRead) == NO_ERROR, "HOST_OBSERVER_ATTACH_FAILED");
        Require(DetourTransactionCommit() == NO_ERROR, "HOST_OBSERVER_COMMIT_FAILED");
    }
    ~ActualCalls()
    {
        receipt.close();
        const auto begin = DetourTransactionBegin();
        const auto thread = DetourUpdateThread(GetCurrentThread());
        const auto detach = DetourDetach(reinterpret_cast<PVOID*>(&symbol), SymbolRead);
        const auto commit = DetourTransactionCommit();
        std::printf("HOST_ACTUAL_OBSERVER_CLOSED begin=%ld thread=%ld detach=%ld commit=%ld\n", begin, thread, detach, commit);
        if (begin || thread || detach || commit) std::terminate();
    }
};

void AssertHdrPixels(const DlssNr::PipelineCaptureFrame& frame, unsigned application, unsigned width, unsigned height)
{
    Require(frame.written && frame.imageCount == 4, "HOST_IO_IMAGES_MISSING");
    uint64_t retained = 0, changed = 0;
    std::vector<unsigned char> input, output;
    UINT pitch = 0, rw = 0, rh = 0;
    std::ofstream receipt(frame.directory / "pixel-assertions.json", std::ios::binary);
    receipt << "{\"schema\":1,\"application\":" << application << ",\"completion\":\"native_fence_retired\",\"images\":[";
    for (unsigned index = 0; index < frame.imageCount; ++index)
    {
        const auto& image = frame.images[index];
        const bool color = image.name == "application_input" || image.name == "final_output";
        Require(image.unavailable.empty() && image.boundedRoi && image.roi.right <= 256 && image.roi.bottom <= 256,
            "HOST_IO_ROI_INVALID");
        std::ifstream file(frame.directory / (image.name + ".raw"), std::ios::binary | std::ios::ate);
        Require(bool(file) && file.tellg() == std::streamoff(image.bytes), "HOST_IO_RAW_SIZE_MISMATCH");
        std::vector<unsigned char> pixels(size_t(image.bytes));
        file.seekg(0); file.read(reinterpret_cast<char*>(pixels.data()), std::streamsize(pixels.size()));
        Require(bool(file), "HOST_IO_RAW_READ_FAILED");
        retained += image.bytes;
        const unsigned channels = color ? 4u : image.name == "motion" ? 2u : 1u;
        const unsigned pixelBytes = color || channels == 2 ? 8u : 4u;
        uint64_t finite = 0;
        for (unsigned y = 0; y < image.roi.bottom; ++y)
        for (unsigned x = 0; x < image.roi.right; ++x)
        {
            const auto offset = size_t(image.layout.Offset) + size_t(y) * image.layout.Footprint.RowPitch + x * pixelBytes;
            Require(offset + pixelBytes <= pixels.size(), "HOST_IO_PIXEL_BOUNDS_INVALID");
            for (unsigned channel = 0; channel < channels; ++channel)
            {
                float value;
                if (color)
                {
                    uint16_t half; std::memcpy(&half, pixels.data() + offset + channel * 2, 2);
                    value = HalfValue(half);
                }
                else std::memcpy(&value, pixels.data() + offset + channel * 4, 4);
                Require(std::isfinite(value), "HOST_IO_NONFINITE_PIXEL");
                ++finite;
                if (color && channel == 3) Require(value == 1.f, "HOST_IO_ALPHA_MISMATCH");
                if (image.name == "depth") Require(std::abs(value - (2.f - .1f) / (100.f - .1f)) <= 1e-7f,
                    "HOST_IO_DEPTH_PROVENANCE_MISMATCH");
                if (image.name == "motion") Require(value == (channel ? -1.f : -2.f), "HOST_IO_MOTION_PROVENANCE_MISMATCH");
                if (image.name == "application_input")
                {
                    const float wx = ((x + .5f) / width * 2.f - 1.f) * 3.2f - application * (6.4f * 2.f / width);
                    const float wy = (1.f - (y + .5f) / height * 2.f) * 1.8f + application * (3.6f / height);
                    const float expected[] = {
                        (int(std::floor(wx * 9)) + int(std::floor(wy * 9))) & 1 ? .65f : .2f,
                        .15f + .25f * (wx + 3.2f) / 6.4f, 96.f / 255.f, 1.f
                    };
                    Require(value == HalfValue(Half(expected[channel])), "HOST_IO_APPLICATION_PROVENANCE_MISMATCH");
                }
            }
        }
        if (image.name == "application_input") { input = pixels; pitch = image.layout.Footprint.RowPitch;
            rw = image.roi.right; rh = image.roi.bottom; }
        if (image.name == "final_output") { output = pixels;
            Require(pitch == image.layout.Footprint.RowPitch && rw == image.roi.right && rh == image.roi.bottom,
                "HOST_IO_COMPARE_LAYOUT_MISMATCH"); }
        std::printf("HOST_HDR_IO role=%s bytes=%llu format=%u rawSha256=%s finite=1 alpha=1\n",
            image.name.c_str(), image.bytes, unsigned(image.layout.Footprint.Format),
            FileSha256(frame.directory / (image.name + ".raw")).c_str());
        if (index) receipt << ',';
        receipt << "{\"role\":\"" << image.name << "\",\"bytes\":" << image.bytes << ",\"finiteComponents\":"
            << finite << ",\"rawSha256\":\"" << FileSha256(frame.directory / (image.name + ".raw")) << "\"}";
    }
    Require(!input.empty() && input.size() == output.size(), "HOST_IO_COMPARE_IMAGES_MISSING");
    for (unsigned y = 0; y < rh; ++y)
    for (unsigned x = 0; x < rw; ++x)
    for (unsigned c = 0; c < 6; ++c) changed += input[size_t(y) * pitch + x * 8 + c] != output[size_t(y) * pitch + x * 8 + c];
    std::printf("HOST_HDR_IO_DELTA changedRgbBytes=%llu classification=%s retainedRawBytes=%llu\n",
        changed, changed ? "changed" : "neutral", retained);
    receipt << "],\"changedRgbBytes\":" << changed << ",\"classification\":\"" << (changed ? "changed" : "neutral") << "\"}";
    receipt.close(); Require(!receipt.fail(), "HOST_IO_PIXEL_RECEIPT_WRITE_FAILED");
}

void RunCandidate(const RuntimeOptions& options)
{
    const auto& candidate = *options.runtimeCase;
    std::string summaryText;
    {
    const bool present = candidate.route == RuntimeCase::Route::Present;
    const bool render = candidate.route == RuntimeCase::Route::Render;
    Config config;
    KernelBaseProxy::Init();
    OwnedGpu gpu(false, candidate.hdr);
    Configure(config, options, gpu);
    config.DlssNrFinishedPicture = present;
    config.DlssNrRunBeforeSr = render;
    config.DlssNrAutomaticUICorrection = candidate.adopted;
    config.DlssNrPasses = candidate.passes;
    config.DlssNrWorkingScale = candidate.scale;
    config.DlssNrTransfer = candidate.transfer;
    config.DlssNrInputFilter = static_cast<DlssNr::InputFilter>(candidate.filter);
    config.DlssNrSignalEncoding = static_cast<DlssNr::SignalEncoding>(candidate.signal);
    DlssNr::FinishedPictureColorSpace(gpu.swapchain.Get(), candidate.hdr ?
        DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
    const auto paths = Util::GetDriverStore();
    const auto luid = gpu.device->GetAdapterLuid();
    const auto selectedDriver = paths.find({ luid.LowPart, luid.HighPart });
    Require(selectedDriver != paths.end(), "HOST_DRIVER_ADAPTER_PATH_MISSING");
    const auto driver = selectedDriver->second / L"_nvngx.dll";
    Require(luid.LowPart == options.adapterLow && static_cast<uint32_t>(luid.HighPart) == options.adapterHigh &&
        std::filesystem::is_regular_file(options.driver) && std::filesystem::equivalent(driver, options.driver) &&
        FileSha256(driver) == options.driverSha256, "HOST_DRIVER_ADAPTER_BINDING_MISMATCH");
    std::printf("HOST_CASE_REQUEST id=%ls route=%u adopted=%u scale=%.9g passes=%u signal=%u filter=%u hdr=%u transfer=%u expectedEffectiveTransfer=%u driverSha256=%s\n",
        candidate.id, unsigned(candidate.route), unsigned(candidate.adopted), candidate.scale, candidate.passes,
        candidate.signal, candidate.filter, unsigned(candidate.hdr), candidate.transfer, candidate.effectiveTransfer, FileSha256(driver).c_str());
    ActualCalls actual(candidate, driver, options.runtimeRoot / L"nvngx_dlssnr.dll", options.fixtureRoot);
    NVNGXProxy::OpenOwnedDriver(driver, options.runtimeRoot, options.fixtureRoot);
    Require(NVNGXProxy::InitDx12(gpu.device.Get()), "HOST_DRIVER_INIT_FAILED");
    const auto format = candidate.hdr ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R8G8B8A8_UNORM;
    auto depth = gpu.Texture(DXGI_FORMAT_R32_FLOAT, D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion = gpu.Texture(DXGI_FORMAT_R32G32_FLOAT, D3D12_RESOURCE_STATE_COPY_DEST);
    auto original = gpu.Texture(format, D3D12_RESOURCE_STATE_COPY_DEST);
    auto output = present ? ComPtr<ID3D12Resource> {} :
        gpu.Texture(format, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, true);
    auto shader = std::make_unique<DlssNr_Dx12>("NRAddonHost.production.case", gpu.device.Get());
    Require(shader->IsInit(), "HOST_PRODUCTION_SHADER_NOT_READY");
    if (options.diagnosticPair && options.diagnosticObserver)
        Require(DlssNr::MfgObserver::Begin(shader.get(), 1), "HOST_DIAGNOSTIC_OBSERVER_START_FAILED");
    auto capture = DlssNr::PipelineCaptureSession::Begin(options.fixtureRoot / "case-io");
    Require(capture != nullptr, "HOST_CAPTURE_SESSION_FAILED");
    RuntimeParameters parameters;
    bool applied = false;
    unsigned composedApplications = 0, copyBackApplications = 0, submittedApplications = 0;
    uint64_t retainedBytes = 0;
    std::filesystem::path captureManifest;
    DlssNr::StatusSnapshot finalStatus;
    std::ostringstream applications;
    for (unsigned application = 1; application <= 8; ++application)
    {
        ActualCalls::application = application; ActualCalls::evaluatedThisFrame = 0;
        ComPtr<ID3D12Resource> picture;
        Hr(gpu.swapchain->GetBuffer(gpu.swapchain->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&picture)), "HOST_PICTURE_FAILED");
        Scene(gpu, application, picture.Get(), depth.Get(), motion.Get(), application == 1);
        Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_SOURCE);
        if (application > 1) Transition(gpu.commands.Get(), original.Get(),
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
        gpu.commands->CopyResource(original.Get(), picture.Get());
        Transition(gpu.commands.Get(), original.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
        auto consumer = DlssNr::StreamlinePicture::Consumer(gpu.swapchain.Get());
        Require(consumer.identity.Known() && DlssNr::StreamlinePicture::SameDevice(consumer.device.Get(), gpu.device.Get()),
            "HOST_CONSUMER_DEVICE_MISMATCH");
        consumer.identity.application = application; consumer.identity.applicationKnown = true;
        if (present)
        {
            parameters.Set(NVSDK_NGX_Parameter_Color, original.Get());
            parameters.Set(NVSDK_NGX_Parameter_Depth, depth.Get());
            parameters.Set(NVSDK_NGX_Parameter_MotionVectors, motion.Get());
            parameters.Set(NVSDK_NGX_Parameter_Output, picture.Get());
            parameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, gpu.width);
            parameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, gpu.height);
            parameters.Set(NVSDK_NGX_Parameter_FrameTimeDeltaInMsec, 16.666667f);
            parameters.Set(NVSDK_NGX_Parameter_MV_Scale_X, 1.f);
            parameters.Set(NVSDK_NGX_Parameter_MV_Scale_Y, 1.f);
            parameters.Set(NVSDK_NGX_Parameter_Reset, application == 1 ? 1u : 0u);
            Require(shader->ProcessSeam(gpu.commands.Get(), &parameters, true, gpu.queue.Get(), false, application,
                false, 0, consumer), "HOST_PRODUCTION_SEAM_REJECTED");
            const auto capturedStatus = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            Require(capturedStatus.guidesValid && capturedStatus.captureSerial && capturedStatus.application == application,
                "HOST_GUIDE_ADMISSION_FAILED");
            gpu.Submit();
            DlssNr::ApplyToFinishedPicture(gpu.swapchain.Get(), gpu.queue.Get());
            applied = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output.Applied();
        }
        else
        {
            DlssNrFrameInfo frame;
            frame.Width = frame.OutputWidth = frame.GuideWidth = frame.RenderSubrectWidth = gpu.width;
            frame.Height = frame.OutputHeight = frame.GuideHeight = frame.RenderSubrectHeight = gpu.height;
            frame.BeforeUpscale = render; frame.ColourIsLinearHdr = candidate.hdr;
            frame.SubmissionEpoch = application; frame.Reset = application == 1;
            frame.IndependentCommands = true;
            frame.OutputArrivalState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            if (options.diagnosticPair)
                shader->DiagnosePipeline(3, gpu.commands.Get(), &parameters, original.Get(), 0, false);
            applied = shader->Dispatch(gpu.commands.Get(), original.Get(), depth.Get(), motion.Get(), output.Get(), frame, gpu.queue.Get());
            Transition(gpu.commands.Get(), output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
            Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST);
            gpu.commands->CopyResource(picture.Get(), output.Get());
            Transition(gpu.commands.Get(), output.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PRESENT);
            if (options.diagnosticPair)
                shader->DiagnosePipeline(4, gpu.commands.Get(), &parameters, picture.Get(), 0, false);
            gpu.Submit();
        }
        const auto status = DlssNr::ReadStatus(DlssNr::Backend::Dx12);
        composedApplications += status.output.composed; copyBackApplications += status.output.copyBack;
        submittedApplications += status.output.submitted; finalStatus = status;
        Require(status.failureReason.empty() && status.output.state != DlssNr::OutputState::Failed, "HOST_REAL_PROVIDER_FAILED");
        std::printf("HOST_CASE_OBSERVED id=%ls application=%u evaluated=%u composed=%u copyBack=%u productionExecuted=%u productionSubmitted=%u nativeFence=%llu passesEvaluated=%u ui=%u filter=%u signal=%u native=%ux%u working=%ux%u hdr=%u requestedTransfer=%u effectiveTransfer=%u privateEnlargement=%u\n",
            candidate.id, application, unsigned(status.output.evaluated), unsigned(status.output.composed),
            unsigned(status.output.copyBack), unsigned(status.output.executed), unsigned(status.output.submitted),
            gpu.fence->GetCompletedValue(), ActualCalls::evaluatedThisFrame, status.output.uiCorrection,
            status.output.inputFilter, status.output.signalEncoding, status.output.optionContext.inputWidth,
            status.output.optionContext.inputHeight, status.output.optionContext.workingWidth,
            status.output.optionContext.workingHeight, unsigned(status.output.optionContext.hdrProxy),
            status.reconstruction.requested, status.reconstruction.effective, unsigned(status.reconstruction.privateEnlargement));
        if (application == 8)
        {
            Require(applied && status.output.application == application && status.output.guidesValid && status.output.evaluated && status.output.composed &&
                status.output.copyBack && ActualCalls::typedValid && ActualCalls::created.size() == candidate.passes &&
                ActualCalls::evaluated.size() == candidate.passes && ActualCalls::evaluatedThisFrame == candidate.passes,
                "HOST_CASE_ACTUAL_CHAIN_NOT_PROVEN");
            Require(status.output.uiCorrection == candidate.ui && status.output.inputFilter == candidate.filter &&
                status.output.signalEncoding == candidate.signal && status.reconstruction.requested == candidate.transfer &&
                status.reconstruction.effective == candidate.effectiveTransfer && !status.reconstruction.privateEnlargement,
                "HOST_CASE_EFFECTIVE_SETTINGS_MISMATCH");
            const DlssNr::CaptureIdentity identity { reinterpret_cast<uintptr_t>(shader.get()),
                reinterpret_cast<uintptr_t>(consumer.identity.consumer), consumer.identity.generation, application, true };
            auto captured = capture->Admit(identity, gpu.captureLifetime, gpu.commands.Get());
            Require(captured != nullptr, "HOST_CAPTURE_ADMISSION_FAILED");
            captured->Copy(gpu.commands.Get(), gpu.device.Get(), "application_input", original.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            captured->Copy(gpu.commands.Get(), gpu.device.Get(), "depth", depth.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            captured->Copy(gpu.commands.Get(), gpu.device.Get(), "motion", motion.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            captured->Copy(gpu.commands.Get(), gpu.device.Get(), "final_output", picture.Get(), D3D12_RESOURCE_STATE_PRESENT);
            captured->Seal(); gpu.Submit();
            Require(WaitForSingleObject(captured->retired, 30000) == WAIT_OBJECT_0 && captured->written, "HOST_CAPTURE_WRITE_FAILED");
            uint64_t bytes = 0;
            for (unsigned i = 0; i < captured->imageCount; ++i) bytes += captured->images[i].bytes;
            Require(bytes <= 33554432 && bytes <= options.reservationBytes, "HOST_RETAINED_BUDGET_REFUSED");
            if (candidate.hdr) AssertHdrPixels(*captured, application, gpu.width, gpu.height);
            else AssertPixels(*captured, application, gpu.width, gpu.height);
            retainedBytes = bytes; captureManifest = captured->directory / "capture.json";
        }
        const auto presentResult = gpu.swapchain->Present(0, 0);
        Hr(presentResult, "HOST_PRESENT_FAILED");
        if (application > 1) applications << ',';
        applications << "{\"fixtureApplication\":" << application << ",\"device\":" << reinterpret_cast<uintptr_t>(gpu.device.Get())
            << ",\"owner\":" << reinterpret_cast<uintptr_t>(shader.get()) << ",\"consumer\":"
            << reinterpret_cast<uintptr_t>(consumer.identity.consumer) << ",\"generation\":" << consumer.identity.generation
            << ",\"input\":" << reinterpret_cast<uintptr_t>(original.Get()) << ",\"depth\":" << reinterpret_cast<uintptr_t>(depth.Get())
            << ",\"motion\":" << reinterpret_cast<uintptr_t>(motion.Get()) << ",\"output\":" << reinterpret_cast<uintptr_t>(picture.Get())
            << ",\"productionCaptureSerial\":" << status.output.captureSerial << ",\"statusApplication\":" << status.output.application
            << ",\"guidesValid\":" << status.output.guidesValid << ",\"state\":" << unsigned(status.output.state)
            << ",\"reason\":" << unsigned(status.output.reason) << ",\"evaluated\":" << status.output.evaluated
            << ",\"composed\":" << status.output.composed << ",\"copyBack\":" << status.output.copyBack
            << ",\"productionExecuted\":" << status.output.executed << ",\"productionSubmitted\":" << status.output.submitted
            << ",\"completionUnknown\":" << status.output.completionUnknown << ",\"passesEvaluated\":" << ActualCalls::evaluatedThisFrame
            << ",\"nativeFenceSerial\":" << gpu.serial << ",\"nativeFenceValue\":" << gpu.fence->GetCompletedValue()
            << ",\"presentResult\":" << unsigned(presentResult) << "}";
    }
    capture->Stop();
    Require(WaitForSingleObject(capture->Exited(), 30000) == WAIT_OBJECT_0 && !capture->TimedOut() &&
        capture->Writes() == 1 && capture->Discarded() == 0, "HOST_CAPTURE_WORKER_NOT_CLOSED");
    if (options.diagnosticPair)
    {
        auto observed = std::make_unique<DlssNr::MfgObserver::Snapshot>();
        DlssNr::MfgObserver::Read(*observed);
        std::ofstream receipt(options.fixtureRoot / "diagnostic-observer.json", std::ios::binary);
        receipt << "{\"schema\":1,\"observer\":" << options.diagnosticObserver << ",\"session\":" << observed->session
            << ",\"owner\":" << observed->owner << ",\"applicationSeams\":" << observed->applicationSeams
            << ",\"eventCount\":" << observed->eventCount << ",\"active\":" << observed->active << ",\"events\":[";
        for (unsigned i = 0; i < observed->eventCount; ++i)
        {
            const auto& event = observed->events[i];
            if (i) receipt << ',';
            receipt << "{\"session\":" << event.session << ",\"activity\":" << event.activity << ",\"seam\":" << unsigned(event.seam)
                << ",\"identity\":{\"owner\":" << event.identity.owner << ",\"consumer\":" << event.identity.consumer
                << ",\"generation\":" << event.identity.generation << ",\"application\":" << event.identity.application
                << ",\"applicationKnown\":" << event.identity.applicationKnown << "},\"provider\":" << event.provider
                << ",\"handle\":" << event.handle << ",\"commands\":" << event.commands << ",\"captureSerial\":" << event.captureSerial
                << ",\"handleId\":" << event.handleId << ",\"feature\":" << event.feature << ",\"featureKnown\":" << event.featureKnown
                << ",\"stage\":" << event.stage << ",\"result\":" << event.result << ",\"resultKnown\":" << event.resultKnown
                << ",\"inputCount\":" << event.inputCount << ",\"inputEntriesObserved\":" << event.inputEntriesObserved
                << ",\"rawIndex\":" << event.rawIndex << ",\"indexReadAttempted\":" << event.indexReadAttempted
                << ",\"indexReadSuccess\":" << event.indexReadSuccess << ",\"indexReadResult\":" << event.indexReadResult
                << ",\"indexSource\":" << unsigned(event.indexSource) << ",\"indexReadResultKnown\":" << event.indexReadResultKnown
                << ",\"phaseKnown\":" << event.phaseKnown << ",\"pixelOriginKnown\":" << event.pixelOriginKnown
                << ",\"displayTimingAvailable\":" << event.displayTimingAvailable << ",\"resources\":[";
            for (unsigned r = 0; r < event.resourceCount; ++r)
            {
                const auto& resource = event.resources[r];
                if (r) receipt << ',';
                receipt << "{\"value\":" << resource.value << ",\"role\":" << unsigned(resource.role)
                    << ",\"declaration\":" << unsigned(resource.declaration) << ",\"readResult\":" << resource.readResult
                    << ",\"readAttempted\":" << resource.readAttempted << ",\"readSuccess\":" << resource.readSuccess
                    << ",\"ngxVkResource\":" << resource.ngxVkResource << ",\"tagType\":" << resource.tagType
                    << ",\"lifecycle\":" << resource.lifecycle << "}";
            }
            receipt << "]}";
        }
        receipt << "],\"contentionDrops\":" << observed->contentionDrops << ",\"capped\":" << observed->capped << "}";
        receipt.close(); Require(!receipt.fail(), "HOST_DIAGNOSTIC_RECEIPT_FAILED");
        std::printf("HOST_DIAGNOSTIC_PAIR observer=%u actualEvents=%u rawPhaseKnown=0 pixelOriginKnown=0 displayTimingAvailable=0 task23Executed=0\n",
            unsigned(options.diagnosticObserver), observed->eventCount);
        DlssNr::MfgObserver::Stop(shader.get());
    }
    DlssNr::SkipFinishedPicture(gpu.swapchain.Get());
    shader->FinishSubmitted();
    Require(shader->ReadyToDestroy(), "HOST_PRODUCTION_OWNERS_NOT_RETIRED");
    shader.reset(); capture.reset();
    Require(gpu.captureLifetime.Idle(), "HOST_CAPTURE_OWNERS_NOT_RETIRED");
    NVNGXProxy::CloseOwnedDriver();
    AssertUnselectedProvidersUnused(); AssertForbiddenStartupUnused();
    State::Instance().currentSwapchain = nullptr; State::Instance().swapchainApi = API::NotSelected;
    State::Instance().gameExe.clear();
    ActualCalls::receipt.flush(); Require(bool(ActualCalls::receipt), "HOST_ACTUAL_CALL_RECEIPT_FAILED");
    std::ostringstream summary;
    summary << "{\"schema\":1,\"runtimeCase\":\"";
    for (const auto* p = candidate.id; *p; ++p) summary << char(*p);
    summary << "\",\"route\":" << unsigned(candidate.route) << ",\"applicationFrames\":8,\"retainedFrames\":1,\"retainedApplication\":8"
        << ",\"captureManifest\":\"" << captureManifest.generic_string() << "\",\"actualCalls\":\""
        << (options.fixtureRoot / "actual-calls.jsonl").generic_string() << "\",\"diagnosticObserver\":" << options.diagnosticObserver
        << ",\"finalNativeFence\":" << gpu.fence->GetCompletedValue() << ",\"requested\":{\"adopted\":" << candidate.adopted
        << ",\"scale\":" << candidate.scale << ",\"passes\":" << candidate.passes << ",\"signal\":" << candidate.signal
        << ",\"filter\":" << candidate.filter << ",\"hdr\":" << candidate.hdr << ",\"transfer\":" << candidate.transfer
        << "},\"effective\":{\"ui\":" << finalStatus.output.uiCorrection << ",\"filter\":" << finalStatus.output.inputFilter
        << ",\"signal\":" << finalStatus.output.signalEncoding << ",\"transfer\":" << finalStatus.reconstruction.effective
        << ",\"privateEnlargement\":" << finalStatus.reconstruction.privateEnlargement << "},\"actualNrCreateCalls\":"
        << ActualCalls::createCalls << ",\"actualNrEvaluateCalls\":" << ActualCalls::evaluateCalls
        << ",\"distinctCreatedHandles\":" << ActualCalls::created.size() << ",\"distinctEvaluatedHandles\":" << ActualCalls::evaluated.size()
        << ",\"compositionApplications\":" << composedApplications << ",\"copyBackApplications\":" << copyBackApplications
        << ",\"productionSubmittedApplications\":" << submittedApplications << ",\"nativeSubmissionCount\":" << gpu.serial
        << ",\"nativeFenceCompletedCount\":" << gpu.fence->GetCompletedValue() << ",\"nativePresentCalls\":8"
        << ",\"productMfgEvaluateCount\":null,\"productMfgPresentCount\":null,\"physicalFgProviderExercised\":false"
        << ",\"retainedRawBytes\":" << retainedBytes << ",\"metadataReservationBytes\":131072,\"retainedReservationBytes\":"
        << options.reservationBytes << ",\"ownedResourcesClosed\":true,\"phaseKnown\":false,\"displayTimingAvailable\":false,\"applications\":["
        << applications.str() << "]}";
    uint64_t metadata = summary.str().size() + std::filesystem::file_size(options.fixtureRoot / "actual-calls.jsonl") +
        std::filesystem::file_size(captureManifest) + std::filesystem::file_size(captureManifest.parent_path() / "pixel-assertions.json");
    if (options.diagnosticPair) metadata += std::filesystem::file_size(options.fixtureRoot / "diagnostic-observer.json");
    Require(metadata <= 131072 && retainedBytes + 131072 <= options.reservationBytes, "HOST_RETAINED_BUDGET_REFUSED");
    summaryText = summary.str();
    } // All case GPU, texture, observer, shader, capture and provider owners have left scope.
    std::ofstream summaryFile(options.fixtureRoot / "case-summary.json", std::ios::binary);
    summaryFile << summaryText; summaryFile.close();
    Require(!summaryFile.fail(), "HOST_CASE_SUMMARY_FAILED");
    std::printf("HOST_CASE_PASS id=%ls frames=8 retainedFrames=1 realNvidiaCalls=1 nativeFenceRetired=1 ownership=closed\n", candidate.id);
}

void Run(const RuntimeOptions& options, bool warp)
{
    Config config;
    KernelBaseProxy::Init();
    OwnedGpu gpu(warp);
    Configure(config, options, gpu);
    auto depth = gpu.Texture(DXGI_FORMAT_R32_FLOAT, D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion = gpu.Texture(DXGI_FORMAT_R32G32_FLOAT, D3D12_RESOURCE_STATE_COPY_DEST);
    auto original = gpu.Texture(DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_STATE_COPY_DEST);
    auto shader = std::make_unique<DlssNr_Dx12>("NRAddonHost.production", gpu.device.Get());
    Require(shader->IsInit(), "HOST_PRODUCTION_SHADER_NOT_READY");
    RuntimeParameters applicationParameters;
    if (options.guideContract != RuntimeOptions::GuideContract::None)
    {
        Require(warp, "HOST_ARGUMENT_INVALID");
        ComPtr<ID3D12Device> foreignDevice;
        ComPtr<ID3D12Resource> foreignDepth;
        if (options.guideContract != RuntimeOptions::GuideContract::Missing)
        {
            ComPtr<IDXGIAdapter1> foreignAdapter = gpu.adapter;
            if (options.guideContract == RuntimeOptions::GuideContract::AdapterMismatch)
            {
                foreignAdapter.Reset();
                for (UINT index = 0; gpu.factory->EnumAdapters1(index, &foreignAdapter) != DXGI_ERROR_NOT_FOUND; ++index)
                {
                    DXGI_ADAPTER_DESC1 description {};
                    Hr(foreignAdapter->GetDesc1(&description), "HOST_ADAPTER_DESCRIPTION_FAILED");
                    if (description.VendorId == 0x10DE && !(description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) break;
                    foreignAdapter.Reset();
                }
                Require(foreignAdapter != nullptr, "HOST_NVIDIA_ADAPTER_MISSING");
            }
            if (options.guideContract == RuntimeOptions::GuideContract::ForeignDevice)
            {
                ComPtr<ID3D12DeviceFactory> factory;
                constexpr GUID factoryClass { 0x114863bf, 0xc386, 0x4aee, { 0xb3, 0x9d, 0x8f, 0x0b, 0xbb, 0x06, 0x29, 0x55 } };
                Hr(D3D12GetInterface(factoryClass, IID_PPV_ARGS(&factory)), "HOST_FOREIGN_DEVICE_FACTORY_FAILED");
                Hr(factory->SetFlags(D3D12_DEVICE_FACTORY_FLAG_DISALLOW_STORING_NEW_DEVICE_AS_SINGLETON),
                    "HOST_FOREIGN_DEVICE_FACTORY_FLAGS_FAILED");
                Hr(factory->CreateDevice(foreignAdapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&foreignDevice)),
                    "HOST_FOREIGN_FIXTURE_DEVICE_FAILED");
            }
            else Hr(D3D12CreateDevice(foreignAdapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&foreignDevice)),
                    "HOST_FOREIGN_FIXTURE_DEVICE_FAILED");
            Require(!DlssNr::StreamlinePicture::SameDevice(foreignDevice.Get(), gpu.device.Get()),
                "HOST_FOREIGN_FIXTURE_DEVICE_NOT_DISTINCT");
            const auto sourceLuid = foreignDevice->GetAdapterLuid(), targetLuid = gpu.device->GetAdapterLuid();
            const bool differentAdapter = sourceLuid.LowPart != targetLuid.LowPart || sourceLuid.HighPart != targetLuid.HighPart;
            Require(differentAdapter == (options.guideContract == RuntimeOptions::GuideContract::AdapterMismatch),
                "HOST_FOREIGN_FIXTURE_ADAPTER_NOT_DISTINCT");
            const auto heap = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_DEFAULT);
            const auto description = depth->GetDesc();
            Hr(foreignDevice->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, nullptr, IID_PPV_ARGS(&foreignDepth)),
                "HOST_FOREIGN_FIXTURE_RESOURCE_FAILED");
            std::printf("HOST_NEGATIVE_GUIDE sourceDevice=%p targetDevice=%p sourceLuid=%08X:%08X targetLuid=%08X:%08X\n",
                foreignDevice.Get(), gpu.device.Get(), unsigned(sourceLuid.HighPart), sourceLuid.LowPart,
                unsigned(targetLuid.HighPart), targetLuid.LowPart);
        }
        ComPtr<ID3D12Resource> picture;
        Hr(gpu.swapchain->GetBuffer(gpu.swapchain->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&picture)), "HOST_PICTURE_FAILED");
        applicationParameters.Set(NVSDK_NGX_Parameter_Depth, foreignDepth.Get());
        applicationParameters.Set(NVSDK_NGX_Parameter_MotionVectors, motion.Get());
        applicationParameters.Set(NVSDK_NGX_Parameter_Output, picture.Get());
        applicationParameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, gpu.width);
        applicationParameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, gpu.height);
        applicationParameters.Set(NVSDK_NGX_Parameter_FrameTimeDeltaInMsec, 16.666667f);
        applicationParameters.Set(NVSDK_NGX_Parameter_MV_Scale_X, 1.0f);
        applicationParameters.Set(NVSDK_NGX_Parameter_MV_Scale_Y, 1.0f);
        auto consumer = DlssNr::StreamlinePicture::Consumer(gpu.swapchain.Get());
        consumer.identity.application = 1; consumer.identity.applicationKnown = true;
        Require(shader->ProcessSeam(gpu.commands.Get(), &applicationParameters, true, gpu.queue.Get(), false, 1,
            false, 0, consumer), "HOST_NEGATIVE_PRODUCTION_SEAM_NOT_REACHED");
        const auto rejected = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
        Require(rejected.state == DlssNr::OutputState::Skipped && rejected.reason == DlssNr::OutputReason::Admission &&
            !rejected.guidesValid && !rejected.evaluated && !rejected.executed && !rejected.submitted,
            "HOST_NEGATIVE_PRODUCTION_GUIDE_WAS_ADMITTED");
        Require((rejected.captureSerial != 0) == (options.guideContract != RuntimeOptions::GuideContract::Missing),
            "HOST_NEGATIVE_PRODUCTION_OWNERSHIP_NOT_OBSERVED");
        std::printf("HOST_NEGATIVE_PRODUCTION state=%u reason=%u guidesValid=0 evaluated=0 captureSerial=%llu\n",
            unsigned(rejected.state), unsigned(rejected.reason), rejected.captureSerial);
        gpu.Submit();
        DlssNr::SkipFinishedPicture(gpu.swapchain.Get());
        shader->FinishSubmitted();
        Require(shader->ReadyToDestroy(), "HOST_NEGATIVE_PRODUCTION_OWNERS_NOT_RETIRED");
        shader.reset();
        Require(gpu.captureLifetime.Idle(), "HOST_NEGATIVE_CAPTURE_OWNERS_NOT_RETIRED");
        Require(!NVNGXProxy::IsDx12Inited(), "HOST_NEGATIVE_PROVIDER_WAS_INITIALIZED");
        State::Instance().currentSwapchain = nullptr;
        State::Instance().swapchainApi = API::NotSelected;
        State::Instance().gameExe.clear();
        std::printf("HOST_NEGATIVE_CLOSURE shaderReadyToDestroy=1 captureIdle=1 providerInitialized=0\n");
        AssertForbiddenStartupUnused();
        AssertUnselectedProvidersUnused();
        throw std::runtime_error(options.guideContract == RuntimeOptions::GuideContract::Missing ? "HOST_GUIDE_MISSING" :
            options.guideContract == RuntimeOptions::GuideContract::ForeignDevice ? "HOST_FOREIGN_DEVICE" : "HOST_ADAPTER_MISMATCH");
    }
    auto capture = DlssNr::PipelineCaptureSession::Begin(options.fixtureRoot / (warp ? "warp-io" : "runtime-io"));
    Require(capture != nullptr, "HOST_CAPTURE_SESSION_FAILED");
    bool applied = false;
    unsigned frames = 0;
    try
    {
        if (!warp)
        {
            const auto paths = Util::GetDriverStore();
            const auto luid = gpu.device->GetAdapterLuid();
            const auto selected = paths.find({ luid.LowPart, luid.HighPart });
            Require(selected != paths.end(), "HOST_DRIVER_ADAPTER_PATH_MISSING");
            const auto driver = selected->second / L"_nvngx.dll";
            std::printf("HOST_DRIVER_SHA256=%s\n", FileSha256(driver).c_str());
            NVNGXProxy::OpenOwnedDriver(driver, options.runtimeRoot, options.fixtureRoot);
            Require(NVNGXProxy::InitDx12(gpu.device.Get()), "HOST_DRIVER_INIT_FAILED");
        }
        for (unsigned application = 1; application <= (warp ? 1u : 8u); ++application)
        {
            ComPtr<ID3D12Resource> picture;
            Hr(gpu.swapchain->GetBuffer(gpu.swapchain->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&picture)), "HOST_PICTURE_FAILED");
            Scene(gpu, application, picture.Get(), depth.Get(), motion.Get(), application == 1);
            Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_SOURCE);
            if (application > 1) Transition(gpu.commands.Get(), original.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
            gpu.commands->CopyResource(original.Get(), picture.Get());
            Transition(gpu.commands.Get(), original.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Transition(gpu.commands.Get(), picture.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
            applicationParameters.Set(NVSDK_NGX_Parameter_Color, original.Get());
            applicationParameters.Set(NVSDK_NGX_Parameter_Depth, depth.Get());
            applicationParameters.Set(NVSDK_NGX_Parameter_MotionVectors, motion.Get());
            applicationParameters.Set(NVSDK_NGX_Parameter_Output, picture.Get());
            applicationParameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, gpu.width);
            applicationParameters.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, gpu.height);
            applicationParameters.Set(NVSDK_NGX_Parameter_FrameTimeDeltaInMsec, 16.666667f);
            applicationParameters.Set(NVSDK_NGX_Parameter_MV_Scale_X, 1.0f);
            applicationParameters.Set(NVSDK_NGX_Parameter_MV_Scale_Y, 1.0f);
            applicationParameters.Set(NVSDK_NGX_Parameter_Reset, application == 1 ? 1u : 0u);
            auto consumer = DlssNr::StreamlinePicture::Consumer(gpu.swapchain.Get());
            Require(consumer.identity.Known() && DlssNr::StreamlinePicture::SameDevice(consumer.device.Get(), gpu.device.Get()), "HOST_CONSUMER_DEVICE_MISMATCH");
            consumer.identity.application = application; consumer.identity.applicationKnown = true;
            Require(shader->ProcessSeam(gpu.commands.Get(), &applicationParameters, true, gpu.queue.Get(), false, application,
                false, 0, consumer), "HOST_PRODUCTION_SEAM_REJECTED");
            const auto captured = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
            Require(captured.guidesValid && captured.captureSerial && captured.application == application, "HOST_GUIDE_ADMISSION_FAILED");
            gpu.Submit();
            if (!warp)
            {
                DlssNr::ApplyToFinishedPicture(gpu.swapchain.Get(), gpu.queue.Get());
                const auto status = DlssNr::ReadStatus(DlssNr::Backend::Dx12);
                std::printf("HOST_NR_OBSERVED application=%u state=%u reason=%u evaluated=%u composed=%u copyBack=%u executed=%u submitted=%u completionUnknown=%u captureSerial=%llu\n",
                    application, unsigned(status.output.state), unsigned(status.output.reason), unsigned(status.output.evaluated),
                    unsigned(status.output.composed), unsigned(status.output.copyBack), unsigned(status.output.executed),
                    unsigned(status.output.submitted), unsigned(status.output.completionUnknown), status.output.captureSerial);
                Require(status.failureReason.empty() && status.output.state != DlssNr::OutputState::Failed, "HOST_REAL_PROVIDER_FAILED");
                applied = status.output.Applied() && status.output.evaluated;
                if (applied) Require(status.output.state == DlssNr::OutputState::Submitted &&
                    status.output.reason == DlssNr::OutputReason::None && status.output.evaluated && !status.output.hidden &&
                    status.output.composed && status.output.copyBack && status.output.executed && status.output.submitted &&
                    !status.output.completionUnknown, "HOST_PRODUCTION_COMPOSITION_NOT_PROVEN");
            }
            const DlssNr::CaptureIdentity identity { reinterpret_cast<uintptr_t>(shader.get()),
                reinterpret_cast<uintptr_t>(consumer.identity.consumer), consumer.identity.generation, application, true };
            auto frame = capture->Admit(identity, gpu.captureLifetime, gpu.commands.Get());
            Require(frame != nullptr, "HOST_CAPTURE_ADMISSION_FAILED");
            frame->Copy(gpu.commands.Get(), gpu.device.Get(), "application_input", original.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            frame->Copy(gpu.commands.Get(), gpu.device.Get(), "depth", depth.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            frame->Copy(gpu.commands.Get(), gpu.device.Get(), "motion", motion.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            frame->Copy(gpu.commands.Get(), gpu.device.Get(), "final_output", picture.Get(), D3D12_RESOURCE_STATE_PRESENT);
            frame->Seal();
            gpu.Submit();
            Require(WaitForSingleObject(frame->retired, 30000) == WAIT_OBJECT_0 && frame->written, "HOST_CAPTURE_WRITE_FAILED");
            AssertPixels(*frame, application, gpu.width, gpu.height);
            Hr(gpu.swapchain->Present(0, 0), "HOST_PRESENT_FAILED");
            ++frames;
            if (applied || warp) break;
        }
        Require(warp || applied, "HOST_REAL_PROVIDER_BASELINE_NOT_APPLIED");
        capture->Stop();
        Require(WaitForSingleObject(capture->Exited(), 30000) == WAIT_OBJECT_0 && !capture->TimedOut() &&
            capture->Writes() == frames && capture->Discarded() == 0, "HOST_CAPTURE_WORKER_NOT_CLOSED");
        DlssNr::SkipFinishedPicture(gpu.swapchain.Get());
        shader->FinishSubmitted();
        Require(shader->ReadyToDestroy(), "HOST_PRODUCTION_OWNERS_NOT_RETIRED");
        shader.reset();
        capture.reset();
        Require(gpu.captureLifetime.Idle(), "HOST_CAPTURE_OWNERS_NOT_RETIRED");
        if (!warp) NVNGXProxy::CloseOwnedDriver();
        AssertUnselectedProvidersUnused();
        AssertForbiddenStartupUnused();
        State::Instance().currentSwapchain = nullptr;
        State::Instance().swapchainApi = API::NotSelected;
        State::Instance().gameExe.clear();
        std::printf("HOST_%s_PASS frames=%u providerCalls=%s completion=native_fence captureWorker=exited ownership=closed detourScope=owned_process_exit\n",
            warp ? "WARP_HANDOFF" : "REAL_BASELINE", frames, warp ? "none" : "real_driver_and_NR_runtime");
    }
    catch (...)
    {
        capture->Cancel();
        gpu.commands.Reset();
        const auto closed = WaitForSingleObject(capture->Exited(), 30000);
        std::fprintf(stderr, "HOST_FAILURE_CLOSURE captureWorker=%lu deviceRemoved=0x%08X nativeFence=%llu\n",
            closed, unsigned(gpu.device->GetDeviceRemovedReason()), gpu.fence->GetCompletedValue());
        throw;
    }
}
}
void RunWarpHost(const RuntimeOptions& options) { Run(options, true); }
void RunRuntimeHost(const RuntimeOptions& options)
{
    if (options.task15Candidate) RunCandidate(options);
    else Run(options, false);
}
}
