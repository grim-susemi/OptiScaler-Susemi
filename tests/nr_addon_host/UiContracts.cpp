#include <pch.h>
#include "UiServices.h"
#include <dlssnr/DlssNr_PipelineUi.h>
#include <dlssnr/DlssNr_Placement.h>
#include <dlssnr/DlssNr_PlacementConfig.h>
#include <dlssnr/DlssNr_MenuSections.h>
#include <dlssnr/PassProfiles.h>
#include <shaders/dlssnr/DlssNr_Dx12.h>
#include <cstdio>
#include <stdexcept>
#include <limits>
#include <array>
#include <proxies/FfxApi_Proxy.h>
#include <imgui/imgui_internal.h>
#include <menu/menu_common.h>

#ifndef OPTISCALER_NR_SELF_TEST
#error UI contracts must never enter a product build.
#endif

namespace NrAddonHost
{
namespace
{
struct NrItem
{
    const char* label;
    ImGuiID id;
    ImGuiID windowId;
    bool disabled;
    ImRect item;
    float left, right;
    float top, bottom;
    int vertices;
    float drawLeft, drawRight;
    float drawTop, drawBottom;
};
using PlacementValues = std::array<std::optional<bool>, 5>;
PlacementValues PlacementSnapshot(Config& config)
{
    return { config.DlssNrRunBeforeSr.value_for_config(), config.DlssNrFinishedPicture.value_for_config(),
             config.DlssNrDeferredDlss.value_for_config(), config.DlssNrResidualAcrossRr.value_for_config(),
             config.DlssNrAutomaticUICorrection.value_for_config() };
}
unsigned PlacementBits(const PlacementValues& values)
{
    unsigned bits = 0;
    for (unsigned i = 0; i < values.size(); ++i)
        bits |= unsigned(values[i].value_or(false)) << i;
    return bits;
}
// Independent checkbox transition oracle: no production edit/resolver call.
PlacementValues ExpectedCheckboxEdit(PlacementValues values, int control)
{
    const unsigned bits = PlacementBits(values);
    const bool before = bits & 1, finished = bits & 2;
    const bool deferred = (bits & 4) || (before && ((bits & 8) || finished));
    if (control == 0)
    {
        if (deferred)
            return values;
        values[0] = !before;
        values[3] = false;
    }
    else if (control == 1)
        values[1] = !finished;
    else if (control == 2)
    {
        values[2] = !deferred;
        values[3] = false;
        if (!deferred || finished)
            values[0] = !deferred;
    }
    else
        return values;
    const auto edited = PlacementBits(values);
    const bool editedDeferred = (edited & 4) || ((edited & 1) && ((edited & 8) || (edited & 2)));
    if (!editedDeferred)
    {
        values[3] = false;
        values[4] = true;
    }
    // WithDefault bool false is serialized as auto, not optional(false).
    // Compare the exact saved carrier in addition to the independently derived bits.
    for (auto& value : values)
        if (value == std::optional<bool>(false))
            value.reset();
    return values;
}
void CheckPlacementFrame(const PlacementValues& before, const PlacementValues& after,
                         int control, uint64_t retryDelta)
{
    const auto expected = ExpectedCheckboxEdit(before, control);
    const bool changed = expected != before;
    if (after != expected || retryDelta != unsigned(changed))
        throw std::runtime_error("TASK19_UNREQUESTED_PLACEMENT_OR_RETRY_CHANGE");
}
std::string OptionsSnapshot(Config& config)
{
    CSimpleIniA ini;
    DlssNr::SaveOptionsConfig(config, ini);
    std::string bytes;
    if (ini.Save(bytes) < 0)
        throw std::runtime_error("TASK19_OPTIONS_SERIALIZATION_FAILED");
    return bytes;
}
PlacementValues placementBefore;
uint64_t placementRetryBefore = 0;
uint64_t placementInvocation = 0;
std::string placementOptionsBefore;
std::vector<NrItem> nrItems;
int nrItemsFrame = -1;
struct NrStage
{
    int index, stage, parent, otherParent;
    ImRect item;
    ImRect draw;
    int vertices;
};
std::vector<NrStage> nrStages;
int nrStagesFrame = -1;
int mainColumnMeasurementFrame = -1;
float mainColumnMinimum = 0;
float mainColumnFontSize = 0;
struct OptionObservation
{
    int frame = -1;
    ImGuiID id = 0;
    ImRect item;
    bool selectable = false, hovered = false, current = false, supported = false;
    unsigned requested = 0, effective = 0;
};
std::array<OptionObservation, 2> optionObservations;

bool NrItemOutsideCell(const NrItem& item)
{
    return !item.id || !std::isfinite(item.left) || !std::isfinite(item.right) ||
           !std::isfinite(item.top) || !std::isfinite(item.bottom) ||
           !std::isfinite(item.item.Min.x) || !std::isfinite(item.item.Min.y) ||
           !std::isfinite(item.item.Max.x) || !std::isfinite(item.item.Max.y) ||
           item.item.Min.x < item.left - 1 || item.item.Max.x > item.right + 1 ||
           item.item.Min.y < item.top - 1 || item.item.Max.y > item.bottom + 1 ||
           (item.vertices && (!std::isfinite(item.drawLeft) || !std::isfinite(item.drawRight) ||
                             !std::isfinite(item.drawTop) || !std::isfinite(item.drawBottom) ||
                             item.drawLeft < item.left - 1 || item.drawRight > item.right + 1 ||
                             item.drawTop < item.top - 1 || item.drawBottom > item.bottom + 1));
}
}

void RecordNrOption(unsigned control, bool selectable, bool hovered, bool current,
                    unsigned requested, unsigned effective, bool supported)
{
    const auto& g = *ImGui::GetCurrentContext();
    optionObservations.at(control) = { g.FrameCount, g.LastItemData.ID,
        ImRect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax()), selectable, hovered, current,
        supported, requested, effective };
    if (bool(g.LastItemData.ItemFlags & ImGuiItemFlags_Disabled) == selectable)
        throw std::runtime_error("TASK8_OPTION_DISABLED_ITEM_MISMATCH");
}

void BeginPlacementEditFrame(Config& config)
{
    placementBefore = PlacementSnapshot(config);
    placementRetryBefore = DlssNr::ReadControlRequests().retryGeneration;
    placementOptionsBefore = OptionsSnapshot(config);
}

void EndPlacementEditFrame(Config& config, const std::filesystem::path& root, bool drawn)
{
    const auto& g = *ImGui::GetCurrentContext();
    const auto after = PlacementSnapshot(config);
    const auto retry = DlssNr::ReadControlRequests().retryGeneration;
    int control = -1;
    const NrItem* hit = nullptr;
    const char* labels[] = { "Generate model before upscale", "Apply NR to the finished picture",
                             "Generate before upscale, apply after upscale" };
    if (drawn && nrItemsFrame == g.FrameCount && g.IO.MouseReleased[0])
        for (const auto& item : nrItems)
            for (int i = 0; i < 3; ++i)
                if (std::strcmp(item.label, labels[i]) == 0 && item.id == g.HoveredId &&
                    item.id == g.ActiveIdPreviousFrame && g.HoveredWindow &&
                    g.HoveredWindow->ID == item.windowId && !item.disabled)
                {
                    control = i;
                    hit = &item;
                }
    CheckPlacementFrame(placementBefore, after, control, retry - placementRetryBefore);
    if (OptionsSnapshot(config) != placementOptionsBefore)
        throw std::runtime_error("TASK19_UNRELATED_OPTIONS_CHANGED");
    const bool changed = after != placementBefore;
    std::printf("TASK7_PLACEMENT_FRAME frame=%d invocation=%llu drawn=%u control=%d before=%u after=%u adopted=%u "
                "retryBefore=%llu retryAfter=%llu changed=%u owner=%08X hovered=%08X "
                "activePrevious=%08X expectedWindow=%08X actualWindow=%08X optionsEqual=1\n",
                g.FrameCount, ++placementInvocation, unsigned(drawn), control, PlacementBits(placementBefore), PlacementBits(after),
                unsigned(config.DlssNrAutomaticUICorrection.value_or_default()),
                placementRetryBefore, retry, unsigned(changed), hit ? hit->id : 0, g.HoveredId,
                g.ActiveIdPreviousFrame, hit ? hit->windowId : 0, g.HoveredWindow ? g.HoveredWindow->ID : 0);
    if (changed)
    {
        CSimpleIniA saved;
        if (saved.LoadFile((root / "owned-fixture.ini").c_str()) != SI_OK)
            throw std::runtime_error("TASK19_OWNED_SEED_REOPEN_FAILED");
        DlssNr::SavePlacementConfig(config, saved);
        DlssNr::SaveOptionsConfig(config, saved);
        const auto path = root / ("edit-" + std::to_string(g.FrameCount) + ".ini");
        if (saved.SaveFile(path.c_str()) < 0)
            throw std::runtime_error("TASK19_OWNED_EDIT_SAVE_FAILED");
        CSimpleIniA reopened;
        if (reopened.LoadFile(path.c_str()) != SI_OK)
            throw std::runtime_error("TASK19_OWNED_EDIT_RELOAD_FAILED");
        const char* keys[] = { "RunBeforeSR", "FinishedPicture", "DeferredDLSS", "ResidualAcrossRR",
                               "AutomaticUICorrection" };
        for (unsigned i = 0; i < 5; ++i)
            if (DlssNr::ReadPlacementBool(reopened, keys[i]).value_or(false) != after[i].value_or(false))
                throw std::runtime_error("TASK19_OWNED_EDIT_ROUNDTRIP_CHANGED");
        if (std::string_view(reopened.GetValue("Other", "Retain", "")) != "77")
            throw std::runtime_error("TASK19_UNRELATED_SECTION_CHANGED");
        std::printf("TASK7_NATIVE_ROUNDTRIP frame=%d savedFlags=%u alias=%u unrelated=77 fixtureOnly=1\n",
                    g.FrameCount, PlacementBits(after), unsigned(reopened.GetValue("DlssNr", "BeforeUpscale") != nullptr));
    }
    std::fflush(stdout);
}

