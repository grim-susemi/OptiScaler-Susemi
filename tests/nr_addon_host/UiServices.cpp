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

// Owned English-only presentation service. Production's English guard leaves
// these draw/measure ranges unchanged; no catalog/font/config is loaded here.
namespace Localization
{
LocalizedRange::LocalizedRange(const char*&, const char*&) {}
LocalizedRange::~LocalizedRange() = default;
}

namespace DlssNr
{
// These diagnostic providers are intentionally unavailable in UI-only mode.
std::string FinishedPictureStatus() { return "Fixture: finished-picture processing not initialized."; }
std::string DeferredDlssStatus() { return "Fixture: private upscaler not initialized."; }
std::string FinishedVkStatus() { return "Fixture: Vulkan processing not initialized."; }
} // namespace DlssNr

namespace NrAddonHost
{
bool ParseFixture(std::wstring_view name, Fixture& fixture)
{
    constexpr std::wstring_view names[] = { L"before4", L"before2", L"post4", L"post2", L"no-runtime", L"failure" };
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
    constexpr const char* names[] = { "before4", "before2", "post4", "post2", "no-runtime", "failure" };
    return names[static_cast<unsigned>(fixture)];
}

UiServices::UiServices(const std::filesystem::path& fixtureRoot)
{
    // Reserved owned persistence identity for later host work. The early UI
    // services remain entirely in memory; even this owned file is not loaded.
    State::Instance().gameExe = (fixtureRoot / "NRAddonHost.fixture").string();
    State::Instance().swapchainApi = API::DX12;
    Select(Fixture::Before4);
}

UiServices::~UiServices()
{
    DlssNr::ClearStatus(this);
    State::Instance().gameExe.clear();
    State::Instance().swapchainApi = API::NotSelected;
}

void UiServices::Select(Fixture fixture)
{
    selected = fixture;
    config.DlssNrEnabled = true;
    config.DlssNrApplyModel = true;
    config.DlssNrWorkingScale = 0.65f;
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
    DlssNr::PublishStatus(this, DlssNr::Backend::Dx12, status);
}
} // namespace NrAddonHost
