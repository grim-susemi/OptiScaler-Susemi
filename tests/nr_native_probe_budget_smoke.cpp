// ============================================================================
// nr_native_probe_budget_smoke.cpp - the R10 NR_XEFG_NATIVE_GATE admission policy.
//
// LIVE EVIDENCE
//   .omo/evidence/nr-xefg-device-gate-r10-code-review.md (independent review) H1: the v3
//   condition `edge || seq < 8` admits every refusal when the classification word alternates
//   (measured: 1000 block entries on a 1000-sample sequence, 8 on a stable one), so the promised
//   bounded probe cost was false and every admitted block ran up to eight COM queries plus three
//   log emissions under the NR owner and state locks.
//
// WHAT THIS DRIVES
//   The production admission and selection policies themselves
//   (shaders/dlssnr/DlssNr_NativeProbe.h) - the same header DlssNr_Dx12.cpp includes - not a
//   copied predicate:
//     - NativeProbeAdmission::Admit()             (the R10 probe latch)
//     - NativeProbeAdmission::Admitted()/Budget()
//     - NativeProbeProducerSelection::Consider()  (which producers one probe measures)
//
// WHAT IS PINNED
//   P1 saturation + P2 no-bypass: alternating classifications (review examples 6/5 and 6/14)
//     admit exactly the budget and no more; a stable classification admits the budget; exhaustion
//     is permanent and the counter never wraps.
//   P4 selection: null and duplicate producers are never selected, the selection is scan-ordered
//     and capped at kCap.
//
// FAILURE-PROVABILITY
//   NR_NATIVE_PROBE_SEED_EDGE_ONLY restores the v3 expression (eligibility alone admits, no
//   latch). The two alternating-classification cases must then FAIL: the runner requires it.
// ============================================================================
#include "../OptiScaler/shaders/dlssnr/DlssNr_NativeProbe.h"

#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace
{
int checks = 0;

void Check(bool condition, const std::string& what)
{
    ++checks;
    if (!condition)
        throw std::runtime_error(what);
}

constexpr uint32_t kBudget = DlssNr::NativeProbeAdmission::kBudget;
constexpr uint32_t kSamples = 1000;

// The review's alternating classification words: 6 = successful GetDevice with late.device present
// and a different canonical identity; 5 = failed GetDevice with late.device present; 14 = 6 plus an
// equal canonical identity. INPUT DATA for the admission policy - production only ever passes the
// R9 transition flag and the R9 sequence number into the latch.
uint32_t SignatureOf(uint32_t first, uint32_t second, uint32_t sample)
{
    return (sample % 2 == 0) ? first : second;
}

// Production v4: the R9/R10 eligibility window (`edge || seq < 8`) chooses candidate samples; the
// strict latch is what admits. Returns the number of admitted probe blocks.
uint32_t ProductionAdmissions(uint32_t first, uint32_t second, uint32_t samples)
{
    DlssNr::NativeProbeAdmission admission;
    uint32_t previous = 0;
    bool havePrevious = false;
    uint32_t admitted = 0;
    for (uint32_t sample = 0; sample < samples; ++sample)
    {
        const uint32_t signature = SignatureOf(first, second, sample);
        const bool transition = havePrevious && previous != signature;
        havePrevious = true;
        previous = signature;
        const bool eligible = transition || sample < kBudget;
#if defined(NR_NATIVE_PROBE_SEED_EDGE_ONLY)
        (void) admission;
        const bool admittedNow = eligible; // v3/H1 semantics: no latch (must break the cases)
#else
        const bool admittedNow = eligible && admission.Admit();
#endif
        admitted += admittedNow ? 1u : 0u;
    }
    return admitted;
}

// The v3 expression alone, so a case can show the latch is what bounds the block. Production never
// calls it.
uint32_t LegacyV3Admissions(uint32_t first, uint32_t second, uint32_t samples)
{
    uint32_t previous = 0;
    bool havePrevious = false;
    uint32_t admitted = 0;
    for (uint32_t sample = 0; sample < samples; ++sample)
    {
        const uint32_t signature = SignatureOf(first, second, sample);
        const bool transition = havePrevious && previous != signature;
        havePrevious = true;
        previous = signature;
        if (DlssNr::NativeProbeAdmission::LegacyV3Admits(transition, sample))
            ++admitted;
    }
    return admitted;
}

void StableClassificationAdmitsOnlyTheBudget()
{
    Check(ProductionAdmissions(6, 6, kSamples) == kBudget,
          "a stable classification did not admit exactly the budget");
    Check(LegacyV3Admissions(6, 6, kSamples) == kBudget,
          "the legacy expression did not also admit the budget on a stable classification");
}

void AlternatingSixFiveCannotBypassExhaustion()
{
    Check(LegacyV3Admissions(6, 5, kSamples) == kSamples,
          "the legacy expression did not admit every alternating 6/5 sample (the H1 defect)");
    Check(ProductionAdmissions(6, 5, kSamples) == kBudget,
          "alternating 6/5 bypassed the R10 probe budget");
}

void AlternatingSixFourteenCannotBypassExhaustion()
{
    Check(LegacyV3Admissions(6, 14, kSamples) == kSamples,
          "the legacy expression did not admit every alternating 6/14 sample (the H1 defect)");
    Check(ProductionAdmissions(6, 14, kSamples) == kBudget,
          "alternating 6/14 bypassed the R10 probe budget");
}

void ExhaustionIsPermanentAndNonWrapping()
{
    DlssNr::NativeProbeAdmission admission;
    uint32_t admitted = 0;
    for (uint32_t i = 0; i < kBudget; ++i)
        if (admission.Admit())
            ++admitted;
    Check(admitted == kBudget, "the latch did not admit the whole budget");
    Check(admission.Admitted() == kBudget, "the admitted counter is not the budget after admission");

    uint32_t postExhaustionAdmissions = 0;
    for (uint32_t i = 0; i < 100000; ++i)
        if (admission.Admit())
            ++postExhaustionAdmissions;
    Check(postExhaustionAdmissions == 0, "the latch admitted a probe after exhaustion");
    Check(admission.Admitted() == kBudget, "the admitted counter moved after exhaustion");

    DlssNr::NativeProbeAdmission fresh;
    Check(fresh.Admit() && fresh.Admitted() == 1,
          "a fresh process-lifetime latch admitted nothing");
}

void NullAndDuplicateProducersAreNotSelected()
{
    DlssNr::NativeProbeProducerSelection selection;
    Check(!selection.Consider(nullptr), "a null producer was selected");
    Check(selection.Count() == 0, "a null producer entered the selection");

    const void* const queue = (const void*) 0x1000;
    Check(selection.Consider(queue), "the first real producer was not selected");
    Check(!selection.Consider(queue), "a duplicate producer was selected twice");
    Check(selection.Count() == 1, "the duplicate changed the selection count");
    Check(selection.At(0) == queue, "the selection lost the selected pointer");
}

void ProducerSelectionIsCappedAndOrderPreserving()
{
    DlssNr::NativeProbeProducerSelection selection;
    const void* const slot0 = (const void*) 0x2000;
    const void* const slot1 = (const void*) 0x3000;
    const void* const slot2 = (const void*) 0x4000;
    const void* const late = (const void*) 0x5000;

    Check(selection.Consider(slot0), "slot0 was not selected");
    Check(!selection.Consider(nullptr), "a null slot was selected");
    Check(selection.Consider(slot1), "slot1 was not selected");
    Check(!selection.Consider(slot2), "the selection exceeded its cap");
    Check(!selection.Consider(late), "late.submit was selected after the cap");
    Check(selection.Count() == DlssNr::NativeProbeProducerSelection::kCap,
          "the selection count is not the cap");
    Check(selection.At(0) == slot0 && selection.At(1) == slot1,
          "the selection is not scan-ordered");
    Check(selection.At(2) == nullptr, "reading past the selection returned a pointer");

    DlssNr::NativeProbeProducerSelection dedup;
    Check(dedup.Consider(slot0) && dedup.Consider(late),
          "two distinct producers were not selected");
    Check(!dedup.Consider(slot0), "a duplicate producer consumed a second place");
    Check(dedup.Count() == 2, "the duplicate changed the capped selection");
}
} // namespace