void RecordMenuColumnMeasurement()
{
    auto* config = Config::Instance();
    std::printf("TASK7_VIEW_STATE frame=%d retry=%llu flags=%u adopted=%u\n", ImGui::GetFrameCount(),
                DlssNr::ReadControlRequests().retryGeneration, PlacementBits(PlacementSnapshot(*config)) & 15,
                unsigned(config->DlssNrAutomaticUICorrection.value_or_default()));
    std::fflush(stdout);
    const auto& style = ImGui::GetStyle();
    const float routeWidth = ImGui::GetFrameHeight() + style.ItemInnerSpacing.x + style.FrameBorderSize +
                             ImGui::CalcTextSize("Generate before upscale, apply after upscale").x;
    const float privateWidth = ImGui::GetFrameHeight() * 5 + style.ItemInnerSpacing.x + style.FrameBorderSize +
                               ImGui::CalcTextSize("Private NR upscaler").x +
                               ImGui::CalcTextSize("(?)").x + style.ItemSpacing.x * 2;
    mainColumnMinimum = std::max(routeWidth, privateWidth) + style.IndentSpacing + style.CellPadding.x * 2;
    mainColumnFontSize = ImGui::GetFontSize();
    mainColumnMeasurementFrame = ImGui::GetFrameCount();
}

