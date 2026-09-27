#pragma once
// ============================================================================
// DlssNr_NativeProbe.h - admission and producer selection for the R10
// NR_XEFG_NATIVE_GATE diagnostic (OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp).
//
// WHAT THIS IS
//   The two pure policies the R10 probe block uses, separated from the D3D12/Streamline
//   body so a behavioral test can drive the production logic itself
//   (tests/nr_native_probe_budget_smoke.cpp):
//     - NativeProbeAdmission    - the strict process-lifetime probe budget;
//     - NativeProbeProducerSelection - which retained producer queues one admitted
//       probe measures.
//   No D3D12, no COM, no clock. Production holds one NativeProbeAdmission static in
//   State::PendingFinishedCapture and one NativeProbeProducerSelection per admitted probe.
//
// WHY THE BUDGET EXISTS (R10 independent review, H1)
//   The v3 block was gated by `edge || seq < 8`, where `edge` is the R9 classification
//   transition. A transition is not "a previously unseen classification": a title that
//   alternates classification words (review examples: 6/5 when GetDevice alternately fails
//   and succeeds, 6/14 when the canonical identity alternately matches) makes `edge` true on
//   every refusal, so the v3 block ran unbounded - the review measured 1000 block entries on
//   a 1000-sample alternating sequence while a stable classification admitted 8. Each entry
//   runs up to eight COM queries and three log emissions while the NR owner and state locks
//   are held, so "bounded diagnostic cost" was false.
//
// THE INVARIANT
//   P1 (saturating): admitted() never exceeds kBudget for the lifetime of the object, for any
//      input or interleaving. The counter saturates; it cannot wrap.
//   P2 (no bypass): eligibility - the caller's transition/early window - only chooses WHICH
//      refusals consume the remaining budget. It can never admit a call the budget refused,
//      and once Admit() has returned false it returns false forever for that object.
//   P3 (single-consumer): each successful Admit() accounts for exactly one probe block, so the
//      number of admitted blocks is the number of Admit() calls that returned true.
//   P4 (selection): one probe measures at most kCap distinct non-null producer pointers, in
//      scan order; null and duplicate pointers are never selected.
//
// THREADING
//   Admit() is written for the production call site, which holds the NR owner mutex
//   (DlssNr_Dx12.cpp::XeFGPendingCapture) and the owner state mutex, so calls are serialized
//   there. It is nevertheless safe under concurrent calls: the saturating compare-exchange
//   makes P1 hold without relying on that lock. NativeProbeProducerSelection is a stack
//   object owned by the single probe block; it is not shared.
// ============================================================================
#include <atomic>
#include <cstdint>

namespace DlssNr
{
// Strict, non-wrapping, process-lifetime admission for the R10 probe block.
class NativeProbeAdmission
{
  public:
    static constexpr uint32_t kBudget = 8;

    // Returns true at most kBudget times over this object's lifetime. Once exhausted it returns
    // false for every later call, whatever the caller's eligibility says (P1, P2).
    bool Admit()
    {
        uint32_t current = Admitted_.load(std::memory_order_relaxed);
        while (current < kBudget)
        {
            // current < kBudget, so the stored value is at most kBudget: the counter saturates
            // and can never wrap back into the admissible range.
            if (Admitted_.compare_exchange_weak(current, current + 1, std::memory_order_relaxed))
                return true;
        }
        return false;
    }

    // Number of admitted probes so far (0..kBudget). Also the 1-based index of the newest one.
    uint32_t Admitted() const { return Admitted_.load(std::memory_order_relaxed); }

    static constexpr uint32_t Budget() { return kBudget; }

    // The v3 expression this type replaces, kept only so the test can show that the budget is
    // what bounds the block (and that a regression to v3 fails the test). Production never calls
    // it.
    static bool LegacyV3Admits(bool transition, uint32_t sample)
    {
        return transition || sample < kBudget;
    }

  private:
    std::atomic<uint32_t> Admitted_ { 0 };
};

// The producer queue pointers one admitted probe measures: at most kCap distinct non-null
// pointers, in scan order.
class NativeProbeProducerSelection
{
  public:
    static constexpr unsigned kCap = 2;

    // Returns true when `producer` was newly selected. False for a null pointer, a pointer
    // already selected, or a full selection.
    bool Consider(const void* producer)
    {
        if (producer == nullptr || Count_ >= kCap)
            return false;
        for (unsigned i = 0; i < Count_; ++i)
            if (Selected_[i] == producer)
                return false;
        Selected_[Count_++] = producer;
        return true;
    }

    unsigned Count() const { return Count_; }
    const void* At(unsigned index) const { return index < Count_ ? Selected_[index] : nullptr; }
    static constexpr unsigned Cap() { return kCap; }

  private:
    const void* Selected_[kCap] = {};
    unsigned Count_ = 0;
};
} // namespace DlssNr
