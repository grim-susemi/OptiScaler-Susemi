#pragma once
#include <map>
#include <variant>
#include <nvsdk_ngx_params.h>
#include "../OptiScaler/shaders/dlssnr/DlssNr_Upscaler_Dx12.h"
#include "deferred_support.inc"
#define LOG_TRACE(...) ((void)0)
static bool injectDeferredPrivate = false, injectDeferredComposition = false;
static unsigned privateEvaluations = 0, savedCarriers = 0;
namespace OptiKeys { constexpr const char* FSR_CameraFovVertical = "FSR.cameraFovVertical"; }
struct DeferredParams : NVSDK_NGX_Parameter
{
    using Value = std::variant<unsigned long long, float, double, unsigned, int,
                               ID3D11Resource*, ID3D12Resource*, void*>;
    std::map<std::string, Value> values;
#define R1_PARAM(T) \
    void Set(const char* key, T v) override { values[key] = v; } \
    NVSDK_NGX_Result Get(const char* key, T* v) const override \
    { auto it = values.find(key); if (it == values.end() || !std::holds_alternative<T>(it->second)) \
      return NVSDK_NGX_Result_Fail; *v = std::get<T>(it->second); return NVSDK_NGX_Result_Success; }
    R1_PARAM(unsigned long long)
    R1_PARAM(float)
    R1_PARAM(double)
    R1_PARAM(unsigned)
    R1_PARAM(int)
    R1_PARAM(ID3D11Resource*)
    R1_PARAM(ID3D12Resource*)
    R1_PARAM(void*)
#undef R1_PARAM
    void Reset() override { values.clear(); }
};
inline ID3D12Resource* GetUpscalerResource_Dx12(NVSDK_NGX_Parameter* p, const char* key)
{ ID3D12Resource* r = nullptr; p->Get(key, &r); return r; }
namespace DlssNr
{
struct InputStates_Dx12
{
    D3D12_RESOURCE_STATES color, depth, motion, exposure;
};
// Setup adapter: every borrowed fixture input arrives readable, like the bridge.
inline InputStates_Dx12 ResolveInputStates_Dx12(bool)
{
    constexpr auto readable = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    return { readable, readable, readable, readable };
}
// Explicit private-provider adapter. Actual Before/After make every decision.
struct PrivateUpscalerDx12::Impl {};
inline PrivateUpscalerDx12::PrivateUpscalerDx12(PrivateUpscaler) : impl(std::make_unique<Impl>()) {}
inline PrivateUpscalerDx12::~PrivateUpscalerDx12() = default;
inline bool PrivateUpscalerDx12::Init(ID3D12Device*, ID3D12GraphicsCommandList*, const PrivateUpscalerCreateDx12&)
{ return true; }
inline PrivateRrInputsDx12 PrivateUpscalerDx12::ReadRrInputs(NVSDK_NGX_Parameter*, unsigned, unsigned)
{ return {}; } // tested route is SR, not RR
inline const char* PrivateUpscalerDx12::Name() const { return "fixture provider"; }
inline const std::string& PrivateUpscalerDx12::Error() const
{ static const std::string text = "explicit evaluation refusal"; return text; }
}
