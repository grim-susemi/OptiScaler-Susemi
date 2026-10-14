#include "pch.h"

#include "DlssNr.h"
#include "DlssNrFeature_Vk.h"
#include "DlssNrFinished_Vk.h"
#include "DlssNr_PipelineUi.h"
#include "DlssNr_Upscaler.h"
#include "DlssNr_MenuSections.h"
#include "DlssNr_Placement.h"
#include "DlssNr_PlacementConfig.h"
#include <Config.h>
#include <menu/menu_common.h>
#include <algorithm>
#include <cmath>

namespace DlssNr::MenuSections
{

static void RenderPlacement(Config* config)
{
    const bool enabled = config->DlssNrEnabled.value_or_default();
    const bool finishedPicture = config->DlssNrFinishedPicture.value_or_default();
    if (finishedPicture && enabled)
    {
        const auto feature = State::Instance().currentFeature;
        if (State::Instance().swapchainApi == API::Vulkan)
            ImGui::TextWrapped("%s", DlssNr::FinishedVkStatus().c_str());
        else if (feature && (feature->Api() != API::DX12 ||
                             (feature->IsWithDx12() && State::Instance().swapchainApi != API::DX11 &&
                              State::Instance().swapchainInteropApi != SwapchainInteropApi::Dx11wDx12)))
            ImGui::TextWrapped("This option needs DirectX 12 or a DirectX 11 upscaler marked w/Dx12.");
        else
            ImGui::TextWrapped("%s", DlssNr::FinishedPictureStatus().c_str());
    }

    const auto placement = ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
                                            config->DlssNrDeferredDlss.value_or_default(),
                                            config->DlssNrResidualAcrossRr.value_or_default(), finishedPicture);
    if (placement.deferred)
    {
        ImGui::TextWrapped("Private upscale: %s", DlssNr::DeferredDlssStatus().c_str());
        ImGui::TextWrapped(finishedPicture
            ? "The game processes clean input through SR/RR and its effects. The separately upscaled NR edit is applied to the finished picture."
            : "The game processes clean input through SR/RR. The separately upscaled NR edit is applied after upscale.");
    }

}

