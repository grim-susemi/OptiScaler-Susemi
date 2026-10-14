#pragma once

#include "DlssNr_Status.h"
#include <imgui/imgui.h>
#include <imgui/imgui_internal.h>
#include <menu/Localization.h>
#include <algorithm>
#include <cfloat>
#include <string>
#include <vector>
#include <span>
#include <cmath>

#ifdef OPTISCALER_NR_SELF_TEST
namespace NrAddonHost
{
void RecordNrItem(const char* label, ImGuiID id, float left, float right, int firstVertex);
void RecordNrStage(int index, int stage, int parent, int otherParent, float left, float right, int firstVertex);
}
#endif

namespace DlssNr::PipelineUi
{
enum class Section
{
    Placement,
    Input,
    Model,
    Blend
};
enum class Route
{
    Before,
    After,
    Deferred,
    Finished,
    FinishedBefore
};

inline DlssNrReconstruction ConfiguredReconstruction(uint32_t requested, bool beforeUpscale, float workScale)
{
    // Configuration has a scale, not the actual frame's rounded active extents.
    return DlssNrResolveReconstruction(requested, beforeUpscale, workScale != 1.0f, workScale);
}

inline bool ReconstructionSelectable(uint32_t requested, bool beforeUpscale, float workScale)
{
    return workScale < 0.999f &&
           !ConfiguredReconstruction(requested, beforeUpscale, workScale).compatibilityFallback;
}

inline const char* ReconstructionName(uint32_t transfer)
{
    static constexpr const char* names[] = { "Classic", "Matched residual", "Matched residual + DLSS",
                                            "Lighting + colour", "Lighting + colour + DLSS" };
    return names[std::min(transfer, 4u)];
}

enum class ModelState
{
    Disabled,
    Waiting,
    Active,
    Failed
};

inline ModelState ReadModelState(bool enabled, const StatusSnapshot& status)
{
    if (!enabled)
        return ModelState::Disabled;
    if (!status.failureReason.empty())
        return ModelState::Failed;
    return status.running ? ModelState::Active : ModelState::Waiting;
}

struct View
{
    Route route = Route::After;
    bool enabled = true;
    bool rayReconstruction = false;
    bool applyModel = true;
    const char* privateUpscaler = "DLSS";
    unsigned int passes = 1;
    int scalePercent = 100;
    DlssNrReconstruction reconstruction;
};

inline const char* SectionName(Section section)
{
    static constexpr const char* names[] = { "Placement", "Input", "Model passes", "Apply NR edit" };
    return names[(int) section];
}

// Keep the English widget ID while wrapping the localized clickable label in its allocated row.
inline bool CheckboxWrapped(const char* label, bool* value, float width)
{
    if (ImGui::GetCurrentWindow()->SkipItems)
        return false;
    ImGui::PushID(label);
    const ImGuiID id = ImGui::GetID("##toggle");
#ifdef OPTISCALER_NR_SELF_TEST
    const float left = ImGui::GetCursorScreenPos().x;
    const int firstVertex = ImGui::GetWindowDrawList()->VtxBuffer.Size;
#endif
    ImGui::BeginGroup();
    const float right = ImGui::GetCursorPosX() + width;
    // Keep the theme's stroked frame/AA edge inside the row, not outside its allocation.
    const auto& style = ImGui::GetStyle();
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + style.FrameBorderSize);
    ImGui::SetCursorPosY(ImGui::GetCursorPosY() + style.FrameBorderSize);
    const float square = ImGui::GetFrameHeight();
    const ImVec2 pos = ImGui::GetCursorScreenPos();
    const ImVec2 textSize = ImGui::CalcTextSize(label, nullptr, false,
        std::max(1.0f, right - ImGui::GetCursorPosX() - square - style.ItemInnerSpacing.x));
    const ImRect checkRect(pos, ImVec2(pos.x + square, pos.y + square));
    const ImRect hitRect(pos, ImVec2(pos.x + square + style.ItemInnerSpacing.x + textSize.x,
        pos.y + std::max(square, style.FramePadding.y + textSize.y)));
    // Submit one checkbox identity for both square and wrapped text. ButtonBehavior
    // owns the press through release, including cancellation outside the row.
    ImGui::ItemSize(checkRect, style.FramePadding.y);
    bool changed = false;
    if (ImGui::ItemAdd(hitRect, id))
    {
        bool hovered, held;
        changed = ImGui::ButtonBehavior(hitRect, id, &hovered, &held);
        if (changed)
        {
            *value = !*value;
            ImGui::MarkItemEdited(id);
        }
        ImGui::RenderNavCursor(hitRect, id);
        ImGui::RenderFrame(checkRect.Min, checkRect.Max,
            ImGui::GetColorU32(held && hovered ? ImGuiCol_FrameBgActive :
                              hovered ? ImGuiCol_FrameBgHovered : ImGuiCol_FrameBg),
            true, style.FrameRounding);
        if (*value)
        {
            const float pad = std::max(1.0f, std::trunc(square / 6.0f));
            ImGui::RenderCheckMark(ImGui::GetWindowDrawList(), ImVec2(pos.x + pad, pos.y + pad),
                ImGui::GetColorU32(ImGuiCol_CheckMark), square - pad * 2.0f);
        }
    }
    ImGui::SameLine(0.0f, ImGui::GetStyle().ItemInnerSpacing.x);
    ImGui::PushTextWrapPos(right);
    ImGui::TextUnformatted(label);
    ImGui::PopTextWrapPos();
    if (style.FrameBorderSize > 0)
    {
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() - style.ItemSpacing.y + style.FrameBorderSize);
        ImGui::Dummy(ImVec2(0, 0));
    }
    ImGui::EndGroup();
