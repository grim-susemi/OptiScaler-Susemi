#pragma once
#include <nvsdk_ngx_defs.h>
#include <d3d12.h>
#include "DlssNr_MfgDiagnostics.h"
#include "DlssNr_MfgObserver.h"

namespace DlssNr::NgxDiagnostics
{
// Install before driver initialization; preserve the caller's original logging sink.
void Install(NVSDK_NGX_LoggingInfo& logging);
class Scope
{
  public:
    Scope();
    ~Scope();
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;
};
void RuntimeReport(ID3D12GraphicsCommandList* commands, ID3D12Device* device, const char* phase);
// Explicit ordinary-thread diagnostic entry. Off unless called; do not invoke in a
// render/Present callback. The adapter LUID is an existing value, never a new GPU probe.
MfgDiagnostics::Report MfgPreflight(LUID adapter);
struct MfgPreflightRequest
{
    LUID adapter {};
    std::filesystem::path directory;
    std::string label;
    unsigned run = 0;
    MfgUnlock::TemporalMethod configured = MfgUnlock::TemporalMethod::None;
    bool configuredAvailable = false;
    std::wstring driverDispatcherPath;
};
enum class MfgQueueResult { Idle, Submitted, ModuleReferenceUnavailable, SubmissionFailed };
MfgPreflightRequest CopyMfgRequest(LUID adapter, std::filesystem::path directory,
                                   std::string label, unsigned run);
MfgQueueResult EnqueueMfgPreflight(MfgPreflightRequest request);
MfgQueueResult LastMfgQueueResult();
// Value-only bounded session publication; ordinary-thread reads, no GPU/file work.
void ReadMfgObservation(MfgObserver::Snapshot& result);
}
