// Standalone Contracts fixture, following adjacent no-product-PCH fixtures.
#include "nr_signal_codec_adapter.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace
{
int checks = 0;
double maxEncodeError = 0, maxDecodeError = 0, maxRoundtripError = 0;
constexpr double tolerance = 1e-6;
constexpr int expectedChecks = 1012;

void Check(bool condition, const char* assertion)
{
    ++checks;
    if (!condition) throw std::runtime_error(assertion);
}

void Near(double actual, double expected, double& maximum, const char* assertion)
{
    const double error = std::abs(actual - expected);
    maximum = std::max(maximum, error);
    Check(std::isfinite(actual) && error <= tolerance, assertion);
}

bool SameBits(double a, double b) { return std::memcmp(&a, &b, sizeof(a)) == 0; }
bool SameRgb(const NrSignalScalar::Rgba& a, const NrSignalScalar::Rgba& b)
{
    return SameBits(a.x, b.x) && SameBits(a.y, b.y) && SameBits(a.z, b.z);
}

// Independent scalar reference: branch equations instead of production
// lerp/step, and exp/log ST2084 instead of production pow. Analytic anchors
// below were computed independently at 60 decimal digits (Python Decimal).
// Only these references decide expected transfer values.
double ReferenceBound(double value, unsigned encoding)
{
    if (std::isnan(value) || (encoding != 0 && !std::isfinite(value))) return 0;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

double ReferenceEncode(double value, unsigned encoding)
{
    value = ReferenceBound(value, encoding);
    if (encoding == 2) return value;
    if (encoding != 3)
        return value < 0.0031308 ? value * 12.92
                                : 1.055 * std::exp(std::log(value) / 2.4) - 0.055;
    const double root = value == 0 ? 0 : std::exp(std::log(value / 100.0) * (2610.0 / 16384.0));
    const double ratio = (3424.0 / 4096.0 + (2413.0 / 128.0) * root) /
                         (1 + (2392.0 / 128.0) * root);
    return std::exp(std::log(ratio) * (2523.0 / 32.0));
}

double ReferenceDecode(double value, unsigned encoding)
{
    value = ReferenceBound(value, encoding);
    if (encoding == 2) return value;
    if (encoding != 3)
        return value < 0.04045 ? value / 12.92
                              : std::exp(2.4 * std::log((value + 0.055) / 1.055));
    if (value == 0) return 0;
    const double root = std::exp(std::log(value) * (32.0 / 2523.0));
    const double numerator = root - 3424.0 / 4096.0;
    if (numerator <= 0) return 0;
    const double ratio = numerator / (2413.0 / 128.0 - (2392.0 / 128.0) * root);
    return std::min(1.0, 100.0 * std::exp(std::log(ratio) * (16384.0 / 2610.0)));
}

void AnalyticVectors()
{
    using namespace NrSignalScalar;
    Near(NrSignalEncodeChannel(1, 3, false), 0.508078421517394855065128128841527711,
         maxEncodeError, "T10_PQ_100_NIT_ENCODE");
    struct Anchor { double proxy, code; };
    const std::array<Anchor, 7> pq {{
        {0, 0.000000730955902578396629851764719183771973},
        {0.0001, 0.021486213798685254766231686119955228},
        {0.001, 0.062336865662695880348354241680513162},
        {0.01, 0.149945732100179774566671799889371390},
        {0.1, 0.299699092420986148223839200494476254},
        {0.5, 0.440281573420457936465422175240459558},
        {1, 0.508078421517394855065128128841527711}
    }};
    for (const auto& anchor : pq)
    {
        const double encoded = NrSignalEncodeChannel(anchor.proxy, 3, false);
        const double decoded = NrSignalDecodeChannel(anchor.code, 3, false);
        Near(encoded, anchor.code, maxEncodeError, "T10_PQ_ANALYTIC_ENCODE");
        Near(decoded, anchor.proxy, maxDecodeError, "T10_PQ_ANALYTIC_DECODE");
        std::printf("T10_VECTOR {\"codec\":3,\"proxy\":%.17g,\"code\":%.17g,\"decoded\":%.17g}\n",
                    anchor.proxy, encoded, decoded);
    }
    const std::array<Anchor, 3> srgb {{
        {0.0031308, 0.040449907482690151813276463404408642},
        {0.18, 0.461356129500441649862826868134178786},
        {0.5, 0.735356983052449490616620586145717282}
    }};
    for (const auto& anchor : srgb)
        Near(NrSignalEncodeChannel(anchor.proxy, 1, false), anchor.code, maxEncodeError,
             "T10_SRGB_ANALYTIC_ENCODE");
    Near(NrSignalDecodeChannel(0.04045, 1, false), 0.003130807283067682461373911827366060,
         maxDecodeError, "T10_SRGB_THRESHOLD_UPPER_BRANCH");
    Near(NrSignalDecodeChannel(0.5, 1, false), 0.214041140482232442403080352477665413,
         maxDecodeError, "T10_SRGB_ANALYTIC_DECODE");

    // ST2084's algebraic denominator pole is outside admitted model codes.
    const double pole = 1.992060081856490492082367590664808905;
    Check(NrSignalDecodeChannel(pole, 3, false) == 1 &&
          NrSignalDecodeChannel(std::nextafter(pole, 0.0), 3, false) == 1,
          "T10_PQ_POLE_CLIPPED_BEFORE_DECODE");
    Check(NrSignalDecodeChannel(1, 3, false) == 1, "T10_PQ_MODEL_WHITE_CLIPS_10000_NITS");
    Check(2413.0 / 128.0 - 2392.0 / 128.0 == 0.1640625,
          "T10_PQ_ADMITTED_DENOMINATOR_BOUND");
    Check(NrSignalDecodeChannel(0, 3, false) == 0 &&
          NrSignalDecodeChannel(0.00000073095590257839663, 3, false) <= tolerance,
          "T10_PQ_BLACK_AND_PEDESTAL");
    std::printf("T10_CASE analytic checks=%d\n", checks);
}

void BoundedVectors()
{
    using namespace NrSignalScalar;
    const double inf = std::numeric_limits<double>::infinity();
    const std::array<double, 26> values {{
        -inf, std::numeric_limits<double>::quiet_NaN(), inf, -2, -0.0, 0,
        std::numeric_limits<double>::denorm_min(), 1e-12, 1e-8,
        std::nextafter(0.0031308, 0.0), 0.0031308, std::nextafter(0.0031308, 1.0),
        std::nextafter(0.04045, 0.0), 0.04045, std::nextafter(0.04045, 1.0),
        0.18, 0.25, 0.5, 0.75, std::nextafter(1.0, 0.0), 1,
        std::nextafter(1.0, 2.0), 1.2, 2, 100, std::numeric_limits<double>::max()
    }};
    for (unsigned encoding = 0; encoding < 4; ++encoding)
    {
        for (double value : values)
        {
            const double encoded = NrSignalEncodeChannel(value, encoding, false);
            const double decoded = NrSignalDecodeChannel(value, encoding, false);
            Near(encoded, ReferenceEncode(value, encoding), maxEncodeError, "T10_ENCODE_REFERENCE");
            Near(decoded, ReferenceDecode(value, encoding), maxDecodeError, "T10_DECODE_REFERENCE");
            Near(NrSignalDecodeChannel(encoded, encoding, false), ReferenceBound(value, encoding),
                 maxRoundtripError, "T10_NORMALIZED_PAIR");
            Check(std::isfinite(encoded) && encoded >= 0 && encoded <= 1 &&
                  std::isfinite(decoded) && decoded >= 0 && decoded <= 1,
                  "T10_FINITE_UNIT_BOUNDS");
        }
    }
    std::printf("T10_CASE scalar_bounds checks=%d\n", checks);
    for (unsigned encoding = 0; encoding < 4; ++encoding)
    {
        for (size_t i = 0; i < values.size(); ++i)
        {
            const Rgba input(values[i], values[(i + 9) % values.size()], values[(i + 17) % values.size()],
                             values[(i + 4) % values.size()]);
            const Rgba encoded = NrSignalEncode(input, encoding, false);
            const Rgba decoded = NrSignalDecode(input, encoding, false);
            const Rgba expectedEncode(NrSignalEncodeChannel(input.x, encoding, false),
                                      NrSignalEncodeChannel(input.y, encoding, false),
                                      NrSignalEncodeChannel(input.z, encoding, false), input.w);
            const Rgba expectedDecode(NrSignalDecodeChannel(input.x, encoding, false),
                                      NrSignalDecodeChannel(input.y, encoding, false),
                                      NrSignalDecodeChannel(input.z, encoding, false), input.w);
            Check(SameRgb(encoded, expectedEncode), "T10_RGB_ENCODE_CHANNEL_INDEPENDENCE");
            Check(SameRgb(decoded, expectedDecode), "T10_RGB_DECODE_CHANNEL_INDEPENDENCE");
            Check(SameBits(encoded.w, input.w) && SameBits(decoded.w, input.w), "T10_ALPHA_BITS_UNCHANGED");
            const Rgba passthroughEncode = NrSignalEncode(input, encoding, true);
            const Rgba passthroughDecode = NrSignalDecode(input, encoding, true);
            Check(SameRgb(passthroughEncode, input) && SameBits(passthroughEncode.w, input.w),
                  "T10_SDR_PASSTHROUGH_ENCODE");
            Check(SameRgb(passthroughDecode, input) && SameBits(passthroughDecode.w, input.w),
                  "T10_SDR_PASSTHROUGH_DECODE");
        }
    }
    std::printf("T10_CASE rgb_alpha_passthrough checks=%d\n", checks);
    for (double value : values)
    {
        // Existing shader's operations of record, separate from the reference
        // pair above. No new finite guard may change Legacy Inf/NaN behaviour.
        const double v = std::fmin(std::fmax(value, 0.0), 1.0);
        const double encodeLow = v * 12.92;
        const double encodeHigh = 1.055 * std::pow(std::max(v, 1e-8), 1.0 / 2.4) - 0.055;
        const double decodeLow = v / 12.92;
        const double decodeHigh = std::pow((v + 0.055) / 1.055, 2.4);
        Check(SameBits(NrSignalEncodeChannel(value, 0, false),
                       encodeLow + (v >= 0.0031308 ? 1.0 : 0.0) * (encodeHigh - encodeLow)),
              "T10_LEGACY_ENCODE_ARITHMETIC_GUARD");
        Check(SameBits(NrSignalDecodeChannel(value, 0, false),
                       decodeLow + (v >= 0.04045 ? 1.0 : 0.0) * (decodeHigh - decodeLow)),
              "T10_LEGACY_DECODE_ARITHMETIC_GUARD");
    }
    std::printf("T10_CASE legacy_arithmetic checks=%d\n", checks);
}
}

int main()
try
{
    AnalyticVectors();
    BoundedVectors();
    if (checks != expectedChecks) throw std::runtime_error("T10_EXPECTED_CHECK_COUNT");
    std::printf("T10_RESULT {\"status\":\"PASS\",\"checks\":%d,\"expectedChecks\":%d,"
                "\"scalarBits\":64,\"referenceDecimalDigits\":60,\"inputVectors\":26,"
                "\"maxEncodeError\":%.17g,\"maxDecodeError\":%.17g,\"maxRoundtripError\":%.17g,"
                "\"tolerance\":%.17g,\"ownedResourcesRemaining\":0}\n",
                checks, expectedChecks, maxEncodeError, maxDecodeError, maxRoundtripError, tolerance);
    return 0;
}
catch (const std::exception& error)
{
    std::printf("T10_ASSERT_FAIL {\"assertion\":\"%s\",\"checksBeforeExit\":%d,\"ownedResourcesRemaining\":0}\n",
                error.what(), checks);
    return 1;
}
