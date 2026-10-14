#include <pch.h>
#include "DlssNr_Status.h"

#include <array>
#include <mutex>

namespace DlssNr
{
namespace
{
struct PublishedStatus
{
    const void* owner = nullptr; // Identity only; never dereferenced.
    StatusSnapshot value;
};

std::mutex statusMutex;
std::array<PublishedStatus, 2> published;
ControlRequests requests;
thread_local const MenuStatusScope* menuSnapshot = nullptr;
} // namespace

StatusSnapshot ReadStatus(Backend backend)
{
    if (menuSnapshot)
        return backend == Backend::Dx12 ? menuSnapshot->dx12 : menuSnapshot->vulkan;
    std::lock_guard lock(statusMutex);
    return published[static_cast<size_t>(backend)].value;
}

MenuStatusScope::MenuStatusScope()
{
    std::lock_guard lock(statusMutex);
    dx12 = published[static_cast<size_t>(Backend::Dx12)].value;
    vulkan = published[static_cast<size_t>(Backend::Vulkan)].value;
    menuSnapshot = this;
}

MenuStatusScope::~MenuStatusScope() { menuSnapshot = nullptr; }

void PublishStatus(const void* owner, Backend backend, const StatusSnapshot& status)
{
    std::lock_guard lock(statusMutex);
    published[static_cast<size_t>(backend)] = { owner, status };
}

void ClearStatus(const void* owner)
{
    std::lock_guard lock(statusMutex);
    for (auto& status : published)
        if (status.owner == owner)
            status = {};
}

ControlRequests ReadControlRequests()
{
    std::lock_guard lock(statusMutex);
    return requests;
}

void RetryAfterFailure()
{
    std::lock_guard lock(statusMutex);
    ++requests.retryGeneration;
}

void RequestCapture(unsigned int frames)
{
    std::lock_guard lock(statusMutex);
    requests.captureFrames = frames;
    ++requests.captureGeneration;
}

std::optional<double> LastGpuTime() { return ReadStatus(Backend::Dx12).gpuTime; }
} // namespace DlssNr