#ifdef OPTISCALER_NR_SELF_TEST
    NrAddonHost::RecordNrItem(label, id, left, left + width, firstVertex);
#endif
    ImGui::PopID();
    return changed;
}

enum class TimingSource { Unknown, Present, FgPresent, OverlayFrame };
enum class TimingState { Unavailable, Measured, Overlapping };
struct TimingView
{
    TimingSource source = TimingSource::Unknown;
    TimingState state = TimingState::Unavailable;
    double nrMs = 0.0, intervalMs = 0.0;
    float fraction = 0.0f;
};

inline TimingSource IntervalSource(bool nativeVulkan, bool frameGeneration)
{
    return nativeVulkan ? TimingSource::OverlayFrame :
           frameGeneration ? TimingSource::FgPresent : TimingSource::Present;
}

// Geometry compares two measured intervals, not exclusive remaining GPU work
// or output application. Invalid samples never enter the progress bar.
inline TimingView ResolveTiming(double nrMs, double intervalMs, TimingSource source)
{
    TimingView view;
    view.source = source;
    if (source == TimingSource::Unknown || !std::isfinite(nrMs) || nrMs <= 0.0 ||
        !std::isfinite(intervalMs) || intervalMs <= 0.0)
        return view;
    view.nrMs = nrMs;
    view.intervalMs = intervalMs;
    view.state = nrMs > intervalMs ? TimingState::Overlapping : TimingState::Measured;
    view.fraction = float(nrMs / std::max(nrMs, intervalMs));
    return view;
}

