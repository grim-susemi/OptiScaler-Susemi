#include <pch.h>
#include "UiServices.h"
#include <dlssnr/DlssNr_Placement.h>
#include <dlssnr/PassProfiles.h>
#include <menu/Localization.h>
#include <cstdio>

#ifndef OPTISCALER_NR_SELF_TEST
#error UI fixture services must never enter a product build.
#endif

// Test-only replacement for configuration initialization, not NR policy.
// Member defaults are the production Config defaults. Placement contracts use
// the production INI seam on owned paths; no live OptiScaler.ini is opened.
Config::Config() { _config = this; }
Config* Config::Instance() { return _config; }

namespace DlssNr
{
// These diagnostic providers are intentionally unavailable in UI-only mode.
std::string FinishedVkStatus() { return "Fixture: Vulkan processing not initialized."; }
} // namespace DlssNr

namespace NrAddonHost
{
bool ParseFixture(std::wstring_view name, Fixture& fixture)
{
    constexpr std::wstring_view names[] = { L"before4", L"before2", L"post4", L"post2", L"no-runtime", L"failure",
        L"filter-hdr", L"filter-sdr", L"filter-native", L"filter-supernative", L"filter-unsupported",
        L"missing-current-context" };
    for (unsigned i = 0; i < std::size(names); ++i)
        if (name == names[i])
        {
            fixture = static_cast<Fixture>(i);
            return true;
        }
    return false;
}

const char* FixtureName(Fixture fixture)
{
    constexpr const char* names[] = { "before4", "before2", "post4", "post2", "no-runtime", "failure",
        "filter-hdr", "filter-sdr", "filter-native", "filter-supernative", "filter-unsupported",
        "missing-current-context" };
    return names[static_cast<unsigned>(fixture)];
}

UiServices::UiServices(const std::filesystem::path& fixtureRoot)
{
    // Reserved owned persistence identity for later host work. The early UI
    // services remain entirely in memory; even this owned file is not loaded.
    State::Instance().gameExe = "NRAddonHost.fixture";
    State::Instance().gameName = "FIXTURE - synthetic status - no processing";
    config.MainDllPath = fixtureRoot.wstring();
    config.OverlayMenu = true;
    config.MenuScale = 1.0f;
    // Production timing consumers expect their preallocated history even before
    // the first fixture Present; these are unavailable (zero), not measured frames.
    State::Instance().frameTimes.assign(300, 0.0);
    State::Instance().swapchainApi = API::DX12;
    Select(Fixture::Before4);
}

UiServices::~UiServices()
{
    DlssNr::ClearStatus(this);
    State::Instance().gameExe.clear();
    State::Instance().gameName.clear();
    State::Instance().frameTimes.clear();
    State::Instance().swapchainApi = API::NotSelected;
}

void UiServices::Select(Fixture fixture)
{
    selected = fixture;
    config.DlssNrEnabled = true;
    config.DlssNrApplyModel = true;
    config.DlssNrWorkingScale = 0.65f;
    if (fixture == Fixture::FilterNative)
        config.DlssNrWorkingScale = 1.0f;
    if (fixture == Fixture::FilterSupernative)
        config.DlssNrWorkingScale = 1.25f;
    config.DlssNrInputFilter = fixture >= Fixture::FilterHdr ? DlssNr::InputFilter::Nearest : DlssNr::InputFilter::Area;
    config.DlssNrSignalEncoding = fixture >= Fixture::FilterHdr ? DlssNr::SignalEncoding::PQSDR : DlssNr::SignalEncoding::Legacy;
    State::Instance().swapchainApi = fixture == Fixture::FilterUnsupported ? API::DX11 : API::DX12;
    config.DlssNrRunBeforeSr = fixture != Fixture::Post4 && fixture != Fixture::Post2;
    config.DlssNrFinishedPicture = false;
    config.DlssNrDeferredDlss = false;
    config.DlssNrResidualAcrossRr = false;
    config.DlssNrAutomaticUICorrection = false;
    config.DlssNrTransfer = fixture == Fixture::Before2 || fixture == Fixture::Post2 ? 2u : 4u;
    Publish();
}

void UiServices::Publish()
{
    DlssNr::StatusSnapshot status;
    // This is labeled fixture model telemetry, never an applied-output receipt.
    status.running = selected != Fixture::NoRuntime && selected != Fixture::Failure;
    if (selected == Fixture::Failure)
        status.failureReason = "Fixture provider failure (no provider was invoked).";
    if (status.running)
    {
        status.gpuTime = 1.25;
        status.frames = 8;
    }
    const auto placement = DlssNr::ResolvePlacement(
        config.DlssNrRunBeforeSr.value_or_default(), config.DlssNrDeferredDlss.value_or_default(),
        config.DlssNrResidualAcrossRr.value_or_default(), config.DlssNrFinishedPicture.value_or_default());
    const auto scale = config.DlssNrWorkingScale.value_or_default();
    status.reconstruction = DlssNrResolveReconstruction(
        config.DlssNrTransfer.value_or_default(), placement.beforeUpscale, scale < 0.999f, scale);
    // UI-only fixture model activity does not prove any output submission.
    status.output.state = selected == Fixture::Failure ? DlssNr::OutputState::Failed
                                                      : DlssNr::OutputState::WaitingForModel;
    status.output.reason = selected == Fixture::Failure ? DlssNr::OutputReason::Model : DlssNr::OutputReason::None;
    status.output.requested = status.output.effective = placement;
    status.output.uiCorrection = DlssNr::Profiles::CreationUICorrection(config, true,
        placement.finished ? DlssNr::UICorrectionInput::FinishedPicture :
        placement.beforeUpscale ? DlssNr::UICorrectionInput::Render : DlssNr::UICorrectionInput::Upscaled);
    static unsigned lastPolicy = ~0u;
    const unsigned policy = status.output.uiCorrection |
        (unsigned(config.DlssNrAutomaticUICorrection.value_or_default()) << 1);
    if (policy != lastPolicy)
    {
        std::printf("T6_UI_RESOLVED value=%u adopted=%u before=%u deferred=%u finished=%u fixture-only=1\n",
            status.output.uiCorrection, unsigned(config.DlssNrAutomaticUICorrection.value_or_default()),
            unsigned(placement.beforeUpscale), unsigned(placement.deferred), unsigned(placement.finished));
        std::fflush(stdout);
        lastPolicy = policy;
    }
    status.output.evaluated = status.running;
    // Explicitly labeled synthetic context only; no processing support is invented.
    if (selected != Fixture::MissingCurrentContext)
    {
        if (selected >= Fixture::FilterHdr)
        {
            status.output.contextState = DlssNr::ModelContextState::Current;
            status.output.identity = { this, this, 1, 0, false };
        }
        status.output.optionContext = { 1920, 1080,
            (uint32_t) (1920 * scale + 0.5f), (uint32_t) (1080 * scale + 0.5f),
            selected != Fixture::FilterUnsupported, selected >= Fixture::FilterHdr && selected != Fixture::FilterSdr };
    }
    status.modelFacts = static_cast<const DlssNr::ModelFacts&>(status.output);
    std::printf("TASK8_UI_CONTEXT fixture=%s state=%u known=%u generation=%llu "
                "input=%u,%u work=%u,%u dx12=%u hdr=%u synthetic=1 providerInit=0\n",
                FixtureName(selected), unsigned(status.output.contextState),
                unsigned(status.output.identity.Known()), status.output.identity.generation,
                status.output.optionContext.inputWidth, status.output.optionContext.inputHeight,
                status.output.optionContext.workingWidth, status.output.optionContext.workingHeight,
                unsigned(status.output.optionContext.nativeDx12), unsigned(status.output.optionContext.hdrProxy));
    std::fflush(stdout);
    const auto options = DlssNr::ResolveOptions(config.DlssNrInputFilter.value_or_default(),
        config.DlssNrSignalEncoding.value_or_default(), status.output.optionContext,
        status.output.inputFilter, status.output.signalEncoding,
        status.output.inputFilterOverrideSupported, status.output.signalEncodingOverrideSupported);
    static unsigned lastOptions = ~0u;
    const unsigned optionBits = unsigned(options.requestedFilter) | (unsigned(options.requestedSignal) << 2) |
        (unsigned(options.filterSelectable) << 4) | (unsigned(options.signalSelectable) << 5);
    if (optionBits != lastOptions)
    {
        std::printf("T7_UI_FACTS filter=%u signal=%u effectiveFilter=%u effectiveSignal=%u filterSelectable=%u "
                    "signalSelectable=%u filterSupported=%u signalSupported=%u fixture-only=1\n",
            unsigned(options.requestedFilter), unsigned(options.requestedSignal),
            unsigned(options.effectiveFilter), unsigned(options.effectiveSignal),
            unsigned(options.filterSelectable), unsigned(options.signalSelectable),
            unsigned(options.filterSupported), unsigned(options.signalSupported));
        std::fflush(stdout);
        lastOptions = optionBits;
    }
    DlssNr::PublishStatus(this, DlssNr::Backend::Dx12, status);
}
} // namespace NrAddonHost