void RecordNrStage(int index, int stage, int parent, int otherParent, float left, float right, int firstVertex)
{
    if (ImGui::GetCurrentWindow()->SkipItems)
        return;
    const auto& g = *ImGui::GetCurrentContext();
    if (nrStagesFrame != g.FrameCount)
    {
        nrStages.clear();
        nrStagesFrame = g.FrameCount;
    }
    const auto* list = ImGui::GetWindowDrawList();
    ImRect bounds(ImVec2(FLT_MAX, FLT_MAX), ImVec2(-FLT_MAX, -FLT_MAX));
    for (int i = firstVertex; i < list->VtxBuffer.Size; ++i)
        bounds.Add(list->VtxBuffer[i].pos);
    const ImRect item(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    const int vertices = list->VtxBuffer.Size - firstVertex;
    nrStages.push_back({ index, stage, parent, otherParent, item, bounds, vertices });
    if (item.Min.x < left - 1 || item.Max.x > right + 1 ||
        (vertices && (bounds.Min.x < left - 1 || bounds.Max.x > right + 1)))
        throw std::runtime_error("TASK6_CHART_DRAW_OUTSIDE_NODE");
    std::printf("TASK6_NR_STAGE frame=%d index=%d stage=%d parent=%d other=%d "
                "id=%08X window=%08X item=%.2f,%.2f,%.2f,%.2f cell=%.2f,%.2f vertices=%d draw=%.2f,%.2f,%.2f,%.2f\n",
                g.FrameCount, index, stage, parent, otherParent,
                g.LastItemData.ID, ImGui::GetCurrentWindow()->ID,
                item.Min.x, item.Min.y, item.Max.x, item.Max.y, left, right, vertices,
                vertices ? bounds.Min.x : left, vertices ? bounds.Min.y : item.Min.y,
                vertices ? bounds.Max.x : left, vertices ? bounds.Max.y : item.Min.y);
    std::fflush(stdout);
}

void RecordNrItem(const char* label, ImGuiID id, float left, float right, int firstVertex)
{
    const auto& g = *ImGui::GetCurrentContext();
    if (nrItemsFrame != g.FrameCount)
    {
        nrItems.clear();
        nrItemsFrame = g.FrameCount;
    }
    const auto* draw = ImGui::GetWindowDrawList();
    float drawLeft = FLT_MAX, drawRight = -FLT_MAX;
    float drawTop = FLT_MAX, drawBottom = -FLT_MAX;
    for (int i = firstVertex; i < draw->VtxBuffer.Size; ++i)
    {
        drawLeft = std::min(drawLeft, draw->VtxBuffer[i].pos.x);
        drawRight = std::max(drawRight, draw->VtxBuffer[i].pos.x);
        drawTop = std::min(drawTop, draw->VtxBuffer[i].pos.y);
        drawBottom = std::max(drawBottom, draw->VtxBuffer[i].pos.y);
    }
    const auto item = ImRect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    // EndGroup submits this exact group rectangle to ItemSize/ItemAdd for wrapped
    // checkbox/private-upscaler rows; BeginCombo does the same for its total_bb.
    // This is the production vertical allocation, not an inferred draw envelope.
    const float top = item.Min.y, bottom = item.Max.y;
    const int vertices = draw->VtxBuffer.Size - firstVertex;
    nrItems.push_back({ label, id, ImGui::GetCurrentWindow()->ID,
                        bool(g.CurrentItemFlags & ImGuiItemFlags_Disabled),
                        item, left, right, top, bottom, vertices,
                        drawLeft, drawRight, drawTop, drawBottom });
    std::printf("TASK6_NR_ITEM frame=%d label=\"%s\" id=%08X item=%.2f,%.2f,%.2f,%.2f "
                "cell=%.2f,%.2f vertices=%d draw=%.2f,%.2f row=%.9f,%.9f drawY=%.9f,%.9f\n",
                g.FrameCount, label, id, item.Min.x, item.Min.y, item.Max.x, item.Max.y,
                left, right, vertices, vertices ? drawLeft : left, vertices ? drawRight : left,
                top, bottom, vertices ? drawTop : top, vertices ? drawBottom : top);
    std::fflush(stdout);
}

// The native host calls this on the last real production window/table draw.
// It is deliberately not a helper-only or replacement-window sizing test.
void AssertMenuGeometry(const ImGuiWindow& main, const ImGuiTable& table, const ImDrawData& draw,
                        const ImGuiWindow& nr)
{
    const auto& g = *ImGui::GetCurrentContext();
    if (main.Flags & (ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoResize))
        throw std::runtime_error("TASK5_MAIN_MENU_NOT_TWO_AXIS_RESIZABLE");
    if (!(main.Flags & ImGuiWindowFlags_NoSavedSettings) || g.IO.IniFilename || g.IO.LogFilename)
        throw std::runtime_error("TASK5_GEOMETRY_PERSISTENCE_ENABLED");
    if (!std::isfinite(main.Pos.x) || !std::isfinite(main.Pos.y) ||
        !std::isfinite(main.Size.x) || !std::isfinite(main.Size.y) ||
        main.Size.x <= 0 || main.Size.y <= 0 || main.Pos.x < 0 || main.Pos.y < 0 ||
        main.Pos.x + main.Size.x > g.IO.DisplaySize.x + 1.0f ||
        main.Pos.y + main.Size.y > g.IO.DisplaySize.y + 1.0f)
        throw std::runtime_error("TASK5_MAIN_WINDOW_OUTSIDE_DISPLAY");
    const bool nrVisible = !nr.Hidden && nr.Rect().Overlaps(main.InnerClipRect);
    if (mainColumnMeasurementFrame != g.FrameCount)
        throw std::runtime_error("TASK6_ACTIVE_FRAME_COLUMN_MEASUREMENT_MISSING");
    const float frameHeight = mainColumnFontSize + g.Style.FramePadding.y * 2;
    const int expectedColumns = table.OuterRect.GetWidth() >= mainColumnMinimum * 2 ? 2 : 1;
    if (main.LastFrameActive != g.FrameCount || table.LastFrameActive != g.FrameCount ||
        nr.LastFrameActive != g.FrameCount || table.ColumnsCount != expectedColumns ||
        main.DrawList->VtxBuffer.empty() || (nrVisible && nr.DrawList->VtxBuffer.empty()) ||
        draw.TotalVtxCount <= 0 || draw.TotalIdxCount <= 0)
        throw std::runtime_error("TASK5_PRODUCTION_MENU_TABLE_NR_DRAW_MISSING");
    for (const auto* list : draw.CmdLists)
        for (const auto& vertex : list->VtxBuffer)
            if (!std::isfinite(vertex.pos.x) || !std::isfinite(vertex.pos.y))
                throw std::runtime_error("TASK5_NONFINITE_PRODUCTION_GEOMETRY");
    if (nrVisible && nr.Size.y > frameHeight * 2)
    {
        const auto* config = Config::Instance();
        const auto route = DlssNr::ResolvePlacement(config->DlssNrRunBeforeSr.value_or_default(),
            config->DlssNrDeferredDlss.value_or_default(), config->DlssNrResidualAcrossRr.value_or_default(),
            config->DlssNrFinishedPicture.value_or_default());
        if (nrItemsFrame != g.FrameCount || nrItems.size() != 5 + unsigned(route.deferred))
            throw std::runtime_error("TASK6_AFFECTED_NR_CONTROLS_MISSING");
        for (const auto& item : nrItems)
        {
            if (NrItemOutsideCell(item))
            {
                std::printf("TASK6_NR_BOUND_FAIL frame=%d label=\"%s\" item=%.9f,%.9f cell=%.9f,%.9f "
                            "draw=%.9f,%.9f leftLimit=%.9f rightLimit=%.9f "
                            "row=%.9f,%.9f drawY=%.9f,%.9f topLimit=%.9f bottomLimit=%.9f\n",
                            g.FrameCount, item.label, item.item.Min.x, item.item.Max.x, item.left, item.right,
                            item.drawLeft, item.drawRight, item.left - 1, item.right + 1,
                            item.top, item.bottom, item.drawTop, item.drawBottom, item.top - 1, item.bottom + 1);
                std::fflush(stdout);
                throw std::runtime_error(std::string("TASK6_NR_ITEM_OUTSIDE_ALLOCATED_CELL: ") + item.label);
            }
        }
        // A current-frame observation, not manufactured item/draw bounds: only its allocated cell is invalidated.
        auto invalidCell = nrItems.front();
        invalidCell.right = invalidCell.item.Max.x - 2;
        if (!NrItemOutsideCell(invalidCell))
            throw std::runtime_error("TASK6_INVALID_ALLOCATED_CELL_NOT_REJECTED");
        std::printf("TASK6_CURRENT_FRAME_INVALID_CELL_REJECTED frame=%d id=%08X "
                    "actualItemRight=%.9f actualCellRight=%.9f mutatedCellRight=%.9f\n",
                    g.FrameCount, invalidCell.id, invalidCell.item.Max.x, nrItems.front().right, invalidCell.right);
        std::fflush(stdout);
        // Oracle mutation of one current positive-vertex observation. Item/cell X/Y
        // and IDs remain untouched; only the copied emitted Y envelope is invalid.
        const auto observed = std::find_if(nrItems.begin(), nrItems.end(),
                                          [](const NrItem& item) { return item.vertices > 0; });
        if (observed != nrItems.end())
        {
            auto invalidY = *observed;
            invalidY.drawTop = invalidY.top - 2;
            if (!NrItemOutsideCell(invalidY))
                throw std::runtime_error("TASK6_INVALID_EMITTED_Y_ENVELOPE_NOT_REJECTED");
            std::printf("TASK6_CURRENT_FRAME_INVALID_Y_REJECTED classification=ORACLE_MUTATION frame=%d id=%08X "
                        "actualDrawTop=%.9f rowTop=%.9f mutatedDrawTop=%.9f\n",
                        g.FrameCount, invalidY.id, observed->drawTop, invalidY.top, invalidY.drawTop);
            std::fflush(stdout);
        }
        for (int i = 0; i < (int) nrItems.size(); ++i)
        {
            if (nrItems[i].item.Overlaps(nr.ClipRect) && nrItems[i].vertices <= 0)
                throw std::runtime_error("TASK6_VISIBLE_NR_CONTROL_DRAW_MISSING");
            for (int j = 0; j < i; ++j)
                if (nrItems[i].item.Overlaps(nrItems[j].item))
                    throw std::runtime_error("TASK6_NR_CONTROL_ROWS_OVERLAP");
        }
        if (nrStagesFrame != g.FrameCount || nrStages.empty())
            throw std::runtime_error("TASK6_PRODUCTION_CHART_STAGES_MISSING");
        for (int i = 0; i < (int) nrStages.size(); ++i)
        {
            const auto& stage = nrStages[i];
            if (stage.index != i || !stage.vertices ||
                stage.item.Min.x < nr.InnerRect.Min.x - 1 || stage.item.Max.x > nr.InnerRect.Max.x + 1 ||
                stage.draw.Min.y < stage.item.Min.y - 1 || stage.draw.Max.y > stage.item.Max.y + 1)
                throw std::runtime_error("TASK6_CHART_ITEM_DRAW_BOUNDS_INVALID");
            for (int parent : { stage.parent, stage.otherParent })
                if (parent >= 0 && (parent >= i || nrStages[parent].item.Max.y > stage.item.Min.y))
                    throw std::runtime_error("TASK6_CHART_CAUSAL_ORDER_LOST");
            for (int j = 0; j < i; ++j)
                if (stage.item.Overlaps(nrStages[j].item))
                    throw std::runtime_error("TASK6_CHART_NODES_OVERLAP");
        }
    }
    std::printf("TASK6_MAIN_COLUMNS_CONTRACT frame=%d columns=%d expected=%d width=%.2f minimum=%.2f "
                "font=%.2f locale=%s\n", g.FrameCount, table.ColumnsCount, expectedColumns,
                table.OuterRect.GetWidth(), mainColumnMinimum, mainColumnFontSize, Localization::EffectiveLanguageCode());
    std::printf("TASK5_PRODUCTION_GEOMETRY_PASS frame=%d main=%08X table=%08X nr=%08X vertices=%d "
                "nrVisible=%u nrVertices=%d\n",
                g.FrameCount, main.ID, table.ID, nr.ID, draw.TotalVtxCount, unsigned(nrVisible),
                nr.DrawList->VtxBuffer.Size);
    std::fflush(stdout);
}

void RunStartupContracts()
{
    const auto before = FfxApiProxy::OwnedObservation();
    const bool unavailable = !FfxApiProxy::Dx12Module() && !FfxApiProxy::Dx12Module_SR() &&
        !FfxApiProxy::Dx12Module_FG() && !FfxApiProxy::IsFGReady() && !FfxApiProxy::IsFGReady(false) &&
        FfxApiProxy::VersionDx12_FG() == feature_version {};
    const auto& after = FfxApiProxy::OwnedObservation();
    if (!unavailable || after.module != before.module || after.suppliedPath != before.suppliedPath ||
        after.initRequests != before.initRequests || after.exportAccesses != before.exportAccesses ||
        after.nativeCalls != before.nativeCalls || after.loads != before.loads ||
        after.liveContexts != before.liveContexts)
        throw std::runtime_error("HOST_FFX_UI_QUERY_SIDE_EFFECT");
    std::puts("HOST_STARTUP_QUERY_CONTRACT_PASS unavailable=1 init=0 loads=0 exports=0 nativeCalls=0");
}
namespace
{
// CPU-only admission refusal. A failing GetDevice reaches the real inner
// reset, then returns before any picture, queue or GPU work can be used.
struct RefusingQueue final : ID3D12CommandQueue
{
    unsigned deviceCalls = 0;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void** out) override { *out = nullptr; return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void** out) override { ++deviceCalls; *out = nullptr; return E_NOINTERFACE; }
    void STDMETHODCALLTYPE UpdateTileMappings(ID3D12Resource*, UINT, const D3D12_TILED_RESOURCE_COORDINATE*,
        const D3D12_TILE_REGION_SIZE*, ID3D12Heap*, UINT, const D3D12_TILE_RANGE_FLAGS*, const UINT*, const UINT*,
        D3D12_TILE_MAPPING_FLAGS) override {}
    void STDMETHODCALLTYPE CopyTileMappings(ID3D12Resource*, const D3D12_TILED_RESOURCE_COORDINATE*, ID3D12Resource*,
        const D3D12_TILED_RESOURCE_COORDINATE*, const D3D12_TILE_REGION_SIZE*, D3D12_TILE_MAPPING_FLAGS) override {}
    void STDMETHODCALLTYPE ExecuteCommandLists(UINT, ID3D12CommandList* const*) override {}
    void STDMETHODCALLTYPE SetMarker(UINT, const void*, UINT) override {}
    void STDMETHODCALLTYPE BeginEvent(UINT, const void*, UINT) override {}
    void STDMETHODCALLTYPE EndEvent() override {}
    HRESULT STDMETHODCALLTYPE Signal(ID3D12Fence*, UINT64) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Wait(ID3D12Fence*, UINT64) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetTimestampFrequency(UINT64*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetClockCalibration(UINT64*, UINT64*) override { return E_NOTIMPL; }
    D3D12_COMMAND_QUEUE_DESC STDMETHODCALLTYPE GetDesc() override { return {}; }
};

struct UnusedPicture final : ID3D12Resource
{
    unsigned accesses = 0;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void** out) override { ++accesses; *out = nullptr; return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { ++accesses; return 1; }
    ULONG STDMETHODCALLTYPE Release() override { ++accesses; return 1; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID, UINT*, void*) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID, UINT, const void*) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID, const IUnknown*) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID, void** out) override { ++accesses; *out = nullptr; return E_NOINTERFACE; }
    HRESULT STDMETHODCALLTYPE Map(UINT, const D3D12_RANGE*, void**) override { ++accesses; return E_NOTIMPL; }
    void STDMETHODCALLTYPE Unmap(UINT, const D3D12_RANGE*) override { ++accesses; }
    D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc() override { ++accesses; return {}; }
    D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE GetGPUVirtualAddress() override { ++accesses; return 0; }
    HRESULT STDMETHODCALLTYPE WriteToSubresource(UINT, const D3D12_BOX*, const void*, UINT, UINT) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE ReadFromSubresource(void*, UINT, UINT, UINT, const D3D12_BOX*) override { ++accesses; return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetHeapProperties(D3D12_HEAP_PROPERTIES*, D3D12_HEAP_FLAGS*) override { ++accesses; return E_NOTIMPL; }
};
} // namespace
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

        // Seed explicit fixture values, then execute the actual production
        // public finished caller and its State::Publish, without a GPU.
        services.Select(Fixture::FilterHdr);
        config->DlssNrFinishedPicture = true;
        config->DlssNrRunBeforeSr = false;
        DlssNr_Dx12 shader("Task2 CPU finished-caller fixture", nullptr);
        OutputStatus evaluated;
        evaluated.state = OutputState::EvaluatedHidden;
        evaluated.evaluated = true;
        evaluated.hidden = true;
        evaluated.generation = 17;
        evaluated.uiCorrection = 0;
        evaluated.optionContext = { 1920, 1080, 1248, 702, true, true };
        const FinishedIdentity identity { &shader, &services, 17, 91, true };
        unsigned resetFailures = 0;
        for (const auto stage : { FinishedFixtureStage::Public, FinishedFixtureStage::Internal,
                                  FinishedFixtureStage::Capture })
        {
            FinishedStatusFixture = FinishedCallerFixture { evaluated, stage };
            RefusingQueue queue;
            UnusedPicture picture;
            const bool inner = stage == FinishedFixtureStage::Internal;
            check(!shader.ApplyFinished(inner ? &picture : nullptr, inner ? &queue : nullptr,
                                        DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, false, identity), "not-applied");
            const auto skipped = ReadStatus(Backend::Dx12);
            const auto& observed = stage == FinishedFixtureStage::Capture ? *FinishedStatusObserved : skipped.output;
            check(skipped.output.state == OutputState::Skipped &&
                      skipped.output.reason == OutputReason::Admission && !skipped.output.Applied() &&
                      !skipped.output.evaluated && !skipped.output.composed && !skipped.output.executed &&
                      !skipped.output.submitted, "not-applied");
            check(queue.deviceCalls == unsigned(inner) && !picture.accesses, "cpu-admission-no-gpu-work");
            const bool kept = observed.optionContext.inputWidth == 1920 &&
                observed.optionContext.workingWidth == 1248 && observed.optionContext.hdrProxy &&
                observed.uiCorrection == 0;
            resetFailures += !kept;
            check(skipped.modelFacts.contextState == ModelContextState::Current &&
                      skipped.modelFacts.backend == Backend::Dx12 &&
                      skipped.modelFacts.identity.generation == 17, "current-model-identity");
            std::printf("TASK2_CASE=model-facts-after-skipped-present stage=%u retained=%u "
                        "caller=production fixture-values=1 gpu=0\n", unsigned(stage), unsigned(kept));
        }
        check(!resetFailures, "model-facts-after-skipped-present");

        auto ownerless = identity;
        ownerless.owner = nullptr; // Real Consumer() tokens do not name an NR shader.
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, ownerless), "not-applied");
        check(ReadStatus(Backend::Dx12).modelFacts.contextState == ModelContextState::Current &&
                  ReadStatus(Backend::Dx12).output.optionContext.inputWidth == 1920,
              "consumer-without-nr-owner");
        std::puts("TASK2_CASE=consumer-without-nr-owner current=1 caller=production");

        auto changed = identity;
        changed.generation = 18;
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, changed), "not-applied");
        auto stale = ReadStatus(Backend::Dx12);
        check(stale.modelFacts.contextState == ModelContextState::Absent &&
                  !stale.output.optionContext.inputWidth && stale.output.generation == 18 &&
                  !stale.output.Applied(), "old-generation-context");
        std::puts("TASK2_CASE=old-generation-context rejected=1 caller=production");

        FinishedStatusFixture = FinishedCallerFixture { evaluated };
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, identity), "not-applied");
        auto foreignOwner = identity;
        foreignOwner.owner = config;
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, foreignOwner), "not-applied");
        check(ReadStatus(Backend::Dx12).modelFacts.contextState == ModelContextState::Absent,
              "foreign-model-owner");

        FinishedStatusFixture = FinishedCallerFixture { evaluated, FinishedFixtureStage::Public, Backend::Vulkan };
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, identity), "not-applied");
        stale = ReadStatus(Backend::Dx12);
        check(stale.modelFacts.contextState == ModelContextState::Absent &&
                  !stale.output.optionContext.inputWidth, "old-backend-context");

        FinishedStatusFixture = FinishedCallerFixture { evaluated };
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709,
                                    false, identity), "not-applied");
        check(!shader.ApplyFinished(nullptr, nullptr, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709),
              "not-applied");
        stale = ReadStatus(Backend::Dx12);
        check(stale.modelFacts.contextState == ModelContextState::Unknown &&
                  !stale.output.optionContext.inputWidth && !stale.output.generation &&
                  !stale.output.Applied(), "unknown-current-context");

        evaluated.state = OutputState::Submitted;
        evaluated.hidden = false;
        check(!evaluated.Applied(), "not-applied");
        std::puts("TASK2_CASE=not-applied evaluated-only=1 rejected=1");

        services.Publish();
        const auto initial = ReadStatus(Backend::Dx12);
        {
            MenuStatusScope scope;
            auto changedView = initial;
            changedView.output.optionContext.inputWidth = 77;
            PublishStatus(&services, Backend::Dx12, changedView);
            check(ReadStatus(Backend::Dx12).output.optionContext.inputWidth ==
                      initial.output.optionContext.inputWidth, "menu-consistent-snapshot");
        }
        check(ReadStatus(Backend::Dx12).output.optionContext.inputWidth == 77,
              "menu-snapshot-next-draw");

        {
            const auto context = std::unique_ptr<ImGuiContext, void (*)(ImGuiContext*)>(
                ImGui::CreateContext(), ImGui::DestroyContext);
            auto& io = ImGui::GetIO();
            io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
            io.DisplaySize = ImVec2(480.0f, 720.0f);
            io.DeltaTime = 1.0f / 60.0f;
            io.IniFilename = nullptr;
            io.LogFilename = nullptr;
            using PipelineUi::TimingSource;
            using PipelineUi::TimingState;
            check(PipelineUi::IntervalSource(false, false) == TimingSource::Present &&
                      PipelineUi::IntervalSource(false, true) == TimingSource::FgPresent &&
                      PipelineUi::IntervalSource(true, true) == TimingSource::OverlayFrame,
                  "timing-source");
            struct TimingCase { double nr, interval; TimingState expected; };
            const double nan = std::numeric_limits<double>::quiet_NaN();
            const double infinity = std::numeric_limits<double>::infinity();
            const double largest = std::numeric_limits<double>::max();
            const TimingCase timingCases[] = {
                { 1, 16, TimingState::Measured }, { 16, 8, TimingState::Overlapping },
                { 8, 8, TimingState::Measured }, { 0, 16, TimingState::Unavailable },
                { 1, 0, TimingState::Unavailable }, { -1, 16, TimingState::Unavailable },
                { 1, -1, TimingState::Unavailable }, { nan, 16, TimingState::Unavailable },
                { 1, nan, TimingState::Unavailable }, { infinity, 16, TimingState::Unavailable },
                { 1, infinity, TimingState::Unavailable }, { largest, largest, TimingState::Measured }
            };
            unsigned frames = 0;
            for (const auto source : { TimingSource::Present, TimingSource::FgPresent,
                                       TimingSource::OverlayFrame, TimingSource::Unknown })
            for (const auto& sample : timingCases)
            {
                const auto timing = PipelineUi::ResolveTiming(sample.nr, sample.interval, source);
                check(timing.source == source &&
                          timing.state == (source == TimingSource::Unknown ? TimingState::Unavailable : sample.expected),
                      "timing-source");
                check(std::isfinite(timing.nrMs) && std::isfinite(timing.intervalMs) &&
                          std::isfinite(timing.fraction) && timing.fraction >= 0.0f && timing.fraction <= 1.0f,
                      "timing-finite-geometry");
                ImGui::NewFrame();
                ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
                ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
                ImGui::Begin("Task2 timing CPU draw", nullptr, ImGuiWindowFlags_NoSavedSettings);
                const auto vertices = ImGui::GetWindowDrawList()->VtxBuffer.Size;
                PipelineUi::DrawTimingBar(sample.nr, sample.interval, source);
                check(ImGui::GetWindowDrawList()->VtxBuffer.Size > vertices, "timing-nonblank-draw");
                ImGui::End();
                ImGui::Render();
                const auto* data = ImGui::GetDrawData();
                check(data && data->TotalVtxCount > 0, "timing-nonblank-draw");
                for (const auto* list : data->CmdLists)
                {
                    for (const auto& vertex : list->VtxBuffer)
                        check(std::isfinite(vertex.pos.x) && std::isfinite(vertex.pos.y), "timing-finite-geometry");
                    for (const auto& command : list->CmdBuffer)
                        check(std::isfinite(command.ClipRect.x) && std::isfinite(command.ClipRect.y) &&
                                  std::isfinite(command.ClipRect.z) && std::isfinite(command.ClipRect.w),
                              "timing-finite-geometry");
                }
                check(!ReadStatus(Backend::Dx12).output.Applied(), "not-applied");
                ++frames;
            }
            std::printf("TASK2_CASE=timing-source cpu-draw-frames=%u finite=1 gpu=0 visual-claim=0\n", frames);
        }
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
    unsigned checkboxCases = 0, unchangedCases = 0, rejectedObservations = 0;
    for (unsigned mask = 0; mask < 16; ++mask)
    for (int marker = -1; marker <= 1; ++marker)
    for (int control = 0; control < 3; ++control)
    {
        CSimpleIniA input;
        const char* keys[] = { "RunBeforeSR", "FinishedPicture", "DeferredDLSS", "ResidualAcrossRR" };
        for (unsigned bit = 0; bit < 4; ++bit)
            input.SetValue("DlssNr", keys[bit], mask & (1u << bit) ? "true" : "false");
        if (marker >= 0)
            input.SetValue("DlssNr", "AutomaticUICorrection", marker ? "true" : "false");
        input.SetValue("DlssNr", "BeforeUpscale", "true");
        input.SetValue("DlssNr", "Transfer", "4");
        input.SetValue("Other", "Retain", "77");
        check(input.SaveFile(inputPath.c_str()) >= 0, "checkbox-owned-input-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "checkbox-owned-input-load");
        const auto retryBeforeLoad = ReadControlRequests().retryGeneration;
        Config config;
        LoadPlacementConfig(config, loaded);
        const auto before = PlacementSnapshot(config);
        check((PlacementBits(before) & 15) == mask &&
                  ReadControlRequests().retryGeneration == retryBeforeLoad, "load-does-not-retry-or-migrate");
        const bool derivedDeferred = (mask & 4) || ((mask & 1) && ((mask & 8) || (mask & 2)));
        const bool shown = control == 0 ? bool((mask & 1) || derivedDeferred) :
                           control == 1 ? bool(mask & 2) : derivedDeferred;
        check(!EditPlacementCheckbox(config, static_cast<PlacementCheckbox>(control), shown) &&
                  PlacementSnapshot(config) == before && ReadControlRequests().retryGeneration == retryBeforeLoad,
              "unchanged-checkbox-does-not-adopt-or-retry");
        ++unchangedCases;
        const auto expected = ExpectedCheckboxEdit(before, control);
        const bool changed = expected != before;
        const bool edited = EditPlacementCheckbox(config, static_cast<PlacementCheckbox>(control), !shown);
        const auto after = PlacementSnapshot(config);
        const auto retryAfter = ReadControlRequests().retryGeneration;
        check(edited == changed && after == expected && retryAfter - retryBeforeLoad == unsigned(changed),
              "actual-checkbox-transition-and-one-retry");
        CheckPlacementFrame(before, after, changed ? control : -1, retryAfter - retryBeforeLoad);
        check(!EditPlacementCheckbox(config, static_cast<PlacementCheckbox>(control),
                  control == 0 ? bool((PlacementBits(after) & 1) || ((PlacementBits(after) & 4) ||
                      ((PlacementBits(after) & 1) && ((PlacementBits(after) & 8) || (PlacementBits(after) & 2))))) :
                  control == 1 ? bool(PlacementBits(after) & 2) :
                      bool((PlacementBits(after) & 4) || ((PlacementBits(after) & 1) &&
                          ((PlacementBits(after) & 8) || (PlacementBits(after) & 2))))) &&
                  PlacementSnapshot(config) == after && ReadControlRequests().retryGeneration == retryAfter,
              "next-unchanged-frame-has-no-second-retry");
        const unsigned expectedBits = PlacementBits(expected);
        const bool expectedDeferred = (expectedBits & 4) || ((expectedBits & 1) &&
            ((expectedBits & 8) || (expectedBits & 2)));
        const auto role = expectedBits & 2 ? UICorrectionInput::FinishedPicture :
            (expectedBits & 1) || expectedDeferred ? UICorrectionInput::Render : UICorrectionInput::Upscaled;
        const auto policy = Profiles::CreationUICorrection(config, true, role);
        check(policy == ((expectedBits & 16) && !expectedDeferred && !(expectedBits & 2) ? 0u : 1u) &&
                  Profiles::CreationUICorrection(config, false, role) == 1u,
              "checkbox-adoption-keeps-deferred-and-unsupported-exclusion");
        const auto reconstruction = PipelineUi::ConfiguredReconstruction(4, bool((expectedBits & 1) || expectedDeferred), 0.65f);
        check(reconstruction.requested == 4 && reconstruction.effective ==
                  (((expectedBits & 1) || expectedDeferred) ? 3u : 4u), "checkbox-preserves-private-fallback");
        SavePlacementConfig(config, loaded);
        check(loaded.SaveFile(savedPath.c_str()) >= 0, "checkbox-production-owned-save");
        CSimpleIniA reopened;
        check(reopened.LoadFile(savedPath.c_str()) == SI_OK, "checkbox-owned-reopen");
        Config reloaded;
        LoadPlacementConfig(reloaded, reopened);
        check(PlacementSnapshot(reloaded) == after && ReadControlRequests().retryGeneration == retryAfter,
              "checkbox-alias-save-reload-does-not-resurrect-or-retry");
        check(std::string_view(reopened.GetValue("Other", "Retain", "")) == "77" &&
                  std::string_view(reopened.GetValue("DlssNr", "Transfer", "")) == "4",
              "checkbox-unrelated-section-and-retained-request-survive");
        if (changed)
        {
            for (int invalid : { -1, (control + 1) % 3 })
            {
                bool refused = false;
                try { CheckPlacementFrame(before, after, invalid, 1); }
                catch (const std::runtime_error&) { refused = true; }
                check(refused, "unrequested-or-wrong-control-observation-rejected");
                ++rejectedObservations;
            }
            bool refused = false;
            try { CheckPlacementFrame(before, after, control, 2); }
            catch (const std::runtime_error&) { refused = true; }
            check(refused, "double-retry-observation-rejected");
            ++rejectedObservations;
        }
        std::printf("TASK7_CHECKBOX_CASE mask=%u marker=%d control=%d before=%u after=%u changed=%u retryDelta=%llu "
                    "policy=%u fallbackRequested=%u fallbackEffective=%u roundtrip=1 unrelated=77 retained=4\n",
                    mask, marker, control, PlacementBits(before), expectedBits, unsigned(changed),
                    retryAfter - retryBeforeLoad, policy, reconstruction.requested, reconstruction.effective);
        ++checkboxCases;
    }
    std::printf("TASK7_CHECKBOX_CONTRACT_PASS cases=%u unchanged=%u rejectedObservations=%u classification=OBSERVATION_MUTATION\n",
                checkboxCases, unchangedCases, rejectedObservations);
    {
        // Actual production wrapped checkbox/input, then an invocation whose
        // production RenderMenu returns false. No sleeps or invented hit IDs.
        const auto context = std::unique_ptr<ImGuiContext, void (*)(ImGuiContext*)>(
            ImGui::CreateContext(), ImGui::DestroyContext);
        auto& io = ImGui::GetIO();
        io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
        io.DisplaySize = ImVec2(480, 720);
        io.DeltaTime = 1.0f / 60.0f;
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        const auto frameRoot = fixtureRoot / "task19-frame";
        std::filesystem::create_directory(frameRoot);
        Config config;
        config.DlssNrRunBeforeSr = true;
        CSimpleIniA seed;
        seed.SetValue("Other", "Retain", "77");
        SavePlacementConfig(config, seed);
        SaveOptionsConfig(config, seed);
        check(seed.SaveFile((frameRoot / "owned-fixture.ini").c_str()) >= 0, "frame-owned-seed-save");
        const auto drawCheckbox = [&]()
        {
            BeginPlacementEditFrame(config);
            ImGui::NewFrame();
            ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
            ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
            ImGui::Begin("Task19 actual checkbox input", nullptr, ImGuiWindowFlags_NoSavedSettings);
            bool value = config.DlssNrRunBeforeSr.value_or_default();
            if (PipelineUi::CheckboxWrapped("Generate model before upscale", &value, 400))
                EditPlacementCheckbox(config, PlacementCheckbox::Before, value);
            ImGui::End();
            EndPlacementEditFrame(config, frameRoot, true);
            ImGui::Render();
        };
        drawCheckbox();
        const auto point = nrItems.back().item.Min + ImVec2(8, 8);
        io.AddMousePosEvent(point.x, point.y);
        drawCheckbox();
        io.AddMouseButtonEvent(0, true);
        drawCheckbox();
        io.AddMouseButtonEvent(0, false);
        drawCheckbox();
        const auto& g = *ImGui::GetCurrentContext();
        check(g.IO.MouseReleased[0] && g.HoveredId != 0 && g.HoveredId == nrItems.back().id &&
                  g.ActiveIdPreviousFrame == nrItems.back().id && nrItemsFrame == g.FrameCount,
              "actual-release-retained-after-drawn-frame");
        const auto values = PlacementSnapshot(config);
        const auto retry = ReadControlRequests().retryGeneration;
        BeginPlacementEditFrame(config);
        const bool frame = MenuCommon::RenderMenu();
        check(!frame && nrItemsFrame == g.FrameCount && g.IO.MouseReleased[0],
              "actual-production-no-new-frame-retains-last-release");
        std::printf("TASK19_NO_NEW_FRAME_BEGIN drawn=%u frame=%d retainedRelease=%u hovered=%08X activePrevious=%08X "
                    "retry=%llu flags=%u scope=CPU_ACTUAL_IMGUI_INPUT_PRODUCTION_MENU_RESULT\n",
                    unsigned(frame), g.FrameCount, unsigned(g.IO.MouseReleased[0]), g.HoveredId,
                    g.ActiveIdPreviousFrame, retry, PlacementBits(values));
        std::fflush(stdout);
        EndPlacementEditFrame(config, frameRoot, frame);
        check(PlacementSnapshot(config) == values && ReadControlRequests().retryGeneration == retry,
              "no-new-frame-keeps-placement-options-and-retry");
        std::puts("TASK19_NO_NEW_FRAME_PASS actualMenuResult=0 unchanged=1 retryDelta=0 gpu=0");
    }
    for (const char* language : { "en", "ko" })
    for (int control = 0; control < 3; ++control)
    for (bool disabled : { false, true })
    {
        const auto context = std::unique_ptr<ImGuiContext, void (*)(ImGuiContext*)>(
            ImGui::CreateContext(), ImGui::DestroyContext);
        auto& io = ImGui::GetIO();
        io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
        io.DisplaySize = ImVec2(480, 720);
        io.DeltaTime = 1.0f / 60.0f;
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        Localization::RegisterHangulFont(io.Fonts);
        Localization::SetLanguage(language);
        check(std::strcmp(Localization::EffectiveLanguageCode(), language) == 0,
              "wrapped-checkbox-actual-language");
        const auto frameRoot = fixtureRoot / ("f2b1-" + std::string(language) + "-" +
            std::to_string(control) + "-" + std::to_string(disabled));
        std::filesystem::create_directory(frameRoot);
        Config config;
        config.DlssNrRunBeforeSr = control == 0;
        CSimpleIniA seed;
        seed.SetValue("Other", "Retain", "77");
        SavePlacementConfig(config, seed);
        SaveOptionsConfig(config, seed);
        check(seed.SaveFile((frameRoot / "owned-fixture.ini").c_str()) >= 0, "wrapped-owned-seed-save");
        const char* labels[] = { "Generate model before upscale", "Apply NR to the finished picture",
                                 "Generate before upscale, apply after upscale" };
        const auto draw = [&]()
        {
            BeginPlacementEditFrame(config);
            ImGui::NewFrame();
            ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
            ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
            ImGui::Begin("F2-B1 actual wrapped checkbox", nullptr, ImGuiWindowFlags_NoSavedSettings);
            ImGui::BeginDisabled(disabled);
            bool value = control == 0 ? config.DlssNrRunBeforeSr.value_or_default() :
                         control == 1 ? config.DlssNrFinishedPicture.value_or_default() :
                                        config.DlssNrDeferredDlss.value_or_default();
            if (PipelineUi::CheckboxWrapped(labels[control], &value, 180))
                EditPlacementCheckbox(config, PlacementCheckbox(control), value);
            ImGui::EndDisabled();
            ImGui::End();
            EndPlacementEditFrame(config, frameRoot, true);
            ImGui::Render();
        };
        draw();
        for (int part = 0; part < 3; ++part)
        {
            const auto item = nrItems.back().item;
            check(item.GetHeight() > ImGui::GetFrameHeight(), "wrapped-label-has-multiple-lines");
            const ImVec2 point(part == 0 ? item.Min.x + 8 :
                              item.Min.x + ImGui::GetFrameHeight() + ImGui::GetStyle().ItemInnerSpacing.x + 4,
                              part == 2 ? item.Max.y - 4 : item.Min.y + 8);
            io.AddMousePosEvent(point.x, point.y);
            draw();
            const auto before = PlacementSnapshot(config);
            const auto retry = ReadControlRequests().retryGeneration;
            io.AddMouseButtonEvent(0, true);
            draw();
            check(PlacementSnapshot(config) == before && ReadControlRequests().retryGeneration == retry,
                  "wrapped-press-does-not-edit");
            io.AddMouseButtonEvent(0, false);
            draw();
            check(PlacementSnapshot(config) == ExpectedCheckboxEdit(before, disabled ? -1 : control) &&
                  ReadControlRequests().retryGeneration - retry == unsigned(!disabled),
                  "wrapped-release-exact-edit-and-one-retry");
            BeginPlacementEditFrame(config);
            EndPlacementEditFrame(config, frameRoot, false);
            std::printf("F2B1_INPUT_PASS language=%s control=%d disabled=%u part=%d release=1 nondrawn=1\n",
                        language, control, unsigned(disabled), part);
        }
        const auto item = nrItems.back().item;
        io.AddMousePosEvent(item.Min.x + ImGui::GetFrameHeight() + 8, item.Min.y + 8);
        draw();
        const auto before = PlacementSnapshot(config);
        const auto retry = ReadControlRequests().retryGeneration;
        io.AddMouseButtonEvent(0, true);
        draw();
        io.AddMousePosEvent(470, 700);
        draw();
        io.AddMouseButtonEvent(0, false);
        draw();
        check(PlacementSnapshot(config) == before && ReadControlRequests().retryGeneration == retry,
              "wrapped-release-outside-cancels");
        std::printf("F2B1_CANCEL_PASS language=%s control=%d disabled=%u\n", language, control, unsigned(disabled));
    }
    Localization::SetLanguage("en");
    std::printf("T6_PLACEMENT_CONTRACT_PASS checks=%u persisted-cases=%u invalid-boundary-cases=%u\n",
                checks, persistedCases, boundaryCases);
}
void RunOptionsContracts(const std::filesystem::path& fixtureRoot)
{
    using namespace DlssNr;
    unsigned checks = 0, persisted = 0, invalid = 0, eligibility = 0;
    const auto check = [&](bool condition, const char* caseId)
    {
        ++checks;
        if (!condition)
            throw std::runtime_error(std::string("T7_OPTIONS: ") + caseId);
    };
    check(unsigned(InputFilter::Area) == 0 && unsigned(InputFilter::Bilinear) == 1 &&
          unsigned(InputFilter::Nearest) == 2, "filter-numeric-contract");
    check(unsigned(SignalEncoding::Legacy) == 0 && unsigned(SignalEncoding::sRGB) == 1 &&
          unsigned(SignalEncoding::LinearSDR) == 2 && unsigned(SignalEncoding::PQSDR) == 3,
          "signal-numeric-contract");
    const auto inputPath = fixtureRoot / "task7-input.ini";
    const auto savedPath = fixtureRoot / "task7-saved.ini";
    // Independent machine-token oracle; do not derive accepted spellings from
    // the production name table being verified.
    constexpr const char* filterTokens[] = { "Area", "Bilinear", "Nearest" };
    constexpr const char* signalTokens[] = { "Legacy", "sRGB", "LinearSDR", "PQSDR" };
    for (int filter = -1; filter < 3; ++filter)
    for (int signal = -1; signal < 4; ++signal)
    {
        CSimpleIniA input;
        input.SetValue("Other", "Retain", "77");
        if (filter >= 0)
            input.SetValue("DlssNr", "InputFilter", filterTokens[filter]);
        if (signal >= 0)
            input.SetValue("DlssNr", "SignalEncoding", signalTokens[signal]);
        check(input.SaveFile(inputPath.c_str()) >= 0, "owned-input-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "owned-input-load");
        Config config;
        LoadOptionsConfig(config, loaded);
        const unsigned expectedFilter = filter < 0 ? 0u : unsigned(filter);
        const unsigned expectedSignal = signal < 0 ? 0u : unsigned(signal);
        check(unsigned(config.DlssNrInputFilter.value_or_default()) == expectedFilter &&
              unsigned(config.DlssNrSignalEncoding.value_or_default()) == expectedSignal,
              "exact-token-load-and-omitted-defaults");
        SaveOptionsConfig(config, loaded);
        check(std::string_view(loaded.GetValue("DlssNr", "InputFilter")) ==
                  (filter < 0 ? "auto" : filterTokens[filter]) &&
              std::string_view(loaded.GetValue("DlssNr", "SignalEncoding")) ==
                  (signal < 0 ? "auto" : signalTokens[signal]), "exact-saved-token");
        check(std::string_view(loaded.GetValue("Other", "Retain")) == "77", "unrelated-value-preserved");
        check(loaded.SaveFile(savedPath.c_str()) >= 0, "owned-production-save");
        CSimpleIniA reopened;
        check(reopened.LoadFile(savedPath.c_str()) == SI_OK, "owned-production-reload");
        Config reloaded;
        LoadOptionsConfig(reloaded, reopened);
        check(unsigned(reloaded.DlssNrInputFilter.value_or_default()) == expectedFilter &&
              unsigned(reloaded.DlssNrSignalEncoding.value_or_default()) == expectedSignal,
              "actual-file-roundtrip");
        std::printf("T7_PERSIST_CASE filter=%d signal=%d effectiveFilter=%u effectiveSignal=%u\n",
            filter, signal, expectedFilter, expectedSignal);
        ++persisted;
    }
    for (const char* token : { "", "auto", "area", "AREA", "nearest", "bilinear", "srgb",
                              "LinearSdr", "PQsdr", "0", "1", "-1", "4", "unknown", "Area extra" })
    {
        CSimpleIniA input;
        input.SetValue("DlssNr", "InputFilter", token);
        input.SetValue("DlssNr", "SignalEncoding", token);
        check(input.SaveFile(inputPath.c_str()) >= 0, "invalid-owned-save");
        CSimpleIniA loaded;
        check(loaded.LoadFile(inputPath.c_str()) == SI_OK, "invalid-owned-load");
        Config config;
        LoadOptionsConfig(config, loaded);
        check(config.DlssNrInputFilter.value_or_default() == InputFilter::Area &&
              config.DlssNrSignalEncoding.value_or_default() == SignalEncoding::Legacy,
              "invalid-boundary-defaults");
        check(!config.DlssNrInputFilter.value_for_config() && !config.DlssNrSignalEncoding.value_for_config(),
              "invalid-not-retained-as-valid-enum");
        ++invalid;
    }
    struct ExtentCase { uint32_t iw, ih, ww, wh; bool shrink; };
    const ExtentCase extents[] = {
        { 1920,1080,1248,702,true }, { 5,5,2,2,true }, { 5,5,5,5,false },
        { 5,5,6,6,false }, { 1,1,1,1,false }, { 1,5,1,2,true },
        { 5,5,2,5,true }, { 5,5,6,2,false }, { 0,5,0,2,false }, { 5,5,0,0,false }
    };
    for (const auto& extent : extents)
    for (bool dx12 : { false, true })
    for (bool hdr : { false, true })
    for (unsigned filter = 0; filter < 3; ++filter)
    for (unsigned signal = 0; signal < 4; ++signal)
    for (bool publishedSupport : { false, true })
    {
        const OptionContext context { extent.iw, extent.ih, extent.ww, extent.wh, dx12, hdr };
        const auto result = ResolveOptions(static_cast<InputFilter>(filter), static_cast<SignalEncoding>(signal),
                                          context, 1, 2, publishedSupport, publishedSupport);
        const bool filterEligible = dx12 && extent.shrink, signalEligible = dx12 && hdr;
        check(unsigned(result.requestedFilter) == filter && unsigned(result.requestedSignal) == signal,
              "unsupported-retains-requested-intent");
        check(result.filterSelectable == filterEligible && result.signalSelectable == signalEligible,
              "resolution-api-hdr-eligibility");
        check(result.filterSupported == (filterEligible && publishedSupport) &&
              result.signalSupported == (signalEligible && publishedSupport), "published-support-not-combo");
        check(unsigned(result.effectiveFilter) == (filterEligible && publishedSupport ? 1u : 0u) &&
              unsigned(result.effectiveSignal) == (signalEligible && publishedSupport ? 2u : 0u),
              "effective-from-published-state-not-request");
        ++eligibility;
    }
    {
        UiServices services(fixtureRoot);
        for (const auto fixture : { Fixture::FilterHdr, Fixture::FilterSdr, Fixture::FilterNative,
                                   Fixture::FilterSupernative, Fixture::FilterUnsupported, Fixture::MissingCurrentContext })
        {
            services.Select(fixture);
            auto* config = services.Configuration();
            const auto savedFilter = config->DlssNrInputFilter.value_for_config();
            const auto savedSignal = config->DlssNrSignalEncoding.value_for_config();
            const auto status = ReadStatus(Backend::Dx12);
            check(status.output.contextState == (fixture == Fixture::MissingCurrentContext ?
                      ModelContextState::Absent : ModelContextState::Current) &&
                      status.output.identity.Known() == (fixture != Fixture::MissingCurrentContext),
                  "host-explicit-current-or-missing-provenance");
            const auto result = ResolveOptions(*savedFilter, *savedSignal, status.output.optionContext,
                status.output.inputFilter, status.output.signalEncoding,
                status.output.inputFilterOverrideSupported, status.output.signalEncodingOverrideSupported);
            check(result.requestedFilter == InputFilter::Nearest && result.requestedSignal == SignalEncoding::PQSDR,
                  "host-requested-intent");
            check(result.effectiveFilter == InputFilter::Area && result.effectiveSignal == SignalEncoding::Legacy &&
                  !result.filterSupported && !result.signalSupported && !status.output.Applied(),
                  "host-does-not-invent-shipped-processing");
            check(result.filterSelectable == (fixture == Fixture::FilterHdr || fixture == Fixture::FilterSdr) &&
                  result.signalSelectable == (fixture == Fixture::FilterHdr || fixture == Fixture::FilterNative ||
                                               fixture == Fixture::FilterSupernative), "actual-host-context-eligibility");
            check(config->DlssNrInputFilter.value_for_config() == savedFilter &&
                  config->DlssNrSignalEncoding.value_for_config() == savedSignal, "status-read-only");
            CSimpleIniA saved;
            saved.SetValue("Other", "Retain", "77");
            SaveOptionsConfig(*config, saved);
            check(saved.SaveFile(savedPath.c_str()) >= 0, "unsupported-request-owned-save");
            CSimpleIniA reopened;
            check(reopened.LoadFile(savedPath.c_str()) == SI_OK, "unsupported-request-owned-reload");
            Config reloaded;
            LoadOptionsConfig(reloaded, reopened);
            check(reloaded.DlssNrInputFilter.value_or_default() == InputFilter::Nearest &&
                  reloaded.DlssNrSignalEncoding.value_or_default() == SignalEncoding::PQSDR,
                  "unsupported-request-persists-without-migration");
        }
    }
    unsigned currentCases = 0;
    {
        UiServices services(fixtureRoot);
        auto* config = services.Configuration();
        config->DlssNrInputFilter = InputFilter::Nearest;
        config->DlssNrSignalEncoding = SignalEncoding::PQSDR;
        const auto context = std::unique_ptr<ImGuiContext, void (*)(ImGuiContext*)>(
            ImGui::CreateContext(), ImGui::DestroyContext);
        auto& io = ImGui::GetIO();
        io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
        io.DisplaySize = ImVec2(800, 1600);
        io.DeltaTime = 1.0f / 60.0f;
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        const auto oldInput = State::Instance().activeFgInput;
        const auto oldOutput = State::Instance().activeFgOutput;
        struct Case
        {
            const char* id;
            ModelContextState state;
            OptionContext facts;
            API api;
            float scale;
            bool support, known, stale, current, filterSelectable, signalSelectable;
            unsigned effectiveFilter, effectiveSignal;
        };
        const Case cases[] = {
            { "current-supported", ModelContextState::Current, {7,5,5,3,true,true},
              API::DX12, .65f, true,true,false,true,true,true,1,2 },
            { "current-unsupported", ModelContextState::Current, {7,5,5,3,true,true},
              API::DX12, .65f, false,true,false,true,true,true,0,0 },
            { "missing-current-context", ModelContextState::Absent, {7,5,5,3,true,true},
              API::DX12, .65f, true,true,false,false,false,false,0,0 },
            { "unknown-current-context", ModelContextState::Unknown, {7,5,5,3,true,true},
              API::DX12, .65f, true,true,false,false,false,false,0,0 },
            { "unknown-current-identity", ModelContextState::Current, {7,5,5,3,true,true},
              API::DX12, .65f, true,false,false,false,false,false,0,0 },
            { "stale-current-generation", ModelContextState::Current, {7,5,5,3,true,true},
              API::DX12, .65f, true,true,true,false,false,false,0,0 },
            { "native-filter-hdr-signal", ModelContextState::Current, {7,5,7,5,true,true},
              API::DX12, 1.0f, true,true,false,true,false,true,0,2 },
            { "supernative-filter-hdr-signal", ModelContextState::Current, {7,5,9,6,true,true},
              API::DX12, 1.25f, true,true,false,true,false,true,0,2 },
            { "sdr-filter-only", ModelContextState::Current, {7,5,5,3,true,false},
              API::DX12, .65f, true,true,false,true,true,false,1,0 },
            { "non-dx12-retained-request", ModelContextState::Current, {7,5,5,3,false,true},
              API::DX11, .65f, true,true,false,true,false,false,0,0 },
            { "committed-preview-not-processing", ModelContextState::Current, {7,5,5,3,true,true},
              API::DX12, 1.0f, true,true,false,true,false,true,1,2 },
            { "rounded-one-pixel-native", ModelContextState::Current, {1,1,1,1,true,true},
              API::DX12, .65f, true,true,false,true,false,true,0,2 }
        };
        for (const auto& test : cases)
        {
            std::array<OptionObservation, 2> paired;
            for (bool xefg : { false, true })
            {
                State::Instance().activeFgInput = xefg ? FGInput::XeFG : FGInput::DLSSG;
                State::Instance().activeFgOutput = xefg ? FGOutput::XeFG : FGOutput::DLSSG;
                State::Instance().swapchainApi = test.api;
                config->DlssNrWorkingScale = test.scale;
                StatusSnapshot snapshot;
                auto& facts = snapshot.output;
                facts.contextState = test.state;
                facts.identity = { &services, &services, test.known ? 17u : 0u, 1, true };
                facts.optionContext = test.facts;
                facts.inputFilter = 1;
                facts.signalEncoding = 2;
                facts.inputFilterOverrideSupported = facts.signalEncodingOverrideSupported = test.support;
                if (test.stale)
                {
                    auto next = facts.identity;
                    ++next.generation;
                    facts.ValidateCurrent(Backend::Dx12, next);
                }
                snapshot.modelFacts = facts;
                PublishStatus(&services, Backend::Dx12, snapshot);
                const auto draw = [&]()
                {
                    ImGui::NewFrame();
                    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
                    ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
                    ImGui::Begin("Task8 production Input contracts", nullptr, ImGuiWindowFlags_NoSavedSettings);
                    MenuSections::RenderInput(config);
                    ImGui::End();
                    ImGui::Render();
                };
                draw();
                for (unsigned control = 0; control < 2; ++control)
                {
                    const auto item = optionObservations[control];
                    check(item.frame == ImGui::GetFrameCount() && item.id != 0, "actual-production-option-item");
                    check(item.current == test.current && item.selectable ==
                              (control == 0 ? test.filterSelectable : test.signalSelectable),
                          "current-context-controls-not-retained-facts");
                    check(item.requested == (control == 0 ? 2u : 3u) &&
                              item.effective == (control == 0 ? test.effectiveFilter : test.effectiveSignal) &&
                              item.supported == (control == 0 ? test.effectiveFilter != 0 : test.effectiveSignal != 0),
                          "published-processing-not-preview-or-request");
                    if (xefg)
                        check(item.id == paired[control].id && item.selectable == paired[control].selectable &&
                                  item.current == paired[control].current && item.effective == paired[control].effective &&
                                  item.supported == paired[control].supported,
                              "same-current-context-provider-label-pair");
                    else
                        paired[control] = item;
                    if (!item.selectable)
                    {
                        const auto point = item.item.Min + ImVec2(8, 8);
                        io.AddMousePosEvent(point.x, point.y);
                        draw();
                        check(optionObservations[control].hovered &&
                                  optionObservations[control].id == item.id,
                              "actual-disabled-hover-reason-path");
                    }
                }
                check(config->DlssNrInputFilter.value_or_default() == InputFilter::Nearest &&
                          config->DlssNrSignalEncoding.value_or_default() == SignalEncoding::PQSDR,
                      "current-context-read-and-hover-retain-intent");
                std::printf("TASK8_CONTEXT_CASE=%s provider=%s current=%u filterSelectable=%u signalSelectable=%u "
                            "effectiveFilter=%u effectiveSignal=%u requests=2,3 caller=production-menu gpu=0\n",
                            test.id, xefg ? "XeFG" : "DLSSG", unsigned(test.current),
                            unsigned(test.filterSelectable), unsigned(test.signalSelectable),
                            test.effectiveFilter, test.effectiveSignal);
                ++currentCases;
            }
        }
        State::Instance().activeFgInput = oldInput;
        State::Instance().activeFgOutput = oldOutput;
        CSimpleIniA saved;
        saved.SetValue("Other", "Retain", "77");
        SaveOptionsConfig(*config, saved);
        check(saved.SaveFile(savedPath.c_str()) >= 0, "missing-context-request-save");
        CSimpleIniA reopened;
        check(reopened.LoadFile(savedPath.c_str()) == SI_OK, "missing-context-request-reopen");
        Config reloaded;
        LoadOptionsConfig(reloaded, reopened);
        check(reloaded.DlssNrInputFilter.value_or_default() == InputFilter::Nearest &&
                  reloaded.DlssNrSignalEncoding.value_or_default() == SignalEncoding::PQSDR &&
                  std::string_view(reopened.GetValue("Other", "Retain", "")) == "77",
              "current-context-request-file-retention");
    }
    check(ReadStatus(Backend::Dx12).output.optionContext.inputWidth == 0, "owned-published-status-closed");
    std::printf("T7_OPTIONS_PASS checks=%u persisted=%u invalid=%u eligibility=%u hostFixtures=6\n",
                checks, persisted, invalid, eligibility);
    std::printf("TASK8_CURRENT_CONTEXT_PASS cases=%u providerPairs=%u productionInput=1 disabledHover=1 persistence=1\n",
                currentCases, currentCases / 2);
}
} // namespace NrAddonHost
