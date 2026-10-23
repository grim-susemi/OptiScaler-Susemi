#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <shaders/dlssnr/DlssNr_Common.h>
#include "DlssNr_Placement.h"
#include "DlssNr_FinishedConsumer.h"

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

// Recording, queue execution and a successfully queued retirement signal are
// separate facts. Neither evaluation nor execution alone proves applied output.
struct OutputStatus
{
    OutputState state = OutputState::Disabled;
    OutputReason reason = OutputReason::None;
    Placement requested {}, effective {};
    FinishedConsumer consumer = FinishedConsumer::Generic;
    uint64_t application = 0, generation = 0, captureSerial = 0;
    bool guidesValid = false;
    // Current creation/shader contracts. Later policy/filter/codec tasks own
    // resolving overrides; a selected future option is not reported active here.
    uint32_t uiCorrection = 1, inputFilter = 0, signalEncoding = 0;
    bool automaticUiCorrection = false;
    bool inputFilterOverrideSupported = false, signalEncodingOverrideSupported = false;
    bool evaluated = false, hidden = false, composed = false, copyBack = false;
    bool executed = false, submitted = false, completionUnknown = false;

    bool Applied() const
    {
        return state == OutputState::Submitted && !hidden && composed && copyBack &&
               executed && submitted && !completionUnknown;
    }
};

// Menu telemetry contains values only. GPU resources remain owned by the shader instance.
struct StatusSnapshot
{
    bool running = false;
    std::string failureReason;
    std::optional<double> gpuTime;
    unsigned long long frames = 0;
    DlssNrReconstruction reconstruction;
    OutputStatus output;
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
