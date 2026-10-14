#pragma once

#include <cstdint>
#include <optional>
#include <string_view>

namespace DlssNr
{
enum class InputFilter : uint32_t { Area = 0, Bilinear = 1, Nearest = 2 };
enum class SignalEncoding : uint32_t { Legacy = 0, sRGB = 1, LinearSDR = 2, PQSDR = 3 };

inline constexpr const char* InputFilterNames[] = { "Area", "Bilinear", "Nearest" };
inline constexpr const char* SignalEncodingNames[] = { "Legacy", "sRGB", "LinearSDR", "PQSDR" };

// Exact INI tokens, parsed once at the configuration boundary.
template <typename Enum, size_t N>
inline std::optional<Enum> ReadOptionToken(const char* token, const char* const (&names)[N])
{
    if (token)
        for (size_t i = 0; i < N; ++i)
            if (std::string_view(token) == names[i])
                return static_cast<Enum>(i);
    return std::nullopt;
}

// Published from actual frame dimensions/colour metadata, not a menu choice.
struct OptionContext
{
    uint32_t inputWidth = 0, inputHeight = 0, workingWidth = 0, workingHeight = 0;
    bool nativeDx12 = false, hdrProxy = false;
};

struct OptionState
{
    InputFilter requestedFilter = InputFilter::Area, effectiveFilter = InputFilter::Area;
    SignalEncoding requestedSignal = SignalEncoding::Legacy, effectiveSignal = SignalEncoding::Legacy;
    bool filterSelectable = false, signalSelectable = false;
    bool filterSupported = false, signalSupported = false;
};

inline OptionState ResolveOptions(InputFilter filter, SignalEncoding signal, const OptionContext& context,
                                  uint32_t publishedFilter, uint32_t publishedSignal,
                                  bool filterSupported, bool signalSupported)
{
    const bool subnative = context.inputWidth && context.inputHeight && context.workingWidth &&
        context.workingHeight && context.workingWidth <= context.inputWidth &&
        context.workingHeight <= context.inputHeight &&
        (context.workingWidth < context.inputWidth || context.workingHeight < context.inputHeight);
    const bool filterEligible = context.nativeDx12 && subnative;
    const bool signalEligible = context.nativeDx12 && context.hdrProxy;
    // Override support/effective values are published processing facts. Eligibility
    // does not assert that the forthcoming shader or paired transport is shipped.
    return { filter, filterEligible && filterSupported ? static_cast<InputFilter>(publishedFilter) : InputFilter::Area,
             signal, signalEligible && signalSupported ? static_cast<SignalEncoding>(publishedSignal) : SignalEncoding::Legacy,
             filterEligible, signalEligible,
             filterEligible && filterSupported, signalEligible && signalSupported };
}
} // namespace DlssNr
