#ifndef DLSSNR_SIGNAL_HLSLI
#define DLSSNR_SIGNAL_HLSLI

// Local NR proxy transfers, not NGX encodings or swapchain colour transport.
// The caller supplies an already-mapped proxy and an admitted code 0..3.
// WhitePoint, SoftKnee, Neutwo/Hybrid, residual carriers and restoration stay
// outside this helper. In SDR passthrough, the caller's existing frame clamp
// stays upstream and no transfer is applied. Alpha passes through unchanged.
//
// Types default to HLSL float. The native scalar contract adapter supplies
// binary64 types to verify the mathematical pair, not shader precision.
#ifndef NR_SIGNAL_SCALAR
#define NR_SIGNAL_SCALAR float
#define NR_SIGNAL_RGB float3
#define NR_SIGNAL_RGBA float4
#define NR_SIGNAL_EXPONENT_MASK 0x7f800000u
#define NR_SIGNAL_DEFAULT_TYPES
#endif

// Separate from the 203-nit swapchain reference white and 80-nit scRGB unit.
static const NR_SIGNAL_SCALAR kNrSignalPqNitsPerUnit = 100.0;
static const NR_SIGNAL_SCALAR kNrSignalPqPeakNits = 10000.0;

NR_SIGNAL_SCALAR NrSignalBound(NR_SIGNAL_SCALAR value)
{
    // Integer classification survives FXC's finite-arithmetic assumptions;
    // NaN and both infinities have the all-ones IEEE exponent.
    return (asuint(value) & NR_SIGNAL_EXPONENT_MASK) == NR_SIGNAL_EXPONENT_MASK ? 0.0 : saturate(value);
}

// Preserve the current Legacy saturate/lerp/step arithmetic and floor exactly.
NR_SIGNAL_SCALAR NrSignalSrgbEncode(NR_SIGNAL_SCALAR value)
{
    value = saturate(value);
    return lerp(value * 12.92, 1.055 * pow(max(value, 1e-8), 1.0 / 2.4) - 0.055,
                step(0.0031308, value));
}

NR_SIGNAL_SCALAR NrSignalSrgbDecode(NR_SIGNAL_SCALAR value)
{
    value = saturate(value);
    return lerp(value / 12.92, pow((value + 0.055) / 1.055, 2.4), step(0.04045, value));
}

// Existing finished-colour ST2084 implementation with its unit conversion
// named explicitly. Black retains the OETF pedestal, about 7.309559e-7.
NR_SIGNAL_SCALAR NrSignalPqEncode(NR_SIGNAL_SCALAR proxy)
{
    const NR_SIGNAL_SCALAR m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
    const NR_SIGNAL_SCALAR c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
    NR_SIGNAL_SCALAR p = pow(saturate(proxy * kNrSignalPqNitsPerUnit / kNrSignalPqPeakNits), m1);
    return pow((c1 + c2 * p) / (1.0 + c3 * p), m2);
}

NR_SIGNAL_SCALAR NrSignalPqDecode(NR_SIGNAL_SCALAR code)
{
    const NR_SIGNAL_SCALAR m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
    const NR_SIGNAL_SCALAR c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
    code = saturate(code);
    if (code == 0.0) return 0.0;
    NR_SIGNAL_SCALAR t = -log(code) / m2;
    if (t >= 0.18) return 0.0;
    // Direct 1-exp(-t) avoids rounding p near one; degree-seven remainder <= 2.734e-11.
    NR_SIGNAL_SCALAR q = t * (1.0 + t * (-1.0 / 2.0 + t * (1.0 / 6.0 +
        t * (-1.0 / 24.0 + t * (1.0 / 120.0 + t * (-1.0 / 720.0 + t / 5040.0))))));
    NR_SIGNAL_SCALAR n = max((1.0 - c1) - q, 0.0);
    NR_SIGNAL_SCALAR d = max((c2 - c3) + c3 * q, 1e-6);
    return pow(n / d, 1.0 / m1) *
           kNrSignalPqPeakNits / kNrSignalPqNitsPerUnit;
}

NR_SIGNAL_SCALAR NrSignalEncodeChannel(NR_SIGNAL_SCALAR proxy, uint encoding, bool passthrough)
{
    if (passthrough) return proxy;
    if (encoding == 0) return NrSignalSrgbEncode(proxy);
    proxy = NrSignalBound(proxy);
    if (encoding == 1) return NrSignalBound(NrSignalSrgbEncode(proxy));
    if (encoding == 2) return proxy;
    return NrSignalBound(NrSignalPqEncode(proxy)); // admitted PQSDR=3
}

NR_SIGNAL_SCALAR NrSignalDecodeChannel(NR_SIGNAL_SCALAR code, uint encoding, bool passthrough)
{
    if (passthrough) return code;
    if (encoding == 0) return NrSignalSrgbDecode(code);
    code = NrSignalBound(code);
    if (encoding == 1) return NrSignalBound(NrSignalSrgbDecode(code));
    if (encoding == 2) return code;
    // Model code clips before EOTF; proxy clips again before restoration.
    // The denominator pole at code ~1.99206 is unreachable after clipping.
    // Code 1 is 10000 nits (proxy 100), explicitly saturated to proxy 1.
    return NrSignalBound(NrSignalPqDecode(code)); // admitted PQSDR=3
}

NR_SIGNAL_RGB NrSignalEncodeRgb(NR_SIGNAL_RGB proxy, uint encoding, bool passthrough)
{
    return NR_SIGNAL_RGB(NrSignalEncodeChannel(proxy.x, encoding, passthrough),
                         NrSignalEncodeChannel(proxy.y, encoding, passthrough),
                         NrSignalEncodeChannel(proxy.z, encoding, passthrough));
}

NR_SIGNAL_RGB NrSignalDecodeRgb(NR_SIGNAL_RGB code, uint encoding, bool passthrough)
{
    return NR_SIGNAL_RGB(NrSignalDecodeChannel(code.x, encoding, passthrough),
                         NrSignalDecodeChannel(code.y, encoding, passthrough),
                         NrSignalDecodeChannel(code.z, encoding, passthrough));
}

NR_SIGNAL_RGBA NrSignalEncode(NR_SIGNAL_RGBA proxy, uint encoding, bool passthrough)
{
    NR_SIGNAL_RGB rgb = NrSignalEncodeRgb(NR_SIGNAL_RGB(proxy.x, proxy.y, proxy.z), encoding, passthrough);
    return NR_SIGNAL_RGBA(rgb.x, rgb.y, rgb.z, proxy.w);
}

NR_SIGNAL_RGBA NrSignalDecode(NR_SIGNAL_RGBA code, uint encoding, bool passthrough)
{
    NR_SIGNAL_RGB rgb = NrSignalDecodeRgb(NR_SIGNAL_RGB(code.x, code.y, code.z), encoding, passthrough);
    return NR_SIGNAL_RGBA(rgb.x, rgb.y, rgb.z, code.w);
}

#ifdef NR_SIGNAL_DEFAULT_TYPES
#undef NR_SIGNAL_DEFAULT_TYPES
#undef NR_SIGNAL_SCALAR
#undef NR_SIGNAL_RGB
#undef NR_SIGNAL_RGBA
#undef NR_SIGNAL_EXPONENT_MASK
#endif
#endif
