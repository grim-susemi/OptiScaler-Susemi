#pragma once

namespace DlssNr
{
struct Placement
{
    bool beforeUpscale;
    bool deferred;
    bool finished;
};

// The old across-RR key is accepted as an alias for the unified private-upscaler route.
constexpr Placement ResolvePlacement(bool before, bool deferred, bool legacyAcrossRr, bool finished)
{
    deferred = deferred || (before && legacyAcrossRr) || (finished && before);
    return { before || deferred, deferred, finished };
}

enum class UICorrectionInput { Unknown, Render, Upscaled, FinishedPicture };

// A creation caller must establish support and the input role. Resources alone
// do not prove either. Current callers have no proven UI-layer creation input.
constexpr unsigned int ResolveUICorrection(bool adopted, Placement placement, bool supported,
                                          UICorrectionInput input, bool validUiBinding = false)
{
    if (!adopted || placement.deferred || !supported || validUiBinding)
        return 1u;
    if (!placement.finished &&
        ((input == UICorrectionInput::Render && placement.beforeUpscale) ||
         (input == UICorrectionInput::Upscaled && !placement.beforeUpscale)))
        return 0u;
    return 1u;
}

// Menu indices only, not a new processing/timing authority.
constexpr int DirectPlacementIndex(bool before, bool finished, bool deferred, bool legacyAcrossRr)
{
    const auto placement = ResolvePlacement(before, deferred, legacyAcrossRr, finished);
    return placement.deferred ? -1 : finished ? 2 : before ? 0 : 1;
}

template <typename Configuration> bool SelectDirectPlacement(Configuration& config, int selection)
{
    if (selection < 0 || selection > 2)
        return false;
    config.DlssNrRunBeforeSr = selection == 0;
    config.DlssNrFinishedPicture = selection == 2;
    config.DlssNrDeferredDlss = false;
    config.DlssNrResidualAcrossRr = false;
    config.DlssNrAutomaticUICorrection = true;
    return true;
}
} // namespace DlssNr
