#pragma once
#include "DlssNr_MfgObserver.h"
#include <sl.h>

namespace DlssNr::MfgObserver
{
inline Event Streamline(uint64_t provider, sl::Feature feature, const sl::FrameToken& frame,
                         const sl::BaseStructure** inputs, uint32_t count, sl::CommandBuffer* commands)
{
    Event event;
    event.seam = Seam::StreamlineEvaluate;
    if (!Enabled()) return event;
    event.session = Session();
    event.provider = provider;
    event.feature = feature;
    event.featureKnown = true;
    // Keep both the actual token address and its SDK index. Neither is the NR
    // application token or a generated/real phase convention.
    event.handle = Value(&frame);
    event.rawIndex = static_cast<uint32_t>(frame);
    event.indexSource = IndexSource::StreamlineFrameToken;
    event.indexReadAttempted = event.indexReadSuccess = true;
    event.commands = Value(commands);
    event.inputCount = count;
    for (uint32_t i = 0; inputs && i < count && i < event.resources.size(); ++i)
    {
        ++event.inputEntriesObserved;
        if (!inputs[i] || inputs[i]->structType != sl::ResourceTag::s_structType) continue;
        const auto& tag = *static_cast<const sl::ResourceTag*>(inputs[i]);
        auto& resource = event.resources[event.resourceCount++];
        resource.tagType = tag.type;
        resource.lifecycle = tag.lifecycle;
        if (tag.resource) resource.value = Value(tag.resource->native);
        // SL tags are declarations, not an associated current NR application picture.
    }
    return event;
}
}
