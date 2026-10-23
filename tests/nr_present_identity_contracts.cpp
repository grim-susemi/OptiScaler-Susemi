#include "../OptiScaler/dlssnr/DlssNr_FinishedConsumer.h"
#include "../OptiScaler/dlssnr/DlssNr_FinishedReady.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_Guides.h"
#include "../OptiScaler/shaders/dlssnr/DlssNr_SeamClock.h"
#include <array>
#include <cstdio>
#include <stdexcept>

static unsigned checks = 0;
static void Check(bool condition, const char* label)
{
    ++checks;
    if (!condition) throw std::runtime_error(label);
}
int main() try
{
    int owner = 0, consumer = 0, foreign = 0;
    const DlssNr::FinishedIdentity known { &owner, &consumer, 1, 7 };
    Check(known.Known(), "known consumer");
    for (uint64_t generation = 0; generation != 3; ++generation)
        for (const void* candidate : { static_cast<void*>(nullptr), static_cast<void*>(&consumer), static_cast<void*>(&foreign) })
        {
            const DlssNr::FinishedIdentity other { &owner, candidate, generation, 99 };
            Check(known.SameConsumer(other) == (candidate == &consumer && generation == 1),
                  "consumer and generation, not application/display extent");
        }
    DlssNr::LateSelection absent;
    Check(!absent.have && !absent.Usable(), "absent capture");
    for (unsigned mask = 0; mask != 16; ++mask)
    {
        const bool pending = (mask & 1) != 0, pinned = (mask & 2) != 0;
        const bool submitted = (mask & 4) != 0, promise = (mask & 8) != 0;
        const bool usable = pending && !pinned && submitted && !promise;
        Check(DlssNr::LateCaptureSelectable(pending, pinned, submitted, promise) == usable,
              "actual enqueue, never promise");
        for (bool reversed : { false, true })
        {
            DlssNr::LateSelection newest;
            if (reversed) { newest.Consider(2, usable); newest.Consider(1, true); }
            else { newest.Consider(1, true); newest.Consider(2, usable); }
            Check(newest.serial == 2 && newest.Usable() == usable, "newest before usability");
            Check(DlssNr::LateCompositionRefuses(newest) == !usable, "unusable newest refuses");
            Check(!DlssNr::LateCompositionMayUseHeld(newest), "unusable is not absent");
        }
    }
    for (bool sameQueue : { false, true })
        for (uint64_t required : { 0ull, 1ull, 9ull })
            for (uint64_t completed : { 0ull, 1ull, 8ull, 9ull, UINT64_MAX })
                Check(DlssNr::FinishedInputReady(sameQueue, completed, required) ==
                      (completed != UINT64_MAX && (sameQueue || completed >= required)),
                      "same queue or completed fence; removal refuses");
    auto guides = DlssNr::ResolveGuideRegions({8,8}, {8,8}, {8,8}, {8,8}, true, 8, 0, 0, 0);
    Check(!guides.depth.valid() && guides.motion.valid(), "invalid real depth region");
    guides = DlssNr::ResolveGuideRegions({8,8}, {8,8}, {8,8}, {8,8}, true, 0, 0, 0, 8);
    Check(guides.depth.valid() && !guides.motion.valid(), "invalid real motion region");
    DlssNrSeamClock applications;
    const auto first = applications.AtSeam(true, false, 0);
    Check(applications.AtSeam(false, false, UINT64_MAX) == first, "post seam retains application");
    Check(applications.AtSeam(true, false, 0) == first + 1, "new application without display clock");
    uint64_t ready = 0, done = 0, promised = 0;
    bool pending = false, submitted = false, owned = false, promise = false;
    DlssNr::ArmLateSlot(ready, done, pending, submitted, owned);
    DlssNr::RecordLateSlotPromise(ready, promised, promise);
    Check(owned && !submitted && !DlssNr::LateCaptureSelectable(pending, false, submitted, promise), "promise stays owned");
    DlssNr::ClearLateSlotSelection(pending);
    Check(owned && promise && done == 0, "presentation refusal retains ownership");
    DlssNr::EnqueueLateSlotPromise(promised, done, submitted, owned, promise);
    Check(!owned && submitted && !promise && done == promised, "actual submission resolves captured token");
    Check(!DlssNr::LateSlotReusable(false, false, false, false, true, done, UINT64_MAX), "removed slot not reusable");
    std::printf("T4_IDENTITY_CONTRACT_PASS checks=%u gpu=none\n", checks);
    return 0;
}
catch (const std::exception& error) { std::printf("T4_IDENTITY_CONTRACT_FAIL=%s\n", error.what()); return 1; }
