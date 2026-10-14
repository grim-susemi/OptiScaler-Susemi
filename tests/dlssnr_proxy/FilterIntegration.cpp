// This fixture executes actual production source. NGX/GPU boundaries are typed
// services; shader pixels are verified separately from the recorded operations.
#ifdef NR_PROXY_SOURCE
#include "proxy-declarations.inc"
#include NR_PROXY_SOURCE
#else
#include "../../OptiScaler/dlssnr/DlssNr_Proxy.cpp"
#endif
#include "../../OptiScaler/dlssnr/DlssNr_Status.cpp"
#include "../../OptiScaler/dlssnr/PassProfiles.h"
#include <cstdio>
#include "proxy-services.inc"
#include "ModelPreparation.h"
#ifdef NR_ENCODE_SOURCE
#include NR_ENCODE_SOURCE
#else
#include "encode-production.inc"
#endif
#ifdef NR_RUN_SOURCE
#include NR_RUN_SOURCE
#else
#include "run-production.inc"
#endif

using FilterFixture::Require;
void closeModels(DlssNr_Dx12::State& state, ID3D12GraphicsCommandList& cmd)
{
    for (auto& model : state.nr.models) { model.Release(); model.ResetRecording(&cmd); }
    state.lifetime.ResetRecording(&cmd);
}

void historyContracts()
{
    unsigned cases = 0;
    ID3D12Device device;
    ID3D12GraphicsCommandList cmd;
    for (bool nativeApi : {false, true})
    for (auto native : {DlssNr::ColorExtent{7,5}, {5,1}, {1,5}, {1,1}})
    for (auto work : {DlssNr::ColorExtent{unsigned(native.width*.65f+.5f),unsigned(native.height*.65f+.5f)},
        native, {unsigned(native.width*1.25f+.5f),unsigned(native.height*1.25f+.5f)},
        {native.width,std::max(1u,native.height-1)}, {std::max(1u,native.width-1),native.height+1}})
    {
        auto& cfg = *Config::Instance(); cfg = {};
        DlssNr_Dx12::State state;
        state.outputStatus.optionContext.nativeDx12 = nativeApi;
        DlssNrFrameInfo frame;
        D3D12_RESOURCE_DESC desc {native.width, native.height, 1};
        const bool eligible = nativeApi && work.width <= native.width && work.height <= native.height &&
                              (work.width < native.width || work.height < native.height);
        const auto prepare = [&] {
            return state.PrepareRunModels(&cmd, &device, frame, desc, native, work,
                                         work.width > native.width || work.height > native.height ? 1.25f : .65f, 2);
        };
        Require(!prepare(), "T9_HISTORY: first-feature-readiness");
        ++frame.SubmissionEpoch; Require(!prepare(), "T9_HISTORY: second-feature-readiness");
        ++frame.SubmissionEpoch; Require(prepare(), "T9_HISTORY: finite-readiness");
        auto* scratch = state.nr.output;
        unsigned previous = 0;
        for (unsigned code : {1u,2u,2u,0u})
        {
            const unsigned expected = eligible ? code : 0u;
            auto* oldMap = Mock::latest;
            const auto created = Mock::creations, released = Mock::releases, destroyed = Mock::destructions;
            cfg.DlssNrInputFilter.value = static_cast<DlssNr::InputFilter>(code);
            state.nr.reset = false;
            const bool ready = prepare();
            if (expected != previous)
            {
                Require(!ready && state.nr.reset, "T9_HISTORY: effective-filter-reset");
                Require(Mock::creations == created + 1 && Mock::latest != oldMap,
                        "T9_HISTORY: effective-filter-recreate");
                Require(Mock::releases == released && Mock::destructions == destroyed,
                        "T9_HISTORY: prior-owner-retained");
                ++frame.SubmissionEpoch; Require(!prepare(), "T9_HISTORY: next-pass-readiness");
                ++frame.SubmissionEpoch; Require(prepare(), "T9_HISTORY: changed-ready");
            }
            else
                Require(ready && !state.nr.reset && Mock::creations == created,
                        "T9_HISTORY: no-false-reset");
            Require(state.nr.output == scratch && state.parked == 0, "T9_HISTORY: scratch-preserved");
            for (unsigned pass = 0; pass < 2; ++pass)
                Require(state.nr.builtSettings[pass].effectiveInputFilter == expected,
                        "T9_HISTORY: saved-effective-identity");
            for (unsigned pass = 0; pass < 30; ++pass)
            {
                Require(DlssNr::Profiles::PassSettings(cfg,pass,0,expected).effectiveInputFilter == expected,
                        "T9_HISTORY: inherited-filter-identity");
                Require(DlssNr::Profiles::PassSettings(cfg,pass).effectiveInputFilter == 0,
                        "T9_HISTORY: shared-vulkan-zero");
            }
            previous = expected; ++cases;
        }
        // Preserve the accepted automatic UI creation behavior in this new
        // interaction, without invoking the old contract suite.
        cfg.DlssNrAutomaticUICorrection.value = true;
        state.nr.reset = false;
        Require(!prepare() && state.nr.reset && state.outputStatus.uiCorrection == 0,
                "T9_UI: creation-policy-reset");
        Require(std::get<unsigned>(Mock::creationValues.back().at("DLSSNR.UICorrection")) == 0,
                "T9_UI: actual-typed-creation");
        Require(!Mock::creationValues.back().contains("DLSSNR.InputFilter"),
                "T9_HISTORY: no-invented-sdk-parameter");
        closeModels(state,cmd);
    }
    Require(Mock::handles.empty() && Mock::allocations == Mock::destructions,
            "T9_HISTORY: owner-closure");
    std::printf("T9_HISTORY_PASS switch-cases=%u actual-models=2 profiles=30 retained-owner=1 closure=1\n",cases);
}