static void RenderStatus(Config* config)
{
    const bool enabled = config->DlssNrEnabled.value_or_default();
    const bool finishedPicture = config->DlssNrFinishedPicture.value_or_default();
    const auto dx12 = ReadStatus(Backend::Dx12);
    const auto vk = ReadStatus(Backend::Vulkan);
    const auto feature = State::Instance().currentFeature;
    const bool nativeVk = feature && feature->Api() == API::Vulkan && !feature->IsWithDx12();
    const bool vulkan = nativeVk || vk.running;
    const auto& status = vulkan ? vk : dx12;
    const auto modelState = PipelineUi::ReadModelState(enabled, status);
    const auto options = ResolveOptions(config->DlssNrInputFilter.value_or_default(),
        config->DlssNrSignalEncoding.value_or_default(), status.output.optionContext,
        status.output.inputFilter, status.output.signalEncoding,
        status.output.inputFilterOverrideSupported, status.output.signalEncodingOverrideSupported);
    ImGui::TextWrapped("Input filter: requested %s; effective %s; overrides %s.",
        InputFilterNames[static_cast<unsigned>(options.requestedFilter)],
        InputFilterNames[static_cast<unsigned>(options.effectiveFilter)],
        options.filterSupported ? "supported" : "unsupported");
    ImGui::TextWrapped("Signal encoding: requested %s; effective %s; overrides %s.",
        SignalEncodingNames[static_cast<unsigned>(options.requestedSignal)],
        SignalEncodingNames[static_cast<unsigned>(options.effectiveSignal)],
        options.signalSupported ? "supported" : "unsupported");
    if (!options.filterSupported || !options.signalSupported)
        ImGui::TextWrapped("Override processing is not available in this build/context. "
                           "The saved requests are retained; actual processing remains Area/Legacy.");

    // An existing model handle does not mean NR is enabled this frame.
    if (modelState == PipelineUi::ModelState::Disabled)
    {
        ImGui::TextDisabled("NR off.");
    }
    else if (modelState == PipelineUi::ModelState::Failed)
    {
        ImGui::TextWrapped("NR failed: %s", status.failureReason.c_str());
        if (nativeVk)
            ImGui::TextWrapped("Restart the game to retry native Vulkan NR.");
        else if (ImGui::SmallButton("Retry"))
            DlssNr::RetryAfterFailure();
    }
    else if (modelState == PipelineUi::ModelState::Waiting)
    {
        if (feature && feature->Api() == API::DX11 && !feature->IsWithDx12())
        {
            ImGui::TextWrapped("NR needs the D3D12 bridge on D3D11. Choose an upscaler marked w/Dx12 and restart.");
        }
        else if (nativeVk && ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
                     config->DlssNrDeferredDlss.value_or_default(),
                     config->DlssNrResidualAcrossRr.value_or_default(), finishedPicture).deferred)
        {
            ImGui::TextWrapped("The private edit-upscale path requires DirectX 12 or its bridge. Disable separate edit upscaling to use native Vulkan NR.");
        }
        else
            ImGui::TextWrapped("Waiting for model activity. The configured flow is not runtime confirmation.");
    }
    else
    {
        const auto ms = status.gpuTime;

        // Hiding the edit keeps model evaluation running.
        const char* runSuffix = !config->DlssNrApplyModel.value_or_default() ? "  (edit configured hidden)" : "";

        if (ms.has_value() && std::isfinite(ms.value()) && ms.value() > 0.0)
            ImGui::TextWrapped("NR GPU elapsed%s: %.2f ms%s", vulkan ? " (native Vulkan)" : "",
                               ms.value(), runSuffix);
        else if (vulkan)
            // Measured but not yet read: the first few frames are still in the query ring.
            ImGui::TextWrapped("Model activity (native Vulkan): %llu frames%s", vk.frames, runSuffix);
        else
            ImGui::TextWrapped("Model activity reported.%s", runSuffix);

        ImGui::SameLine();
        ImGui::TextDisabled("(?)");
        if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
            ImGui::SetTooltip("Time between the start and end of NR on the GPU, including delays while other work "
                              "runs.\nCompare FPS to check the effect on game performance.");

        if (ms.has_value())
        {
            const auto& state = State::Instance();
            // The FG swapchain interval is between real game frames, not interpolated presents.
            // Native Vulkan has no DXGI timing, so use the existing overlay frame interval there.
            const double frameMs = state.swapchainApi == API::Vulkan
                                       ? (state.frameTimes.empty() ? 0.0 : state.frameTimes.back())
                                   : state.currentFG ? state.lastFGFrameTime
                                                     : state.presentFrameTime;
            PipelineUi::DrawTimingBar(ms.value(), frameMs,
                PipelineUi::IntervalSource(state.swapchainApi == API::Vulkan, state.currentFG != nullptr));
        }
        ImGui::TextWrapped("Reported frame reconstruction: requested %s (%u); effective %s (%u).",
                           PipelineUi::ReconstructionName(status.reconstruction.requested),
                           status.reconstruction.requested,
                           PipelineUi::ReconstructionName(status.reconstruction.effective),
                           status.reconstruction.effective);
        if (status.reconstruction.compatibilityFallback)
            ImGui::TextWrapped("Compatibility fallback: spatial reconstruction, not an NR failure.");
    }
    if (enabled && !vulkan)
    {
        const auto& output = status.output;
        const char* result = output.Applied() ? "submitted"
            : output.state == OutputState::EvaluatedHidden ? "evaluated, hidden"
            : output.composed && !output.executed && output.state != OutputState::Failed
                ? "composed, awaiting submission"
            : output.state == OutputState::Failed ? "failed"
            : output.state == OutputState::Skipped ? "skipped"
            : output.state == OutputState::Capturing ? "capturing"
            : output.state == OutputState::Disabled ? "disabled" : "waiting for model";
        static constexpr const char* reasons[] = { "none", "input admission", "missing or unreadable resource",
            "model", "composition", "final encode", "command-list Close", "queue Signal", "recording discarded" };
        ImGui::TextWrapped("Output application: %s (%s).", result, reasons[(unsigned) output.reason]);
        ImGui::TextWrapped("Runtime facts: evaluated %s; composed %s; copy-back %s; submitted %s.",
            output.evaluated ? "yes" : "no", output.composed ? "yes" : "no",
            output.copyBack ? "yes" : "no", output.submitted ? "yes" : "no");
        if (status.modelFacts.contextState != ModelContextState::Current)
            ImGui::TextWrapped("Current model/input context: %s.",
                status.modelFacts.contextState == ModelContextState::Unknown ? "unknown" : "unavailable");
        else
        {
            ImGui::TextWrapped("Resolved creation/shader values: UI Correction %u; filter %u; signal %u.",
                status.modelFacts.uiCorrection, status.modelFacts.inputFilter, status.modelFacts.signalEncoding);
            ImGui::TextWrapped("Model/input context generation %llu; backend %u.",
                status.modelFacts.identity.generation, (unsigned) status.modelFacts.backend);
        }
        const auto& requested = output.requested;
        const auto& effective = output.effective;
        ImGui::TextWrapped("Runtime route: requested %s; effective %s.",
            requested.deferred ? "separate edit" : requested.finished ? "Present" : requested.beforeUpscale ? "Render" : "Upscaled",
            effective.deferred ? "separate edit" : effective.finished ? "Present" : effective.beforeUpscale ? "Render" : "Upscaled");
        ImGui::TextWrapped("Application %llu; generation %llu; capture %llu; guides %s; consumer %u.",
            output.application, output.generation, output.captureSerial, output.guidesValid ? "valid" : "unavailable",
            (unsigned) output.consumer);
        if (output.completionUnknown)
            ImGui::TextWrapped("GPU completion unknown; the output resources remain pinned.");
    }
    else if (enabled)
        ImGui::TextWrapped("Output application: unconfirmed by current model telemetry.");
}

} // namespace DlssNr::MenuSections

