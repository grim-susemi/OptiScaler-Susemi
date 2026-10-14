#include <d3d12.h>
#include <shaders/dlssnr/DlssNr_LateSlot.h>
#include <algorithm>
#include <atomic>
#include <barrier>
#include <climits>
#include <cstdio>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
static void require(bool value, const char* id) { if (!value) throw std::runtime_error(id); }
struct Counts
{
    std::atomic_uint prepared { 0 }, resolved { 0 }, originalPromises { 0 }, originalSubmits { 0 };
};
struct ControlledSubmission
{
    std::shared_ptr<Counts> counts = std::make_shared<Counts>();
    bool enabled = false;
    std::function<void()> PrepareCapture(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*)
    {
        if (!enabled) return {};
        ++counts->prepared;
        return [owned = counts, once = false]() mutable { if (!once) { once = true; ++owned->resolved; } };
    }
};
struct Service
{
    std::recursive_mutex mutex;
    ControlledSubmission lifetime;
    ID3D12CommandQueue* expectedQueue = nullptr;
    ID3D12CommandList* const* expectedLists = nullptr;
    UINT expectedCount = 0;
    void Check(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists)
    { require(queue == expectedQueue && count == expectedCount && lists == expectedLists, "T21_ORIGINAL_ARGUMENTS"); }
    void FinishedPicturePromised(DlssNr::LatePromiseBatch& batch, const void* owner, ID3D12CommandQueue* queue,
                                UINT count, ID3D12CommandList* const* lists)
    {
        Check(queue, count, lists); ++lifetime.counts->originalPromises;
        batch.push_back({ owner, 7, 11, 13, queue, lists[0] });
    }
    void FinishedPictureSubmitted(DlssNr::LatePromiseBatch& batch, const void* owner, ID3D12CommandQueue* queue,
                                 UINT count, ID3D12CommandList* const* lists)
    {
        Check(queue, count, lists); ++lifetime.counts->originalSubmits;
        for (const auto& entry : batch) if (entry.owner == owner)
            require(!entry.captureSubmitted && entry.slot == 7 && entry.serial == 11 && entry.token == 13 &&
                    entry.queue == queue && entry.producer == lists[0], "T21_SENTINEL_BEFORE_ORIGINAL_CONSUMER");
    }
};
class DlssNr_Dx12
{
  public:
    std::unique_ptr<Service> _state = std::make_unique<Service>();
    void PromiseFinishedCommands(DlssNr::LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
    void SubmitFinishedCommands(DlssNr::LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
};
@PRODUCTION_BODIES@
static void Configure(DlssNr_Dx12& owner, ID3D12CommandQueue* queue, ID3D12CommandList* const* lists, bool enabled)
{
    owner._state->expectedQueue = queue; owner._state->expectedLists = lists; owner._state->expectedCount = 2;
    owner._state->lifetime.enabled = enabled;
}
int main() try
{
    auto* queue = reinterpret_cast<ID3D12CommandQueue*>(uintptr_t(0x100));
    ID3D12CommandList* lists[] { reinterpret_cast<ID3D12CommandList*>(uintptr_t(0x200)),
                                reinterpret_cast<ID3D12CommandList*>(uintptr_t(0x300)) };
    DlssNr_Dx12 off; Configure(off, queue, lists, false);
    DlssNr::LatePromiseBatch offBatch;
    off.PromiseFinishedCommands(offBatch, queue, 2, lists);
    off.SubmitFinishedCommands(offBatch, queue, 2, lists);
    require(offBatch.size() == 1 && off._state->lifetime.counts->prepared == 0 &&
            off._state->lifetime.counts->originalPromises == 1 && off._state->lifetime.counts->originalSubmits == 1,
            "T21_DEFAULT_OFF_ORIGINAL_ONCE");
    DlssNr_Dx12 a, b; Configure(a, queue, lists, true); Configure(b, queue, lists, true);
    DlssNr::LatePromiseBatch batch;
    a.PromiseFinishedCommands(batch, queue, 2, lists); b.PromiseFinishedCommands(batch, queue, 2, lists);
    require(batch.size() == 4 && !a._state->lifetime.counts->resolved && !b._state->lifetime.counts->resolved,
            "T21_BATCH_PREEXEC_NO_RESOLUTION");
    a.SubmitFinishedCommands(batch, queue, 2, lists);
    require(batch.size() == 3 && batch[0].owner == &a && batch[0].slot == 7 &&
            batch[1].owner == &b && batch[1].slot == UINT_MAX && batch[1].captureSubmitted &&
            batch[2].owner == &b && batch[2].slot == 7 && a._state->lifetime.counts->resolved == 1 &&
            b._state->lifetime.counts->resolved == 0, "T21_MULTIOWNER_ISOLATED_ORDER");
    b.SubmitFinishedCommands(batch, queue, 2, lists);
    require(batch.size() == 2 && batch[0].owner == &a && batch[1].owner == &b &&
            a._state->lifetime.counts->resolved == 1 && b._state->lifetime.counts->resolved == 1 &&
            a._state->lifetime.counts->originalSubmits == 1 && b._state->lifetime.counts->originalSubmits == 1,
            "T21_MULTIOWNER_EXACT_ONCE");
    DlssNr_Dx12 concurrent; Configure(concurrent, queue, lists, true);
    std::barrier start(8);
    std::atomic_uint failures { 0 };
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 8; ++i) threads.emplace_back([&] {
        try {
            DlssNr::LatePromiseBatch local;
            concurrent.PromiseFinishedCommands(local, queue, 2, lists);
            start.arrive_and_wait();
            concurrent.SubmitFinishedCommands(local, queue, 2, lists);
            require(local.size() == 1 && local[0].slot == 7, "T21_CONCURRENT_PER_CALL_BATCH");
        } catch (...) { ++failures; }
    });
    for (auto& thread : threads) thread.join();
    require(!failures && concurrent._state->lifetime.counts->prepared == 8 &&
            concurrent._state->lifetime.counts->resolved == 8 &&
            concurrent._state->lifetime.counts->originalPromises == 8 &&
            concurrent._state->lifetime.counts->originalSubmits == 8, "T21_CONCURRENT_EXACT_COUNTS");
    std::shared_ptr<Counts> retained;
    std::function<void()> closure;
    {
        DlssNr_Dx12 retiring; Configure(retiring, queue, lists, true);
        retained = retiring._state->lifetime.counts;
        DlssNr::LatePromiseBatch pending;
        retiring.PromiseFinishedCommands(pending, queue, 2, lists);
        closure = std::move(pending[0].captureSubmitted);
    }
    closure(); closure(); closure = {};
    require(retained->resolved == 1, "T21_BATCH_OWNED_CLOSURE_RETIREMENT");
    std::puts("PASS source-extracted capture wrappers: off/arguments/order/multiowner/concurrent/percall/ownedclosure; controlled submission service; GPU0");
    return 0;
}
catch (const std::exception& error) { std::fprintf(stderr, "FAIL %s\n", error.what()); return 1; }
