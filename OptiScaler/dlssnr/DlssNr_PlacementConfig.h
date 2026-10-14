#pragma once

#include <Config.h>
#include <SimpleIni.h>
#include "DlssNr_Status.h"

namespace DlssNr
{
enum class PlacementCheckbox { Before, Finished, Deferred };

// Only actual checkbox changes enter this seam. Preserve the checkbox-specific
// retained transitions rather than normalizing them through direct selection.
inline bool EditPlacementCheckbox(Config& config, PlacementCheckbox checkbox, bool value)
{
    const bool finished = config.DlssNrFinishedPicture.value_or_default();
    const auto placement = ResolvePlacement(config.DlssNrRunBeforeSr.value_or_default(),
        config.DlssNrDeferredDlss.value_or_default(), config.DlssNrResidualAcrossRr.value_or_default(), finished);
    if (checkbox == PlacementCheckbox::Before)
    {
        if (placement.deferred || value == placement.beforeUpscale)
            return false;
        config.DlssNrRunBeforeSr = value;
        config.DlssNrResidualAcrossRr = false;
    }
    else if (checkbox == PlacementCheckbox::Finished)
    {
        if (value == finished)
            return false;
        config.DlssNrFinishedPicture = value;
    }
    else
    {
        if (value == placement.deferred)
            return false;
        config.DlssNrDeferredDlss = value;
        config.DlssNrResidualAcrossRr = false;
        if (value || finished)
            config.DlssNrRunBeforeSr = value;
    }
    const auto edited = ResolvePlacement(config.DlssNrRunBeforeSr.value_or_default(),
        config.DlssNrDeferredDlss.value_or_default(), config.DlssNrResidualAcrossRr.value_or_default(),
        config.DlssNrFinishedPicture.value_or_default());
    if (!edited.deferred)
    {
        config.DlssNrResidualAcrossRr = false;
        config.DlssNrAutomaticUICorrection = true;
    }
    RetryAfterFailure();
    return true;
}

inline void LoadOptionsConfig(Config& config, CSimpleIniA& ini)
{
    config.DlssNrInputFilter.set_from_config(
        ReadOptionToken<InputFilter>(ini.GetValue("DlssNr", "InputFilter"), InputFilterNames));
    config.DlssNrSignalEncoding.set_from_config(
        ReadOptionToken<SignalEncoding>(ini.GetValue("DlssNr", "SignalEncoding"), SignalEncodingNames));
}

inline void SaveOptionsConfig(Config& config, CSimpleIniA& ini)
{
    const auto filter = config.DlssNrInputFilter.value_for_config();
    const auto signal = config.DlssNrSignalEncoding.value_for_config();
    ini.SetValue("DlssNr", "InputFilter", filter ? InputFilterNames[static_cast<unsigned>(*filter)] : "auto");
    ini.SetValue("DlssNr", "SignalEncoding", signal ? SignalEncodingNames[static_cast<unsigned>(*signal)] : "auto");
}

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