namespace DlssNr
{

void RenderMenu(Config* config, float menuResScale)
{
    MenuStatusScope statusScope;
    using namespace MenuSections;
    ImGui::Spacing();
    if (auto header = ScopedCollapsingHeader("DLSS Neural Rendering"); header.IsHeaderOpen())
    {
        ScopedIndent indent {};
        const float toggleGap = ImGui::GetStyle().ItemSpacing.x;
        const float available = ImGui::GetContentRegionAvail().x;
        const float frameInset = ImGui::GetStyle().FrameBorderSize;
        const float checkboxPadding = ImGui::GetFrameHeight() + ImGui::GetStyle().ItemInnerSpacing.x + frameInset;
        bool enabled = config->DlssNrEnabled.value_or_default();
        if (PipelineUi::CheckboxWrapped("Enable Neural Rendering", &enabled, available))
            config->DlssNrEnabled = enabled;
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip(
                "Enable NR processing.");

        bool applyModel = config->DlssNrApplyModel.value_or_default();
        if (PipelineUi::CheckboxWrapped("Apply model", &applyModel, available))
            config->DlssNrApplyModel = applyModel;
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Show or hide the NR effect. The model still runs when hidden.\nDisable Enable Neural "
                              "Rendering to stop its GPU cost.");

        const auto feature = State::Instance().currentFeature;
        const bool rayReconstruction = feature && feature->GetUpscalerType() == Upscaler::DLSSD;
        bool finished = config->DlssNrFinishedPicture.value_or_default();
        auto placement = ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
                                          config->DlssNrDeferredDlss.value_or_default(),
                                          config->DlssNrResidualAcrossRr.value_or_default(), finished);
        bool generateBefore = placement.beforeUpscale;
        ImGui::BeginDisabled(placement.deferred);
        if (PipelineUi::CheckboxWrapped("Generate model before upscale", &generateBefore,
                                        available))
            EditPlacementCheckbox(*config, PlacementCheckbox::Before, generateBefore);
        ImGui::EndDisabled();
        if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
            ImGui::SetTooltip(placement.deferred ? "The separate-edit path always generates before upscale."
                                               : "Run NR before the game's upscaler, including RR.");

        const float finishedWidth = checkboxPadding + ImGui::CalcTextSize("Apply NR to the finished picture").x;
        const float deferredWidth = checkboxPadding + ImGui::CalcTextSize("Generate before upscale, apply after upscale").x;
        const bool routesPaired = finishedWidth + toggleGap + deferredWidth <= available;
        const float deferredRight = ImGui::GetCursorPosX() + finishedWidth + toggleGap;
        if (PipelineUi::CheckboxWrapped("Apply NR to the finished picture", &finished,
                                        routesPaired ? finishedWidth : available))
            EditPlacementCheckbox(*config, PlacementCheckbox::Finished, finished);
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Apply NR after game effects and HUD. Early generation carries the edit through a separate upscaler.");

