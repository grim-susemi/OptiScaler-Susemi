// Current whole production bodies with typed SDK/resource/completion boundaries.
#include "pch.h"
#define main FilterIntegrationMain
#include "FilterIntegration.cpp"
#undef main

void signalHistory()
{
    unsigned cases = 0;
    ID3D12Device device; ID3D12GraphicsCommandList cmd;
    for (bool nativeApi : {false, true})
    for (bool hdr : {false, true})
    for (float scale : {.65f, 1.0f, 1.25f})
    {
        auto& cfg = *Config::Instance(); cfg = {};
        DlssNr_Dx12::State state;
        state.outputStatus.optionContext.nativeDx12 = nativeApi;
        DlssNrFrameInfo frame; frame.ColourIsLinearHdr = hdr;
        DlssNr::ColorExtent native {7,5}, work {unsigned(7*scale+.5f),unsigned(5*scale+.5f)};
        D3D12_RESOURCE_DESC desc {7,5,1};
        const auto prepare = [&] {
            return state.PrepareRunModels(&cmd,&device,frame,desc,native,work,scale,2);
        };
        Require(!prepare(),"T11_HISTORY: initial-create");
        ++frame.SubmissionEpoch; Require(!prepare(),"T11_HISTORY: second-create");
        ++frame.SubmissionEpoch; Require(prepare(),"T11_HISTORY: ready");
        auto* scratch = state.nr.output;
        unsigned previous = 0;
        for (unsigned code : {1u,2u,3u,3u,0u})
        {
            cfg.DlssNrSignalEncoding.value = static_cast<DlssNr::SignalEncoding>(code);
            state.nr.reset = false;
            auto* old = Mock::latest;
            const auto created = Mock::creations, released = Mock::releases;
            const auto destroyed = Mock::destructions;
            const unsigned expected = nativeApi && hdr ? code : 0;
            const bool ready = prepare();
            if (expected != previous)
            {
                Require(!ready && state.nr.reset,"T11_HISTORY: effective-signal-reset");
                Require(Mock::creations == created+1 && old != Mock::latest,
                        "T11_HISTORY: effective-signal-recreate");
                Require(Mock::releases == released && Mock::destructions == destroyed,
                        "T11_HISTORY: retained-old-owner");
                ++frame.SubmissionEpoch; Require(!prepare(),"T11_HISTORY: next-pass");
                ++frame.SubmissionEpoch; Require(prepare(),"T11_HISTORY: changed-ready");
            }
            else
                Require(ready && !state.nr.reset && Mock::creations == created,
                        "T11_HISTORY: unchanged-unsupported-reuse");
            Require(state.nr.output == scratch && state.parked == 0,"T11_HISTORY: scratch-retained");
            for (unsigned pass=0; pass<2; ++pass)
                Require(state.nr.builtSettings[pass].effectiveSignalEncoding == expected,
                        "T11_HISTORY: saved-effective-signal");
            for (unsigned pass=0; pass<30; ++pass)
            {
                Require(PassSettings(cfg,pass,1,0,expected).effectiveSignalEncoding == expected,
                        "T11_HISTORY: all-pass-identity");
                Require(PassSettings(cfg,pass).effectiveSignalEncoding == 0,
                        "T11_HISTORY: shared-vulkan-legacy");
            }
            const auto& values = Mock::creationValues.back();
            for (const char* name : {"DLSSNR.UI","DLSSNR.UIAlpha","DLSSNR.ControlMask","DLSSNR.Backbuffer"})
                Require(std::get<ID3D12Resource*>(values.at(name)) == nullptr,
                        "T11_UI: actual-null-bindings");
            Require(!values.contains("DLSSNR.SignalEncoding") && !values.contains("DLSSNR.InputFilter"),
                    "T11_HISTORY: no-invented-sdk-key");
            previous = expected; ++cases;
        }
        // Effective filter and signal share the same existing creation identity.
        cfg.DlssNrInputFilter.value = DlssNr::InputFilter::Nearest;
        state.nr.reset = false;
        const bool filterEligible = nativeApi && scale < 1;
        const bool ready = prepare();
        Require(filterEligible ? (!ready && state.nr.reset) : (ready && !state.nr.reset),
                "T11_HISTORY: coupled-filter-reset");
        if (filterEligible)
        {
            ++frame.SubmissionEpoch; Require(!prepare(),"T11_HISTORY: filter-second-pass");
            ++frame.SubmissionEpoch; Require(prepare(),"T11_HISTORY: filter-ready");
        }
        cfg.DlssNrAutomaticUICorrection.value = true;
        state.nr.reset = false;
        Require(!prepare() && state.nr.reset && state.outputStatus.uiCorrection == 0,
                "T11_UI: preserved-policy");
        Require(std::get<unsigned>(Mock::creationValues.back().at("DLSSNR.UICorrection")) == 0,
                "T11_UI: actual-typed-policy");
        closeModels(state,cmd);
    }
    Require(Mock::handles.empty() && Mock::allocations == Mock::destructions,"T11_HISTORY: owner-closure");
    std::printf("T11_HISTORY_PASS cases=%u histories=2 profiles=30 coupled-filter=1 null-ui=1 closure=1\n",cases);
}

