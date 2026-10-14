#include "pch.h"
#include <cstdio>
// SDK acceptance is a typed boundary. The entire production carrier caller,
// including admission, constants, dispatch and history reset, executes below.
namespace DlssNr
{
enum class PrivateUpscaler { DLSS };
struct PrivateUpscalerCreateDx12
{
    unsigned width,height,outputWidth,outputHeight,quality;
    bool depthInverted,rayReconstruction;
};
struct PrivateUpscalerFrameDx12
{
    struct Binding { ID3D12Resource* resource=nullptr; } color,depth,motion,exposure,output;
    unsigned width,height,outputWidth,outputHeight;
    bool reset;
    float motionScaleX,motionScaleY,jitterX,jitterY,frameTimeMs;
};
inline PrivateUpscalerFrameDx12 carrierEvaluated {};
class PrivateUpscalerDx12
{
public:
    explicit PrivateUpscalerDx12(PrivateUpscaler) {}
    bool Init(ID3D12Device*,ID3D12GraphicsCommandList*,const PrivateUpscalerCreateDx12&) { return true; }
    bool Evaluate(ID3D12GraphicsCommandList*,const PrivateUpscalerFrameDx12& frame)
    { carrierEvaluated=frame; return true; }
    std::string Error() const { return {}; }
};
}
#ifdef NR_PROXY_SOURCE
#include "proxy-declarations.inc"
#include NR_PROXY_SOURCE
#else
#include "../../OptiScaler/dlssnr/DlssNr_Proxy.cpp"
#endif
#include "../../OptiScaler/dlssnr/DlssNr_Status.cpp"
#include "../../OptiScaler/dlssnr/PassProfiles.h"
#include "proxy-services.inc"
#include "ModelPreparation.h"
#include "carrier-production.inc"

int main()
try
{
    using FilterFixture::Require;
    unsigned cases=0;
    for (bool pass : {false,true})
    for (unsigned code : {0u,1u,2u,3u})
    for (unsigned transfer : {1u,3u})
    {
        auto& cfg=*Config::Instance(); cfg={};
        ID3D12Device device; ID3D12GraphicsCommandList cmd;
        ID3D12CommandQueue queue; queue.device=&device;
        ID3D12Resource proxy(5,3),answer(5,3),depth(7,5),motion(7,5);
        DlssNrFrameInfo frame; frame.IndependentCommands=true;
        DlssNrConstants resolve {}; resolve.Width=7; resolve.Height=5;
        resolve.Passthrough=pass ? 1u : 0u; resolve.SignalEncoding=pass ? 0u : code;
        resolve.Transfer=transfer;
        DlssNr_Dx12::State state;
        Require(!state.EnlargeMatchedResidual(&cmd,&device,&proxy,&answer,&depth,&motion,frame,
                resolve,false,&queue),"T11_CARRIER: actual-creation-before-submission");
        Require(state.enlarger && state.enlarger->creation==&cmd,"T11_CARRIER: creation-command");
        state.enlarger->submitted=true; state.frames=1; FilterFixture::operations.clear();
        auto* result=state.EnlargeMatchedResidual(&cmd,&device,&proxy,&answer,&depth,&motion,frame,
                resolve,true,&queue);
        Require(result==state.enlarger->output.Get(),"T11_CARRIER: actual-evaluation-output");
        const FilterFixture::Operation* carrier=nullptr;
        for (const auto& op : FilterFixture::operations)
            if (op.kind==0 && (op.constants.Mode==9 || op.constants.Mode==12)) carrier=&op;
        Require(carrier && carrier->constants.SignalEncoding==resolve.SignalEncoding &&
                carrier->constants.Passthrough==resolve.Passthrough &&
                carrier->source==proxy.id && carrier->model==answer.id &&
                carrier->constants.Width==5 && carrier->constants.Height==3,
                "T11_CARRIER: actual-prepared-domain-upload");
        Require(carrier->constants.Mode==(transfer==3 ? 12u : 9u),
                "T11_CARRIER: actual-field-mode");
        Require(DlssNr::carrierEvaluated.reset && DlssNr::carrierEvaluated.color.resource==
                state.enlarger->input.Get(),"T11_CARRIER: existing-private-reset-carrier");
        state.enlarger->lifetime.ResetRecording(&cmd);
        state.lifetime.ResetRecording(&cmd);
        state.ReleaseEnlarger();
        Require(!state.enlarger && state.retiredEnlargers.empty(),"T11_CARRIER: existing-retirement-closure");
        ++cases;
    }
    std::printf("T11_CARRIER_PASS cases=%u actual-whole-body=1 mode9-mode12=1 closure=1 provider=typed-boundary\n",cases);
    return 0;
}
catch (const std::exception& error) { std::fprintf(stderr,"FAIL: %s\n",error.what()); return 1; }
