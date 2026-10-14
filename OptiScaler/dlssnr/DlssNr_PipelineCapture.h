#pragma once
#if defined(T16_R63_CAPS_HANDOFF) && (!defined(T16_R54_CAPS_PROOF) || !defined(T16_R63_GREEN))
#error R63 requires the test-only R54 gates and the proved GREEN build
#endif
#if defined(T16_R63_CAPS_HANDOFF) && T16_R63_GREEN != 1
#error Canonical R63 handoff requires GREEN=1
#endif
#include "DlssNr_Readback.h"
#include "DlssNr_GpuLifetime.h"
#include <array>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <vector>
#include <sstream>
#include <cstring>
#ifdef T16_R54_CAPS_PROOF
#include <cstdio>
#endif

namespace DlssNr
{
struct CaptureIdentity
{
    uint64_t owner = 0, consumer = 0, generation = 0, application = 0;
    bool known = false;
    bool operator==(const CaptureIdentity&) const = default;
};
struct CaptureBudget
{
    static constexpr UINT64 ReadbackCap = 32ull * 1024 * 1024;
    static constexpr UINT64 SessionCap = 256ull * 1024 * 1024;
    static constexpr UINT64 MetadataReservation = 64 * 1024;
    std::mutex mutex;
    UINT64 inFlight = 0, retained = MetadataReservation, peak = 0;
    unsigned frames = 0, ringDrops = 0, budgetDrops = 0, duplicateDrops = 0, unknownDrops = 0;
};
#ifdef T16_R54_CAPS_PROOF
// Test-only shared ownership; gates are installed only by the canonical caps fixture.
struct R54Gate
{
    HANDLE startRelease = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE entered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE resetDone = CreateEventW(nullptr, TRUE, FALSE, nullptr);
#ifdef T16_R63_CAPS_HANDOFF
    HANDLE resume = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    bool handoff = false;
    DWORD resumeWait = WAIT_FAILED;
    int snapshotExit = -1;
#endif
    unsigned sequence = 0, resourceRelease = 0, retiredSignal = 0, lockOwned = 0, slotReset = 0, unlocked = 0;
    int slots = -1, stop = -1, timedOut = -1, quarantine = -1;
    unsigned frames = 0, ringDrops = 0, budgetDrops = 0, duplicateDrops = 0, unknownDrops = 0;
    UINT64 retained = 0, inFlight = 0, peak = 0;
    DWORD startWait = WAIT_FAILED, releaseWait = WAIT_FAILED;
    ~R54Gate()
    {
#ifdef T16_R63_CAPS_HANDOFF
        if (resume) CloseHandle(resume);
#endif
        if (startRelease) CloseHandle(startRelease); if (entered) CloseHandle(entered);
        if (release) CloseHandle(release); if (resetDone) CloseHandle(resetDone);
    }
};
#endif
struct PipelineCaptureFrame
{
    struct Image : ReadbackImage
    {
        Microsoft::WRL::ComPtr<ID3D12Resource> source;
        std::string name, unavailable;
        uintptr_t provenance = 0;
        D3D12_RESOURCE_STATES sourceState {};
    };
    std::array<Image, 8> images {};
    unsigned imageCount = 0, number = 0;
    CaptureIdentity identity;
    std::shared_ptr<CaptureBudget> budget;
    std::shared_ptr<CaptureCompletion> completion;
    std::filesystem::path directory;
    std::atomic_bool sealed { false }, canceled { false };
    UINT64 allocation = 0, payload = 0;
    DWORD writeThread = 0;
    DWORD workerThread = 0;
    bool written = false;
    uint32_t preExposureBits = 0, resolvedPreExposureBits = 0, exposureStateRaw = 0, exposureMode = 0;
    uint32_t preExposureReadResult = 0, exposureReadResult = 0;
    bool preExposureReadAttempted = false, preExposureReadSucceeded = false, exposureReadSucceeded = false;
    uintptr_t exposureResource = 0;
    bool exposureProvenanceKnown = false;
#ifdef T16_R54_CAPS_PROOF
    std::shared_ptr<R54Gate> r54Gate; // assigned before Seal publishes the frame
#endif
    HANDLE retired = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ~PipelineCaptureFrame()
    {
        if (retired) CloseHandle(retired);
        if (budget)
        {
            std::lock_guard lock(budget->mutex);
            budget->inFlight -= allocation;
        }
    }
    void Copy(ID3D12GraphicsCommandList* cmd, ID3D12Device* device, const char* name,
              ID3D12Resource* source, D3D12_RESOURCE_STATES state, bool knownState = true)
    {
        if (sealed) return;
        unsigned index = 0;
        for (; index < imageCount; ++index) if (images[index].name == name) break;
        if (index == imageCount)
        {
            if (imageCount == images.size()) return;
            ++imageCount;
        }
        auto& image = images[index];
        if (image.readback) return;
        image.name = std::string(name).substr(0, 40);
        image.provenance = reinterpret_cast<uintptr_t>(source);
        image.sourceState = state;
        if (!knownState || !cmd || !device || !source)
        { image.unavailable = "state_queue_or_ownership_unestablished"; return; }
        Microsoft::WRL::ComPtr<ID3D12Device> commandDevice, sourceDevice;
        Microsoft::WRL::ComPtr<IUnknown> commandIdentity, sourceIdentity, providedIdentity;
        if (FAILED(cmd->GetDevice(IID_PPV_ARGS(&commandDevice))) ||
            FAILED(source->GetDevice(IID_PPV_ARGS(&sourceDevice))) ||
            FAILED(commandDevice.As(&commandIdentity)) || FAILED(sourceDevice.As(&sourceIdentity)) ||
            FAILED(device->QueryInterface(IID_PPV_ARGS(&providedIdentity))) ||
            commandIdentity.Get() != providedIdentity.Get() || sourceIdentity.Get() != providedIdentity.Get())
        { image.unavailable = "device_origin_unestablished"; return; }
        const auto desc = source->GetDesc();
        const auto format = TypedReadbackFormat(desc.Format);
        const bool supported = format == DXGI_FORMAT_R16G16B16A16_FLOAT ||
            format == DXGI_FORMAT_R32G32B32A32_FLOAT || format == DXGI_FORMAT_R32_FLOAT ||
            format == DXGI_FORMAT_R16_FLOAT || format == DXGI_FORMAT_R16G16_FLOAT ||
            format == DXGI_FORMAT_R32G32_FLOAT || format == DXGI_FORMAT_R11G11B10_FLOAT ||
            format == DXGI_FORMAT_R8G8B8A8_UNORM || format == DXGI_FORMAT_B8G8R8A8_UNORM ||
            format == DXGI_FORMAT_R10G10B10A2_UNORM;
        if (!supported) { image.unavailable = "unsupported_format"; return; }
        std::unique_lock lock(budget->mutex, std::try_to_lock);
        if (!lock.owns_lock()) { image.unavailable = "budget_contention"; return; }
        const auto available = (std::min)(CaptureBudget::ReadbackCap - budget->inFlight,
                                         CaptureBudget::SessionCap - budget->retained);
        if (!image.AllocateRoi(device, desc, available))
        { image.unavailable = "readback_budget_or_allocation"; ++budget->budgetDrops; return; }
        budget->inFlight += image.allocationBytes;
        budget->retained += image.allocationBytes;
        budget->peak = (std::max)(budget->peak, budget->inFlight);
        allocation += image.allocationBytes;
        payload += image.bytes;
        lock.unlock();
        image.source = source;
        image.unavailable.clear();
        image.Copy(cmd, source, state);
    }
    void Unavailable(const char* name, ID3D12Resource* source = nullptr)
    {
        Copy(nullptr, nullptr, name, source, D3D12_RESOURCE_STATE_COMMON, false);
    }
    void Seal() { sealed.store(true, std::memory_order_release); if (completion) SetEvent(completion->event); }
    void Cancel() { canceled = true; Seal(); }
    bool Write()
    {
        if (!workerThread || workerThread != GetCurrentThreadId() || !sealed || canceled ||
            !completion || completion->Readiness() != CaptureCompletion::Result::Ready) return false;
        writeThread = GetCurrentThreadId();
        std::error_code error;
        std::filesystem::create_directories(directory, error);
        if (error) return false;
        std::ostringstream manifest;
        manifest << "{\"schema\":1,\"applicationKnown\":true,\"owner\":" << identity.owner
                 << ",\"consumer\":" << identity.consumer << ",\"generation\":" << identity.generation
                 << ",\"application\":" << identity.application << ",\"workerThread\":" << writeThread
                 << ",\"exposureProvenanceKnown\":" << (exposureProvenanceKnown ? "true" : "false")
                 << ",\"preExposureRawBits\":" << preExposureBits << ",\"exposureResource\":" << exposureResource
                 << ",\"preExposureReadAttempted\":" << (preExposureReadAttempted ? "true" : "false")
                 << ",\"preExposureReadSucceeded\":" << (preExposureReadSucceeded ? "true" : "false")
                 << ",\"preExposureReadResult\":" << preExposureReadResult
                 << ",\"resolvedPreExposureBits\":" << resolvedPreExposureBits
                 << ",\"exposureReadSucceeded\":" << (exposureReadSucceeded ? "true" : "false")
                 << ",\"exposureReadResult\":" << exposureReadResult
                 << ",\"exposureStateRaw\":" << exposureStateRaw << ",\"resolvedExposureMode\":" << exposureMode
                 << ",\"observerReference\":\"../mfg-preflight.json\",\"phaseKnown\":false,"
                    "\"displayTimingAvailable\":false,\"images\":[";
        bool success = true;
        for (unsigned i = 0; i < imageCount; ++i)
        {
            auto& image = images[i];
            const bool available = image.readback && image.Write(directory / (image.name + ".raw"));
            if (image.readback && !available) success = false;
            if (i) manifest << ',';
            manifest << "{\"role\":\"" << image.name << "\",\"imageAvailable\":"
                     << (available ? "true" : "false") << ",\"sourceState\":" << unsigned(image.sourceState)
                     << ",\"rawResource\":" << image.provenance
                     << ",\"pixelOrigin\":\"" << (available ? "owned_nr_surface" : "unknown") << '"';
            if (available)
                manifest << ",\"evidence\":\"" << image.name << ".raw\",\"width\":" << image.roi.right
                         << ",\"height\":" << image.roi.bottom << ",\"format\":" << image.layout.Footprint.Format
                         << ",\"rowPitch\":" << image.layout.Footprint.RowPitch << ",\"bytes\":" << image.bytes;
            else
                manifest << ",\"unavailableReason\":\"" << (image.unavailable.empty() ? "map_or_write_failed" : image.unavailable) << '"';
            manifest << '}';
        }
        manifest << "]}";
        const auto text = manifest.str();
        if (text.size() > CaptureBudget::MetadataReservation) return false;
        std::ofstream file(directory / "capture.json", std::ios::binary);
        file << text;
        file.close();
        written = success && !file.fail();
        return written;
    }
    void ReleaseCompletedResources()
    {
        for (auto& image : images) { image.readback.Reset(); image.source.Reset(); }
        std::lock_guard lock(budget->mutex);
        budget->inFlight -= allocation;
        allocation = 0;
#ifdef T16_R54_CAPS_PROOF
        if (r54Gate)
        {
            r54Gate->resourceRelease = ++r54Gate->sequence;
            r54Gate->frames = budget->frames; r54Gate->retained = budget->retained;
            r54Gate->inFlight = budget->inFlight; r54Gate->peak = budget->peak;
            r54Gate->ringDrops = budget->ringDrops; r54Gate->budgetDrops = budget->budgetDrops;
            r54Gate->duplicateDrops = budget->duplicateDrops; r54Gate->unknownDrops = budget->unknownDrops;
        }
#endif
    }
};
class PipelineCaptureSession
{
  public:
    enum class QuarantineCause { None, DeviceRemovedUnprovenRetirement };
  private:
    struct State
    {
#ifdef T16_R54_CAPS_PROOF
        std::shared_ptr<R54Gate> r54Start;
#endif
        std::mutex mutex;
        std::array<std::shared_ptr<PipelineCaptureFrame>, 4> slots {};
        std::array<CaptureIdentity, 64> admitted {};
        std::shared_ptr<CaptureBudget> budget = std::make_shared<CaptureBudget>();
        std::filesystem::path directory;
        HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        HANDLE thread = nullptr;
        std::atomic_bool stop { false }, timedOut { false };
        std::atomic<QuarantineCause> quarantineCause { QuarantineCause::None };
        std::atomic_uint writes { 0 }, discarded { 0 }, removed { 0 };
        ~State() { if (wake) CloseHandle(wake); if (thread) CloseHandle(thread); }
    };
    std::shared_ptr<State> state;
    static std::atomic_bool& Active() { static std::atomic_bool value { false }; return value; }
    static bool Drain(const std::shared_ptr<State>& work)
    {
        for (;;)
        {
            std::array<HANDLE, 5> events {};
            events[0] = work->wake;
            DWORD count = 1;
            std::array<std::shared_ptr<PipelineCaptureFrame>, 4> jobs;
            {
                std::lock_guard lock(work->mutex);
                jobs = work->slots;
            }
            bool pending = false;
#ifdef T16_R63_CAPS_HANDOFF
            // Caps publishes only one frame between handoffs; keep its destructor off READY.
            std::shared_ptr<PipelineCaptureFrame> handoffFrame;
#endif
            for (unsigned i = 0; i < jobs.size(); ++i)
            {
                auto& frame = jobs[i];
                if (!frame) continue;
                const auto ready = frame->completion->Readiness();
                if (!frame->sealed || ready == CaptureCompletion::Result::Pending)
                {
                    events[count++] = frame->completion->event;
                    pending = true;
                    continue;
                }
                if (ready == CaptureCompletion::Result::Ready && !frame->canceled)
                {
                    frame->workerThread = GetCurrentThreadId();
                    if (frame->Write()) ++work->writes;
                }
                else if (ready == CaptureCompletion::Result::DeviceRemoved)
                {
                    ++work->removed;
                    work->quarantineCause = QuarantineCause::DeviceRemovedUnprovenRetirement;
                    work->stop = true;
                    return false;
                }
                else ++work->discarded;
                frame->ReleaseCompletedResources();
                SetEvent(frame->retired);
#ifdef T16_R54_CAPS_PROOF
                auto gate = frame->r54Gate;
                if (gate) gate->retiredSignal = ++gate->sequence;
#endif
                {
                    std::lock_guard lock(work->mutex);
#ifdef T16_R54_CAPS_PROOF
                    if (gate)
                    {
                        gate->lockOwned = ++gate->sequence;
                        gate->slots = unsigned(std::count_if(work->slots.begin(), work->slots.end(), [](const auto& slot) { return bool(slot); }));
                        gate->stop = work->stop.load(); gate->timedOut = work->timedOut.load();
                        gate->quarantine = int(work->quarantineCause.load());
                        SetEvent(gate->entered);
                        gate->releaseWait = WaitForSingleObject(gate->release, 10000);
                        if (gate->releaseWait != WAIT_OBJECT_0)
                        {
                            std::fprintf(stderr, "R54_WRITER_GATE_FAILURE wait=%lu\n", gate->releaseWait);
                            work->timedOut = true;
                            return false;
                        }
                    }
#endif
                    if (work->slots[i] == frame) work->slots[i].reset();
#ifdef T16_R54_CAPS_PROOF
                    if (gate) gate->slotReset = ++gate->sequence;
#endif
                }
#ifdef T16_R54_CAPS_PROOF
                if (gate)
                {
                    gate->unlocked = ++gate->sequence;
#ifdef T16_R63_CAPS_HANDOFF
                    if (!gate->handoff)
#endif
                        SetEvent(gate->resetDone);
                }
#endif
#ifdef T16_R63_CAPS_HANDOFF
                if (gate && gate->handoff) handoffFrame = std::move(frame);
                else
#endif
                frame.reset();
            }
#ifdef T16_R63_CAPS_HANDOFF
            // Make the original old-snapshot decision BEFORE exposing the next admission.
            // RESUME must not re-evaluate it after that admission can set stop at frame64.
            const bool exitSnapshot = work->stop && !pending;
            if (handoffFrame)
            {
                const auto& gate = handoffFrame->r54Gate;
                gate->snapshotExit = int(exitSnapshot);
                // Exact slot reset/unlock and snapshot decision are complete. Neither mutex
                // is owned; the retained frame prevents budget-lock destruction before RESUME.
                if (!SetEvent(gate->resetDone))
                {
                    std::fprintf(stderr, "R63_READY_SIGNAL_FAILURE error=%lu\n", GetLastError());
                    work->timedOut = true;
                    return false;
                }
                gate->resumeWait = WaitForSingleObject(gate->resume, 10000);
                if (gate->resumeWait != WAIT_OBJECT_0)
                {
                    std::fprintf(stderr, "R63_RESUME_GATE_FAILURE wait=%lu\n", gate->resumeWait);
                    work->timedOut = true;
                    return false;
                }
                handoffFrame.reset();
            }
            if (exitSnapshot)
#else
            if (work->stop && !pending)
#endif
            {
                std::error_code error;
                std::filesystem::create_directories(work->directory, error);
                if (!error)
                {
                    std::lock_guard lock(work->budget->mutex);
                    std::ofstream summary(work->directory / "capture-session.json", std::ios::binary);
                    summary << "{\"schema\":1,\"frames\":" << work->budget->frames
                            << ",\"writes\":" << work->writes << ",\"discarded\":" << work->discarded
                            << ",\"deviceRemoved\":" << work->removed
                            << ",\"ringDrops\":" << work->budget->ringDrops
                            << ",\"budgetDrops\":" << work->budget->budgetDrops
                            << ",\"duplicateDrops\":" << work->budget->duplicateDrops
                            << ",\"unknownIdentityDrops\":" << work->budget->unknownDrops
                            << ",\"peakReadbackBytes\":" << work->budget->peak
                            << ",\"retainedReservationBytes\":" << work->budget->retained
                            << ",\"inFlightReadbackBytes\":" << work->budget->inFlight << '}';
                }
                return true;
            }
            const auto result = WaitForMultipleObjects(count, events.data(), FALSE, pending ? 30000 : INFINITE);
            if (result == WAIT_TIMEOUT || result == WAIT_FAILED)
            {
                work->timedOut = true;
                return false;
            }
        }
    }
    static DWORD Work(void* parameter)
    {
        std::unique_ptr<std::shared_ptr<State>> owner(static_cast<std::shared_ptr<State>*>(parameter));
        auto work = *owner;
        owner.reset();
#ifdef T16_R54_CAPS_PROOF
        // Fixture bootstrap only: worker has acquired no state/budget mutex yet.
        // Begin installs this event before CreateThread; no Admit synchronization changes.
        if (work->r54Start)
        {
            work->r54Start->startWait = WaitForSingleObject(work->r54Start->startRelease, 10000);
            if (work->r54Start->startWait != WAIT_OBJECT_0)
            {
                std::fprintf(stderr, "R54_START_GATE_FAILURE wait=%lu\n", work->r54Start->startWait);
                work->timedOut = true;
            }
        }
#endif
#ifdef T16_R54_CAPS_PROOF
        if ((work->r54Start && work->r54Start->startWait != WAIT_OBJECT_0) || !Drain(work))
#else
        if (!Drain(work))
#endif
        {
            // Timeout or removal proves no GPU retirement. Keep every slot and its charged ownership.
            // Supported loader/caller retains code residency.
            auto* retained = new std::shared_ptr<State>(std::move(work));
            (void)retained;
            return 1;
        }
        work.reset();
        Active() = false;
        return 0;
    }
    static DWORD WINAPI Worker(void* parameter)
    {
        // Work returns after every owned C++ automatic object is destroyed; ExitThread skips unwinding.
        const DWORD result = Work(parameter);
        ExitThread(result);
    }
  public:
#ifdef T16_R54_CAPS_PROOF
    static std::shared_ptr<PipelineCaptureSession> Begin(const std::filesystem::path& directory,
        const std::shared_ptr<R54Gate>& r54Start = {})
#else
    static std::shared_ptr<PipelineCaptureSession> Begin(const std::filesystem::path& directory)
#endif
    {
        bool expected = false;
        if (!Active().compare_exchange_strong(expected, true)) return {};
        auto session = std::make_shared<PipelineCaptureSession>();
        auto work = std::make_shared<State>();
#ifdef T16_R54_CAPS_PROOF
        work->r54Start = r54Start;
#endif
        // Product loader preserves live-module residency. A standalone DLL caller must own its
        // LoadLibrary reference until worker exit and every capture object/callback is closed.
        if (!work->wake) { Active() = false; return {}; }
        work->directory = directory;
        auto* parameter = new std::shared_ptr<State>(work);
        const auto thread = CreateThread(nullptr, 0, Worker, parameter, 0, nullptr);
        if (!thread)
        {
            delete parameter;
            Active() = false;
            return {};
        }
        work->thread = thread;
        session->state = std::move(work);
        return session;
    }
    ~PipelineCaptureSession() { Stop(); }
    std::shared_ptr<PipelineCaptureFrame> Admit(const CaptureIdentity& identity, GpuLifetime& lifetime,
                                               ID3D12GraphicsCommandList* commands)
    {
        if (!state || state->stop || state->timedOut) return {};
        std::unique_lock lock(state->mutex, std::try_to_lock);
        if (!lock.owns_lock()) return {};
        auto& budget = *state->budget;
        std::unique_lock budgetLock(budget.mutex, std::try_to_lock);
        if (!budgetLock.owns_lock()) return {};
        if (!identity.known || !identity.owner || !identity.consumer)
        { ++budget.unknownDrops; return {}; }
        for (unsigned i = 0; i < budget.frames; ++i)
            if (state->admitted[i] == identity) { ++budget.duplicateDrops; return {}; }
        if (budget.frames == state->admitted.size()) { state->stop = true; SetEvent(state->wake); return {}; }
        const auto index = std::find(state->slots.begin(), state->slots.end(), nullptr);
        if (index == state->slots.end()) { ++budget.ringDrops; return {}; }
        if (CaptureBudget::MetadataReservation > CaptureBudget::SessionCap - budget.retained)
        { ++budget.budgetDrops; return {}; }
        lifetime.Record(commands);
        auto completion = lifetime.SubscribeCapture(commands);
        if (!completion) return {};
        auto frame = std::make_shared<PipelineCaptureFrame>();
        frame->identity = identity; frame->completion = std::move(completion); frame->budget = state->budget;
        frame->number = budget.frames;
        frame->directory = state->directory / ("frame-" + std::to_string(frame->number));
        budget.retained += CaptureBudget::MetadataReservation;
        state->admitted[budget.frames++] = identity;
        *index = frame;
        if (budget.frames == state->admitted.size()) state->stop = true;
        SetEvent(state->wake);
        return frame;
    }
    void Stop() { if (state) { state->stop = true; SetEvent(state->wake); } }
    void Cancel()
    {
        if (!state) return;
        std::lock_guard lock(state->mutex);
        for (auto& frame : state->slots) if (frame) frame->Cancel();
        state->stop = true;
        SetEvent(state->wake);
    }
    HANDLE Exited() const { return state ? state->thread : nullptr; }
    std::shared_ptr<CaptureBudget> Budget() const { return state ? state->budget : nullptr; }
    unsigned Writes() const { return state ? state->writes.load() : 0; }
    unsigned Discarded() const { return state ? state->discarded.load() : 0; }
    bool TimedOut() const { return state && state->timedOut; }
    QuarantineCause QuarantinedBy() const { return state ? state->quarantineCause.load() : QuarantineCause::None; }
    static bool Busy() { return Active(); }
};
}
