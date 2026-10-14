#pragma once
#include <framegen/dlssg/MfgUnlockStatus.h>
#include <framegen/dlssg/MfgUnlockProvider.h>
#include <optional>
#include <sstream>
#include <iomanip>
#include <filesystem>

namespace DlssNr::MfgDiagnostics
{
struct Module
{
    bool loaded = false;
    std::wstring path;
    std::string sha256;
    std::string version;
};
struct Inputs
{
    Module optiscaler, provider, streamline, plugin, driverDispatcher;
    std::optional<std::string> adapter;
    std::optional<std::string> driverStore;
    bool statusAvailable = false;
    MfgUnlock::Status status;
    MfgUnlock::TemporalMethod configured = MfgUnlock::TemporalMethod::None;
    bool configuredAvailable = false;
    std::string label;
    unsigned run = 0;
    unsigned workerThread = 0;
    LUID adapterLuid {};
};
struct Report
{
    Inputs inputs;
    bool builtInUnlock = false;
    bool providerOta = false;
    bool identityMatched = false;
    bool identityMismatch = false;
    bool correctionActivity = false;
    bool optionsSeen = false, stateSeen = false, active = false;
    unsigned requested = 0, sent = 0, result = 0, presented = 0, maxPresented = 0;
};

// The production adapter projects existing facts, never requests a mode or patches a module.
inline Report Read(const Inputs& inputs, const MfgUnlock::Telemetry* telemetry)
{
    Report report;
    report.inputs = inputs;
#if defined(OPTISCALER_RTX40_MFG)
    report.builtInUnlock = true;
#endif
    const auto actual = MfgUnlock::Provider::NormalisePath(inputs.provider.path);
    const auto recorded = MfgUnlock::Provider::NormalisePath(inputs.status.ModulePath);
    report.providerOta = actual.find(L"\\models\\dlssg\\") != std::wstring::npos;
    report.identityMismatch = inputs.statusAvailable && inputs.status.ModuleFound &&
                              ((!actual.empty() && !recorded.empty() && actual != recorded) ||
                               (!inputs.provider.version.empty() && !inputs.status.SnippetVersion.empty() &&
                                inputs.provider.version != inputs.status.SnippetVersion));
    report.identityMatched = inputs.provider.loaded && !actual.empty() && !recorded.empty() &&
                             actual == recorded && inputs.provider.sha256.size() == 64 &&
                             inputs.statusAvailable && inputs.status.ModuleFound && !report.identityMismatch;
    report.correctionActivity = report.builtInUnlock && report.identityMatched &&
                                inputs.status.AdvertiseMatched && inputs.status.ValidateMatched &&
                                inputs.status.KernelsRewritten > 0 &&
                                inputs.status.TemporalAttempted != MfgUnlock::TemporalMethod::None;
    if (telemetry && report.builtInUnlock)
    {
        report.optionsSeen = telemetry->optionsSeen.load(std::memory_order_acquire);
        if (report.optionsSeen)
        {
            report.active = telemetry->active.load(std::memory_order_relaxed);
            report.requested = telemetry->requested.load(std::memory_order_relaxed);
            report.sent = telemetry->sent.load(std::memory_order_relaxed);
            report.result = telemetry->result.load(std::memory_order_relaxed);
        }
        report.stateSeen = telemetry->stateSeen.load(std::memory_order_acquire);
        if (report.stateSeen)
        {
            report.presented = telemetry->presented.load(std::memory_order_relaxed);
            report.maxPresented = telemetry->maxPresented.load(std::memory_order_relaxed);
        }
    }
    return report;
}

inline std::string Utf8(std::wstring_view value)
{
    if (value.empty()) return {};
    const auto count = WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0, nullptr, nullptr);
    std::string text(count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), text.data(), count, nullptr, nullptr);
    return text;
}
inline void String(std::ostream& out, std::string_view value)
{
    out << '"';
    for (unsigned char c : value)
    {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 0x20) out << "\\u00" << "0123456789abcdef"[c >> 4] << "0123456789abcdef"[c & 15];
        else out << c;
    }
    out << '"';
}
inline void WriteModule(std::ostream& out, const Module& module)
{
    out << "{\"loaded\":" << module.loaded << ",\"path\":";
    if (module.path.empty()) out << "null"; else String(out, Utf8(module.path));
    out << ",\"sha256\":";
    if (module.sha256.size() != 64) out << "null"; else String(out, module.sha256);
    out << ",\"version\":";
    if (module.version.empty()) out << "null"; else String(out, module.version);
    out << '}';
}
inline std::string Json(const Report& report)
{
    std::ostringstream out;
    out << std::boolalpha << "{\"schema\":\"nr-mfg-preflight-v1\","
           "\"observationScope\":\"worker-time-metadata-not-frame-phase\",\"label\":";
    String(out, report.inputs.label);
    out << ",\"run\":" << report.inputs.run << ",\"workerThread\":" << report.inputs.workerThread
        << ",\"adapterLuidHigh\":" << report.inputs.adapterLuid.HighPart
        << ",\"adapterLuidLow\":" << report.inputs.adapterLuid.LowPart << ",\"buildFlavor\":";
    String(out, report.builtInUnlock ? "rtx40-mfg" : "plain");
    out << ",\"builtInUnlockCompiled\":" << report.builtInUnlock
        << ",\"statusAvailable\":" << report.inputs.statusAvailable
        << ",\"identityMatched\":" << report.identityMatched
        << ",\"identityMismatch\":" << report.identityMismatch
        << ",\"providerOta\":" << report.providerOta
        << ",\"correctionActivity\":" << report.correctionActivity
        << ",\"qualityFixProven\":false,\"displayTimingAvailable\":false,"
           "\"hashScope\":\"current-file-not-mapped-image\",\"telemetryAtomicity\":\"independent-last-values\","
           "\"modules\":{\"optiscaler\":";
    WriteModule(out, report.inputs.optiscaler);
    out << ",\"provider\":"; WriteModule(out, report.inputs.provider);
    out << ",\"streamline\":"; WriteModule(out, report.inputs.streamline);
    out << ",\"plugin\":"; WriteModule(out, report.inputs.plugin);
    out << ",\"driverDispatcher\":"; WriteModule(out, report.inputs.driverDispatcher);
    out << "},\"adapter\":";
    if (report.inputs.adapter) String(out, *report.inputs.adapter); else out << "null";
    out << ",\"driverStore\":";
    if (report.inputs.driverStore) String(out, *report.inputs.driverStore); else out << "null";
    out << ",\"driverVersion\":null,\"configuredTemporalMethod\":";
    if (report.inputs.configuredAvailable) out << unsigned(report.inputs.configured); else out << "null";
    out << ",\"attemptedTemporalMethod\":" << unsigned(report.inputs.status.TemporalAttempted)
        << ",\"kernelsRewritten\":" << report.inputs.status.KernelsRewritten
        << ",\"advertiseMatched\":" << report.inputs.status.AdvertiseMatched
        << ",\"validateMatched\":" << report.inputs.status.ValidateMatched
        << ",\"temporalDetail\":";
    String(out, report.inputs.status.TemporalDetail);
    out << ",\"statusProviderPath\":"; String(out, Utf8(report.inputs.status.ModulePath));
    out << ",\"statusProviderVersion\":"; String(out, report.inputs.status.SnippetVersion);
    out << ",\"pluginCeilingRaw\":"; String(out, report.inputs.status.PluginCeiling);
    out << ",\"pacingRaw\":"; String(out, report.inputs.status.FlipMetering);
    out << ",\"pacingRequested\":" << report.inputs.status.FlipRequested
        << ",\"pacingSites\":" << report.inputs.status.FlipSites
        << ",\"optionsSeen\":" << report.optionsSeen << ",\"stateSeen\":" << report.stateSeen
        << ",\"active\":";
    if (report.optionsSeen) out << report.active; else out << "null";
    for (auto [name, value] : { std::pair{"requested", report.requested}, {"sent", report.sent}, {"optionResultRaw", report.result} })
    {
        out << ",\"" << name << "\":";
        if (report.optionsSeen) out << value; else out << "null";
    }
    out << ",\"presented\":";
    if (report.stateSeen) out << report.presented; else out << "null";
    out << ",\"maxPresented\":";
    if (report.stateSeen) out << report.maxPresented; else out << "null";
    out << '}';
    return out.str();
}
}
