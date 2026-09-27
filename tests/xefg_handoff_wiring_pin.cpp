// tests/xefg_handoff_wiring_pin.cpp - production-route pin for the XeFG finished-picture NR handoff.
//
// SUSEMI T9 ADAPTATION of the reviewed upstream-main T6 pin: Sections A/C drive the ACTUAL
// Susemi decision headers (dlssnr/DlssNr_XeFGHandoff.h, dlssnr/DlssNr_FinishedConsumer.h,
// dlssnr/DlssNr_FinishedReady.h) with fixed contracts: duplicate/stale/unsubmitted/
// not-ready/cancelled/ambiguous inputs must refuse with their named reasons. Susemi has no
// DlssNr_QueueIdentity.h (UnwrapOrPreserveQueue/SameRecordedQueue): its cross-queue/device
// protection is the FinishedInputReady same-queue rule plus the LateContext::Acquire
// device-identity refusal (see Section F and docs/SUSEMI-SOURCE-PROVENANCE.md T9 mapping).
// Cross-queue incompleteness is pinned through the REAL FinishedInputReady helper with
// literal booleans (never re-derived): same-queue order suffices, cross-queue incomplete
// input refuses, UINT64_MAX completion never reads ready. Nothing is re-derived from
// the code under test: every expectation is a literal written below.
//   - Sections D-F read the ACTUAL production sources given on the command line
//     (default: the repo's OptiScaler/framegen/xefg/XeFG_Dx12.cpp,
//     OptiScaler/hooks/FG_Hooks.cpp and OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp) and
//     assert the wiring INSIDE the real function bodies: XeFG_Dx12::Present must publish
//     PublishFinishedConsumerState(consumes) before calling OwnedNrHandoff() under the same
//     consumes predicate, FGHooks::FGPresent must bypass the generic ApplyToFinishedPicture
//     on the owned route and report NR_XEFG_PRESENT, and LateContext must refuse a changed
//     device and admit captures only while the finished consumer is available.
//   - The runner (tests/run_xefg_production_route_smoke.ps1) re-runs this binary against
//     disposable copies with the call site removed (must fail PIN_XEFG_CALLSITE), the
//     bypass removed (must fail PIN_FG_BYPASS), and the Late device-identity refusal removed
//     (must fail PIN_LATE_DEVICE). A seed that exits 0 means this pin no longer detects
//     its defect.
//
// Usage: xefg_handoff_wiring_pin.exe [XeFG_Dx12.cpp] [FG_Hooks.cpp] [DlssNr_Dx12_Late.cpp]
// Exit codes: 0 = every pin held; 1 = a pin failed (PIN_* marker printed); 2 = environment broken.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#include <dlssnr/DlssNr_XeFGHandoff.h>
#include <dlssnr/DlssNr_FinishedConsumer.h>
#include <dlssnr/DlssNr_FinishedReady.h>
// NOTE (Susemi T9): no DlssNr_QueueIdentity.h in this tree; see file header.

namespace
{
int g_failures = 0;

void Pin(bool held, const char* marker, const char* detail)
{
    if (held)
        return;
    ++g_failures;
    std::printf("%s: %s\n", marker, detail);
}

std::string ReadFile(const char* path, bool& ok)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
    {
        ok = false;
        return {};
    }
    std::ostringstream text;
    text << in.rdbuf();
    ok = true;
    return text.str();
}

// Extracts the body (without the outer braces) of the function whose definition starts at
// `signature`, e.g. "XeFG_Dx12::Present()". Strings, character literals and comments are
// skipped so braces inside them cannot corrupt the match. Empty when not found.
std::string FunctionBody(const std::string& source, const std::string& signature)
{
    const size_t at = source.find(signature);
    if (at == std::string::npos)
        return {};
    size_t open = source.find('{', at);
    if (open == std::string::npos)
        return {};
    size_t i = open + 1;
    int depth = 1;
    bool lineComment = false, blockComment = false, str = false, ch = false;
    for (; i < source.size(); ++i)
    {
        const char c = source[i];
        const char next = i + 1 < source.size() ? source[i + 1] : '\0';
        if (lineComment)
        {
            if (c == '\n')
                lineComment = false;
            continue;
        }
        if (blockComment)
        {
            if (c == '*' && next == '/')
            {
                blockComment = false;
                ++i;
            }
            continue;
        }
        if (str)
        {
            if (c == '\\')
                ++i;
            else if (c == '"')
                str = false;
            continue;
        }
        if (ch)
        {
            if (c == '\\')
                ++i;
            else if (c == '\'')
                ch = false;
            continue;
        }
        if (c == '/' && next == '/')
            lineComment = true;
        else if (c == '/' && next == '*')
            blockComment = true;
        else if (c == '"')
            str = true;
        else if (c == '\'')
            ch = true;
        else if (c == '{')
            ++depth;
        else if (c == '}')
        {
            if (--depth == 0)
                return source.substr(open + 1, i - open - 1);
        }
    }
    return {};
}
} // namespace

