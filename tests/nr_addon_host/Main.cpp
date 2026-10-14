#include <pch.h>
#include "UiServices.h"
#include "Runtime.h"
#include "ForbiddenStartup.h"
#include <imgui/imgui.h>
#include <imgui/imgui_impl_dx11.h>
#include <imgui/imgui_impl_win32.h>
#include <menu/Localization.h>
#include <menu/menu_common.h>
#include <dlssnr/DlssNr_PlacementConfig.h>
#include <menu/input/input_system.h>
#include <imgui/imgui_internal.h>
#include <d3d11.h>
#include <d3d11_4.h>
#include <wrl/client.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

#ifndef OPTISCALER_NR_SELF_TEST
#error NRAddonHost entry must never enter a product build.
#endif

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

namespace NrAddonHost
{
void BeginPlacementEditFrame(Config& config);
void EndPlacementEditFrame(Config& config, const std::filesystem::path& root, bool drawn);
void AssertMenuGeometry(const ImGuiWindow& main, const ImGuiTable& table, const ImDrawData& draw,
                        const ImGuiWindow& nr);
}

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
    bool optionsContracts = false;
    bool startupContracts = false;
    bool missingMenuEntry = false;
    bool forbiddenStartup = false;
    bool geometryFixture = false;
    bool placementEditFixture = false;
    int width = 1280;
    int height = 900;
    float menuScale = 1.0f;
    bool lightTheme = false;
    std::string language = "en";
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
        else if (argument == L"--inject-missing-menu-entry")
            result.missingMenuEntry = true;
        else if (argument == L"--inject-forbidden-startup")
            result.forbiddenStartup = true;
        else if (argument == L"--geometry-fixture")
            result.geometryFixture = true;
        else if (argument == L"--placement-edit-fixture")
        {
            if (result.placementEditFixture)
                throw std::runtime_error("HOST_PLACEMENT_EDIT_MODE_REPEATED");
            result.placementEditFixture = true;
        }
        else if (argument == L"--ui-contracts")
            result.contracts = true;
        else if (argument == L"--ui-correction-contracts")
            result.contracts = result.placementContracts = true;
        else if (argument == L"--nr-options-contracts")
            result.contracts = result.optionsContracts = true;
        else if (argument == L"--startup-contracts")
            result.contracts = result.startupContracts = true;
        else if (argument == L"--runtime" || argument == L"--headless")
            throw std::runtime_error("HOST_MODE_UNSUPPORTED: Runtime is not implemented in early13.UiReady");
        else if (argument == L"--width" && i + 1 < argc)
            result.width = Dimension(argv[++i], 320, 4096);
        else if (argument == L"--height" && i + 1 < argc)
            result.height = Dimension(argv[++i], 256, 2160);
        else if (argument == L"--menu-scale" && i + 1 < argc)
        {
            const std::wstring_view scale = argv[++i];
            if (scale != L"0.75" && scale != L"1.0" && scale != L"1.5")
                throw std::runtime_error("--menu-scale must be 0.75, 1.0 or 1.5");
            result.menuScale = scale == L"0.75" ? 0.75f : scale == L"1.5" ? 1.5f : 1.0f;
        }
        else if (argument == L"--theme" && i + 1 < argc)
        {
            const std::wstring_view theme = argv[++i];
            if (theme != L"dark" && theme != L"light")
                throw std::runtime_error("--theme must be dark or light");
            result.lightTheme = theme == L"light";
        }
        else if (argument == L"--language" && i + 1 < argc)
        {
            const std::wstring_view language = argv[++i];
            if (language != L"en" && language != L"ko")
                throw std::runtime_error("--language must be en or ko");
            result.language = language == L"ko" ? "ko" : "en";
        }
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
    if (result.placementEditFixture && (!ui || result.contracts || result.geometryFixture ||
                                      result.missingMenuEntry || result.forbiddenStartup))
        throw std::runtime_error("HOST_PLACEMENT_EDIT_MODE_MIXED");
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
        if (context)
        {
            MenuCommon::Shutdown();
            context = false;
        }
        target.Reset();
        swapchain.Reset();
        completionContext.Reset();
        fence.Reset();
        if (fenceEvent)
        {
            CloseHandle(fenceEvent);
            fenceEvent = nullptr;
        }
        deviceContext.Reset();
        device.Reset();
        if (window && IsWindow(window))
            DestroyWindow(window);
        if (registered)
            UnregisterClassW(L"NRAddonHost.UiOnly", GetModuleHandleW(nullptr));
        std::printf("HOST_UI_CLEANUP remainingReferences=%u remainingWindow=%u remainingImGui=%u "
                    "remainingEvent=%u remainingBackends=%u remainingInput=%u remainingMenuOwner=%u\n",
                    unsigned(bool(target) || bool(swapchain) || bool(completionContext) || bool(fence) ||
                             bool(deviceContext) || bool(device)),
                    unsigned(window && IsWindow(window)), unsigned(ImGui::GetCurrentContext() != nullptr),
                    unsigned(fenceEvent != nullptr), unsigned(dxBackend),
                    unsigned(OptiInput::GetDebugState().Initialized), unsigned(MenuCommon::Handle() != nullptr));
        std::fflush(stdout);
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
        ComPtr<ID3D11Device5> completionDevice;
        Check(device.As(&completionDevice), "owned D3D11 completion device");
        Check(deviceContext.As(&completionContext), "owned D3D11 completion context");
        Check(completionDevice->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)),
              "owned D3D11 completion fence");
        fenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!fenceEvent)
            throw std::runtime_error("owned D3D11 completion event failed");
        std::printf("HOST_UI_OWNED_QUEUE device=%p context=%p swapchain=%p fence=%p event=%p\n",
                    device.Get(), completionContext.Get(), swapchain.Get(), fence.Get(), fenceEvent);
        services.Configuration()->Language = options.language;
        services.Configuration()->MenuScale = options.menuScale;
        services.Configuration()->LightTheme = options.lightTheme;
        services.Configuration()->DisableSplash = true;
        services.Configuration()->ShowFps = false;
        placementEditFixture = options.placementEditFixture;
        placementFixtureRoot = options.root;
        geometryFixture = options.geometryFixture || placementEditFixture;
        if (geometryFixture)
        {
            CSimpleIniA fixture;
            if (fixture.LoadFile((options.root / "owned-fixture.ini").c_str()) != SI_OK)
                throw std::runtime_error("HOST_MENU_GEOMETRY_FIXTURE_INPUT_MISSING");
            // Select seeded these values; the fixture loader only initializes unset optionals.
            services.Configuration()->DlssNrRunBeforeSr.reset();
            services.Configuration()->DlssNrFinishedPicture.reset();
            services.Configuration()->DlssNrDeferredDlss.reset();
            services.Configuration()->DlssNrResidualAcrossRr.reset();
            services.Configuration()->DlssNrAutomaticUICorrection.reset();
            DlssNr::LoadPlacementConfig(*services.Configuration(), fixture);
            DlssNr::LoadOptionsConfig(*services.Configuration(), fixture);
            fixtureConfig = FixtureConfig();
        }
        if (options.forbiddenStartup)
            services.Configuration()->SaveIni();
        if (!options.missingMenuEntry)
        {
            MenuCommon::Init(window, false);
            context = true;
        }
        if (!MenuCommon::IsInited() || MenuCommon::Handle() != window || !ImGui::GetCurrentContext())
            throw std::runtime_error("HOST_PRODUCTION_MENU_ENTRY_MISSING");
        Localization::SetLanguage(options.language);
        std::printf("HOST_UI_LANGUAGE requested=%s effective=%s fonts=%d sources=%d productionInit=1\n",
                    options.language.c_str(), Localization::EffectiveLanguageCode(),
                    ImGui::GetIO().Fonts->Fonts.Size, ImGui::GetIO().Fonts->Fonts[0]->Sources.Size);
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
        RetireQueue();
    }

  private:
    void RetireQueue()
    {
        // Arm the exact fence event before submitting its completion signal.
        // Native QA teardown observes queue retirement, never a timed sleep.
        const auto value = ++fenceValue;
        Check(fence->SetEventOnCompletion(value, fenceEvent), "owned fence event registration");
        std::printf("HOST_UI_FENCE_ARMED fence=%p event=%p value=%llu\n", fence.Get(), fenceEvent, value);
        Check(completionContext->Signal(fence.Get(), value), "owned context completion Signal");
        if (WaitForSingleObject(fenceEvent, 30000) != WAIT_OBJECT_0)
            throw std::runtime_error("owned completion fence event missing");
        std::printf("HOST_UI_FENCE_RETIRED value=%llu remainingPendingSignals=%u\n",
                    fence->GetCompletedValue(), unsigned(fence->GetCompletedValue() < value));
        std::fflush(stdout);
    }

    NrAddonHost::UiServices& services;
    HWND window = nullptr;
    bool registered = false;
    bool context = false;
    bool dxBackend = false;
    unsigned paintFrames = 2;
    std::string error;
    bool productionDraw = false;
    bool geometryFixture = false;
    bool placementEditFixture = false;
    std::string fixtureConfig;
    std::filesystem::path placementFixtureRoot;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> deviceContext;
    ComPtr<IDXGISwapChain> swapchain;
    ComPtr<ID3D11RenderTargetView> target;
    ComPtr<ID3D11DeviceContext4> completionContext;
    ComPtr<ID3D11Fence> fence;
    HANDLE fenceEvent = nullptr;
    UINT64 fenceValue = 0;

    void CreateTarget()
    {
        ComPtr<ID3D11Texture2D> buffer;
        Check(swapchain->GetBuffer(0, IID_PPV_ARGS(&buffer)), "GetBuffer");
        Check(device->CreateRenderTargetView(buffer.Get(), nullptr, &target), "CreateRenderTargetView");
    }

    ImGuiWindow* MainWindow() const
    {
        for (auto* candidate : ImGui::GetCurrentContext()->Windows)
            if (!candidate->ParentWindow && std::strstr(candidate->Name, "NRAddonHost.fixture"))
                return candidate;
        return nullptr;
    }

    ImGuiWindow* NrWindow(const ImGuiWindow& main) const
    {
        const auto tableId = ImHashStr("main", 0, main.ID);
        const auto id = ImHashStr("##CollapsingHeaderChild", 0, ImHashStr("DLSS Neural Rendering", 0, tableId));
        for (auto* candidate : ImGui::GetCurrentContext()->Windows)
            if (candidate->ParentWindow == &main && candidate->ChildId == id)
                return candidate;
        return nullptr;
    }

    std::string FixtureConfig() const
    {
        CSimpleIniA fixture;
        DlssNr::SavePlacementConfig(*services.Configuration(), fixture);
        DlssNr::SaveOptionsConfig(*services.Configuration(), fixture);
        std::string bytes;
        if (fixture.Save(bytes) < 0)
            throw std::runtime_error("HOST_MENU_GEOMETRY_CONFIG_SERIALIZATION_FAILED");
        return bytes;
    }

    void TraceOwnedViewport(const char* stage, UINT message = 0, WPARAM wparam = 0, LPARAM lparam = 0)
    {
        if (!geometryFixture)
            return;
        RECT client {}, bounds {}, suggested {};
        const BOOL clientRead = GetClientRect(window, &client);
        const BOOL boundsRead = GetWindowRect(window, &bounds);
        if (message == WM_DPICHANGED && lparam)
            suggested = *reinterpret_cast<const RECT*>(lparam);
        std::printf("HOST_OWNED_VIEWPORT stage=%s hwnd=%p thread=%lu message=%u wp=%llu lp=%lld "
                    "clientRead=%u client=%ld,%ld,%ld,%ld windowRead=%u window=%ld,%ld,%ld,%ld "
                    "dpi=%u windowContext=%p threadContext=%p suggested=%ld,%ld,%ld,%ld frame=%d\n",
                    stage, static_cast<void*>(window), GetCurrentThreadId(), message,
                    static_cast<unsigned long long>(wparam), static_cast<long long>(lparam),
                    unsigned(clientRead), client.left, client.top, client.right, client.bottom,
                    unsigned(boundsRead), bounds.left, bounds.top, bounds.right, bounds.bottom,
                    GetDpiForWindow(window), static_cast<void*>(GetWindowDpiAwarenessContext(window)),
                    static_cast<void*>(GetThreadDpiAwarenessContext()),
                    suggested.left, suggested.top, suggested.right, suggested.bottom,
                    ImGui::GetCurrentContext() ? ImGui::GetFrameCount() : -1);
        std::fflush(stdout);
    }

    void Render()
    {
        if (!dxBackend || IsIconic(window))
            return;
        TraceOwnedViewport("render-before");
        ImGui_ImplDX11_NewFrame();
        services.Publish();
        const auto& state = State::Instance();
        if (state.activeFgInput != FGInput::NoFG || state.activeFgOutput != FGOutput::NoFG ||
            state.currentFeature || state.currentFGSwapchain)
            NrAddonHost::ForbidProviderStartup();
        productionDraw = false;
        if (placementEditFixture)
            NrAddonHost::BeginPlacementEditFrame(*services.Configuration());
        const bool frame = MenuCommon::RenderMenu();
        if (placementEditFixture)
            NrAddonHost::EndPlacementEditFrame(*services.Configuration(), placementFixtureRoot, frame);
        TraceOwnedViewport("render-after");
        if (frame)
            ImGui::Render();
        constexpr float background[] = { 0.08f, 0.08f, 0.08f, 1.0f };
        ID3D11RenderTargetView* view = target.Get();
        deviceContext->OMSetRenderTargets(1, &view, nullptr);
        deviceContext->ClearRenderTargetView(view, background);
        if (frame)
        {
            auto* draw = ImGui::GetDrawData();
            ImGui_ImplDX11_RenderDrawData(draw);
            auto* g = ImGui::GetCurrentContext();
            ImGuiWindow* main = MainWindow();
            const auto* table = main ? ImGui::TableFindByID(ImHashStr("main", 0, main->ID)) : nullptr;
            productionDraw = main && main->LastFrameActive == g->FrameCount && table &&
                             table->LastFrameActive == g->FrameCount && draw->TotalVtxCount > 0;
            // Native QA observes the actual production window and table draw
            // after message-delivered input, never a substitute fixture window.
            std::printf("HOST_PRODUCTION_MENU_FRAME visible=%u windows=%d tables=%d vertices=%d indices=%d\n",
                        unsigned(MenuCommon::IsVisible()), ImGui::GetCurrentContext()->Windows.Size,
                        ImGui::GetCurrentContext()->Tables.GetAliveCount(), draw->TotalVtxCount, draw->TotalIdxCount);
            if (productionDraw)
            {
                std::printf("HOST_PRODUCTION_MAIN_TABLE window=%08X table=%08X columns=%d size=%.1f,%.1f\n",
                            main->ID, table->ID, table->ColumnsCount, main->Size.x, main->Size.y);
                const auto* nr = NrWindow(*main);
                std::printf("HOST_MENU_GEOMETRY frame=%d display=%.1f,%.1f pos=%.1f,%.1f size=%.1f,%.1f "
                            "scroll=%.1f,%.1f max=%.1f,%.1f scale=%.2f font=%.1f flags=%u "
                            "mainVertices=%d nrVertices=%d nrPos=%.1f,%.1f nrSize=%.1f,%.1f\n",
                            g->FrameCount, g->IO.DisplaySize.x, g->IO.DisplaySize.y,
                            main->Pos.x, main->Pos.y, main->Size.x, main->Size.y,
                            main->Scroll.x, main->Scroll.y, main->ScrollMax.x, main->ScrollMax.y,
                            services.Configuration()->MenuScale.value_or(1.0f), main->FontRefSize,
                            unsigned(main->Flags), main->DrawList->VtxBuffer.Size,
                            nr ? nr->DrawList->VtxBuffer.Size : 0,
                            nr ? nr->Pos.x : 0, nr ? nr->Pos.y : 0, nr ? nr->Size.x : 0, nr ? nr->Size.y : 0);
            }
        }
        Check(swapchain->Present(0, 0), "fixture window Present");
        if (geometryFixture && !placementEditFixture)
        {
            if (FixtureConfig() != fixtureConfig)
                throw std::runtime_error("TASK5_GEOMETRY_CHANGED_NR_CONFIG");
            std::printf("HOST_MENU_FIXTURE_CONFIG_UNCHANGED bytes=%zu loadedOwnedFixture=1 liveSaveIni=0\n",
                        fixtureConfig.size());
        }
        std::fflush(stdout);
        // Finite follow-up frames consume queued input transitions and resolve
        // newly opened sections. They are not a timed readiness wait.
        if (paintFrames && --paintFrames)
            InvalidateRect(window, nullptr, FALSE);
    }

    LRESULT Message(UINT message, WPARAM wparam, LPARAM lparam)
    {
        if (message == WM_SIZE || message == WM_DPICHANGED)
            TraceOwnedViewport("message", message, wparam, lparam);
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
        if (message == WM_APP + 4)
        {
            const auto* config = services.Configuration();
            const auto status = DlssNr::ReadStatus(DlssNr::Backend::Dx12);
            const auto options = DlssNr::ResolveOptions(config->DlssNrInputFilter.value_or_default(),
                config->DlssNrSignalEncoding.value_or_default(), status.output.optionContext,
                status.output.inputFilter, status.output.signalEncoding,
                status.output.inputFilterOverrideSupported, status.output.signalEncodingOverrideSupported);
            return unsigned(options.requestedFilter) | (unsigned(options.requestedSignal) << 2) |
                   (unsigned(options.filterSelectable) << 4) | (unsigned(options.signalSelectable) << 5) |
                   (unsigned(options.effectiveFilter) << 6) | (unsigned(options.effectiveSignal) << 8) |
                   (unsigned(options.filterSupported) << 10) | (unsigned(options.signalSupported) << 11);
        }
        if (message == WM_APP + 5)
            return unsigned(MenuCommon::IsInited()) | (unsigned(MenuCommon::IsVisible()) << 1) |
                   (unsigned(OptiInput::GetDebugState().Initialized) << 2);
        if (message == WM_APP + 6)
            return unsigned(productionDraw);
        if (message == WM_APP + 7)
        {
            RetireQueue();
            ImGui_ImplDX11_Shutdown();
            dxBackend = false;
            MenuCommon::Shutdown();
            context = false;
            if (ImGui::GetCurrentContext() || MenuCommon::Handle() ||
                OptiInput::GetDebugState().Initialized || OptiInput::IsKeyDown('A') ||
                OptiInput::GetLastPressedKey())
                throw std::runtime_error("HOST_CONTEXT_RESET_OWNER_REMAINED");
            std::puts("HOST_CONTEXT_RESET_CLOSED context=0 platform=0 renderer=0 input=0 keys=0");
            MenuCommon::Init(window, false);
            context = true;
            Localization::SetLanguage(services.Configuration()->Language.value_or_default());
            ImGui::GetIO().BackendFlags &= ~ImGuiBackendFlags_HasMouseHoveredViewport;
            dxBackend = ImGui_ImplDX11_Init(device.Get(), deviceContext.Get());
            if (!dxBackend)
                throw std::runtime_error("HOST_CONTEXT_RESET_RENDERER_FAILED");
            paintFrames = 2;
            Render();
            std::printf("HOST_CONTEXT_RESET_RECREATED visible=%u input=%u language=%s\n",
                        unsigned(MenuCommon::IsVisible()), unsigned(OptiInput::GetDebugState().Initialized),
                        Localization::EffectiveLanguageCode());
            return 1;
        }
        if (message == WM_APP + 8)
            return unsigned(OptiInput::IsKeyDown('A')) | (unsigned(OptiInput::GetLastPressedKey() != 0) << 1);
        if (message == WM_APP + 9)
        {
            NrAddonHost::AssertBackendInputUnused();
            return 0;
        }
        if (message == WM_APP + 10)
        {
            // Retire submitted rendering before deliberately reaching a refused
            // backend call. This exercises the real frame or message path.
            RetireQueue();
            NrAddonHost::backendPollingSensitivity = true;
            if (lparam)
                ImGui_ImplWin32_WndProcHandler(window, WM_KEYDOWN, VK_CONTROL, 1 << 16);
            else
                ImGui_ImplWin32_NewFrame();
            throw std::runtime_error("HOST_BACKEND_SENSITIVITY_DID_NOT_REFUSE");
        }
        if (message == WM_APP + 11)
        {
            const auto& io = ImGui::GetIO();
            return unsigned(io.KeyCtrl) | (unsigned(io.KeyShift) << 1) |
                   (unsigned(io.KeyAlt) << 2) | (unsigned(io.KeySuper) << 3) |
                   (unsigned(ImGui::IsKeyDown(ImGuiKey_LeftCtrl)) << 4) |
                   (unsigned(ImGui::IsKeyDown(ImGuiKey_RightShift)) << 5);
        }
        if (message == WM_APP + 12)
        {
            const auto* main = MainWindow();
            if (!main)
                throw std::runtime_error("HOST_MENU_GEOMETRY_WINDOW_MISSING");
            const auto* nr = NrWindow(*main);
            if (!nr)
                throw std::runtime_error("HOST_MENU_GEOMETRY_NR_MISSING");
            const float values[] = {
                main->Pos.x, main->Pos.y, main->Size.x, main->Size.y,
                main->Scroll.x, main->Scroll.y, main->ScrollMax.x, main->ScrollMax.y,
                nr->Pos.x, nr->Pos.y, nr->Size.x, nr->Size.y, float(nr->DrawList->VtxBuffer.Size),
                main->FontRefSize, services.Configuration()->MenuScale.value_or(1.0f),
                float(main->DrawList->VtxBuffer.Size), ImGui::GetIO().DisplaySize.x, ImGui::GetIO().DisplaySize.y
            };
            if (wparam >= std::size(values))
                throw std::runtime_error("HOST_MENU_GEOMETRY_FIELD_REFUSED");
            return static_cast<LRESULT>(std::lround(values[wparam] * 1000.0f));
        }
        if (message == WM_APP + 13)
        {
            if (wparam != 75 && wparam != 100 && wparam != 150)
                throw std::runtime_error("HOST_MENU_GEOMETRY_SCALE_REFUSED");
            services.Configuration()->MenuScale = float(wparam) / 100.0f;
            return 1;
        }
        if (message == WM_APP + 14)
        {
            // Sensitivity: restore the old actual ImGui 1x1 reset, then let
            // production frames expose the resulting loss of session size.
            auto* main = MainWindow();
            if (!main)
                throw std::runtime_error("HOST_MENU_GEOMETRY_WINDOW_MISSING");
            ImGui::SetWindowSize(main, ImVec2(1.0f, 1.0f), ImGuiCond_Always);
            std::puts("HOST_MENU_GEOMETRY_RESET_INJECTED actualWindow=1 size=1,1");
            return 1;
        }
        if (message == WM_APP + 15)
        {
            RetireQueue();
            const auto* main = MainWindow();
            const auto* table = main ? ImGui::TableFindByID(ImHashStr("main", 0, main->ID)) : nullptr;
            const auto* nr = main ? NrWindow(*main) : nullptr;
            const auto* draw = ImGui::GetDrawData();
            if (!main || !table || !nr || !draw)
                throw std::runtime_error("HOST_MENU_GEOMETRY_PRODUCTION_DRAW_MISSING");
            NrAddonHost::AssertMenuGeometry(*main, *table, *draw, *nr);
            return 1;
        }
        if (message == WM_APP + 16)
        {
            auto* main = MainWindow();
            if (!geometryFixture || !main)
                throw std::runtime_error("HOST_FOOTER_OBSERVATION_REFUSED");
            const auto& g = *ImGui::GetCurrentContext();
            const ImGuiID ids[] = { g.HoveredId, g.HoveredWindow ? g.HoveredWindow->ID : 0,
                                   main->ID, main->GetID("##Language"),
                                   main->GetID("Save Settings"), main->GetID("Close") };
            if (wparam < std::size(ids))
                return static_cast<LRESULT>(ids[wparam]);
            if (wparam == 6)
                return static_cast<LRESULT>(g.FrameCount);
            const float clip[] = { main->InnerClipRect.Min.x, main->InnerClipRect.Min.y,
                                   main->InnerClipRect.Max.x, main->InnerClipRect.Max.y };
            if (wparam >= 7 && wparam < 7 + std::size(clip))
                return static_cast<LRESULT>(std::lround(clip[wparam - 7] * 1000.0f));
            throw std::runtime_error("HOST_FOOTER_OBSERVATION_FIELD_REFUSED");
        }
        if (message == WM_APP + 17)
        {
            auto* main = MainWindow();
            if (!geometryFixture || !main || !wparam || lparam <= 0 ||
                wparam > ImGui::GetIO().DisplaySize.x || lparam > ImGui::GetIO().DisplaySize.y)
                throw std::runtime_error("HOST_FOOTER_VIEW_FOOTPRINT_REFUSED");
            // Footer-only view setup uses already qualified main dimensions.
            // It does not replay or assert grip, scale, or reset behavior.
            ImGui::SetWindowSize(main, ImVec2(float(wparam), float(lparam)), ImGuiCond_Always);
            return 1;
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
        if (dxBackend && (message == WM_KEYDOWN || message == WM_KEYUP) &&
            wparam >= VK_F1 && wparam <= VK_F11)
        {
            if (message == WM_KEYDOWN)
            {
                services.Select(static_cast<NrAddonHost::Fixture>(wparam - VK_F1));
                paintFrames = 2;
                InvalidateRect(window, nullptr, FALSE);
            }
            // Owned fixture commands must not activate the Win32 F10 menu loop.
            return 0;
        }
        if (dxBackend && message == WM_PAINT)
        {
            PAINTSTRUCT paint {};
            BeginPaint(window, &paint);
            EndPaint(window, &paint);
            Render();
            return 0;
        }
        if (context)
        {
            // Keep both modifier sides in the existing owned input owner.
            // Windows sends generic virtual keys with the side in lParam.
            WPARAM ownedKey = wparam;
            if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)
            {
                if (wparam == VK_SHIFT)
                    ownedKey = LOBYTE(HIWORD(lparam)) == 0x36 ? VK_RSHIFT : VK_LSHIFT;
                else if (wparam == VK_CONTROL)
                    ownedKey = (lparam & (1 << 24)) ? VK_RCONTROL : VK_LCONTROL;
                else if (wparam == VK_MENU)
                    ownedKey = (lparam & (1 << 24)) ? VK_RMENU : VK_LMENU;
            }
            OptiInput::OwnedMessage(window, message, ownedKey, lparam);
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
        unsigned uiModes = 0, runtimeModes = 0;
        for (int i = 1; i < argc; ++i)
        {
            const std::wstring_view argument = argv[i];
            uiModes += argument == L"--ui-only" || argument == L"--ui-contracts" ||
                       argument == L"--ui-correction-contracts" || argument == L"--nr-options-contracts" ||
                       argument == L"--startup-contracts";
            runtimeModes += argument == L"--runtime" || argument == L"--host-contracts" ||
                            argument == L"--warp-handoff";
        }
        if (uiModes > 1 || runtimeModes > 1 || (uiModes && runtimeModes))
            throw std::runtime_error("HOST_MIXED_MODE_REFUSED_BEFORE_DISPATCH");
        if (const auto result = NrAddonHost::TryRunHost(argc, argv))
            return *result;
        const auto options = Parse(argc, argv);
        if (options.contracts)
        {
            if (options.startupContracts)
                NrAddonHost::RunStartupContracts();
            else if (options.optionsContracts)
                NrAddonHost::RunOptionsContracts(options.root);
            else if (options.placementContracts)
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
        NrAddonHost::AssertBackendInputUnused();
        NrAddonHost::AssertForbiddenStartupUnused();
        return 0;
    }
    catch (const std::exception& exception)
    {
        std::fprintf(stderr, "HOST_ERROR=%s\n", exception.what());
        std::printf("HOST_STARTUP_FAILURE_OBSERVED menu=%u configSave=%u provider=%u gpuDiscovery=%u\n",
                    NrAddonHost::forbiddenMenuStartup.load(), NrAddonHost::forbiddenConfigSave.load(),
                    NrAddonHost::forbiddenProviderStartup.load(), NrAddonHost::forbiddenGpuDiscovery.load());
        return 1;
    }
}
