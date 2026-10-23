#include <pch.h>
#include "UiServices.h"
#include <imgui/imgui.h>
#include <imgui/imgui_impl_dx11.h>
#include <imgui/imgui_impl_win32.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

#ifndef OPTISCALER_NR_SELF_TEST
#error NRAddonHost entry must never enter a product build.
#endif

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace
{
using Microsoft::WRL::ComPtr;

void Check(HRESULT result, const char* operation)
{
    if (FAILED(result))
    {
        std::fprintf(stderr, "HOST_UI_ERROR=%s HRESULT=0x%08lX\n", operation, static_cast<unsigned long>(result));
        throw std::runtime_error(operation);
    }
}

struct Options
{
    bool contracts = false;
    bool placementContracts = false;
    int width = 1280;
    int height = 900;
    NrAddonHost::Fixture fixture = NrAddonHost::Fixture::Before4;
    std::filesystem::path root;
};

int Dimension(const wchar_t* text, int minimum, int maximum)
{
    wchar_t* end = nullptr;
    errno = 0;
    const long value = std::wcstol(text, &end, 10);
    if (errno || end == text || *end || value < minimum || value > maximum)
        throw std::runtime_error("invalid window dimension");
    return static_cast<int>(value);
}

Options Parse(int argc, wchar_t** argv)
{
    Options result;
    bool ui = false;
    for (int i = 1; i < argc; ++i)
    {
        const std::wstring_view argument = argv[i];
        if (argument == L"--ui-only")
            ui = true;
        else if (argument == L"--ui-contracts")
            result.contracts = true;
        else if (argument == L"--ui-correction-contracts")
            result.contracts = result.placementContracts = true;
        else if (argument == L"--runtime" || argument == L"--headless")
            throw std::runtime_error("HOST_MODE_UNSUPPORTED: Runtime is not implemented in early13.UiReady");
        else if (argument == L"--width" && i + 1 < argc)
            result.width = Dimension(argv[++i], 320, 4096);
        else if (argument == L"--height" && i + 1 < argc)
            result.height = Dimension(argv[++i], 256, 2160);
        else if (argument == L"--fixture" && i + 1 < argc)
        {
            if (!NrAddonHost::ParseFixture(argv[++i], result.fixture))
                throw std::runtime_error("unknown fixture case");
        }
        else if (argument == L"--fixture-root" && i + 1 < argc)
            result.root = argv[++i];
        else
            throw std::runtime_error("unknown or incomplete host argument");
    }
    if (!ui && !result.contracts)
        throw std::runtime_error("HOST_MODE_UNSUPPORTED: specify --ui-only; Runtime is not implemented");
    if (!result.root.is_absolute() || !std::filesystem::is_directory(result.root))
        throw std::runtime_error("--fixture-root must name an existing absolute task-owned directory");
    return result;
}

class UiWindow
{
  public:
    explicit UiWindow(NrAddonHost::UiServices& services) : services(services) {}
    ~UiWindow()
    {
        if (dxBackend)
        {
            ImGui_ImplDX11_Shutdown();
            dxBackend = false;
        }
        if (winBackend)
        {
            ImGui_ImplWin32_Shutdown();
            winBackend = false;
        }
        if (context)
        {
            ImGui::DestroyContext();
            context = false;
        }
        target.Reset();
        swapchain.Reset();
        deviceContext.Reset();
        device.Reset();
        if (window && IsWindow(window))
            DestroyWindow(window);
        if (registered)
            UnregisterClassW(L"NRAddonHost.UiOnly", GetModuleHandleW(nullptr));
    }

    void Open(const Options& options)
    {
        ImGui_ImplWin32_EnableDpiAwareness();
        WNDCLASSEXW wc { sizeof(wc) };
        wc.style = CS_CLASSDC;
        wc.lpfnWndProc = Procedure;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
        wc.lpszClassName = L"NRAddonHost.UiOnly";
        if (!RegisterClassExW(&wc))
            throw std::runtime_error("RegisterClassExW failed");
        registered = true;
        RECT rect { 0, 0, options.width, options.height };
        if (!AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0))
            throw std::runtime_error("AdjustWindowRectEx failed");
        window = CreateWindowExW(0, wc.lpszClassName, L"NRAddonHost - FIXTURE DATA - UI only - WARP",
                                 WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                 rect.right - rect.left, rect.bottom - rect.top, nullptr, nullptr, wc.hInstance, this);
        if (!window)
            throw std::runtime_error("CreateWindowExW failed");
        DXGI_SWAP_CHAIN_DESC desc {};
        desc.BufferCount = 2;
        desc.BufferDesc.Width = options.width;
        desc.BufferDesc.Height = options.height;
        desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.OutputWindow = window;
        desc.SampleDesc.Count = 1;
        desc.Windowed = TRUE;
        desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
        D3D_FEATURE_LEVEL level;
        // Never enumerate or initialize a physical adapter in UI-only mode.
        Check(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, nullptr, 0,
                                          D3D11_SDK_VERSION, &desc, &swapchain, &device, &level, &deviceContext),
              "D3D11 WARP device");
        CreateTarget();
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        context = true;
        ImGui::GetIO().IniFilename = nullptr;
        ImGui::GetIO().LogFilename = nullptr;
        ImGui::StyleColorsDark();
        winBackend = ImGui_ImplWin32_Init(window);
        if (!winBackend)
            throw std::runtime_error("ImGui Win32 initialization failed");
        // This owned host has one viewport. Infer it from its Win32 messages,
        // not the user's global cursor, so QA never moves the desktop pointer.
        ImGui::GetIO().BackendFlags &= ~ImGuiBackendFlags_HasMouseHoveredViewport;
        dxBackend = ImGui_ImplDX11_Init(device.Get(), deviceContext.Get());
        if (!dxBackend)
            throw std::runtime_error("ImGui DX11 initialization failed");
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
        Render();
        RECT client {};
        GetClientRect(window, &client);
        std::printf("HOST_UI_READY hwnd=%p width=%ld height=%ld fixture=%s renderer=WARP\n",
                    static_cast<void*>(window), client.right, client.bottom,
                    NrAddonHost::FixtureName(services.Selected()));
        std::fflush(stdout);
    }

    void Run()
    {
        MSG message {};
        BOOL result;
        while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0)
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
            if (!error.empty())
                throw std::runtime_error(error);
        }
        if (result == -1)
            throw std::runtime_error("GetMessageW failed");
        if (!error.empty())
            throw std::runtime_error(error);
    }

  private:
    NrAddonHost::UiServices& services;
    HWND window = nullptr;
    bool registered = false;
    bool context = false;
    bool winBackend = false;
    bool dxBackend = false;
    unsigned paintFrames = 2;
    std::string error;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> deviceContext;
    ComPtr<IDXGISwapChain> swapchain;
    ComPtr<ID3D11RenderTargetView> target;

    void CreateTarget()
    {
        ComPtr<ID3D11Texture2D> buffer;
        Check(swapchain->GetBuffer(0, IID_PPV_ARGS(&buffer)), "GetBuffer");
        Check(device->CreateRenderTargetView(buffer.Get(), nullptr, &target), "CreateRenderTargetView");
    }

    void Render()
    {
        if (!dxBackend || IsIconic(window))
            return;
        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
        ImGui::Begin("NR fixture", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                     ImGuiWindowFlags_NoSavedSettings);
        ImGui::TextWrapped("FIXTURE DATA - UI ONLY - no NGX, model evaluation or applied-output proof.");
        ImGui::TextWrapped("Case: %s. F1/F2: before4/2; F3/F4: post4/2; F5: no-runtime; F6: failure.",
                           NrAddonHost::FixtureName(services.Selected()));
        ImGui::Separator();
        services.Publish();
        DlssNr::RenderMenu(services.Configuration(), 1.0f);
        ImGui::End();
        ImGui::Render();
        constexpr float background[] = { 0.08f, 0.08f, 0.08f, 1.0f };
        ID3D11RenderTargetView* view = target.Get();
        deviceContext->OMSetRenderTargets(1, &view, nullptr);
        deviceContext->ClearRenderTargetView(view, background);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        Check(swapchain->Present(0, 0), "fixture window Present");
        // Finite follow-up frames consume queued input transitions and resolve
        // newly opened sections. They are not a timed readiness wait.
        if (paintFrames && --paintFrames)
            InvalidateRect(window, nullptr, FALSE);
    }

    LRESULT Message(UINT message, WPARAM wparam, LPARAM lparam)
    {
        // Global cursor tracking may enqueue leave while QA sends messages to
        // this sole owned viewport. Keep its message-delivered position until
        // another owned move; never move or consult the user's pointer for QA.
        if (message == WM_MOUSELEAVE)
            return 0;
        if (message == WM_APP + 3)
        {
            const auto* config = services.Configuration();
            return unsigned(config->DlssNrRunBeforeSr.value_or_default()) |
                   (unsigned(config->DlssNrFinishedPicture.value_or_default()) << 1) |
                   (unsigned(config->DlssNrDeferredDlss.value_or_default()) << 2) |
                   (unsigned(config->DlssNrResidualAcrossRr.value_or_default()) << 3) |
                   (unsigned(config->DlssNrAutomaticUICorrection.value_or_default()) << 4);
        }
        if (message == WM_CLOSE)
        {
            DestroyWindow(window);
            return 0;
        }
        if (message == WM_DESTROY)
        {
            PostQuitMessage(0);
            return 0;
        }
        if (dxBackend && message == WM_SIZE && wparam != SIZE_MINIMIZED)
        {
            deviceContext->OMSetRenderTargets(0, nullptr, nullptr);
            target.Reset();
            Check(swapchain->ResizeBuffers(0, LOWORD(lparam), HIWORD(lparam), DXGI_FORMAT_UNKNOWN, 0),
                  "ResizeBuffers");
            CreateTarget();
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }
        if (dxBackend && message == WM_KEYDOWN && wparam >= VK_F1 && wparam <= VK_F6)
            services.Select(static_cast<NrAddonHost::Fixture>(wparam - VK_F1));
        if (dxBackend && message == WM_PAINT)
        {
            PAINTSTRUCT paint {};
            BeginPaint(window, &paint);
            EndPaint(window, &paint);
            Render();
            return 0;
        }
        const bool handled = context && ImGui_ImplWin32_WndProcHandler(window, message, wparam, lparam);
        if (dxBackend && ((message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) ||
                          (message >= WM_KEYFIRST && message <= WM_KEYLAST)))
        {
            paintFrames = 2;
            InvalidateRect(window, nullptr, FALSE);
        }
        if (handled)
            return 1;
        return DefWindowProcW(window, message, wparam, lparam);
    }

    static LRESULT CALLBACK Procedure(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
    {
        auto* self = reinterpret_cast<UiWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (message == WM_NCCREATE)
        {
            self = static_cast<UiWindow*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
            self->window = hwnd;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (!self)
            return DefWindowProcW(hwnd, message, wparam, lparam);
        try
        {
            return self->Message(message, wparam, lparam);
        }
        catch (const std::exception& exception)
        {
            self->error = exception.what();
            PostQuitMessage(1);
            return 0;
        }
    }
};
} // namespace

int wmain(int argc, wchar_t** argv)
{
    try
    {
        const auto options = Parse(argc, argv);
        if (options.contracts)
        {
            if (options.placementContracts)
                NrAddonHost::RunPlacementContracts(options.root);
            else
                NrAddonHost::RunUiContracts(options.root);
            return 0;
        }
        {
            NrAddonHost::UiServices services(options.root);
            services.Select(options.fixture);
            UiWindow window(services);
            window.Open(options);
            window.Run();
        }
        std::puts("HOST_UI_CLOSED=owned-window-device-context-status-released");
        return 0;
    }
    catch (const std::exception& exception)
    {
        std::fprintf(stderr, "HOST_ERROR=%s\n", exception.what());
        return 1;
    }
}
