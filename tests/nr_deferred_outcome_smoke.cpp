// Scoped R1 delta: reuse the owned WARP fixture, not its old case invocation.
#define T5_DEFERRED_R1
#define main historical_finished_main
#include "nr_finished_outcome_smoke.cpp"
#undef main
using DlssNr::CopyActiveColor;

// Allocation and private-provider services are explicit adapters. The asserted
// Before, Run, After, EvaluateInternal and submission bodies are extracted whole.
auto DlssNr_Dx12::State::DeferredSrContext::Allocate(Generation& g) -> bool
{
    for (auto** r : { &g.edited, &g.clean, &g.composed })
        *r = owner.CreateScratch(g.device, DXGI_FORMAT_R8G8B8A8_UNORM, 8, 8);
    for (auto** r : { &g.residualInput, &g.residualOutput })
        *r = owner.CreateScratch(g.device, DXGI_FORMAT_R16G16B16A16_FLOAT, 8, 8);
    g.exposure = owner.CreateScratch(g.device, DXGI_FORMAT_R32_FLOAT, 1, 1);
    g.codec = std::make_unique<DlssNr_Dx12>();
    D3D12_QUERY_HEAP_DESC query {}; query.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP; query.Count = MarkerCount;
    Check(g.device->CreateQueryHeap(&query, IID_PPV_ARGS(&g.queries)));
    D3D12_HEAP_PROPERTIES hp {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
    D3D12_RESOURCE_DESC d {}; d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; d.Width = MarkerCount * sizeof(UINT64);
    d.Height = 1; d.DepthOrArraySize = d.MipLevels = 1; d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    Check(g.device->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &d,
          D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&g.readback)));
    void* mapped = nullptr; Check(g.readback->Map(0, nullptr, &mapped));
    g.completed = static_cast<volatile UINT64*>(mapped);
    for (unsigned i = 0; i < MarkerCount; ++i) g.completed[i] = 0;
    return true;
}
auto DlssNr_Dx12::State::DeferredSrContext::RetireCurrent() -> void
{ current.reset(); } // fixture only, after its independent queue-tail completion

bool DlssNr::PrivateUpscalerDx12::Evaluate(ID3D12GraphicsCommandList* cmd, const PrivateUpscalerFrameDx12& f)
{
    ++privateEvaluations;
    if (injectDeferredPrivate) return false;
    DlssNrConstants p {}; p.Width = f.outputWidth; p.Height = f.outputHeight; p.ApplyModel = true;
    return activeOwner->_state->deferredSr.current->codec->DispatchPass(cmd, p, nullptr, nullptr, nullptr,
        nullptr, nullptr, f.output.resource, nullptr);
}
bool DlssNr_Dx12::State::LateContext::CaptureResidual(ID3D12GraphicsCommandList*, ID3D12Resource*,
    ID3D12Resource*, float, bool, bool)
{ ++savedCarriers; return true; } // explicit carrier storage service, no Present composition
#include "deferred_production.inc"