void recipes(const char* path)
{
    std::ofstream file(path,std::ios::binary);
    Require(file.good(),"T9_RECIPE: output-open");
    auto word = [&](unsigned value) { file.write(reinterpret_cast<const char*>(&value),sizeof(value)); };
    word(0x39524e); word(0); unsigned cases = 0;
    for (auto shape : {DlssNr::ColorExtent{7,5}, {5,1}, {1,5}, {1,1}})
    for (float scale : {.65f,1.0f,1.25f})
    for (unsigned code = 0; code < 3; ++code)
    for (unsigned transfer : {0u,1u,3u})
    for (unsigned hdr : {0u,1u})
    for (unsigned curve = 0; curve < (hdr ? 5u : 1u); ++curve)
    for (unsigned noedit = 0; noedit < 4; ++noedit) // identical, hidden, strength zero, nonneutral
    for (unsigned branch = 0; branch < (scale > 1 ? 3u : 1u); ++branch) // successful/fallback legs
    {
        const auto w = unsigned(shape.width*scale+.5f), h = unsigned(shape.height*scale+.5f);
        const bool eligible = w <= shape.width && h <= shape.height && (w < shape.width || h < shape.height);
#ifdef NR_BASELINE
        if (eligible && code != 0) continue; // Old Area pixels, native and supernative preservation only.
#endif
        auto& cfg = *Config::Instance(); cfg = {};
        cfg.DlssNrInputFilter.value = static_cast<DlssNr::InputFilter>(code);
        cfg.DlssNrWorkingScale.value = scale; cfg.DlssNrTransfer.value = transfer;
        cfg.DlssNrReversibleMode.value = curve;
        cfg.DlssNrApplyModel.value = noedit != 1;
        cfg.DlssNrTransferStrength.value = noedit == 2 ? 0.0f : 1.0f;
        State::Instance().swapchainApi = API::DX12;
        FilterFixture::upReady = branch != 2; FilterFixture::downReady = branch == 0;
        ID3D12Device device; ID3D12GraphicsCommandList cmd;
        ID3D12Resource original(shape.width,shape.height), depth(shape.width,shape.height),
                        motion(shape.width,shape.height);
        original.device = depth.device = motion.device = &device;
        DlssNrFrameInfo frame; frame.ColourIsLinearHdr = hdr != 0;
        frame.IndependentCommands = true;
        DlssNr_Dx12::State state;
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        Require(!state.outputStatus.evaluated,"T9_RUN: creation-not-evaluation");
        ++frame.SubmissionEpoch; FilterFixture::operations.clear();
        state.Run(&cmd,&original,&depth,&motion,&original,frame,nullptr);
        Require(state.outputStatus.evaluated && state.outputStatus.composed && state.outputStatus.copyBack &&
                !state.outputStatus.Applied(),"T9_STATUS: evaluated-not-submitted");
        const auto expected = eligible ? code : 0u;
#ifndef NR_BASELINE
        Require(state.outputStatus.inputFilter == expected &&
                state.outputStatus.inputFilterOverrideSupported == eligible &&
                state.outputStatus.signalEncoding == 0 && !state.outputStatus.signalEncodingOverrideSupported,
                "T9_STATUS: actual-filter-publication");
        DlssNr::StatusSnapshot snapshot; snapshot.output = state.outputStatus;
        DlssNr::PublishStatus(&state,DlssNr::Backend::Dx12,snapshot);
        cfg.DlssNrInputFilter.value = static_cast<DlssNr::InputFilter>((code+1)%3);
        const auto published = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
        const auto options = DlssNr::ResolveOptions(cfg.DlssNrInputFilter.value,DlssNr::SignalEncoding::Legacy,
            published.optionContext,published.inputFilter,published.signalEncoding,
            published.inputFilterOverrideSupported,published.signalEncodingOverrideSupported);
        Require(unsigned(options.effectiveFilter)==expected && !published.Applied(),
                "T9_STATUS: published-not-selected");
        DlssNr::ClearStatus(&state);
#endif
        const FilterFixture::Operation *model = nullptr, *resolve = nullptr;
        for (const auto& op : FilterFixture::operations)
        {
            if (op.kind == 1) model = &op;
            if (op.kind == 0 && op.constants.Mode == DlssNrMode_Resolve) resolve = &op;
        }
        Require(model && resolve,"T9_REFERENCE: actual-run-seams");
        const bool successfulDown = scale > 1 && branch == 0 && (w != shape.width || h != shape.height);
        Require(resolve->source == (successfulDown ? state.nr.colorCopy->id : model->source),
                "T9_REFERENCE: immutable-model-input");
        Require(resolve->model == (successfulDown ? state.nr.outputNative->id : model->output),
                "T9_REFERENCE: legacy-answer-branch");
        Require(state.privateCalls == 0,"T9_PRIVATE: spatial-only-no-runtime");
        word(cases++); word(shape.width); word(shape.height); word(w); word(h);
        word(code); word(transfer); word(hdr); word(curve); word(noedit); word(branch);
        word(original.id); word(unsigned(FilterFixture::operations.size()));
        for (const auto& op : FilterFixture::operations)
        {
            word(op.kind); word(op.source); word(op.model); word(op.original); word(op.output); word(op.keep);
            file.write(reinterpret_cast<const char*>(&op.constants),sizeof(op.constants));
        }
        closeModels(state,cmd);
    }
    file.seekp(sizeof(unsigned)); word(cases); file.close();
    Require(Mock::handles.empty() && Mock::allocations == Mock::destructions,"T9_RECIPE: owner-closure");
    std::printf("T9_RUN_PASS recipes=%u complete-production-bodies=1 actual-reference-branches=1 closure=1\n",cases);
}
int main(int argc,char** argv)
try
{
    Require(argc == 2,"T9_ARGUMENT: recipes-path");
#ifndef NR_BASELINE
    historyContracts();
#endif
    recipes(argv[1]);
    return 0;
}
catch (const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