        placement = ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
                                     config->DlssNrDeferredDlss.value_or_default(),
                                     config->DlssNrResidualAcrossRr.value_or_default(), finished);
        if (routesPaired)
            ImGui::SameLine(deferredRight);
        bool deferred = placement.deferred;
        if (PipelineUi::CheckboxWrapped("Generate before upscale, apply after upscale", &deferred,
                                        routesPaired ? deferredWidth : available))
            EditPlacementCheckbox(*config, PlacementCheckbox::Deferred, deferred);
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Keep the game's SR/RR input clean and upscale only the NR edit with a separate non-RR backend."
                              "\nApply after upscale, or at presentation when finished-picture mode is enabled.");
        ImGui::Spacing();

        placement = ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
                                     config->DlssNrDeferredDlss.value_or_default(),
                                     config->DlssNrResidualAcrossRr.value_or_default(), finished);
        const bool nativePrivateVk = feature && feature->Api() == API::Vulkan && !feature->IsWithDx12();
        if (placement.deferred && !nativePrivateVk)
        {
#ifdef OPTISCALER_NR_SELF_TEST
            const float privateLeft = ImGui::GetCursorScreenPos().x;
            const int privateVertex = ImGui::GetWindowDrawList()->VtxBuffer.Size;
#endif
            ImGui::BeginGroup();
            ImGui::SetCursorPosX(ImGui::GetCursorPosX() + frameInset);
            ImGui::SetCursorPosY(ImGui::GetCursorPosY() + frameInset);
            ImGui::SetNextItemWidth(std::max(1.0f, available - ImGui::CalcTextSize("Private NR upscaler").x -
                ImGui::GetStyle().ItemInnerSpacing.x - ImGui::CalcTextSize("(?)").x -
                ImGui::GetStyle().ItemSpacing.x - frameInset));
            int backend = (int) GetPrivateUpscaler(config->DlssNrPrivateUpscaler.value_or_default());
            if (ImGui::Combo("Private NR upscaler", &backend, "DLSS\0FSR 2.2\0FSR (FidelityFX)\0XeSS\0"))
                config->DlssNrPrivateUpscaler = backend;
            HelpMarker("Upscales only the NR edit, with or without game RR. FSR (FidelityFX) and XeSS need their runtimes.");
            if (frameInset > 0)
            {
                ImGui::SetCursorPosY(ImGui::GetCursorPosY() - ImGui::GetStyle().ItemSpacing.y + frameInset);
                ImGui::Dummy(ImVec2(0, 0));
            }
            ImGui::EndGroup();
#ifdef OPTISCALER_NR_SELF_TEST
            NrAddonHost::RecordNrItem("Private NR upscaler", ImGui::GetID("Private NR upscaler"),
                                     privateLeft, privateLeft + available, privateVertex);
#endif
        }

        PipelineUi::View view;
        view.privateUpscaler = PrivateUpscalerName(GetPrivateUpscaler(config->DlssNrPrivateUpscaler.value_or_default()));
        view.enabled = enabled;
        view.applyModel = config->DlssNrApplyModel.value_or_default();
        view.passes = config->DlssNrPasses.value_or_default();
        view.scalePercent = (int) lroundf(config->DlssNrWorkingScale.value_or_default() * 100.0f);
        view.rayReconstruction = rayReconstruction;
        view.reconstruction = PipelineUi::ConfiguredReconstruction(
            config->DlssNrTransfer.value_or_default(), placement.beforeUpscale,
            config->DlssNrWorkingScale.value_or_default());
        if (finished)
            view.route = placement.deferred ? PipelineUi::Route::FinishedBefore : PipelineUi::Route::Finished;
        else if (placement.deferred)
            view.route = PipelineUi::Route::Deferred;
        else
            view.route = placement.beforeUpscale ? PipelineUi::Route::Before : PipelineUi::Route::After;

        static PipelineUi::Section selected = PipelineUi::Section::Placement;
        ImGui::TextWrapped("Configured reconstruction: requested %s (%u); effective %s (%u).",
                           PipelineUi::ReconstructionName(view.reconstruction.requested),
                           view.reconstruction.requested, PipelineUi::ReconstructionName(view.reconstruction.effective),
                           view.reconstruction.effective);
        if (view.reconstruction.compatibilityFallback)
            ImGui::TextWrapped("Compatibility fallback (not a failure): before-upscale model generation uses "
                               "the spatial equivalent. The saved private DLSS request is retained for a "
                               "compatible post-upscale route.");
        ImGui::Separator();
        PipelineUi::Draw(view, selected);
        ImGui::Separator();
        ImGui::Spacing();
        RenderStatus(config);
        ImGui::SeparatorText(PipelineUi::SectionName(selected));
        ImGui::PushItemWidth(std::min(220.0f * menuResScale, ImGui::GetContentRegionAvail().x * 0.42f));
        static constexpr void (*sections[])(Config*) = { RenderPlacement, RenderInput, RenderModel, RenderBlend };
        sections[(int) selected](config);
        ImGui::PopItemWidth();
        if (ImGui::CollapsingHeader("Inspect NR"))
        {
            ImGui::PushItemWidth(std::min(220.0f * menuResScale, ImGui::GetContentRegionAvail().x * 0.42f));
            RenderInspect(config);
            ImGui::PopItemWidth();
        }
    }
}

} // namespace DlssNr