inline void DrawTimingBar(double nrMs, double intervalMs, TimingSource source)
{
    const auto timing = ResolveTiming(nrMs, intervalMs, source);
    const char* sourceName = source == TimingSource::Present ? "swapchain Present interval" :
        source == TimingSource::FgPresent ? "FG Present interval" :
        source == TimingSource::OverlayFrame ? "overlay frame interval" : "unknown";
    ImGui::TextWrapped("Interval source: %s.", sourceName);
    if (timing.state == TimingState::Unavailable)
    {
        ImGui::TextDisabled("Waiting for frame timing.");
        return;
    }
    ImGui::TextWrapped("NR GPU elapsed %.2f ms  |  measured interval %.2f ms", timing.nrMs, timing.intervalMs);
    const auto text = ImGui::GetStyleColorVec4(ImGuiCol_Text);
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(text.x * 0.20f, text.y * 0.55f, text.z * 0.25f, text.w));
    ImGui::ProgressBar(timing.fraction, ImVec2(-1.0f, ImGui::GetFontSize()), "");
    ImGui::PopStyleColor();
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("NR GPU elapsed versus the measured wall-clock interval. Work can overlap; "
                          "this is not exclusive GPU work or output application.");
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextDisabled("Measured interval: %.2f ms%s", timing.intervalMs,
                        timing.state == TimingState::Overlapping ? " (NR exceeds this interval)" : "");
    ImGui::PopTextWrapPos();
}