void signalRecipes(const char* path)
{
    std::ofstream file(path,std::ios::binary); Require(file.good(),"T11_RECIPE: output-open");
    std::ofstream audit(std::string(path)+".cases.jsonl");
    Require(audit.good(),"T11_RECIPE: requested-effective-audit-open");
    auto word = [&](unsigned value) { file.write(reinterpret_cast<const char*>(&value),4); };
    word(0x39524e); word(0); unsigned cases=0;
    for (auto shape : {DlssNr::ColorExtent{7,5},{5,1},{1,5}})
    for (float scale : {.65f,1.0f,1.25f})
    for (unsigned filter : {0u,1u,2u})
    for (unsigned code : {0u,1u,2u,3u})
    for (unsigned transfer : {0u,1u,3u})
    for (unsigned hdr : {0u,1u})
    for (unsigned curve : {0u,2u,4u})
    for (unsigned answer : {0u,1u,3u})
    for (unsigned branch=0; branch<(scale>1 ? 2u : 1u); ++branch)
    {
        auto& cfg = *Config::Instance(); cfg={};
        cfg.DlssNrInputFilter.value=static_cast<DlssNr::InputFilter>(filter);
        cfg.DlssNrSignalEncoding.value=static_cast<DlssNr::SignalEncoding>(code);
        cfg.DlssNrWorkingScale.value=scale; cfg.DlssNrTransfer.value=transfer;
        cfg.DlssNrReversibleMode.value=curve; cfg.DlssNrApplyModel.value=answer!=1;
        ::State::Instance().swapchainApi=API::DX12;
        FilterFixture::upReady=true; FilterFixture::downReady=branch==0;
        ID3D12Device device; ID3D12GraphicsCommandList cmd;
        ID3D12Resource original(shape.width,shape.height),depth(shape.width,shape.height),
                        motion(shape.width,shape.height);
        original.device=depth.device=motion.device=&device;
        DlssNrFrameInfo frame; frame.ColourIsLinearHdr=hdr!=0; frame.IndependentCommands=true;
        DlssNr_Dx12::State state;
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        Require(!state.outputStatus.evaluated,"T11_RUN: creation-not-evaluation");
        ++frame.SubmissionEpoch; FilterFixture::operations.clear();
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        Require(state.outputStatus.evaluated && state.outputStatus.composed && state.outputStatus.copyBack &&
                !state.outputStatus.Applied(),"T11_STATUS: evaluated-not-applied");
        const unsigned effective=hdr ? code : 0u;
        Require(unsigned(cfg.DlssNrSignalEncoding.value)==code,"T11_STATUS: saved-request-preserved");
        const unsigned w=unsigned(shape.width*scale+.5f),h=unsigned(shape.height*scale+.5f);
        const bool shrink=w<=shape.width && h<=shape.height && (w<shape.width || h<shape.height);
        Require(state.outputStatus.signalEncoding==effective &&
                state.outputStatus.signalEncodingOverrideSupported==(hdr!=0) &&
                state.outputStatus.inputFilter==(shrink ? filter : 0u),
                "T11_STATUS: actual-dispatch-facts");
        const FilterFixture::Operation *encode=nullptr,*model=nullptr,*resolve=nullptr;
        for (const auto& op : FilterFixture::operations)
        {
            if (op.kind==1) model=&op;
            if (op.kind==0 && op.constants.Mode==DlssNrMode_Encode) encode=&op;
            if (op.kind==0 && op.constants.Mode==DlssNrMode_Resolve) resolve=&op;
        }
        Require(encode && model && resolve,"T11_DOMAIN: actual-full-run-seams");
        Require(encode->constants.SignalEncoding==effective && resolve->constants.SignalEncoding==effective,
                "T11_DOMAIN: paired-prepared-code");
        const bool successfulDown=scale>1 && branch==0 && (w!=shape.width || h!=shape.height);
        Require(resolve->source==(successfulDown ? state.nr.colorCopy->id : model->source) &&
                resolve->model==(successfulDown ? state.nr.outputNative->id : model->output),
                "T11_REFERENCE: immutable-pair-preserved");
        Require(state.privateCalls==0,"T11_PRIVATE: no-provider-execution");
        DlssNr::StatusSnapshot snapshot; snapshot.output=state.outputStatus;
        DlssNr::PublishStatus(&state,DlssNr::Backend::Dx12,snapshot);
        cfg.DlssNrSignalEncoding.value=static_cast<DlssNr::SignalEncoding>((code+1)%4);
        const auto published=DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
        const auto options=DlssNr::ResolveOptions(cfg.DlssNrInputFilter.value,cfg.DlssNrSignalEncoding.value,
            published.optionContext,published.inputFilter,published.signalEncoding,
            published.inputFilterOverrideSupported,published.signalEncodingOverrideSupported);
        Require(unsigned(options.effectiveSignal)==effective && !published.Applied(),
                "T11_STATUS: published-not-requested");
        DlssNr::ClearStatus(&state);
        audit << "{\"id\":" << cases << ",\"requestedSignal\":" << code
              << ",\"effectiveSignal\":" << effective << ",\"hdr\":" << hdr
              << ",\"inputFilter\":" << filter << ",\"workingScale\":" << scale
              << ",\"shape\":[" << shape.width << ',' << shape.height
              << "],\"work\":[" << w << ',' << h << "],\"transfer\":" << transfer
              << ",\"curve\":" << curve << ",\"answer\":" << answer
              << ",\"branch\":" << branch << "}\n";
        word(cases++); word(shape.width); word(shape.height); word(w); word(h);
        word(filter); word(transfer); word(hdr); word(curve); word(answer); word(branch);
        word(original.id); word(unsigned(FilterFixture::operations.size()));
        for (const auto& op : FilterFixture::operations)
        {
            word(op.kind); word(op.source); word(op.model); word(op.original); word(op.output); word(op.keep);
            file.write(reinterpret_cast<const char*>(&op.constants),sizeof(op.constants));
        }
        closeModels(state,cmd);
    }
    file.seekp(4); word(cases); file.close();
    Require(Mock::handles.empty() && Mock::allocations==Mock::destructions,"T11_RECIPE: owner-closure");
    std::printf("T11_RUN_PASS recipes=%u complete-production-bodies=1 immutable-reference=1 closure=1\n",cases);
}

