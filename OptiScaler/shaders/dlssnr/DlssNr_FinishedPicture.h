#pragma once
#include "DlssNr_Common.h"
#include "DlssNr_Guides.h"
#include <d3d12.h>
#include <cmath>
#include <limits>
#include <optional>

namespace DlssNr
{
// Actual resources for one finished-picture evaluation, not configured resolutions.
struct FinishedPictureResources
{
    D3D12_RESOURCE_DESC picture, depth, motion;
};

// Run already samples independent guide regions onto its actual colour/output extent.
// Preserve the SR metadata selecting those regions; only convert vector units from
// SR-output pixels to finished-picture pixels before Run's existing work-size scaling.
inline std::optional<DlssNrFrameInfo> PrepareFinishedPicture(
    const DlssNrFrameInfo& captured, const FinishedPictureResources& resources)
{
    const auto texture = [](const D3D12_RESOURCE_DESC& desc)
    {
        return desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && desc.Width && desc.Height &&
               desc.Width <= std::numeric_limits<uint32_t>::max() && desc.DepthOrArraySize == 1 &&
               desc.MipLevels == 1 && desc.SampleDesc.Count == 1;
    };
    if (!captured.FinishedPicture || captured.BeforeUpscale || !captured.OutputWidth || !captured.OutputHeight ||
        !texture(resources.picture) || !texture(resources.depth) || !texture(resources.motion))
        return std::nullopt;
    const auto width = static_cast<uint32_t>(resources.picture.Width);
    const auto height = resources.picture.Height;
    const bool resized = width != captured.OutputWidth || height != captured.OutputHeight;
    // No crop/letterbox mapping is supplied by this capture contract. Only a
    // full-frame uniform resize with known active guide metadata can be adapted.
    if (resized && (uint64_t(width) * captured.OutputHeight != uint64_t(height) * captured.OutputWidth ||
                    !captured.RenderSubrectWidth || !captured.RenderSubrectHeight))
        return std::nullopt;
    const auto fits = [](const D3D12_RESOURCE_DESC& desc, const GuideRegion& region, GuideExtent wanted)
    {
        return region.valid() && (!wanted.width || region.width == wanted.width) &&
               (!wanted.height || region.height == wanted.height) &&
               uint64_t(region.x) + region.width <= desc.Width &&
               uint64_t(region.y) + region.height <= desc.Height;
    };
    const GuideExtent render { captured.RenderSubrectWidth, captured.RenderSubrectHeight };
    const GuideExtent output { captured.OutputWidth, captured.OutputHeight };
    const auto guides = ResolveGuideRegions(
        { uint32_t(resources.depth.Width), resources.depth.Height },
        { uint32_t(resources.motion.Width), resources.motion.Height }, render, output,
        captured.MotionVectorsLowResolution, captured.DepthSubrectBaseX, captured.DepthSubrectBaseY,
        captured.MotionSubrectBaseX, captured.MotionSubrectBaseY);
    if (!fits(resources.depth, guides.depth, render) ||
        !fits(resources.motion, guides.motion, captured.MotionVectorsLowResolution ? render : output))
        return std::nullopt;
    auto prepared = captured;
    if (resized)
    {
        prepared.MvScaleX *= float(width) / captured.OutputWidth;
        prepared.MvScaleY *= float(height) / captured.OutputHeight;
    }
    if (!std::isfinite(prepared.MvScaleX) || !std::isfinite(prepared.MvScaleY) ||
        prepared.MvScaleX == 0 || prepared.MvScaleY == 0)
        return std::nullopt;
    return prepared;
}
}
