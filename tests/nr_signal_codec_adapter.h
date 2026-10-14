#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

// Only type/intrinsic adaptation. The transfer implementation is included
// from the actual production candidate. Binary64 is intentional and does not
// claim binary32 HLSL/GPU precision. No shader, device or model is substituted.
namespace NrSignalScalar
{
using uint = unsigned int;
using std::max;
using std::pow;
using std::log;

struct Rgb
{
    double x, y, z;
    Rgb(double r, double g, double b) : x(r), y(g), z(b) {}
};
struct Rgba
{
    double x, y, z, w;
    Rgba(double r, double g, double b, double a) : x(r), y(g), z(b), w(a) {}
};

// HLSL saturate maps NaN to zero; keep that Legacy intrinsic behaviour.
inline double saturate(double value) { return std::fmin(std::fmax(value, 0.0), 1.0); }
inline double step(double edge, double value) { return value >= edge ? 1.0 : 0.0; }
inline double lerp(double a, double b, double weight) { return a + weight * (b - a); }
inline std::uint64_t asuint(double value)
{
    std::uint64_t bits;
    std::memcpy(&bits, &value, sizeof(value));
    return bits;
}

#define NR_SIGNAL_SCALAR double
#define precise
#define NR_SIGNAL_RGB Rgb
#define NR_SIGNAL_RGBA Rgba
#define NR_SIGNAL_EXPONENT_MASK 0x7ff0000000000000ull
#ifndef NR_SIGNAL_HELPER_HEADER
#define NR_SIGNAL_HELPER_HEADER "../OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli"
#endif
#include NR_SIGNAL_HELPER_HEADER
#undef NR_SIGNAL_HELPER_HEADER
#undef NR_SIGNAL_SCALAR
#undef precise
#undef NR_SIGNAL_RGB
#undef NR_SIGNAL_RGBA
#undef NR_SIGNAL_EXPONENT_MASK
}
