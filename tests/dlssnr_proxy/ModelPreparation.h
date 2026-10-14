#pragma once

// Allocation/frame/state adapters only. The runner includes the complete actual
// production Models.cpp body, not a substitute preparation/equality algorithm.
#ifndef NR_FILTER_INTEGRATION
struct D3D12_RESOURCE_DESC { unsigned long long Width; unsigned Height; unsigned Format; };
namespace DlssNr
{
constexpr unsigned MaxPassCount = 30;
struct ColorExtent { unsigned width, height; };
}
#endif
using DlssNr::Profiles::PassSettings;
#ifdef NR_FILTER_INTEGRATION
#include "FilterIntegrationState.h"
#else
struct DlssNr_Dx12
{
    struct State
    {
        struct ModelState
        {
            DlssNr::Proxy::Context models[30];
            DlssNr::ModelSettings builtSettings[30];
            bool passCreateFailed[30] {};
            unsigned width = 0, height = 0, workWidth = 0, workHeight = 0;
            bool beforeUpscale = false, finishedPicture = false, rayReconstruction = false, reset = true;
            bool passScratchFailed = false, failed = false;
            unsigned effectiveInputFilter = 0;
            unsigned effectiveSignalEncoding = 0;
            const char* reason = "";
            ID3D12Resource *output = nullptr, *passScratch = nullptr, *passClamp = nullptr,
                          *colorCopy = nullptr, *hdrCopy = nullptr, *colorSmall = nullptr,
                          *outputNative = nullptr, *activeColor = nullptr;
        } nr;
        DlssNr::OutputStatus outputStatus;
        bool modelRunning = false;
        std::vector<std::unique_ptr<ID3D12Resource>> scratch;
        void ReleaseSurfacesIfFormatChanged(unsigned) {}
        void ParkNrResource(ID3D12Resource*& resource) { resource = nullptr; }
        ID3D12Resource* CreateScratch(ID3D12Device*, unsigned, unsigned, unsigned)
        {
            scratch.push_back(std::make_unique<ID3D12Resource>());
            return scratch.back().get();
        }
        bool PrepareRunModels(ID3D12GraphicsCommandList*, ID3D12Device*, const DlssNrFrameInfo&,
                              const D3D12_RESOURCE_DESC&, DlssNr::ColorExtent, DlssNr::ColorExtent,
                              float, unsigned);
        const char* NgxResultName(unsigned);
        bool TuningMatchesFeature(const Config&, unsigned, unsigned, unsigned, unsigned);
    };
};
#endif
#ifdef NR_MODELS_SOURCE
#include NR_MODELS_SOURCE
#else
#include "models-production.inc"
#endif