int main(int argc, char** argv) try
{
    Expect(argc == 2, "R1_CASE_REQUIRED");
    const std::string test = argv[1];
    Expect(test == "private-failure" || test == "composition-failure" || test == "success" ||
           test == "future-carrier" || test == "after-refusal", "R1_UNKNOWN_CASE");
    {
    Fixture f(false);
    auto& owner = *f.owner._state;
    auto& cfg = *Config::Instance();
    cfg.DlssNrFinishedPicture.stored = test == "future-carrier";
    cfg.DlssNrDeferredDlss.stored = true;
    owner.lastFinishedMode = cfg.DlssNrFinishedPicture.stored ? 2 : 0;
    owner.allowCaptureTrigger = true;
    injectDeferredPrivate = test == "private-failure";
    injectDeferredComposition = test == "composition-failure";
    privateEvaluations = savedCarriers = 0;
    auto& slot = owner.late.slots[0];
    // Preserve a non-reusable production pin/watermark across the caller chain.
    slot.pinned = true; slot.pending = false;
    const auto ready = slot.ready, done = slot.done;
    ComPtr<ID3D12Resource> color, application;
    color.Attach(owner.CreateScratch(f.device.Get(), DXGI_FORMAT_R8G8B8A8_UNORM, 8, 8));
    application.Attach(owner.CreateScratch(f.device.Get(), DXGI_FORMAT_R8G8B8A8_UNORM, 8, 8));
    Check(slot.allocator->Reset()); Check(slot.commands->Reset(slot.allocator.Get(), nullptr));
    DlssNrConstants black {};
    Expect(f.owner.DispatchPass(slot.commands.Get(), black, nullptr, nullptr, nullptr, nullptr, nullptr,
                                color.Get(), nullptr), "R1_COLOR_SETUP");
    Expect(f.owner.DispatchPass(slot.commands.Get(), black, nullptr, nullptr, nullptr, nullptr, nullptr,
                                application.Get(), nullptr), "R1_APPLICATION_SETUP");
    owner.Barrier(slot.commands.Get(), color.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                  D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    for (auto* guide : { slot.depth.Get(), slot.motion.Get() })
        owner.Barrier(slot.commands.Get(), guide, D3D12_RESOURCE_STATE_COPY_DEST,
                      D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Check(slot.commands->Close()); ID3D12CommandList* lists[] { slot.commands.Get() };
    f.queue->ExecuteCommandLists(1, lists); f.Drain();
    const auto original = f.Pixel(application.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    // Explicit creation adapter: initialize the retained generation at a prior
    // submitted epoch. Actual Before validates its identity and owns its markers.
    auto& deferred = owner.deferredSr;
    deferred.current = std::make_unique<DlssNr_Dx12::State::DeferredSrContext::Generation>();
    auto& g = *deferred.current;
    g.device = f.device.Get(); g.device->AddRef();
    g.queue = f.queue.Get(); g.queue->AddRef();
    g.w = g.h = g.outW = g.outH = 8;
    g.inputFormat = g.outputFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
    g.finishedPicture = cfg.DlssNrFinishedPicture.stored;
    Expect(deferred.Allocate(g), "R1_GENERATION_SETUP");
    g.upscaler = std::make_unique<DlssNr::PrivateUpscalerDx12>(g.backend);
    DeferredParams params;
    params.Set(NVSDK_NGX_Parameter_Color, color.Get());
    params.Set(NVSDK_NGX_Parameter_Output, application.Get());
    params.Set(NVSDK_NGX_Parameter_Depth, slot.depth.Get());
    params.Set(NVSDK_NGX_Parameter_MotionVectors, slot.motion.Get());
    params.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, 8u);
    params.Set(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, 8u);
    Check(slot.allocator->Reset()); Check(slot.commands->Reset(slot.allocator.Get(), nullptr));
    // Finished-picture interop requires a DX11 bridge. This additional case
    // exercises the native DX12 route instead; the locked failures keep their
    // original borrowed-readable/interop setup and exact submitted epoch.
    const bool interop = test != "future-carrier";
    owner.EvaluateInternal(slot.commands.Get(), &params, true, f.queue.Get(), false, 42, interop);
    Expect(owner.nr.successfulDispatches == 1 && owner.nr.models[0].evaluations == 1 &&
           deferred.pending.cmd == slot.commands.Get(), "R1_INTERMEDIATE_RUN_AND_SEAM_SUCCEEDED");
    // The actual caller refuses a mismatched immediate After; no copied policy.
    DeferredParams other;
    owner.EvaluateInternal(slot.commands.Get(), test == "after-refusal" ? &other : &params,
                           false, f.queue.Get(), false, 42, interop);
    owner.Publish();
    const auto recorded = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
    Check(slot.commands->Close());
    f.queue->ExecuteCommandLists(1, lists);
    DlssNr::LatePromiseBatch batch;
    owner.FinishedPictureSubmitted(batch, &f.owner, f.queue.Get(), 1, lists);
    f.Drain();
    const auto o = DlssNr::ReadStatus(DlssNr::Backend::Dx12).output;
    const auto pixel = f.Pixel(application.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    const auto scratch = f.Pixel(g.edited, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    std::printf("R1_FACTS case=%s evaluated=%d recordedApplied=%d state=%u reason=%u composed=%d copyBack=%d executed=%d submitted=%d applied=%d original=%08X application=%08X scratch=%08X nrEvaluations=%u privateEvaluations=%u carriers=%u pin=%d ready=%llu done=%llu markers=%u\n",
        test.c_str(), o.evaluated, recorded.Applied(), unsigned(o.state), unsigned(o.reason), o.composed,
        o.copyBack, o.executed, o.submitted, o.Applied(), original, pixel, scratch,
        owner.nr.models[0].evaluations, privateEvaluations, savedCarriers, slot.pinned, slot.ready, slot.done, g.nextMarker);
    Expect(scratch == 0xFF0000FF && !recorded.Applied(), "R1_ACTUAL_INTERMEDIATE_EDIT");
    Expect(slot.pinned && slot.ready == ready && slot.done == done && slot.submitted &&
           !DlssNr::LateSlotReusable(slot.pending, slot.owned, slot.pinned, slot.promisePending, true,
                                     slot.done, slot.fence->GetCompletedValue()) &&
           g.nextMarker == (test == "after-refusal" ? 1u : 2u) && g.completed[0] != 0,
           "R1_OWNERSHIP_PRESERVED");
    Expect(owner.nr.models[0].evaluations == 1 && owner.nr.successfulDispatches == 1 &&
           privateEvaluations == (test == "after-refusal" ? 0u : 1u), "R1_EVALUATION_COUNTS_PRESERVED");
    if (test == "success")
        Expect(o.Applied() && o.composed && o.copyBack && o.executed && o.submitted &&
               pixel == 0xFF0000FF, "R1_FINAL_DEFERRED_OUTPUT_APPLIED");
    else
    {
        // Keep the pixel assertion independent of the status regression.
        Expect(pixel == original && original == 0xFF000000, "R1_FAILURE_APPLICATION_PIXELS_UNCHANGED");
        const char* assertion = test == "private-failure" ? "R1_PRIVATE_FAILURE_NOT_APPLIED" :
            test == "composition-failure" ? "R1_COMPOSITION_FAILURE_NOT_APPLIED" :
            test == "future-carrier" ? "R1_FUTURE_CARRIER_NOT_APPLIED" : "R1_AFTER_REFUSAL_NOT_APPLIED";
        Expect(!o.Applied() && !o.composed && !o.copyBack && !owner.outputCommands, assertion);
        if (test == "private-failure")
            Expect(o.state == DlssNr::OutputState::Failed && o.reason == DlssNr::OutputReason::Model,
                   "R1_PRIVATE_FAILURE_NAMED");
        if (test == "composition-failure")
            Expect(o.state == DlssNr::OutputState::Failed && o.reason == DlssNr::OutputReason::Composition,
                   "R1_COMPOSITION_FAILURE_NAMED");
        if (test == "future-carrier") Expect(savedCarriers == 1, "R1_CARRIER_SAVED_WITHOUT_APPLICATION");
    }
    f.Drain();
    std::printf("R1_CASE_PASS=%s\n", test.c_str());
    }
    std::puts("R1_CLOSURE=owned_COM_scope_closed");
    return 0;
}
catch (const std::exception& error)
{
    std::puts("R1_CLOSURE=owned_COM_scope_closed");
    std::printf("R1_FAIL=%s\n", error.what());
    return 1;
}
