#include <pch.h>
#include "UiServices.h"
#include <dlssnr/DlssNr_PipelineUi.h>
#include <dlssnr/DlssNr_Placement.h>
#include <dlssnr/DlssNr_PlacementConfig.h>
#include <dlssnr/PassProfiles.h>
#include <cstdio>
#include <stdexcept>

#ifndef OPTISCALER_NR_SELF_TEST
#error UI contracts must never enter a product build.
#endif

namespace NrAddonHost
{
// Called by the same NRAddonHost entry, with its existing task-owned fixture root.
// This drives production menu decisions and the actual status publisher/consumer.
// It does not render a window or prove NVIDIA processing or output application.
void RunUiContracts(const std::filesystem::path& fixtureRoot)
{
    using namespace DlssNr;
    unsigned checks = 0;
    unsigned carrierCases = 0;
    const auto check = [&](bool condition, const char* caseId)
    {
        ++checks;
        if (!condition)
            throw std::runtime_error(std::string("TASK25_UI_CONTRACT: ") + caseId);
    };

    {
        UiServices services(fixtureRoot);
        auto* config = services.Configuration();
        struct Case
        {
            Fixture fixture;
            uint32_t requested, effective;
            bool before, privateEnlargement, fallback;
            PipelineUi::ModelState model;
        };
        const Case cases[] = {
            { Fixture::Before4, 4, 3, true, false, true, PipelineUi::ModelState::Active },
            { Fixture::Before2, 2, 1, true, false, true, PipelineUi::ModelState::Active },
            { Fixture::Post4, 4, 4, false, true, false, PipelineUi::ModelState::Active },
            { Fixture::Post2, 2, 2, false, true, false, PipelineUi::ModelState::Active },
            { Fixture::NoRuntime, 4, 3, true, false, true, PipelineUi::ModelState::Waiting },
            { Fixture::Failure, 4, 3, true, false, true, PipelineUi::ModelState::Failed }
        };
        for (const auto& test : cases)
        {
            services.Select(test.fixture);
            const auto saved = config->DlssNrTransfer.value_for_config();
            const auto placement = ResolvePlacement(
                config->DlssNrRunBeforeSr.value_or_default(), config->DlssNrDeferredDlss.value_or_default(),
                config->DlssNrResidualAcrossRr.value_or_default(), config->DlssNrFinishedPicture.value_or_default());
            const auto scale = config->DlssNrWorkingScale.value_or_default();
            const auto path = PipelineUi::ConfiguredReconstruction(
                config->DlssNrTransfer.value_or_default(), placement.beforeUpscale, scale);
            check(scale == 0.65f && placement.beforeUpscale == test.before, "fixture-input");
            check(path.requested == test.requested && path.effective == test.effective, "fixture-effective-path");
            check(path.privateEnlargement == test.privateEnlargement && path.compatibilityFallback == test.fallback,
                  "fixture-nonfatal-compatibility");
            check(PipelineUi::ReconstructionSelectable(2, placement.beforeUpscale, scale) == !test.before &&
                      PipelineUi::ReconstructionSelectable(4, placement.beforeUpscale, scale) == !test.before,
                  "private-control-eligibility");
            for (uint32_t spatial : { 0u, 1u, 3u })
                check(PipelineUi::ReconstructionSelectable(spatial, placement.beforeUpscale, scale),
                      "spatial-control-eligibility");
            check(config->DlssNrTransfer.value_for_config() == saved, "saved-intent-preserved");

            const auto status = ReadStatus(Backend::Dx12);
            check(PipelineUi::ReadModelState(true, status) == test.model, "published-model-view");
            check(status.reconstruction.requested == path.requested &&
                      status.reconstruction.effective == path.effective &&
                      status.reconstruction.privateEnlargement == path.privateEnlargement &&
                      status.reconstruction.compatibilityFallback == path.compatibilityFallback,
                  "published-fixture-path");
            check(status.failureReason.empty() == (test.model != PipelineUi::ModelState::Failed),
                  "failure-is-distinct-from-fallback");
            if (test.model == PipelineUi::ModelState::Waiting || test.model == PipelineUi::ModelState::Failed)
                check(!status.running && !status.gpuTime && status.frames == 0, "no-model-activity");
            std::printf("TASK25_UI_CASE=%s requested=%u effective=%u before=%u private=%u fallback=%u model=%u\n",
                        FixtureName(test.fixture), path.requested, path.effective, unsigned(test.before),
                        unsigned(path.privateEnlargement), unsigned(path.compatibilityFallback), unsigned(test.model));
        }

        // Preserve every existing placement carrier, including finished-before and the legacy alias.
        for (bool before : { false, true })
        for (bool deferred : { false, true })
        for (bool legacy : { false, true })
        for (bool finished : { false, true })
        for (uint32_t requested : { 0u, 1u, 2u, 3u, 4u })
        for (float scale : { 0.65f, 1.0f, 1.25f })
        {
            config->DlssNrRunBeforeSr = before;
            config->DlssNrDeferredDlss = deferred;
            config->DlssNrResidualAcrossRr = legacy;
            config->DlssNrFinishedPicture = finished;
            config->DlssNrTransfer = requested;
            config->DlssNrWorkingScale = scale;
            const auto placement = ResolvePlacement(before, deferred, legacy, finished);
            const auto saved = config->DlssNrTransfer.value_for_config();
            const auto expected = DlssNrResolveReconstruction(requested, placement.beforeUpscale, scale != 1.0f, scale);
            const auto configured = PipelineUi::ConfiguredReconstruction(requested, placement.beforeUpscale, scale);
            check(configured.requested == expected.requested && configured.effective == expected.effective &&
                      configured.privateEnlargement == expected.privateEnlargement &&
                      configured.compatibilityFallback == expected.compatibilityFallback,
                  "same-production-resolver");
            check(PipelineUi::ReconstructionSelectable(requested, placement.beforeUpscale, scale) ==
                      (scale < 0.999f && !expected.compatibilityFallback),
                  "carrier-control-eligibility");
            check(config->DlssNrTransfer.value_for_config() == saved &&
                      config->DlssNrRunBeforeSr.value_or_default() == before &&
                      config->DlssNrDeferredDlss.value_or_default() == deferred &&
                      config->DlssNrResidualAcrossRr.value_or_default() == legacy &&
                      config->DlssNrFinishedPicture.value_or_default() == finished,
                  "configured-view-is-read-only");
            CustomOptional<uint32_t> reloadedTransfer { 1 };
            reloadedTransfer.set_from_config(saved);
            check(reloadedTransfer.value_or_default() == requested, "saved-request-reload");
            ++carrierCases;
        }

        for (uint32_t requested : { 2u, 4u })
        {
            services.Select(Fixture::Before4);
            config->DlssNrTransfer = requested;
            const auto saved = config->DlssNrTransfer.value_for_config();
            const auto before = PipelineUi::ConfiguredReconstruction(requested, true, 0.65f);
            check(before.compatibilityFallback && before.effective == requested - 1, "retained-before-request");
            config->DlssNrRunBeforeSr = false;
            services.Publish();
            const auto after = PipelineUi::ConfiguredReconstruction(requested, false, 0.65f);
            const auto reported = ReadStatus(Backend::Dx12).reconstruction;
            check(after.privateEnlargement && !after.compatibilityFallback && after.effective == requested &&
                      PipelineUi::ReconstructionSelectable(requested, false, 0.65f),
                  "post-route-restores-private-eligibility");
            check(reported.requested == requested && reported.effective == requested &&
                      config->DlssNrTransfer.value_for_config() == saved,
                  "restoration-keeps-saved-intent");
        }

        StatusSnapshot activity;
        activity.frames = 8;
        activity.gpuTime = 1.25;
        check(PipelineUi::ReadModelState(true, activity) == PipelineUi::ModelState::Waiting,
              "counter-and-timing-are-not-model-activity");
        activity.running = true;
        check(PipelineUi::ReadModelState(true, activity) == PipelineUi::ModelState::Active,
              "running-is-only-model-activity");
        activity.failureReason = std::to_string(checks);
        check(PipelineUi::ReadModelState(true, activity) == PipelineUi::ModelState::Failed,
              "failure-not-hidden-by-running");
        check(PipelineUi::ReadModelState(false, activity) == PipelineUi::ModelState::Disabled, "disabled-view");
    }
    const auto closed = ReadStatus(Backend::Dx12);
    check(!closed.running && closed.failureReason.empty() && closed.frames == 0, "owned-status-closed");
    std::printf("TASK25_UI_CONTRACT_PASS checks=%u fixtures=6 carrier-cases=%u\n", checks, carrierCases);
    RunPlacementContracts(fixtureRoot);
}

void RunPlacementContracts(const std::filesystem::path& fixtureRoot)
{
    using namespace DlssNr;
    unsigned checks = 0;
    const auto check = [&](bool condition, const char* caseId)
    {
        ++checks;
        if (!condition)
            throw std::runtime_error(std::string("T6_PERSISTENCE: ") + caseId);
    };
    const auto inputPath = fixtureRoot / "task3-input.ini";
    const auto savedPath = fixtureRoot / "task3-saved.ini";
    const auto flags = [](const Config& config)
    {
        return unsigned(config.DlssNrRunBeforeSr.value_or_default()) |
               (unsigned(config.DlssNrFinishedPicture.value_or_default()) << 1) |
               (unsigned(config.DlssNrDeferredDlss.value_or_default()) << 2) |
               (unsigned(config.DlssNrResidualAcrossRr.value_or_default()) << 3);
    };
    unsigned persistedCases = 0;
    for (unsigned mask = 0; mask < 16; ++mask)
    for (int marker = -1; marker <= 1; ++marker)
    for (int selection = -1; selection < 3; ++selection)
    {
        CSimpleIniA input;
        const char* keys[] = { "RunBeforeSR", "FinishedPicture", "DeferredDLSS", "ResidualAcrossRR" };
        for (unsigned bit = 0; bit < 4; ++bit)
            input.SetValue("DlssNr", keys[bit], mask & (1u << bit) ? "true" : "false");
        if (marker >= 0)
            input.SetValue("DlssNr", "AutomaticUICorrection", marker ? "true" : "false");
        check(input.SaveFile(inputPath.c_str()) >= 0, "owned-input-file-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "owned-input-file-load");
        Config config;
        LoadPlacementConfig(config, loaded);
        check(flags(config) == mask && config.DlssNrAutomaticUICorrection.value_or_default() == (marker == 1),
              "legacy-load-preserves-every-flag-and-adoption");
        const auto placement = ResolvePlacement(mask & 1, mask & 4, mask & 8, mask & 2);
        const bool expectedDeferred = (mask & 4) || ((mask & 1) && (mask & 8)) ||
                                      ((mask & 1) && (mask & 2));
        check(placement.deferred == expectedDeferred && placement.beforeUpscale == bool((mask & 1) || expectedDeferred)
                  && placement.finished == bool(mask & 2), "legacy-resolver-truth-table");
        check((DirectPlacementIndex(mask & 1, mask & 2, mask & 4, mask & 8) < 0) == expectedDeferred,
              "deferred-never-direct-present");
        const unsigned expectedFlags = selection < 0 ? mask : selection == 0 ? 1u : selection == 2 ? 2u : 0u;
        if (selection >= 0)
            check(SelectDirectPlacement(config, selection), "explicit-direct-selection");
        check(flags(config) == expectedFlags &&
                  config.DlssNrAutomaticUICorrection.value_or_default() == (selection >= 0 || marker == 1),
              "direct-table-and-explicit-only-adoption");
        check(!SelectDirectPlacement(config, -2) && !SelectDirectPlacement(config, 3) &&
                  flags(config) == expectedFlags, "invalid-direct-index-is-not-another-route");
        SavePlacementConfig(config, loaded);
        check(loaded.SaveFile(savedPath.c_str()) >= 0, "production-owned-save");
        CSimpleIniA reloadedIni;
        check(reloadedIni.LoadFile(savedPath.c_str()) == SI_OK, "production-owned-reload");
        Config reloaded;
        LoadPlacementConfig(reloaded, reloadedIni);
        check(flags(reloaded) == expectedFlags &&
                  reloaded.DlssNrAutomaticUICorrection.value_or_default() == (selection >= 0 || marker == 1),
              "actual-file-route-and-marker-roundtrip");
        const auto route = ResolvePlacement(expectedFlags & 1, expectedFlags & 4,
                                            expectedFlags & 8, expectedFlags & 2);
        const auto role = route.finished ? UICorrectionInput::FinishedPicture :
                          route.beforeUpscale ? UICorrectionInput::Render : UICorrectionInput::Upscaled;
        const unsigned expectedUi = (selection >= 0 || marker == 1) && !route.deferred && !route.finished ? 0u : 1u;
        const auto resolved = Profiles::CreationUICorrection(reloaded, true, role);
        check(resolved == expectedUi, "reloaded-production-ui-policy");
        for (unsigned pass = 0; pass < 30; ++pass)
            check(Profiles::PassSettings(reloaded, pass, resolved).uiCorrection == expectedUi,
                  "reloaded-all-thirty-creation-profiles");
        check(Profiles::CreationUICorrection(reloaded, false, role) == 1u &&
              Profiles::CreationUICorrection(reloaded, true, UICorrectionInput::Unknown) == 1u,
              "unsupported-or-unknown-loaded-context-retains-legacy");
        std::printf("TASK3_PERSIST_CASE mask=%u marker=%d selection=%d savedFlags=%u adopted=%u\n",
                    mask, marker, selection, flags(reloaded),
                    unsigned(reloaded.DlssNrAutomaticUICorrection.value_or_default()));
        ++persistedCases;
    }
    unsigned boundaryCases = 0;
    for (const char* key : { "RunBeforeSR", "FinishedPicture", "DeferredDLSS", "ResidualAcrossRR",
                            "AutomaticUICorrection" })
    for (const char* value : { "", "auto", "1", "0", "Present", "-1", "falsejunk", "999999999999999999999" })
    {
        CSimpleIniA input;
        input.SetValue("DlssNr", key, value);
        check(input.SaveFile(inputPath.c_str()) >= 0, "invalid-owned-file-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "invalid-owned-file-load");
        Config config;
        LoadPlacementConfig(config, loaded);
        check(flags(config) == 0 && !config.DlssNrAutomaticUICorrection.value_or_default(),
              "invalid-bool-normalizes-to-legacy-default-without-adoption");
        check(!ReadPlacementBool(loaded, key).has_value(), "invalid-is-not-a-valid-selection");
        ++boundaryCases;
    }
    // The original BeforeUpscale key still loads. Saving an explicit Upscaled
    // selection must not let that retained alias resurrect Render on reload.
    for (int selection = -1; selection < 3; ++selection)
    {
        CSimpleIniA input;
        input.SetValue("DlssNr", "BeforeUpscale", "TrUe");
        check(input.SaveFile(inputPath.c_str()) >= 0, "alias-owned-file-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "alias-owned-file-load");
        Config config;
        LoadPlacementConfig(config, loaded);
        check(flags(config) == 1 && !config.DlssNrAutomaticUICorrection.value_or_default(), "legacy-alias-load");
        if (selection >= 0)
            SelectDirectPlacement(config, selection);
        SavePlacementConfig(config, loaded);
        check(loaded.SaveFile(savedPath.c_str()) >= 0, "alias-production-save");
        CSimpleIniA reopened;
        check(reopened.LoadFile(savedPath.c_str()) == SI_OK, "alias-production-reload");
        Config reloaded;
        LoadPlacementConfig(reloaded, reopened);
        check(flags(reloaded) == (selection < 0 || selection == 0 ? 1u : selection == 2 ? 2u : 0u),
              "alias-does-not-resurrect-cleared-direct-route");
    }
    std::printf("T6_PLACEMENT_CONTRACT_PASS checks=%u persisted-cases=%u invalid-boundary-cases=%u\n",
                checks, persistedCases, boundaryCases);
}
} // namespace NrAddonHost
