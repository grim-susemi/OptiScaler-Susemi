#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <shaders/dlssnr/DlssNr_Common.h>
#include "DlssNr_Placement.h"
#include "DlssNr_FinishedConsumer.h"
#include "DlssNr_Options.h"

class Config;

namespace DlssNr
{
enum class Backend
{
    Dx12,
    Vulkan
};

enum class OutputState
{
    Disabled,
    Capturing,
    WaitingForModel,
    EvaluatedHidden,
    Submitted,
    Skipped,
    Failed
};

enum class OutputReason
{
    None,
    Admission,
    Resource,
    Model,
    Composition,
    FinalEncode,
    Close,
    Signal,
    Discarded
};

enum class ModelContextState { Absent, Current, Unknown };

// Values only; identity pointers are compared, never dereferenced. These
// describe the encoded model input, not whether its answer was applied.
struct ModelFacts
{
    ModelContextState contextState = ModelContextState::Absent;
    Backend backend = Backend::Dx12;
    FinishedIdentity identity;
    uint32_t uiCorrection = 1, inputFilter = 0, signalEncoding = 0;
    bool automaticUiCorrection = false;
    bool inputFilterOverrideSupported = false, signalEncodingOverrideSupported = false;
    OptionContext optionContext;

    void ValidateCurrent(Backend currentBackend, const FinishedIdentity& current)
    {
        if (contextState == ModelContextState::Absent)
            return;
        if (backend != currentBackend)
            *this = {};
        else if (!current.Known())
        {
            *this = {};
            backend = currentBackend;
            contextState = ModelContextState::Unknown;
        }
        else if (contextState == ModelContextState::Current &&
                 ((current.owner && identity.owner != current.owner) || !identity.SameConsumer(current)))
            *this = {};
    }
};

// Recording, queue execution and a successfully queued retirement signal are
// separate facts. Neither evaluation nor execution alone proves applied output.
struct OutputStatus : ModelFacts
{
    OutputState state = OutputState::Disabled;
    OutputReason reason = OutputReason::None;
    Placement requested {}, effective {};
    FinishedConsumer consumer = FinishedConsumer::Generic;
    uint64_t application = 0, generation = 0, captureSerial = 0;
    bool guidesValid = false;
    // Inherited fields are the current run's encoder values. The owner stores
    // its last valid ModelFacts separately from this application outcome.
    bool evaluated = false, hidden = false, composed = false, copyBack = false;
    bool executed = false, submitted = false, completionUnknown = false;

    void ResetOutcome()
    {
        const auto facts = static_cast<const ModelFacts&>(*this);
        *this = {};
        static_cast<ModelFacts&>(*this) = facts;
    }

    bool Applied() const
    {
        return state == OutputState::Submitted && !hidden && composed && copyBack &&
               executed && submitted && !completionUnknown;
    }
};

#ifdef OPTISCALER_NR_SELF_TEST
// Seed only value telemetry before the actual public finished reset/publisher.
// No model, command, device or queue is supplied by this fixture.
enum class FinishedFixtureStage { Public, Internal, Capture };
struct FinishedCallerFixture
{
    OutputStatus output;
    FinishedFixtureStage stage = FinishedFixtureStage::Public;
    Backend backend = Backend::Dx12;
};
extern thread_local std::optional<FinishedCallerFixture> FinishedStatusFixture;
extern thread_local std::optional<OutputStatus> FinishedStatusObserved;
#endif

// Menu telemetry contains values only. GPU resources remain owned by the shader instance.
struct StatusSnapshot
{
    bool running = false;
    std::string failureReason;
    std::optional<double> gpuTime;
    unsigned long long frames = 0;
    DlssNrReconstruction reconstruction;
    OutputStatus output;
    ModelFacts modelFacts;
};

// Freeze both backend values for a single menu draw, including its controls.
struct MenuStatusScope
{
    StatusSnapshot dx12, vulkan;
    MenuStatusScope();
    ~MenuStatusScope();
    MenuStatusScope(const MenuStatusScope&) = delete;
    MenuStatusScope& operator=(const MenuStatusScope&) = delete;
};

struct ControlRequests
{
    uint64_t retryGeneration = 0;
    uint64_t captureGeneration = 0;
    unsigned int captureFrames = 0;
};

void PublishStatus(const void* owner, Backend backend, const StatusSnapshot& status);
void ClearStatus(const void* owner);
StatusSnapshot ReadStatus(Backend backend);
ControlRequests ReadControlRequests();

void RenderMenu(::Config* config, float menuResScale);
void RetryAfterFailure();
std::optional<double> LastGpuTime();
void RequestCapture(unsigned int frames);
} // namespace DlssNr
