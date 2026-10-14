#include "ObserverServices.h"
#include <iostream>
#include "observer-production.inc"
using namespace DlssNr::MfgObserver;

// Repeated assertions share one owned value copy instead of reserving a large
// temporary Snapshot for every expression on the fixture's default stack.
const Snapshot& Observed()
{
    static auto snapshot = std::make_unique<Snapshot>();
    DlssNr::NgxDiagnostics::ReadMfgObservation(*snapshot);
    return *snapshot;
}
void Dump(const char* name)
{
    const auto& snapshot = Observed();
    std::cout << "{\"case\":\"" << name << "\",\"pass\":true,\"session\":" << snapshot.session
              << ",\"owner\":" << snapshot.owner << ",\"applicationSeams\":" << snapshot.applicationSeams
              << ",\"events\":" << snapshot.eventCount << ",\"capped\":" << (snapshot.capped ? "true" : "false")
              << ",\"retainedValueBytes\":" << sizeof(Snapshot) << ",\"displayTimingAvailable\":false"
              << ",\"gpu\":\"not_run\",\"provider\":\"typed_fixture\",\"sample\":[";
    for (uint32_t i = 0; i < std::min(snapshot.eventCount, 8u); ++i)
    {
        const auto& event = snapshot.events[i];
        if (i) std::cout << ',';
        std::cout << "{\"activity\":" << event.activity << ",\"seam\":" << unsigned(event.seam)
                  << ",\"provider\":" << event.provider << ",\"handle\":" << event.handle
                  << ",\"handleId\":" << event.handleId << ",\"featureKnown\":" << event.featureKnown
                  << ",\"feature\":" << event.feature << ",\"owner\":" << event.identity.owner
                  << ",\"consumer\":" << event.identity.consumer << ",\"generation\":" << event.identity.generation
                  << ",\"applicationKnown\":" << event.identity.applicationKnown
                  << ",\"application\":" << event.identity.application << ",\"phase\":null,\"pixelOrigin\":null"
                  << ",\"indexAttempted\":" << event.indexReadAttempted << ",\"indexSuccess\":" << event.indexReadSuccess
                  << ",\"indexResult\":" << event.indexReadResult << ",\"rawIndex\":" << event.rawIndex
                  << ",\"indexSource\":" << unsigned(event.indexSource)
                  << ",\"indexResultKnown\":" << event.indexReadResultKnown
                  << ",\"inputCount\":" << event.inputCount << ",\"inputEntriesObserved\":" << event.inputEntriesObserved
                  << ",\"resultKnown\":" << event.resultKnown << ",\"result\":" << event.result
                  << ",\"resources\":[";
        for (uint32_t j = 0; j < event.resourceCount; ++j)
        {
            const auto& value = event.resources[j];
            if (j) std::cout << ',';
            std::cout << "{\"value\":" << value.value << ",\"role\":" << unsigned(value.role)
                      << ",\"declaration\":" << unsigned(value.declaration) << ",\"attempted\":" << value.readAttempted
                      << ",\"success\":" << value.readSuccess << ",\"result\":" << value.readResult << '}';
        }
        std::cout << "]}";
    }
    std::cout << "]}\n";
}
void UnknownFacts(const Event& event)
{
    Require(!event.phaseKnown, "T20_NO_INVENTED_PHASE");
    Require(!event.pixelOriginKnown, "T20_NO_INVENTED_PIXEL_ORIGIN");
    Require(!event.displayTimingAvailable, "T20_NO_INVENTED_DISPLAY_TIMING");
}
struct Forwarded
{
    std::map<std::string, Params::Value> values;
    std::vector<std::string> order;
    std::array<uint32_t, 4> real, generated;
    NVSDK_NGX_Result result;
};
Forwarded Forward(bool enabled, unsigned mode)
{
    static unsigned owner;
    Stop(&owner);
    if (enabled) Require(Begin(&owner, 20 + mode), "T20_EXPLICIT_SESSION");
    Pixels input {{1, 2, 3, 4}}, real, generated;
    Params parameters;
    parameters.Set("DLSSG.MultiFrameIndex", mode == 2 ? 2u : 7u);
    parameters.Set("DLSSG.MultiFrameCount", mode == 2 ? 3u : 1u);
    parameters.Set("DLSSG.Backbuffer", PixelResource(input));
    parameters.Set("DLSSG.OutputReal", PixelResource(real));
    parameters.Set("DLSSG.OutputInterpolated", PixelResource(generated));
    NVSDK_NGX_Handle native {37}, ffx {43}, arturs {44};
    Nvngx_FG::Nvngx_FG_Handle replacement {2001, &native};
    Nvngx_Combo::Nvngx_Combo_Handle comboHandle {2002, &ffx, &arturs};
    expectedHandle = mode == 2 ? &ffx : &native;
    expectedParameters = &parameters;
    expectedCallback = nullptr;
    expectedIndex = mode == 2 ? 1 : 7;
    evaluateCalls = 0;
    ::order.clear();
    providerResult = NVSDK_NGX_Result_FAIL_InvalidParameter;
    NVSDK_NGX_Result result;
    if (mode == 2)
    {
        Nvngx_Combo combo;
        result = combo.D3D12_EvaluateFeature(expectedCommands, reinterpret_cast<NVSDK_NGX_Handle*>(&comboHandle),
                                            &parameters, expectedCallback);
    }
    else if (mode == 3)
    {
        result = Nvngx_FG::VULKAN_EvaluateFeature(reinterpret_cast<VkCommandBuffer>(expectedCommands),
            reinterpret_cast<NVSDK_NGX_Handle*>(&replacement), &parameters, expectedCallback);
    }
    else
    {
        ::State::Instance().activeFgNvngx = mode == 1 ? FGNvngxReplacement::Other : FGNvngxReplacement::None;
        auto* handle = mode == 1 ? reinterpret_cast<NVSDK_NGX_Handle*>(&replacement) : &native;
        HandleToFeature.Record(handle->Id, NVSDK_NGX_Feature_FrameGeneration);
        result = NVSDK_NGX_D3D12_EvaluateFeature(expectedCommands, handle, &parameters, expectedCallback);
    }
    Require(evaluateCalls == 1, "T20_ORIGINAL_EVALUATE_EXACTLY_ONCE");
    Require(result == providerResult, "T20_ORIGINAL_EVALUATE_RESULT");
    const auto snapshot = Observed();
    if (enabled)
    {
        Require(snapshot.eventCount == 1, "T20_ACTUAL_FORWARDING_OBSERVATION");
        const auto& event = snapshot.events[0];
        UnknownFacts(event);
        Require(event.rawIndex == (mode == 2 ? 2u : 7u) && event.indexReadSuccess, "T20_RAW_INDEX_UNINTERPRETED");
        Require(!event.identity.applicationKnown && event.identity.generation == 0, "T20_NO_CROSS_CALLBACK_ASSOCIATION");
        Require(event.resources[1].declaration == Declaration::ProviderReal &&
                event.resources[2].declaration == Declaration::ProviderGenerated, "T20_PROVIDER_DECLARED_ASSOCIATIONS");
        Require(event.result == unsigned(providerResult) && event.resultKnown, "T20_RAW_PROVIDER_RESULT");
        Require(event.handleId == (mode == 2 ? 2002u : 37u) && event.provider != 0, "T20_ACTUAL_PROVIDER_HANDLE");
        Require(event.resources[0].ngxVkResource == (mode == 3), "T20_VK_OPAQUE_RECORD_NOT_DX12_RESOURCE");
    }
    return {parameters.values, ::order, real.values, generated.values, result};
}
void Forwarding()
{
    for (unsigned mode = 0; mode < 4; ++mode)
    {
        const auto off = Forward(false, mode), on = Forward(true, mode);
        Require(off.values == on.values && off.order == on.order && off.result == on.result,
                "T20_OFF_ON_FORWARDING_EQUAL");
        Require(off.real == on.real && off.generated == on.generated, "T20_OFF_ON_CPU_PIXELS_EQUAL");
    }
}
void Raw()
{
    static unsigned owner;
    Require(Begin(&owner, 30), "T20_EXPLICIT_SESSION");
    NVSDK_NGX_Handle handle {5};
    Params parameters;
    const auto missing = Ngx(Seam::NgxNative, 17, &handle, &parameters, expectedCommands,
                              NVSDK_NGX_Feature_FrameGeneration, true);
    Complete(missing, NVSDK_NGX_Result_Fail);
    Require(missing.indexReadAttempted && !missing.indexReadSuccess &&
            missing.indexReadResultKnown && missing.indexSource == IndexSource::NgxMultiFrameIndex &&
            missing.indexReadResult == unsigned(NVSDK_NGX_Result_Fail) && missing.rawIndex == 0,
            "T20_MISSING_RAW_READ_RESULT");
    Require(missing.resources[1].readAttempted && !missing.resources[1].readSuccess &&
            !missing.resources[1].value, "T20_MISSING_RESOURCE_KEYS");
    Pixels alias;
    parameters.Set("DLSSG.MultiFrameIndex", 0xffffffffu);
    parameters.Set("DLSSG.OutputReal", PixelResource(alias));
    parameters.Set("DLSSG.OutputInterpolated", PixelResource(alias));
    auto conflicting = Ngx(Seam::NgxNative, 17, &handle, &parameters, nullptr,
                            NVSDK_NGX_Feature_FrameGeneration, true);
    Complete(conflicting, NVSDK_NGX_Result_Success);
    Require(conflicting.rawIndex == 0xffffffffu, "T20_RAW_INDEX_UNINTERPRETED");
    Require(conflicting.resources[1].declaration == Declaration::Unknown &&
            conflicting.resources[2].declaration == Declaration::Unknown, "T20_ALIAS_ORIGIN_UNKNOWN");
    const auto untracked = Ngx(Seam::NgxNative, 17, &handle, &parameters, nullptr, 0, false);
    Require(!untracked.featureKnown && untracked.resources[1].declaration == Declaration::Unknown,
            "T20_UNTRACKED_FEATURE_UNKNOWN");
    Complete(untracked, NVSDK_NGX_Result_Fail);
    const auto nullParameters = Ngx(Seam::NgxNative, 17, &handle, nullptr, nullptr, 0, false);
    Require(!nullParameters.indexReadAttempted, "T20_NO_SYNTHETIC_GET_RESULT");
    Complete(nullParameters, NVSDK_NGX_Result_Fail);
    parameters.Set("DLSSG.MultiFrameIndex", 7.75f);
    parameters.Set("DLSSG.OutputReal", static_cast<void*>(PixelResource(alias)));
    const auto converted = Ngx(Seam::NgxNative, 17, &handle, &parameters, nullptr,
                                NVSDK_NGX_Feature_FrameGeneration, true);
    Require(converted.indexReadSuccess && converted.rawIndex == 7 &&
            converted.resources[1].readSuccess && converted.resources[1].value == Value(PixelResource(alias)),
            "T20_PRODUCTION_GET_NUMERIC_AND_POINTER_CONVERSION");
    Complete(converted, NVSDK_NGX_Result_Success);
    parameters.Set("DLSSG.MultiFrameIndex", static_cast<void*>(PixelResource(alias)));
    const auto zeroConversion = Ngx(Seam::NgxNative, 17, &handle, &parameters, nullptr, 0, false);
    Require(zeroConversion.indexReadSuccess && zeroConversion.rawIndex == 0,
            "T20_GET_SUCCESS_NOT_STORED_TYPE_GUESS");
    Complete(zeroConversion, NVSDK_NGX_Result_Success);
    for (unsigned i = 0; i < Observed().eventCount; ++i) UnknownFacts(Observed().events[i]);
}
void Association()
{
    DlssNr_Dx12 owner;
    Require(Begin(&owner, 31), "T20_EXPLICIT_SESSION");
    Pixels colour {{4, 3, 2, 1}};
    Params parameters;
    parameters.Set(NVSDK_NGX_Parameter_Color, PixelResource(colour));
    DlssNr::StreamlinePicture::ConsumerSnapshot consumer;
    const std::array<DlssNr::FinishedIdentity, 5> identities {{
        {&owner, reinterpret_cast<void*>(0x200), 11, 7, true},
        {&owner, reinterpret_cast<void*>(0x200), 11, 7, true}, // duplicate
        {&owner, reinterpret_cast<void*>(0x200), 12, 7, true}, // resize/generation
        {&owner, reinterpret_cast<void*>(0x300), 12, 7, true}, // equal-sized second consumer
        {&owner, reinterpret_cast<void*>(0x300), 13, 0, false} // reset, unknown token
    }};
    for (const auto& identity : identities)
    {
        consumer.identity = identity;
        owner.ProcessSeam(expectedCommands, &parameters, true, nullptr, false, 99, false, 0, consumer);
        const auto event = Observed().events[Observed().eventCount - 1];
        const auto expected = CopyIdentity(identity);
        Require(event.identity.owner == Value(&owner) && event.identity.consumer == expected.consumer &&
                event.identity.generation == expected.generation && event.identity.application == expected.application &&
                event.identity.applicationKnown == expected.applicationKnown, "T20_CURRENT_ASSOCIATION");
        Require(event.resources[0].value == Value(PixelResource(colour)), "T20_CURRENT_RESOURCE_ASSOCIATION");
        UnknownFacts(event);
    }
    Require(Observed().eventCount == identities.size(), "T20_DUPLICATES_ARE_LOGICAL_CALLBACKS");
    Stop(&owner);
    Require(!Enabled(), "T20_OWNER_RETIREMENT_ENDS_SESSION");
}
void Bounds()
{
    static unsigned owner;
    Require(Begin(&owner, 32), "T20_EXPLICIT_SESSION");
    DlssNr::FinishedIdentity identity {&owner, nullptr, 0, 0, false};
    for (unsigned i = 0; i < kApplicationSeamCap + 1; ++i) Nr(&owner, identity, 0, nullptr);
    Require(!Enabled() && Observed().capped && Observed().applicationSeams == 64 &&
            Observed().eventCount == 64, "T20_APPLICATION_CALLBACK_CAP");
    unsigned otherOwner = 0;
    Require(Begin(&owner, 321), "T20_EXPLICIT_SESSION");
    for (unsigned i = 0; i < kApplicationSeamCap + 1; ++i) Nr(&otherOwner, identity, 3, nullptr);
    Require(!Enabled() && Observed().capped && Observed().applicationSeams == 64 &&
            Observed().eventCount == 64, "T20_ALL_NR_APPLICATION_MARKERS_CAPPED");
    Require(Begin(&owner, 33), "T20_EXPLICIT_SESSION");
    Event providerCallback;
    providerCallback.seam = Seam::NgxNative;
    for (unsigned i = 0; i < kEventCap + 1; ++i) Publish(providerCallback);
    Require(!Enabled() && Observed().capped && Observed().eventCount == kEventCap, "T20_FIXED_VALUE_EVENT_CAP");
    Require(Begin(&owner, 34), "T20_EXPLICIT_SESSION");
    // Exact synchronization, no sleeps or timing luck: own the publisher lock
    // while another thread attempts publication; it must return without waiting.
    HANDLE returned = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    Require(returned != nullptr, "T20_SUBSCRIBE_CONTENTION_RETURN");
    std::unique_lock held(DlssNr::MfgObserver::State().mutex);
    std::thread contender([&] { Publish(Event {}); SetEvent(returned); });
    Require(WaitForSingleObject(returned, 5000) == WAIT_OBJECT_0, "T20_CALLBACK_CONTENTION_NO_WAIT");
    held.unlock();
    contender.join();
    CloseHandle(returned);
    Require(Observed().contentionDrops == 1 && Observed().eventCount == 0, "T20_CONTENTION_DROP_REPORTED");
    held.lock();
    HANDLE stopped = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    Require(stopped != nullptr, "T20_SUBSCRIBE_RETIREMENT_RETURN");
    std::thread retirement([&] { Stop(&owner); SetEvent(stopped); });
    Require(WaitForSingleObject(stopped, 5000) == WAIT_OBJECT_0 && !Enabled(),
            "T20_RETIREMENT_STOPS_UNDER_CONTENTION");
    held.unlock();
    retirement.join();
    CloseHandle(stopped);
    Require(Begin(&owner, 34), "T20_EXPLICIT_SESSION");
    Params parameters;
    const auto old = Ngx(Seam::NgxNative, 1, nullptr, &parameters, nullptr, 0, false);
    Require(Begin(&owner, 35), "T20_EXPLICIT_SESSION");
    Complete(old, NVSDK_NGX_Result_Success);
    Require(Observed().eventCount == 0, "T20_OLD_SESSION_CALLBACK_NOT_RELABELED");
}
struct Token : sl::FrameToken { operator uint32_t() const override { return 91; } };
inline unsigned slCalls = 0, presents = 0;
const sl::BaseStructure** expectedSlInputs = nullptr;
uint32_t expectedSlInputCount = 1;
sl::Result SlProvider(sl::Feature feature, const sl::FrameToken& frame, const sl::BaseStructure** inputs,
                       uint32_t count, sl::CommandBuffer* commands)
{
    Require(feature == sl::kFeatureDLSS_G && uint32_t(frame) == 91 && inputs == expectedSlInputs &&
            count == expectedSlInputCount &&
            commands == reinterpret_cast<sl::CommandBuffer*>(expectedCommands), "T20_SL_FORWARDED_PARAMETERS");
    ++slCalls;
    return sl::Result::eErrorInvalidParameter;
}
HRESULT PresentProvider(IDXGISwapChain* chain, UINT interval, UINT flags, bool& skip)
{
    Require(chain == reinterpret_cast<IDXGISwapChain*>(0x400) && interval == 3 && flags == DXGI_PRESENT_TEST && skip,
            "T20_PRESENT_FORWARDED_PARAMETERS");
    ++presents;
    skip = false;
    return E_FAIL;
}
HRESULT Present1Provider(IDXGISwapChain* chain, UINT interval, UINT flags, const DXGI_PRESENT_PARAMETERS* parameters,
                          bool& skip)
{
    Require(parameters && parameters->DirtyRectsCount == 9, "T20_PRESENT1_FORWARDED_POINTER");
    return PresentProvider(chain, interval, flags, skip);
}
UINT PluginIndex(IDXGISwapChain*, bool&) { Require(false, "T20_UNEXPECTED_RESOURCE_QUERY"); return 0; }
HRESULT PluginBuffer(IDXGISwapChain*, UINT, REFIID, void**, bool&)
{ Require(false, "T20_UNEXPECTED_RESOURCE_QUERY"); return E_FAIL; }
void* Plugin(const char* name)
{
    if (!std::strcmp(name, "slHookPresent")) return reinterpret_cast<void*>(&PresentProvider);
    if (!std::strcmp(name, "slHookPresent1")) return reinterpret_cast<void*>(&Present1Provider);
    if (!std::strcmp(name, "slHookGetCurrentBackBufferIndex")) return reinterpret_cast<void*>(&PluginIndex);
    if (!std::strcmp(name, "slHookGetBuffer")) return reinterpret_cast<void*>(&PluginBuffer);
    return nullptr;
}
void Streamline()
{
    static unsigned owner;
    Token token;
    Pixels pixels;
    sl::Resource resource(sl::ResourceType::eTex2d, PixelResource(pixels));
    sl::ResourceTag tag(&resource, sl::kBufferTypeHUDLessColor, sl::ResourceLifecycle::eOnlyValidNow);
    const sl::BaseStructure* inputs[] {&tag};
    expectedSlInputs = inputs;
    o_slEvaluateFeature = &SlProvider;
    auto present = reinterpret_cast<decltype(&PresentProvider)>(DlssNr::StreamlinePicture::Wrap("slHookPresent", Plugin));
    auto present1 = reinterpret_cast<decltype(&Present1Provider)>(DlssNr::StreamlinePicture::Wrap("slHookPresent1", Plugin));
    Require(present && present1, "T20_ACTUAL_PLUGIN_WRAPPERS");
    for (bool enabled : {false, true})
    {
        Stop(&owner);
        if (enabled) Require(Begin(&owner, 36), "T20_EXPLICIT_SESSION");
        slCalls = presents = 0;
        const auto result = StreamlineHooks::hkslEvaluateFeature(sl::kFeatureDLSS_G, token, inputs, 1,
                                                                reinterpret_cast<sl::CommandBuffer*>(expectedCommands));
        Require(result == sl::Result::eErrorInvalidParameter && slCalls == 1, "T20_SL_ORIGINAL_EXACTLY_ONCE_RESULT");
        bool skip = true;
        DXGI_PRESENT_PARAMETERS parameters {};
        parameters.DirtyRectsCount = 9;
        Require(present(reinterpret_cast<IDXGISwapChain*>(0x400), 3, DXGI_PRESENT_TEST, skip) == E_FAIL && !skip,
                "T20_PRESENT_RESULT_AND_REFERENCE");
        skip = true;
        Require(present1(reinterpret_cast<IDXGISwapChain*>(0x400), 3, DXGI_PRESENT_TEST, &parameters, skip) == E_FAIL &&
                !skip && presents == 2, "T20_ORIGINAL_PRESENT_EXACTLY_ONCE");
        if (enabled)
        {
            Require(Observed().eventCount == 3, "T20_SL_AND_PRESENT_ACTUAL_OBSERVATIONS");
            Require(Observed().events[0].resources[0].value == Value(PixelResource(pixels)) &&
                    Observed().events[0].resources[0].lifecycle == sl::ResourceLifecycle::eOnlyValidNow,
                    "T20_SL_VALUE_ONLY_TAG_ASSOCIATION");
            Require(!Observed().events[0].identity.applicationKnown, "T20_SL_INDEX_NOT_NR_TOKEN");
            Require(Observed().events[0].indexSource == IndexSource::StreamlineFrameToken &&
                    !Observed().events[0].indexReadResultKnown, "T20_SL_HAS_NO_NGX_GET_RESULT");
            for (unsigned i = 0; i < 3; ++i) UnknownFacts(Observed().events[i]);
        }
        const sl::BaseStructure* sparse[8] {};
        sparse[7] = &tag;
        expectedSlInputs = sparse;
        expectedSlInputCount = 8;
        Require(StreamlineHooks::hkslEvaluateFeature(sl::kFeatureDLSS_G, token, sparse, 8,
                    reinterpret_cast<sl::CommandBuffer*>(expectedCommands)) == sl::Result::eErrorInvalidParameter &&
                slCalls == 2, "T20_TRUNCATION_PRESERVES_ORIGINAL_EVALUATE");
        if (enabled)
        {
            const auto& event = Observed().events[3];
            Require(event.inputCount == 8 && event.inputEntriesObserved == 6 && event.resourceCount == 0,
                    "T20_STREAMLINE_INPUT_SCAN_CAP");
            UnknownFacts(event);
        }
        expectedSlInputs = inputs;
        expectedSlInputCount = 1;
    }
}
void Entry()
{
    DlssNr_Dx12 owner;
    Require(!Enabled(), "T20_OFF_BY_DEFAULT");
    Config::Instance()->DlssNrEnabled.value = false;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    Require(!Enabled() && DlssNr::NgxDiagnostics::submissions == 0, "T20_DISABLED_ENTRY_OFF");
    Config::Instance()->DlssNrEnabled.value = true;
    focused = false;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    Require(!Enabled(), "T20_UNFOCUSED_ENTRY_OFF");
    focused = true;
    DlssNr::NgxDiagnostics::submittedResult = DlssNr::NgxDiagnostics::MfgQueueResult::SubmissionFailed;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    Require(!Enabled(), "T20_FAILED_QUEUE_NO_SESSION");
    keyF8 = false;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    DlssNr::NgxDiagnostics::submittedResult = DlssNr::NgxDiagnostics::MfgQueueResult::Submitted;
    keyF9 = true;
    Pixels colour;
    owner.DiagnosePipeline(0, nullptr, nullptr, PixelResource(colour), 0, false, false);
    Require(Enabled() && Observed().session == 2 && Observed().owner == Value(&owner), "T20_EXISTING_ENTRY_ACTIVATES");
    Require(Observed().events[0].resources[0].value == Value(PixelResource(colour)), "T20_ENTRY_ACTUAL_NR_COLOUR");
    owner.DiagnosePipeline(0, nullptr, nullptr, PixelResource(colour), 0, false, false);
    Require(DlssNr::NgxDiagnostics::submissions == 2, "T20_HELD_KEY_NO_NEW_SESSION");
    keyF9 = false;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    keyF8 = true;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    Require(DlssNr::NgxDiagnostics::submissions == 2 && owner._state->pipelineCaptureRemaining == 0,
            "T20_EXISTING_TWO_RUN_LIMIT_NO_CAPTURE");
    Config::Instance()->DlssNrEnabled.value = false;
    owner.DiagnosePipeline(0, nullptr, nullptr, nullptr, 0, false, false);
    Require(!Enabled(), "T20_DISABLE_STOPS_OBSERVATION");
}
int main(int argc, char** argv)
{
    if (argc != 3) return 2;
    Util::fixtureRoot = argv[2];
    const std::string name = argv[1];
    if (name == "forwarding") Forwarding();
    else if (name == "raw") Raw();
    else if (name == "association") Association();
    else if (name == "bounds") Bounds();
    else if (name == "entry") Entry();
    else if (name == "streamline") Streamline();
    else return 2;
    Dump(argv[1]);
}
