// ============================================================================
// nr_promise_hook_order_smoke.cpp - production-connected submission ordering.
//
// The runner extracts the body of ResTrack_Dx12's ExecuteCommandLists hook
// (OptiScaler/resource_tracking/ResTrack_dx12.cpp, `hkNrExecuteCommandLists`)
// verbatim into promise_hook_order.inc; this smoke compiles that production body
// with mocks for the original call and the two NR notifications.
//
// It proves the ORDERING R1 depends on: the promise pass runs BEFORE the game's real
// ExecuteCommandLists, and the resolution pass runs after it. Nothing here is a mirror of
// the hook - the hook body itself is the production text.
//
// NARROW GUARANTEE (do not overclaim): both NR notifications are mocks that only append a
// string, and the call passes null queue/lists with count 0. This test therefore cannot
// detect a wrong/empty batch, wrong queue or list arguments, incorrect token resolution,
// a signal failure, or a wrong slot being chosen - those are covered (at predicate level)
// by tests/nr_late_slot_pool_smoke.cpp, and at device level only by a live run.
// ============================================================================
#include "../OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h"

#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using UINT = unsigned int;
struct ID3D12CommandQueue
{
};
struct ID3D12CommandList
{
};
#define STDMETHODCALLTYPE

namespace
{
std::vector<std::string> order;

void FakeExecuteCommandLists(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*)
{
    order.push_back("execute");
}

using PFN_ExecuteCommandLists = void (*)(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);
PFN_ExecuteCommandLists o_ExecuteCommandLists = FakeExecuteCommandLists;
} // namespace

namespace DlssNr
{
void FinishedPicturePromise(LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*)
{
    order.push_back("promise");
}
void FinishedPictureSubmitted(LatePromiseBatch&, ID3D12CommandQueue*, UINT, ID3D12CommandList* const*)
{
    order.push_back("submitted");
}
} // namespace DlssNr

#include "promise_hook_order.inc"

int main()
{
    try
    {
        order.clear();
        hkNrExecuteCommandLists(nullptr, 0, nullptr);
        const std::vector<std::string> expected { "promise", "execute", "submitted" };
        if (order != expected)
        {
            std::string seen = "order=";
            for (const auto& step : order)
                seen += step + " ";
            std::printf("FAIL %s (expected promise execute submitted)\n", seen.c_str());
            return 1;
        }
        std::puts("PASS production ExecuteCommandLists hook: promise before the real submission, "
                  "resolution after it");
        return 0;
    }
    catch (const std::exception& error)
    {
        std::printf("FAIL %s\n", error.what());
        return 1;
    }
}