int main(int argc, char** argv)
{
    const char* xefgPath = argc > 1 ? argv[1] : "OptiScaler/framegen/xefg/XeFG_Dx12.cpp";
    const char* fgHooksPath = argc > 2 ? argv[2] : "OptiScaler/hooks/FG_Hooks.cpp";
    const char* latePath = argc > 3 ? argv[3] : "OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp";

    using DlssNr::XeFGHandoff::Identity;
    using DlssNr::XeFGHandoff::Outcome;
    using DlssNr::XeFGHandoff::SkipReason;
    using DlssNr::XeFGHandoff::Tracker;

    // A. Tracker decision core (actual header): fixed refuse/apply contracts.
    {
        Tracker tracker;
        tracker.Reset(1);
        const uint64_t serial = tracker.OpenInterval(7);
        tracker.Submitted(serial);
        tracker.Ready(serial);
        Identity id {};
        id.generation = 1;
        id.frameId = 7;
        const Outcome happy = tracker.Handoff(id);
        Pin(happy.applied && happy.reason == SkipReason::None && happy.slot == serial, "PIN_TRACKER_HAPPY",
            "open/submit/ready must apply and consume the interval serial");

        const Outcome duplicate = tracker.Handoff(id);
        Pin(!duplicate.applied && duplicate.reason == SkipReason::DuplicateFrame, "PIN_TRACKER_DUPLICATE",
            "second handoff of the same identity must refuse duplicate_frame");
    }
    {
        Tracker tracker;
        tracker.Reset(1);
        const uint64_t serial = tracker.OpenInterval(7);
        tracker.Submitted(serial);
        tracker.Ready(serial);
        tracker.Reset(2); // swapchain recreation / discontinuity: old generation is stale
        Identity stale {};
        stale.generation = 1;
        stale.frameId = 7;
        const Outcome outcome = tracker.Handoff(stale);
        Pin(!outcome.applied && outcome.reason == SkipReason::NoCurrentCapture, "PIN_TRACKER_STALE",
            "old-generation handoff after reset must refuse no_current_capture and consume nothing");
    }
    {
        Tracker tracker;
        tracker.Reset(1);
        tracker.OpenInterval(9); // never submitted
        Identity id {};
        id.generation = 1;
        id.frameId = 9;
        const Outcome outcome = tracker.Handoff(id);
        Pin(!outcome.applied && outcome.reason == SkipReason::ProducerNotSubmitted, "PIN_TRACKER_UNSUBMITTED",
            "unsubmitted capture must refuse producer_not_submitted, never wait");
    }
    {
        Tracker tracker;
        tracker.Reset(1);
        const uint64_t serial = tracker.OpenInterval(9);
        tracker.Submitted(serial); // submitted but cross-queue input not fenced complete
        Identity id {};
        id.generation = 1;
        id.frameId = 9;
        const Outcome outcome = tracker.Handoff(id);
        Pin(!outcome.applied && outcome.reason == SkipReason::ProducerNotReady, "PIN_TRACKER_NOTREADY",
            "submitted-but-not-ready capture must refuse producer_not_ready, never wait");
    }
    {
        Tracker tracker;
        tracker.Reset(1);
        const uint64_t serial = tracker.OpenInterval(11);
        tracker.Cancelled(serial);
        Identity id {};
        id.generation = 1;
        id.frameId = 11;
        const Outcome outcome = tracker.Handoff(id);
        Pin(!outcome.applied && outcome.reason == SkipReason::NoCurrentCapture, "PIN_TRACKER_CANCELLED",
            "cancelled capture must refuse no_current_capture");
    }
    {
        Tracker tracker;
        tracker.Reset(1);
        tracker.OpenInterval(13);
        tracker.OpenInterval(13); // pipelined duplicate: never guessed
        Identity id {};
        id.generation = 1;
        id.frameId = 13;
        const Outcome outcome = tracker.Handoff(id);
        Pin(!outcome.applied && outcome.reason == SkipReason::AmbiguousCapture, "PIN_TRACKER_AMBIGUOUS",
            "pipelined frames must refuse ambiguous_capture");
    }

    // B. Producer readiness (actual Susemi header DlssNr_FinishedReady.h).
    // Susemi has no DlssNr_QueueIdentity.h: cross-queue protection is this same-queue
    // rule (cross-queue input must already be complete; a removed-device UINT64_MAX
    // completion never reads ready) plus the LateContext device-identity refusal
    // pinned in Section F. Literals below, never re-derived.
    Pin(DlssNr::FinishedInputReady(true, 5, 10), "PIN_READY_SAME_QUEUE",
        "same-queue submission order must be sufficient");
    Pin(!DlssNr::FinishedInputReady(false, 5, 10), "PIN_READY_CROSS_QUEUE_PENDING",
        "cross-queue incomplete input must not be ready (skip, never wait)");
    Pin(DlssNr::FinishedInputReady(false, 10, 10), "PIN_READY_CROSS_QUEUE_DONE",
        "cross-queue completed input must be ready");
    Pin(!DlssNr::FinishedInputReady(false, UINT64_MAX, 1), "PIN_READY_REMOVED_DEVICE",
        "UINT64_MAX completion must never be ready");
    Pin(!DlssNr::FinishedInputReady(true, UINT64_MAX, 1), "PIN_READY_REMOVED_DEVICE_SAME_QUEUE",
        "UINT64_MAX completion must never be ready even same-queue");

    // C. Consumer publication policy (actual header): only the registered owner publishes, an
    // aborted release publishes nothing, and the default route admits captures.
    {
        const void* owner = reinterpret_cast<const void*>(0x1234);
        const void* other = reinterpret_cast<const void*>(0x5678);
        Pin(DlssNr::FinishedConsumerMayPublish(owner, owner), "PIN_CONSUMER_CLAIM_OWNER",
            "registered owner must be allowed to publish");
        Pin(!DlssNr::FinishedConsumerMayPublish(other, owner), "PIN_CONSUMER_CLAIM_NONOWNER",
            "non-owner must never publish");
        Pin(DlssNr::FinishedConsumerMayPublish(owner, nullptr), "PIN_CONSUMER_CLAIM_UNREGISTERED",
            "claim allowed while no owner is registered");
        Pin(DlssNr::FinishedConsumerIsOwner(owner, owner), "PIN_CONSUMER_IS_OWNER",
            "owner identity must hold");
        Pin(!DlssNr::FinishedConsumerIsOwner(other, owner), "PIN_CONSUMER_IS_NOT_OWNER",
            "stale instance must not own the consumer state");
        Pin(!DlssNr::FinishedConsumerIsOwner(nullptr, owner), "PIN_CONSUMER_NULL_NEVER_OWNS",
            "null instance must never own the consumer state");
        Pin(DlssNr::ReleasePublishesGeneric(true, false), "PIN_CONSUMER_RELEASE_PUBLISHES",
            "completed owner release must return the route to generic");
        Pin(!DlssNr::ReleasePublishesGeneric(true, true), "PIN_CONSUMER_RELEASE_ABORTED",
            "aborted reentrant release must publish nothing");
        Pin(!DlssNr::ReleasePublishesGeneric(false, false), "PIN_CONSUMER_RELEASE_NONOWNER",
            "non-owner release must publish nothing");
        Pin(DlssNr::FinishedConsumerAdmitsCapture(), "PIN_CONSUMER_DEFAULT_ADMITS",
            "default generic route must admit captures");
    }

    // D. Actual XeFG_Dx12::Present wiring, function-bounded.
    {
        bool ok = false;
        const std::string source = ReadFile(xefgPath, ok);
        if (!ok)
        {
            std::printf("PIN_ENV: cannot read %s\n", xefgPath);
            return 2;
        }
        const std::string present = FunctionBody(source, "XeFG_Dx12::Present()");
        if (present.empty())
        {
            std::printf("PIN_ENV: XeFG_Dx12::Present body not found in %s\n", xefgPath);
            return 2;
        }
        const size_t publish = present.find("PublishFinishedConsumerState(consumes)");
        const size_t handoff = present.find("OwnedNrHandoff()");
        const size_t gate = present.find("if (consumes)");
        Pin(publish != std::string::npos, "PIN_XEFG_CALLSITE",
            "Present must publish PublishFinishedConsumerState(consumes)");
        Pin(handoff != std::string::npos, "PIN_XEFG_CALLSITE",
            "Present must call OwnedNrHandoff()");
        Pin(publish != std::string::npos && handoff != std::string::npos && publish < handoff,
            "PIN_XEFG_CALLSITE", "publication must precede the handoff call");
        Pin(gate != std::string::npos, "PIN_XEFG_CALLSITE",
            "OwnedNrHandoff must run under the consumes predicate");
        // Susemi Present derives consumes from Dispatch()/IsActive()/IsPaused() results held in
        // locals (dispatched/active/paused); all three sources must be present in the body.
        const bool derivation = present.find("Dispatch()") != std::string::npos &&
            present.find("IsActive()") != std::string::npos && present.find("IsPaused()") != std::string::npos &&
            present.find("dispatched && active && !paused") != std::string::npos;
        Pin(derivation, "PIN_XEFG_CALLSITE",
            "consumes must derive from dispatched, active and unpaused in Present");
    }

    // E. Actual FGHooks::FGPresent wiring, function-bounded: generic NR bypass + report.
    {
        bool ok = false;
        const std::string source = ReadFile(fgHooksPath, ok);
        if (!ok)
        {
            std::printf("PIN_ENV: cannot read %s\n", fgHooksPath);
            return 2;
        }
        const std::string fgPresent = FunctionBody(source, "FGHooks::FGPresent(");
        if (fgPresent.empty())
        {
            std::printf("PIN_ENV: FGHooks::FGPresent body not found in %s\n", fgHooksPath);
            return 2;
        }
        const size_t apply = fgPresent.find("ApplyToFinishedPicture(This, state.currentCommandQueue)");
        Pin(apply != std::string::npos, "PIN_FG_BYPASS", "generic ApplyToFinishedPicture call must exist");
        bool guarded = false;
        if (apply != std::string::npos)
        {
            const size_t window = apply >= 120 ? 120 : apply;
            guarded = fgPresent.substr(apply - window, window).find("!xefgOwnedHandoff") != std::string::npos;
        }
        Pin(guarded, "PIN_FG_BYPASS",
            "generic ApplyToFinishedPicture must be bypassed on the owned handoff route");
        Pin(fgPresent.find("XeFGHandoffSince") != std::string::npos, "PIN_FG_REPORT",
            "FGPresent must read the decided handoff record via XeFGHandoffSince");
        Pin(fgPresent.find("NR_XEFG_PRESENT") != std::string::npos, "PIN_FG_REPORT",
            "FGPresent must report NR_XEFG_PRESENT after the original proxy Present");
    }

    // F. Actual LateContext device/capture gates, function-bounded (Susemi device-identity
    // gate). LateContext::Acquire must refuse a changed graphics device (a foreign queue's
    // device never becomes this route's device), and both capture entry points must admit
    // captures only while the finished consumer is available (FinishedConsumerAdmitsCapture).
    {
        bool ok = false;
        const std::string source = ReadFile(latePath, ok);
        if (!ok)
        {
            std::printf("PIN_ENV: cannot read %s\n", latePath);
            return 2;
        }
        const std::string acquire = FunctionBody(source, "LateContext::Acquire(ID3D12GraphicsCommandList* cmd)");
        if (acquire.empty())
        {
            std::printf("PIN_ENV: LateContext::Acquire body not found in %s\n", latePath);
            return 2;
        }
        Pin(acquire.find("GetDevice") != std::string::npos &&
                acquire.find("if (device && device != currentDevice)") != std::string::npos,
            "PIN_LATE_DEVICE",
            "LateContext::Acquire must refuse a changed graphics device");
        const std::string capture = FunctionBody(source, "LateContext::Capture(ID3D12GraphicsCommandList* cmd");
        if (capture.empty())
        {
            std::printf("PIN_ENV: LateContext::Capture body not found in %s\n", latePath);
            return 2;
        }
        Pin(capture.find("FinishedConsumerAdmitsCapture()") != std::string::npos, "PIN_LATE_ADMIT",
            "LateContext::Capture must admit captures only while the consumer is available");
        const std::string residual =
            FunctionBody(source, "LateContext::CaptureResidual(ID3D12GraphicsCommandList* cmd");
        if (residual.empty())
        {
            std::printf("PIN_ENV: LateContext::CaptureResidual body not found in %s\n", latePath);
            return 2;
        }
        Pin(residual.find("FinishedConsumerAdmitsCapture()") != std::string::npos, "PIN_LATE_ADMIT",
            "LateContext::CaptureResidual must admit captures only while the consumer is available");
    }

    if (g_failures == 0)
        std::printf("XEFG production route pin: all pins held.\n");
    return g_failures == 0 ? 0 : 1;
}