inline bool TestModelPreparation()
{
    using namespace DlssNr;
    Config& cfg = *Config::Instance();
    cfg = {};
    const UICorrectionInput roles[] = { UICorrectionInput::Unknown, UICorrectionInput::Render,
        UICorrectionInput::Upscaled, UICorrectionInput::FinishedPicture };
    unsigned policyCases = 0, profileCases = 0;
    for (unsigned mask = 0; mask < 16; ++mask)
    for (bool adopted : { false, true })
    for (bool supported : { false, true })
    for (auto role : roles)
    for (bool bindings : { false, true })
    {
        const auto placement = ResolvePlacement(mask & 1, mask & 4, mask & 8, mask & 2);
        const bool expectedZero = adopted && supported && !bindings && !placement.deferred &&
            !placement.finished && ((role == UICorrectionInput::Render && placement.beforeUpscale) ||
                                   (role == UICorrectionInput::Upscaled && !placement.beforeUpscale));
        assert(ResolveUICorrection(adopted, placement, supported, role, bindings) == (expectedZero ? 0u : 1u));
        ++policyCases;
    }
    for (int route = 0; route < 3; ++route)
    {
        cfg.DlssNrRunBeforeSr.value = route == 0;
        cfg.DlssNrFinishedPicture.value = route == 2;
        const auto role = roles[route + 1];
        for (bool adopted : { false, true })
        {
            cfg.DlssNrAutomaticUICorrection.value = adopted;
            const auto resolved = Profiles::CreationUICorrection(cfg, true, role);
            assert(resolved == (adopted && route != 2 ? 0u : 1u));
            for (unsigned pass = 0; pass < 30; ++pass)
            {
                const auto defaults = Profiles::PassSettings(Config {}, pass, resolved);
                assert(defaults.uiCorrection == resolved && defaults.intensity == 0.5f &&
                       defaults.localTone == (pass == 0 ? 0.75f : 0.0f));
                if (pass)
                {
                    auto& extra = cfg.DlssNrPassOverrides[pass - 1];
                    extra.preset = 3u; extra.style = 2u; extra.intensity = 1.25f;
                    extra.structure = 0.4f; extra.tone = 0.3f; extra.skin = 0.2f; extra.autoMask = false;
                }
                const auto inherited = Profiles::PassSettings(cfg, pass, resolved);
                assert(inherited.uiCorrection == resolved);
                assert(Profiles::PassSettings(cfg, pass).uiCorrection == 1u); // Shared/Vulkan legacy.
                if (pass)
                {
                    assert(inherited.preset == (pass <= 2 ? 3u : cfg.DlssNrPreset.value));
                    assert(inherited.style == 2u && inherited.intensity == 1.25f && !inherited.autoMask);
                }
                ++profileCases;
            }
        }
    }
    cfg = {};
    ID3D12Device device;
    ID3D12GraphicsCommandList commands;
    D3D12_RESOURCE_DESC desc { 1920, 1080, 1 };
    DlssNrFrameInfo frame;
    DlssNr_Dx12::State state;
    const auto prepare = [&] { return state.PrepareRunModels(&commands, &device, frame, desc,
        { 1920, 1080 }, { 1920, 1080 }, 1.0f, 2); };
    const auto advance = [&] { ++frame.SubmissionEpoch; };
    assert(!prepare()); advance();
    assert(!prepare()); advance();
    assert(prepare());
    auto* scratch = state.nr.output;
    auto* oldMap = Mock::latest;
    const auto created = Mock::creations, released = Mock::releases, destroyed = Mock::destructions;
    assert(state.nr.builtSettings[0].uiCorrection == 1u && state.nr.builtSettings[1].uiCorrection == 1u);
    state.nr.reset = false;
    cfg.DlssNrPassOverrides[28].intensity = 1.5f;
    assert(prepare() && Mock::creations == created && !state.nr.reset); // Inactive pass.
    cfg.DlssNrAutomaticUICorrection.value = true;
    assert(!prepare() && state.nr.reset && state.nr.output == scratch);
    assert(state.nr.builtSettings[0].uiCorrection == 0u && state.outputStatus.uiCorrection == 0u);
    assert(Mock::releases == released && Mock::destructions == destroyed);
    assert(oldMap != Mock::latest);
    unsigned oldValue = 0;
    assert(oldMap->Get("DLSSNR.UICorrection", &oldValue) == NVSDK_NGX_Result_Success && oldValue == 1u);
    advance(); assert(!prepare()); advance(); assert(prepare());
    assert(state.nr.builtSettings[1].uiCorrection == 0u);
    const auto rebuilt = Mock::creations;
    state.nr.reset = false;
    assert(prepare() && Mock::creations == rebuilt && !state.nr.reset);
    // Real creation caller roles, not a resource-interface inference. Each
    // transition prepares the actual two profiles and saves their identities.
    const auto buildChanged = [&](unsigned expected)
    {
        assert(!prepare() && state.nr.reset);
        assert(state.outputStatus.uiCorrection == expected && state.nr.builtSettings[0].uiCorrection == expected);
        assert(std::get<unsigned>(Mock::creationValues.back().at("DLSSNR.UICorrection")) == expected);
        advance(); assert(!prepare()); advance(); assert(prepare());
        assert(state.nr.builtSettings[1].uiCorrection == expected);
        state.nr.reset = false;
    };
    cfg.DlssNrRunBeforeSr.value = true;
    frame.BeforeUpscale = true;
    buildChanged(0u); // adopted direct Render
    cfg.DlssNrAutomaticUICorrection.value = false;
    buildChanged(1u); // old/false Render
    cfg.DlssNrAutomaticUICorrection.value = true;
    buildChanged(0u);
    cfg.DlssNrDeferredDlss.value = true;
    buildChanged(1u); // retained adoption cannot override deferred
    cfg.DlssNrDeferredDlss.value = false;
    cfg.DlssNrRunBeforeSr.value = false;
    cfg.DlssNrFinishedPicture.value = true;
    frame.BeforeUpscale = false;
    frame.FinishedPicture = true;
    buildChanged(1u); // finished application picture, not reconstruction
    cfg.DlssNrFinishedPicture.value = false;
    cfg.DlssNrAutomaticUICorrection.value = false;
    frame.FinishedPicture = false;
    if (prepare() || !state.nr.reset)
    {
        std::printf("T6_ROLE_HISTORY_REJECT oldUi=1 newUi=1 recreated=0\n");
        return false;
    }
    assert(state.nr.builtSettings[0].uiCorrection == 1u && !state.nr.finishedPicture);
    advance(); assert(!prepare()); advance(); assert(prepare());
    for (auto& model : state.nr.models)
    {
        model.Release();
        model.ResetRecording(&commands);
    }
    assert(Mock::handles.empty() && Mock::allocations == Mock::destructions);
    std::printf("T6_PREPARATION_PASS policy-cases=%u profiles=%u aggregate-passes=2 "
                "scratch-preserved=1 inactive-reuse=1 history-reset=1 old-map-retained=1 "
                "actual-role-transitions=6 same-value-role-reset=1 closure=1\n",
                policyCases, profileCases);
    return true;
}