int main()
{
    struct Case
    {
        const char* name;
        void (*run)();
    };
    const Case cases[] = {
        { "stable_classification_admits_only_the_budget", StableClassificationAdmitsOnlyTheBudget },
        { "alternating_6_5_cannot_bypass_exhaustion", AlternatingSixFiveCannotBypassExhaustion },
        { "alternating_6_14_cannot_bypass_exhaustion", AlternatingSixFourteenCannotBypassExhaustion },
        { "exhaustion_is_permanent_and_non_wrapping", ExhaustionIsPermanentAndNonWrapping },
        { "null_and_duplicate_producers_are_not_selected", NullAndDuplicateProducersAreNotSelected },
        { "producer_selection_is_capped_and_order_preserving", ProducerSelectionIsCappedAndOrderPreserving },
    };

    std::printf("NR_NATIVE_PROBE_BUDGET production=shaders/dlssnr/DlssNr_NativeProbe.h budget=%u cases=%u "
                "seed_edge_only=%d\n",
                (unsigned) kBudget, (unsigned) (sizeof(cases) / sizeof(cases[0])),
#if defined(NR_NATIVE_PROBE_SEED_EDGE_ONLY)
                1
#else
                0
#endif
    );
    unsigned failed = 0;
    for (const Case& test : cases)
    {
        checks = 0;
        try
        {
            test.run();
            if (checks == 0)
                throw std::runtime_error("scenario exercised no assertions");
            std::printf("CASE %-58s PASS (%d checks)\n", test.name, checks);
        }
        catch (const std::exception& error)
        {
            ++failed;
            std::printf("CASE %-58s FAIL %s\n", test.name, error.what());
        }
    }
    std::printf("NR_NATIVE_PROBE_BUDGET cases=%u failed=%u\n",
                (unsigned) (sizeof(cases) / sizeof(cases[0])), failed);
    return failed == 0 ? 0 : 1;
}