void unsupportedDispatch()
{
    for (API api : {API::DX11,API::Vulkan})
    for (bool hdr : {false,true})
    for (unsigned code : {0u,1u,2u,3u})
    {
        auto& cfg=*Config::Instance(); cfg={};
        cfg.DlssNrSignalEncoding.value=static_cast<DlssNr::SignalEncoding>(code);
        cfg.DlssNrInputFilter.value=DlssNr::InputFilter::Nearest; cfg.DlssNrWorkingScale.value=.65f;
        ::State::Instance().swapchainApi=api;
        ID3D12Device device; ID3D12GraphicsCommandList cmd;
        ID3D12Resource original(7,5),depth(7,5),motion(7,5);
        original.device=depth.device=motion.device=&device;
        DlssNrFrameInfo frame; frame.ColourIsLinearHdr=hdr; frame.IndependentCommands=true;
        DlssNr_Dx12::State state;
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        ++frame.SubmissionEpoch; FilterFixture::operations.clear();
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        Require(state.outputStatus.evaluated && state.outputStatus.signalEncoding==0 &&
                !state.outputStatus.signalEncodingOverrideSupported && state.outputStatus.inputFilter==0 &&
                !state.outputStatus.inputFilterOverrideSupported,"T11_UNSUPPORTED: legacy-dispatch");
        for (const auto& op : FilterFixture::operations)
            Require(op.constants.SignalEncoding==0 && op.constants.InputFilter==0,
                    "T11_UNSUPPORTED: legacy-constants");
        closeModels(state,cmd);
    }
    std::puts("T11_UNSUPPORTED_PASS cases=16 bridges=DX11,Vulkan legacy-constants=1");
}

int main(int argc,char** argv)
try
{
    Require(argc==2,"T11_ARGUMENT: recipes-path");
    signalHistory(); unsupportedDispatch(); signalRecipes(argv[1]); return 0;
}
catch (const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
