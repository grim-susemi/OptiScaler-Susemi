#pragma once

#include <Config.h>
#include <SimpleIni.h>

namespace DlssNr
{
// The production placement load/save seam is shared with the owned INI fixture.
// Like Config::readBool, only true/false (case insensitive) are accepted.
inline std::optional<bool> ReadPlacementBool(CSimpleIniA& ini, const char* key)
{
    const char* value = ini.GetValue("DlssNr", key, "auto");
    if (lstrcmpiA(value, "true") == 0)
        return true;
    if (lstrcmpiA(value, "false") == 0)
        return false;
    return std::nullopt;
}

inline void LoadPlacementConfig(Config& config, CSimpleIniA& ini)
{
    auto before = ReadPlacementBool(ini, "RunBeforeSR");
    if (!before.has_value())
        before = ReadPlacementBool(ini, "BeforeUpscale");
    config.DlssNrRunBeforeSr.set_from_config(before);
    config.DlssNrFinishedPicture.set_from_config(ReadPlacementBool(ini, "FinishedPicture"));
    config.DlssNrDeferredDlss.set_from_config(ReadPlacementBool(ini, "DeferredDLSS"));
    config.DlssNrResidualAcrossRr.set_from_config(ReadPlacementBool(ini, "ResidualAcrossRR"));
    config.DlssNrAutomaticUICorrection.set_from_config(ReadPlacementBool(ini, "AutomaticUICorrection"));
}

inline void SavePlacementConfig(Config& config, CSimpleIniA& ini)
{
    const auto write = [&](const char* key, std::optional<bool> value)
    {
        ini.SetValue("DlssNr", key, !value.has_value() ? "auto" : *value ? "true" : "false");
    };
    // A retained BeforeUpscale alias must not override canonical default false.
    write("RunBeforeSR", ini.GetValue("DlssNr", "BeforeUpscale") != nullptr
                            ? std::optional<bool>(config.DlssNrRunBeforeSr.value_or_default())
                            : config.DlssNrRunBeforeSr.value_for_config());
    write("FinishedPicture", config.DlssNrFinishedPicture.value_for_config());
    write("DeferredDLSS", config.DlssNrDeferredDlss.value_for_config());
    write("ResidualAcrossRR", config.DlssNrResidualAcrossRr.value_for_config());
    write("AutomaticUICorrection", config.DlssNrAutomaticUICorrection.value_for_config());
}
} // namespace DlssNr
