#pragma once
#include "DlssNr_MfgObserver.h"
#include <nvsdk_ngx_params.h>

namespace DlssNr::MfgObserver
{
inline Event Ngx(Seam seam, uint64_t provider, const NVSDK_NGX_Handle* handle,
                 NVSDK_NGX_Parameter* parameters, const void* commands,
                 uint32_t feature, bool featureKnown, bool existingRead = false,
                 uint32_t rawIndex = 0, NVSDK_NGX_Result readResult = NVSDK_NGX_Result_Fail,
                 bool vkResources = false)
{
    Event event;
    event.seam = seam;
    if (!Enabled()) return event;
    event.session = Session();
    event.provider = provider;
    event.handle = Value(handle);
    if (handle) event.handleId = handle->Id;
    event.feature = feature;
    event.featureKnown = featureKnown;
    event.commands = Value(commands);
    if (!parameters) return event;
    if (!existingRead) readResult = parameters->Get("DLSSG.MultiFrameIndex", &rawIndex);
    event.indexReadAttempted = true;
    event.indexSource = IndexSource::NgxMultiFrameIndex;
    event.indexReadResultKnown = true;
    event.indexReadResult = static_cast<uint32_t>(readResult);
    event.indexReadSuccess = readResult == NVSDK_NGX_Result_Success;
    event.rawIndex = event.indexReadSuccess ? rawIndex : 0;
    constexpr const char* keys[] = { "DLSSG.Backbuffer", "DLSSG.OutputReal", "DLSSG.OutputInterpolated",
                                    "DLSSG.HUDLess", "DLSSG.Depth", "DLSSG.MVecs" };
    constexpr Role roles[] = { Role::Backbuffer, Role::OutputReal, Role::OutputInterpolated,
                              Role::Hudless, Role::Depth, Role::Motion };
    for (uint32_t i = 0; i < event.resources.size(); ++i)
    {
        ID3D12Resource* resource = nullptr;
        void* vkResource = nullptr;
        auto& value = event.resources[i];
        value.role = roles[i];
        value.readAttempted = true;
        const auto result = vkResources ? parameters->Get(keys[i], &vkResource) : parameters->Get(keys[i], &resource);
        value.readResult = static_cast<uint32_t>(result);
        value.readSuccess = result == NVSDK_NGX_Result_Success;
        value.ngxVkResource = vkResources;
        if (value.readSuccess) value.value = vkResources ? Value(vkResource) : Value(resource);
        // Provider-declared binding only; it does not prove a generated pixel or
        // completion. Conflicting bindings cannot establish even that declaration.
        if (featureKnown && feature == NVSDK_NGX_Feature_FrameGeneration && value.value)
            value.declaration = i == 0 ? Declaration::ApplicationInput :
                                i == 1 ? Declaration::ProviderReal :
                                i == 2 ? Declaration::ProviderGenerated : Declaration::Unknown;
    }
    event.resourceCount = static_cast<uint32_t>(event.resources.size());
    for (uint32_t i = 0; i < event.resourceCount; ++i)
        for (uint32_t j = 0; j < event.resourceCount; ++j)
            if (i != j && event.resources[i].value && event.resources[i].value == event.resources[j].value &&
                event.resources[i].role != event.resources[j].role)
                event.resources[i].declaration = Declaration::Unknown;
    return event;
}
inline void NrParameters(const void* owner, const FinishedIdentity& identity, bool before,
                          NVSDK_NGX_Parameter* parameters, const void* commands)
{
    if (!Enabled()) return;
    Event event;
    event.session = Session();
    event.identity = CopyIdentity(identity);
    event.identity.owner = Value(owner);
    event.stage = before ? 3u : 4u;
    event.commands = Value(commands);
    constexpr const char* keys[] = { NVSDK_NGX_Parameter_Color, NVSDK_NGX_Parameter_Output,
                                    NVSDK_NGX_Parameter_Depth, NVSDK_NGX_Parameter_MotionVectors };
    constexpr Role roles[] = { Role::NrColour, Role::NrColour, Role::Depth, Role::Motion };
    for (uint32_t i = 0; parameters && i < 4; ++i)
    {
        auto& value = event.resources[event.resourceCount++];
        value.role = roles[i];
        value.readAttempted = true;
        ID3D12Resource* resource = nullptr;
        const auto result = parameters->Get(keys[i], &resource);
        value.readResult = static_cast<uint32_t>(result);
        value.readSuccess = result == NVSDK_NGX_Result_Success;
        if (value.readSuccess) value.value = Value(resource);
    }
    Publish(event);
}
inline void Complete(Event event, NVSDK_NGX_Result result)
{
    if (!Enabled() || !event.session) return;
    event.result = static_cast<uint32_t>(result);
    event.resultKnown = true;
    Publish(event);
}
}