// This describes the configured colour/edit flow. It never changes a rendering option.
inline void Draw(const View& view, Section& selected)
{
    ImGui::PushID("NR pipeline chart");
    ImGui::SeparatorText("Configured NR flow");
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextDisabled("Configured stages only - not proof of applied output.");
    ImGui::PopTextWrapPos();
    const ImVec2 origin = ImGui::GetCursorScreenPos();
    const float width = std::max(ImGui::GetContentRegionAvail().x, 1.0f);
    const float gap = ImGui::GetFontSize() * 1.5f;
    const bool split = view.enabled && (view.route == Route::Deferred ||
                                        view.route == Route::FinishedBefore);
    const bool finished = view.route == Route::Finished || view.route == Route::FinishedBefore;
    enum Stage { GameInput, Upscale, Effects, Prepare, Model, Apply, Enlarge, GameOutput };
    struct Label { std::string title; std::string detail; int section = -1; };
    Label labels[] = {
        { "Game input", "Placement / routing", (int) Section::Placement },
        { view.rayReconstruction ? "RR + Super Resolution" : "Super Resolution",
          split ? "Clean game image" : "Game upscaler" },
        { "Game effects + HUD", "Game rendering" },
        { "Prepare NR input", "HDR / paper white / " + std::to_string(view.scalePercent) + "%", (int) Section::Input },
        { "NR model", std::to_string(view.passes) + (view.passes == 1 ? " pass" : " passes"), (int) Section::Model },
        { "Apply NR edit", view.applyModel ? std::string("Strength / skin\n") +
                                                ReconstructionName(view.reconstruction.effective)
                                          : "Configured edit hidden", (int) Section::Blend },
        { "Upscale NR edit", std::string("Separate ") + view.privateUpscaler + " pass (no RR)" },
        { "Game output", "FG / presentation" }
    };
    for (auto& label : labels)
    {
        label.title = Localization::Translate(label.title);
        label.detail = Localization::Translate(label.detail);
    }
    // AddText bypasses ordinary widget localization. Translate once above,
    // then measure those exact bytes with the font's matching wrap routine.
    // A second CalcTextSize localization pass could normalize translated
    // multi-line detail text and measure bytes different from the raw draw.
    const auto measure = [](const std::string& text, float wrap)
    {
        return ImGui::GetFont()->CalcTextSizeA(ImGui::GetFontSize(), FLT_MAX, wrap, text.c_str());
    };
    // Parents encode the two branches directly; ordinary routes are simple ordered stages.
    struct Node { Stage stage; int lane, row, parent, otherParent = -1; };
    std::vector<Node> nodes;
    if (split)
    {
        nodes = { { GameInput, 0, 0, -1 }, { Prepare, -1, 1, 0 }, { Model, -1, 2, 1 },
                  { Enlarge, -1, 3, 2 }, { Upscale, 1, 1, 0 } };
        if (finished)
            nodes.push_back({ Effects, 1, 2, 4 });
        nodes.push_back({ Apply, 0, 4, 3, (int) nodes.size() - 1 });
        if (!finished)
            nodes.push_back({ Effects, 0, 5, (int) nodes.size() - 1 });
        nodes.push_back({ GameOutput, 0, finished ? 5 : 6, (int) nodes.size() - 1 });
    }
    else
    {
        static constexpr Stage off[] = { GameInput, Upscale, Effects, GameOutput };
        static constexpr Stage before[] = { GameInput, Prepare, Model, Apply, Upscale, Effects, GameOutput };
        static constexpr Stage after[] = { GameInput, Upscale, Prepare, Model, Apply, Effects, GameOutput };
        static constexpr Stage present[] = { GameInput, Upscale, Effects, Prepare, Model, Apply, GameOutput };
        std::span<const Stage> flow = off;
        if (view.enabled)
            flow = view.route == Route::Before ? std::span(before) : finished ? std::span(present) : std::span(after);
        for (auto stage : flow)
        {
            const int row = (int) nodes.size();
            nodes.push_back({ stage, 0, row, row - 1 });
        }
    }
    const float padding = ImGui::GetStyle().FramePadding.x + 4.0f;
    float minimumNodeWidth = 0.0f;
    for (const auto& node : nodes)
    {
        const auto& label = labels[node.stage];
        minimumNodeWidth = std::max(minimumNodeWidth,
            std::max(measure(label.title, 0).x, measure(label.detail, 0).x) + padding * 2);
    }
    const bool stacked = split && width < minimumNodeWidth * 2 + gap;
    const float nodeWidth = stacked ? std::max(width - gap * 2, 1.0f) :
        split ? std::max((width - gap) * 0.5f, 1.0f) : std::min(width, ImGui::GetFontSize() * 27.0f);
    if (stacked)
        for (int i = 0; i < (int) nodes.size(); ++i)
        {
            nodes[i].lane = 0;
            nodes[i].row = i;
        }
    const int lastRow = nodes.back().row;

    // Translate, measure and wrap the same bytes; keep both causal branches even when stacked.
    const float wrapWidth = std::max(nodeWidth - padding * 2.0f, 1.0f);
    float height = 0.0f;
    for (const auto& node : nodes)
    {
        const auto& label = labels[node.stage];
        height = std::max(height, measure(label.title, wrapWidth).y +
                                 measure(label.detail, wrapWidth).y + 12.0f);
    }
    const float step = height + gap;
    const auto topLeft = [&](int index)
    {
        const auto& node = nodes[index];
        const float x = node.lane < 0 ? 0.0f : node.lane > 0 ? width - nodeWidth : (width - nodeWidth) * 0.5f;
        return ImVec2(origin.x + x, origin.y + node.row * step);
    };
    auto* draw = ImGui::GetWindowDrawList();
    const ImU32 lineColour = ImGui::GetColorU32(ImGuiCol_TextDisabled);
    for (int i = 0; i < (int) nodes.size(); ++i)
    for (int parent : { nodes[i].parent, nodes[i].otherParent })
    {
        if (parent < 0) continue;
        const auto a = topLeft(parent), b = topLeft(i);
        const ImVec2 start(a.x + nodeWidth * 0.5f, a.y + height), end(b.x + nodeWidth * 0.5f, b.y);
        const float bend = end.y - gap * 0.5f;
        if (stacked && nodes[i].row > nodes[parent].row + 1)
        {
            // Branch edges bypass intervening nodes rather than cross their labels.
            const float edge = origin.x + (parent == 0 ? width - gap * 0.5f : gap * 0.5f);
            const float leave = start.y + gap * 0.5f;
            draw->AddLine(start, ImVec2(start.x, leave), lineColour, 1.5f);
            draw->AddLine(ImVec2(start.x, leave), ImVec2(edge, leave), lineColour, 1.5f);
            draw->AddLine(ImVec2(edge, leave), ImVec2(edge, bend), lineColour, 1.5f);
            draw->AddLine(ImVec2(edge, bend), ImVec2(end.x, bend), lineColour, 1.5f);
        }
        else
        {
            draw->AddLine(start, ImVec2(start.x, bend), lineColour, 1.5f);
            draw->AddLine(ImVec2(start.x, bend), ImVec2(end.x, bend), lineColour, 1.5f);
        }
        draw->AddLine(ImVec2(end.x, bend), end, lineColour, 1.5f);
        draw->AddTriangleFilled(end, ImVec2(end.x - 3, end.y - 5), ImVec2(end.x + 3, end.y - 5), lineColour);
    }
    for (int i = 0; i < (int) nodes.size(); ++i)
    {
        const auto& label = labels[nodes[i].stage];
        const auto at = topLeft(i);
        ImGui::SetCursorScreenPos(at);
        ImGui::PushID(i);
#ifdef OPTISCALER_NR_SELF_TEST
        const int firstVertex = draw->VtxBuffer.Size;
#endif
        const bool editable = label.section >= 0;
        const bool chosen = editable && label.section == (int) selected;
        bool hovered = false;
        if (editable)
        {
            if (ImGui::InvisibleButton("stage", ImVec2(nodeWidth, height)))
                selected = (Section) label.section;
            hovered = ImGui::IsItemHovered();
        }
        else
            ImGui::Dummy(ImVec2(nodeWidth, height));
        const auto background = chosen     ? ImGuiCol_HeaderActive
                                : hovered  ? ImGuiCol_ButtonHovered
                                : editable ? ImGuiCol_Button
                                           : ImGuiCol_FrameBg;
        auto fill = ImGui::GetStyleColorVec4(background);
        draw->AddRectFilled(at, ImVec2(at.x + nodeWidth, at.y + height), ImGui::GetColorU32(fill),
                            ImGui::GetStyle().FrameRounding);
        const auto titleSize = measure(label.title, wrapWidth);
        const auto detailSize = measure(label.detail, wrapWidth);
        const float y = at.y + (height - titleSize.y - detailSize.y) * 0.5f;
        draw->AddText(nullptr, 0.0f, ImVec2(at.x + (nodeWidth - titleSize.x) * 0.5f, y),
                      ImGui::GetColorU32(ImGuiCol_Text), label.title.c_str(), nullptr, wrapWidth);
        draw->AddText(nullptr, 0.0f, ImVec2(at.x + (nodeWidth - detailSize.x) * 0.5f, y + titleSize.y),
                      ImGui::GetColorU32(editable ? ImGuiCol_Text : ImGuiCol_TextDisabled), label.detail.c_str(),
                      nullptr, wrapWidth);
#ifdef OPTISCALER_NR_SELF_TEST
        NrAddonHost::RecordNrStage(i, (int) nodes[i].stage, nodes[i].parent, nodes[i].otherParent,
                                  at.x, at.x + nodeWidth, firstVertex);
#endif
        ImGui::PopID();
    }
    ImGui::SetCursorScreenPos(ImVec2(origin.x, origin.y + (lastRow + 1) * step));
    ImGui::Dummy(ImVec2(width, 0));
    // Inspection is a tool, not a colour path or a processing stage.
    float toolUsed = 0.0f;
    const auto tool = [&](const char* label, Section section)
    {
        const float buttonWidth = ImGui::CalcTextSize(label).x + ImGui::GetStyle().FramePadding.x * 2;
        if (toolUsed > 0 && toolUsed + ImGui::GetStyle().ItemSpacing.x + buttonWidth <= width)
        {
            ImGui::SameLine();
            toolUsed += ImGui::GetStyle().ItemSpacing.x;
        }
        else
            toolUsed = 0;
        const bool chosen = selected == section;
        if (chosen)
            ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyleColorVec4(ImGuiCol_HeaderActive));
        if (ImGui::Button(label))
            selected = section;
        if (chosen)
            ImGui::PopStyleColor();
        toolUsed += buttonWidth;
    };
    if (!view.enabled)
    {
        tool("Prepare input", Section::Input);
        tool("Model passes", Section::Model);
        tool("Apply edit", Section::Blend);
    }
    ImGui::PopID();
}
} // namespace DlssNr::PipelineUi
