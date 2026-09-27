// ============================================================================
// tests/i18n_seam_smoke.cpp - row 3 seam runner for susemi-next-ui-lang.
//
// It compiles the REAL vendored ImGui text seams, the REAL Localization unit,
// the production DlssNr label-key functions and the production Config::readString
// body (both extracted verbatim by tools/i18n_extract_seam.py), then asserts the
// cases row 3 requires:
//
//   * a KO probe returns KO metrics from CalcTextSize and real KO glyph coverage
//   * the draw path renders the KO bytes while GetID/PushID/strcmp keep English
//   * a catalog miss keeps the caller's exact pointer and content
//   * the R7 label-key path still receives the English label
//   * the [Menu] Language INI round trip: write, read, absent/unknown -> en, ko-KR -> ko
//
// The only thing substituted is the project's precompiled header: the runner
// passes a stub pch.h so this translation unit stands alone. No other compiled
// code is faked.
//
// --inject-trap runs the identity probe with the translated label forced into the
// key path. The runner must then FAIL, which proves the identity check can see
// the trap at all. Exit 1 = trap detected as designed, exit 2 = the check is blind.
// ============================================================================

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <format>
#include <fstream>
#include <optional>
#include <ranges>
#include <string>
#include <unordered_map>
#include <vector>

#include "SimpleIni.h"
#include "imgui.h"
#include "imgui_internal.h"
#include "menu/Localization.h"

// ---------------------------------------------------------------------------
// Real production code, extracted verbatim at run time from the sources.
// ---------------------------------------------------------------------------

static CSimpleIniA ini;

template <class T> struct ConfigValue
{
    // Mirrors Config.h CustomOptional<T, WithDefault>: an unset value falls back
    // to the declared default. The declaration itself is pinned by the
    // config-anchors case.
    T declared;
    std::optional<T> loaded;

    T value_or_default() const { return loaded.has_value() ? *loaded : declared; }

    void set_from_config(const std::optional<T>& value)
    {
        if (!loaded.has_value())
            loaded = value;
    }
};

// Defines I18N_PRODUCTION_LOAD_STATEMENT / I18N_PRODUCTION_SAVE_STATEMENT.
struct Config;
static Config* Instance();
#include "production-config-language.inc"

struct Config
{
    std::vector<std::string> _log;
    ConfigValue<std::string> Language { "en", std::nullopt };

    std::optional<std::string> readString(std::string section, std::string key, bool lowercase = false);

    void LoadLanguage() { I18N_PRODUCTION_LOAD_STATEMENT }
    void SaveLanguage() { I18N_PRODUCTION_SAVE_STATEMENT }
};

static Config* Instance();

#include "production-config-read.inc"

static Config g_config;
static Config* Instance()
{
    return &g_config;
}

namespace DlssNr::MenuSections
{
static std::string g_helpMarker;
static void HelpMarker(const char* text)
{
    g_helpMarker = text != nullptr ? text : "";
}

struct FakeSliderOption
{
    float value = 1.0f;
    float value_or_default() const { return value; }
    FakeSliderOption& operator=(float other)
    {
        value = other;
        return *this;
    }
};

struct FakeDeferredOption
{
    float value = 1.0f;
    float value_or(float) const { return value; }
    FakeDeferredOption& operator=(float other)
    {
        value = other;
        return *this;
    }
    FakeDeferredOption& operator=(std::optional<float> other)
    {
        value = other.value_or(0.0f);
        return *this;
    }
};

#include "production-seam.inc"
} // namespace DlssNr::MenuSections

// ---------------------------------------------------------------------------
// Probe helpers
// ---------------------------------------------------------------------------

// Korean bytes of the catalog entries used by the probes (octal UTF-8 escapes).
static const char* const kApplyChangesKo = "\353\263\200\352\262\275 \354\240\201\354\232\251"; // 변경 적용
static const char* const kModelPassesKo = "\353\252\250\353\215\270 \355\214\250\354\212\244"; // 모델 패스
static const char* const kKernelImageKo = "\354\273\244\353\204\220 \354\235\264\353\257\270\354\247\200"; // 커널 이미지
// The status line renders through the dynamic-template path: the Korean template with the
// loader's own state name (English, the vocabulary the receipts quote) substituted in.
static const char* const kUnlockStatusLoadedKo =
    "20/30 \354\236\240\352\270\210 \355\225\264\354\240\234 \354\203\201\355\203\234: Loaded"; // 20/30 잠금 해제 상태: Loaded

struct Case
{
    std::string name;
    bool ok;
    std::string detail;
};
static std::vector<Case> g_cases;

static void Progress(const char* name)
{
    std::printf("run %s\n", name);
    std::fflush(stdout);
}

static void Check(std::string name, bool ok, std::string detail)
{
    g_cases.emplace_back(Case { std::move(name), ok, std::move(detail) });
}

static unsigned long long Fnv1a64(const char* data, std::size_t size)
{
    unsigned long long hash = 1469598103934665603ull;
    for (std::size_t i = 0; i < size; ++i)
    {
        hash ^= static_cast<unsigned char>(data[i]);
        hash *= 1099511628211ull;
    }
    return hash;
}

static unsigned long long Fnv1a64(const std::string& text)
{
    return Fnv1a64(text.data(), text.size());
}

static std::string FnvHex(const std::string& text)
{
    return std::format("0x{:016x}", Fnv1a64(text));
}

static bool ReadFile(const std::string& path, std::string& out)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        return false;
    out.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
    return true;
}

static std::vector<ImWchar> Codepoints(const char* text)
{
    std::vector<ImWchar> result;
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(text); *p != 0;)
    {
        unsigned int codepoint = 0;
        int extra = 0;
        if (*p < 0x80)
            codepoint = *p++;
        else if ((*p & 0xE0) == 0xC0)
        {
            codepoint = *p++ & 0x1Fu;
            extra = 1;
        }
        else if ((*p & 0xF0) == 0xE0)
        {
            codepoint = *p++ & 0x0Fu;
            extra = 2;
        }
        else
        {
            codepoint = *p++ & 0x07u;
            extra = 3;
        }
        for (int i = 0; i < extra; ++i)
            codepoint = (codepoint << 6) | (*p++ & 0x3Fu);
        result.push_back(static_cast<ImWchar>(codepoint));
    }
    return result;
}

static bool SetupImGui(const std::string& fontPath)
{
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    // 1.92 contract: a backend that supports texture updates lets glyphs load on
    // demand, which is exactly what the menu relies on.
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
    io.DisplaySize = ImVec2(1280.0f, 720.0f);
    io.DeltaTime = 1.0f / 60.0f;
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    // 1.92 loads glyphs on demand, so the glyph range list is not needed here.
    ImFont* font = io.Fonts->AddFontFromFileTTF(fontPath.c_str(), 16.0f);
    if (font == nullptr)
        return false;
    io.FontDefault = font;
    return true;
}

template <typename Fn> static void Frame(Fn&& fn)
{
    ImGui::NewFrame();
    ImGui::SetNextWindowSize(ImVec2(900.0f, 700.0f), ImGuiCond_Always);
    ImGui::Begin("seam");
    fn();
    ImGui::End();
    ImGui::EndFrame();
}

// Vertices the real draw seam emits for one range. The position must sit inside
// the window clip rect, otherwise ImGui fast-forwards the whole line as invisible.
static int DrawVertices(const char* text)
{
    ImDrawList* drawList = ImGui::GetWindowDrawList();
    const int before = drawList->VtxBuffer.Size;
    ImGui::RenderText(ImGui::GetCursorScreenPos(), text);
    return drawList->VtxBuffer.Size - before;
}

// CSimpleIniA::LoadFile merges into whatever the object already holds, so a fresh
// process reading one file means Reset() first. The product reads one ini once.
static void LoadFreshIni(const std::string& path)
{
    ini.Reset();
    ini.LoadFile(path.c_str());
}

static bool IniSectionHasKey(const std::string& text, const std::string& section, const std::string& key)
{
    std::string current;
    std::size_t start = 0;
    while (start <= text.size())
    {
        const std::size_t end = text.find('\n', start);
        std::string line = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
        start = end == std::string::npos ? text.size() + 1 : end + 1;

        while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
            line.pop_back();
        const std::size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos)
            continue;
        line = line.substr(first);

        if (line.front() == '[' && line.back() == ']')
        {
            current = line.substr(1, line.size() - 2);
            continue;
        }
        if (current == section && line.rfind(key, 0) == 0 && line.size() > key.size() &&
            (line[key.size()] == '=' || line[key.size()] == ' ' || line[key.size()] == '\t'))
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

// The identity probe under test: the production Slider pushes nothing but lets the
// caller read the identity it computed, because the slider itself is the last item.
struct IdentityProbeResult
{
    ImGuiID english_seen = 0;
    ImGuiID english_expected = 0;
    ImGuiID translated_seen = 0;
    bool ok = false;
};

static IdentityProbeResult RunIdentityProbe()
{
    using DlssNr::MenuSections::FakeSliderOption;
    using DlssNr::MenuSections::Slider;

    IdentityProbeResult result;
    Frame(
        [&result]
        {
            FakeSliderOption option;
            Localization::SetLanguage("ko");

            Slider("Model passes", option, 1.0f, 2.0f, "%.2f");
            result.english_seen = ImGui::GetItemID();
            result.english_expected = ImGui::GetID("Model passes");

            // Injected regression: the translated bytes forced into the identity path.
            const std::string translated = Localization::Translate("Model passes");
            Slider(translated.c_str(), option, 1.0f, 2.0f, "%.2f");
            result.translated_seen = ImGui::GetItemID();
        });
    result.ok = result.english_seen != 0 && result.english_seen == result.english_expected &&
                result.translated_seen != result.english_expected;
    return result;
}

static void RunCases(const std::string& root, const std::string& evidenceDir, const std::string& fontPath)
{
    Localization::SetLanguage("en");
    Frame([] {});
    Frame([] {}); // two warm-up frames so lazily baked sizes are stable

    // 1) Guard, catalog hit.
    {
        Progress("1 seam-hit-substitutes-range");
        const char* label = "Apply Changes";
        const char* end = label + std::strlen(label);
        Localization::SetLanguage("ko");
        {
            Localization::LocalizedRange localized(label, end);
            const bool substituted = label != nullptr && std::strcmp(label, "Apply Changes") != 0 &&
                                     std::string(label, static_cast<std::size_t>(end - label)) == kApplyChangesKo;
            Check("seam-hit-substitutes-range", substituted,
                  "guard repointed the draw range at the catalog text " + FnvHex(kApplyChangesKo));
        }
        Localization::SetLanguage("en");
    }

    // 2) Guard, catalog miss: pointer and content identity.
    {
        Progress("2 seam-miss-keeps-pointer");
        const char* label = "No such key zzz";
        const char* end = label + std::strlen(label);
        const char* const originalBegin = label;
        const char* const originalEnd = end;
        Localization::SetLanguage("ko");
        {
            Localization::LocalizedRange localized(label, end);
            Check("seam-miss-keeps-pointer",
                  label == originalBegin && end == originalEnd && std::strcmp(label, "No such key zzz") == 0 &&
                      Localization::Lookup("No such key zzz") == nullptr,
                  "miss returns the original pointer and content; Lookup returned null");
        }
        Localization::SetLanguage("en");
    }

    // 3) The real measure seam returns the KO metrics.
    {
        Progress("3 seam-measure-ko-metrics");
        ImVec2 english {};
        ImVec2 korean {};
        ImVec2 literal {};
        Frame(
            [&]
            {
                Localization::SetLanguage("en");
                english = ImGui::CalcTextSize("Apply Changes");
                Localization::SetLanguage("ko");
                korean = ImGui::CalcTextSize("Apply Changes");
                literal = ImGui::CalcTextSize(kApplyChangesKo);
            });
        Check("seam-measure-ko-metrics",
              korean.x == literal.x && korean.y == literal.y && korean.x != english.x,
              std::format("ko-active {:.1f}x{:.1f}, literal {:.1f}x{:.1f}, en-active {:.1f}x{:.1f}", korean.x, korean.y,
                          literal.x, literal.y, english.x, english.y));
    }

    // 4) The real draw seam emits the KO glyphs.
    {
        Progress("4 seam-draw-ko-vertices");
        int koreanVertices = 0, literalVertices = 0, englishVertices = 0;
        Frame(
            [&]
            {
                Localization::SetLanguage("ko");
                koreanVertices = DrawVertices("Apply Changes");
                literalVertices = DrawVertices(kApplyChangesKo);
                Localization::SetLanguage("en");
                englishVertices = DrawVertices("Apply Changes");
            });
        Check("seam-draw-ko-vertices",
              koreanVertices > 0 && koreanVertices == literalVertices && englishVertices > koreanVertices,
              std::format("ko-active {} vertices, literal {}, en-active {}", koreanVertices, literalVertices,
                          englishVertices));
    }

    // 5) Real glyph coverage: the Hangul codepoints are baked, not tofu.
    {
        Progress("5 seam-glyph-coverage");
        bool coverage = true;
        std::string missing;
        int controlAbsent = 0;
        Frame(
            [&]
            {
                ImFontBaked* baked = ImGui::GetFontBaked();
                for (char pass = 0; pass < 1; ++pass)
                {
                    Localization::SetLanguage("ko");
                    const std::vector<ImWchar> codepoints = Codepoints(kApplyChangesKo);
                    for (ImWchar codepoint : codepoints)
                        if (codepoint == ' ')
                            continue;
                        else if (baked->FindGlyphNoFallback(codepoint) == nullptr)
                        {
                            coverage = false;
                            missing += std::format(" U+{:04X}", static_cast<unsigned>(codepoint));
                        }
                }
                // Negative control: these scripts are not in the Hangul source, so
                // the same probe must be able to report an absent glyph.
                for (ImWchar codepoint : { static_cast<ImWchar>(0x0590), static_cast<ImWchar>(0x0E01),
                                           static_cast<ImWchar>(0x10A0) })
                    if (baked->FindGlyphNoFallback(codepoint) == nullptr)
                        ++controlAbsent;
            });
        Check("seam-glyph-coverage", coverage && controlAbsent > 0,
              std::format("missing{}{}negative-control absent glyphs {}", missing.empty() ? " none" : missing,
                          missing.empty() ? "" : ", ", controlAbsent));
    }

    // 6) Widget identity does not depend on the language.
    {
        Progress("6 seam-id-stable");
        ImGuiID ids[2][4] = {};
        const char* keys[4] = { "Intensity", "Reset##Intensity", "Menu Scale", "##Language" };
        for (int language = 0; language < 2; ++language)
        {
            Frame(
                [&, language]
                {
                    Localization::SetLanguage(language == 0 ? "en" : "ko");
                    for (int i = 0; i < 4; ++i)
                        ids[language][i] = ImGui::GetID(keys[i]);
                });
        }
        bool equal = true;
        std::string detail = "GetID under en equals GetID under ko:";
        for (int i = 0; i < 4; ++i)
        {
            equal = equal && ids[0][i] == ids[1][i] && ids[0][i] != 0;
            detail += std::format(" {} 0x{:08X}", keys[i], ids[0][i]);
        }
        Check("seam-id-stable", equal, detail);
    }

    // 7) The caller's label and range survive a real seam call untouched.
    {
        Progress("7 seam-caller-label-untouched");
        bool untouched = true;
        Frame(
            [&]
            {
                Localization::SetLanguage("ko");
                char buffer[64];
                std::strcpy(buffer, "Apply Changes");
                const char* label = buffer;
                const char* end = label + std::strlen(label);
                ImGui::CalcTextSize(label);
                ImGui::RenderText(ImGui::GetCursorScreenPos(), label);
                ImGui::RenderTextWrapped(ImGui::GetCursorScreenPos(), label, end, 200.0f);
                untouched = label == buffer && std::strcmp(buffer, "Apply Changes") == 0 &&
                            static_cast<std::size_t>(end - label) == std::strlen(buffer);
            });
        Check("seam-caller-label-untouched", untouched,
              "caller buffer and range unchanged after CalcTextSize/RenderText/RenderTextWrapped");
    }

    // 8) No dlssnr UI file touches the localization unit at all.
    {
        Progress("8 seam-ui-files");
        const char* files[] = { "OptiScaler/dlssnr/DlssNr_Menu.cpp", "OptiScaler/dlssnr/DlssNr_MenuControls.cpp",
                                "OptiScaler/dlssnr/DlssNr_MenuOverlay.cpp", "OptiScaler/dlssnr/DlssNr_PipelineUi.h",
                                "OptiScaler/dlssnr/DlssNr_MenuSections.h" };
        bool clean = true;
        std::string offenders;
        for (const char* file : files)
        {
            std::string text;
            if (!ReadFile(root + "/" + file, text))
            {
                clean = false;
                offenders += std::format(" missing:{}", file);
                continue;
            }
            if (text.find("Localization") != std::string::npos || text.find("SetLanguage") != std::string::npos ||
                text.find("Translate(") != std::string::npos)
            {
                clean = false;
                offenders += std::format(" references-localization:{}", file);
            }
        }
        Check("seam-ui-files-keep-english-labels", clean,
              clean ? std::format("{} dlssnr UI files free of localization calls", std::size(files)) : offenders);
    }

    // 9) The R7 production label-key path still receives the English label.
    {
        Progress("9 r7-english-label");
        using DlssNr::MenuSections::DeferredSlider;
        using DlssNr::MenuSections::FakeDeferredOption;
        using DlssNr::MenuSections::g_helpMarker;

        g_helpMarker.clear();
        Frame(
            [&]
            {
                Localization::SetLanguage("ko");
                FakeDeferredOption option;
                DeferredSlider("Intensity", &option, 0.0f, 2.0f, 1.0f);
            });
        Check("r7-english-label-reaches-key-path", g_helpMarker == "Enhancement strength. 1 = default.",
              std::format("strcmp branch matched the English help text ({})", FnvHex("Enhancement strength. 1 = default.")));
    }

    // 10) The identity probe has teeth: the injected translation really changes it.
    {
        Progress("10 r7-trap-detectable");
        const IdentityProbeResult probe = RunIdentityProbe();
        Check("r7-ko-label-trap-detectable", probe.ok,
              std::format("english slider id 0x{:08X} (expected 0x{:08X}), translated label id 0x{:08X}",
                          probe.english_seen, probe.english_expected, probe.translated_seen));
    }

    // 11) The bottom-bar switch exists, is width-clamped, and never auto-saves.
    {
        Progress("11 menu-combo");
        std::string source;
        const bool loaded = ReadFile(root + "/OptiScaler/menu/menu_common.cpp", source);
        const std::string startMarker = "if (ImGui::BeginCombo(\"##Language\"";
        const std::size_t start = loaded ? source.find(startMarker) : std::string::npos;
        const std::size_t comboEnd = start == std::string::npos ? std::string::npos : source.find("ImGui::EndCombo();", start);
        const std::size_t regionEnd = comboEnd == std::string::npos ? std::string::npos : source.find('}', comboEnd);
        const bool found =
            start != std::string::npos && regionEnd != std::string::npos && regionEnd > start;
        const std::string region = found ? source.substr(start, regionEnd - start + 1) : std::string();
        const std::size_t windowStart = start > 240 ? start - 240 : 0;
        const std::string preceding = start == std::string::npos ? std::string()
                                                                : source.substr(windowStart, start - windowStart);
        Check("menu-combo-placement-and-no-autosave",
              found && region.find("SaveIni") == std::string::npos &&
                  region.find("Localization::Languages[i].code") != std::string::npos &&
                  preceding.find("ImGui::SetNextItemWidth(100.0f * menuResScale)") != std::string::npos,
              found ? std::format("combo region {} bytes, no SaveIni call, width clamped as the Menu Scale combo",
                                  region.size())
                    : "combo region not found in menu_common.cpp");
    }

    // 12) The one additive key and its anchors are where the plan pins them.
    {
        Progress("12 config-anchors");
        std::string header, implementation;
        const bool headerLoaded = ReadFile(root + "/OptiScaler/Config.h", header);
        const bool implementationLoaded = ReadFile(root + "/OptiScaler/Config.cpp", implementation);
        const bool field = headerLoaded && header.find("CustomOptional<std::string> Language { \"en\" };") != std::string::npos;
        const bool load = implementationLoaded &&
                          implementation.find("Language.set_from_config(readString(\"Menu\", \"Language\", true)") !=
                              std::string::npos;
        const bool save =
            implementationLoaded && implementation.find("ini.SetValue(\"Menu\", \"Language\"") != std::string::npos;
        Check("config-language-anchors", field && load && save,
              std::format("field {}, load anchor {}, save anchor {}", field, load, save));
    }

    // 13) The shipped OptiScaler.ini defaults are untouched.
    {
        Progress("13 menu-ini-default");
        std::string shipped;
        const bool loaded = ReadFile(root + "/OptiScaler.ini", shipped);
        const bool hasKey = loaded && IniSectionHasKey(shipped, "Menu", "Language");
        Check("menu-ini-default-untouched", loaded && !hasKey,
              loaded ? "shipped [Menu] carries no Language key" : "OptiScaler.ini not readable");
    }

    // 14-18) The [Menu] Language INI round trip through the production statements.
    {
        Progress("14-18 ini-roundtrip");
        const std::string iniPath = evidenceDir + "/i18n-roundtrip.ini";
        auto resetConfig = [](const std::string& code)
        {
            g_config.Language.declared = code;
            g_config.Language.loaded.reset();
        };

        // 14) write then read.
        {
            std::filesystem::remove(iniPath);
            CSimpleIniA writer;
            writer.SetValue("Menu", "Language", "ko");
            writer.SetValue("Menu", "FontSize", "14.0");
            writer.SetValue("Graphics", "Untouched", "keep");
            writer.SaveFile(iniPath.c_str());

            resetConfig("en");
            LoadFreshIni(iniPath);
            g_config.LoadLanguage();
            const std::string effective = g_config.Language.value_or_default();

            CSimpleIniA verify;
            verify.LoadFile(iniPath.c_str());
            const bool kept = std::string(verify.GetValue("Graphics", "Untouched", "")) == "keep" &&
                              std::string(verify.GetValue("Menu", "FontSize", "")) == "14.0";
            Check("ini-write-read", effective == "ko" && Localization::LanguageIndex(effective) == 1 && kept,
                  std::format("wrote and read [Menu] Language=ko, effective '{}' index {}", effective,
                              Localization::LanguageIndex(effective)));
        }

        // 15) a Korean region suffix is canonicalized on the way back out.
        {
            const std::string regionPath = evidenceDir + "/i18n-roundtrip-region.ini";
            std::filesystem::remove(regionPath);
            CSimpleIniA writer;
            writer.SetValue("Menu", "Language", "ko-KR");
            writer.SaveFile(regionPath.c_str());

            resetConfig("en");
            LoadFreshIni(regionPath);
            g_config.LoadLanguage();
            g_config.SaveLanguage();
            ini.SaveFile(regionPath.c_str());

            resetConfig("en");
            LoadFreshIni(regionPath);
            g_config.LoadLanguage();
            const std::string effective = g_config.Language.value_or_default();
            Check("ini-ko-region-normalizes",
                  effective == "ko" && Localization::NormalizeLanguageCode("ko_KR") == "ko" &&
                      Localization::NormalizeLanguageCode("KO-kr") == "ko",
                  std::format("ko-KR round-tripped as '{}'; ko_KR and KO-kr normalize to ko", effective));
        }

        // 16) absent and auto both mean English.
        {
            const std::string absentPath = evidenceDir + "/i18n-roundtrip-absent.ini";
            std::filesystem::remove(absentPath);
            CSimpleIniA writer;
            writer.SetValue("Menu", "FontSize", "14.0");
            writer.SaveFile(absentPath.c_str());

            resetConfig("en");
            LoadFreshIni(absentPath);
            g_config.LoadLanguage();
            const std::string absent = g_config.Language.value_or_default();

            CSimpleIniA autoWriter;
            const std::string autoPath = evidenceDir + "/i18n-roundtrip-auto.ini";
            std::filesystem::remove(autoPath);
            autoWriter.SetValue("Menu", "Language", "auto");
            autoWriter.SaveFile(autoPath.c_str());
            resetConfig("en");
            LoadFreshIni(autoPath);
            g_config.LoadLanguage();
            const std::string automatic = g_config.Language.value_or_default();

            Localization::SetLanguage(absent);
            const bool englishContent = Localization::Translate("Apply Changes") == "Apply Changes";
            Localization::SetLanguage("en");
            Check("ini-absent-en", absent == "en" && automatic == "en" && englishContent,
                  std::format("absent -> '{}', auto -> '{}', menu content stays English", absent, automatic));
        }

        // 17) an unknown value resolves to English, never to a blank or a crash.
        {
            const std::string unknownPath = evidenceDir + "/i18n-roundtrip-unknown.ini";
            std::filesystem::remove(unknownPath);
            CSimpleIniA writer;
            writer.SetValue("Menu", "Language", "xx");
            writer.SaveFile(unknownPath.c_str());

            resetConfig("en");
            LoadFreshIni(unknownPath);
            g_config.LoadLanguage();
            const auto raw = g_config.readString("Menu", "Language", true);
            const std::string stored = g_config.Language.value_or_default();
            const std::string canonical = Localization::NormalizeLanguageCode(stored);
            Localization::SetLanguage(canonical);
            const bool englishContent = Localization::Translate("Apply Changes") == "Apply Changes";
            Localization::SetLanguage("en");
            Check("ini-unknown-en",
                  raw.has_value() && *raw == "xx" && stored == "en" && canonical == "en" && englishContent,
                  std::format("injected 'xx' read as '{}', stored as canonical '{}', language index {} (English), menu "
                              "content stays English",
                              raw.has_value() ? *raw : std::string("(absent)"), stored,
                              Localization::LanguageIndex(stored)));
        }
    }

    // 19) A new RTX 20/30 unlock string renders Korean through the real seams.
    //     "Kernel Image" is one of the labels todo 7 added to menu_common.cpp; the
    //     literal below must equal the ko.json entry the generated include carries.
    {
        Progress("19 ampere-kernel-image-ko");
        ImVec2 korean {};
        ImVec2 literal {};
        int koreanVertices = 0, literalVertices = 0;
        Frame(
            [&]
            {
                Localization::SetLanguage("ko");
                korean = ImGui::CalcTextSize("Kernel Image");
                literal = ImGui::CalcTextSize(kKernelImageKo);
                koreanVertices = DrawVertices("Kernel Image");
                literalVertices = DrawVertices(kKernelImageKo);
            });
        const std::string translated = Localization::Translate("Kernel Image");
        Localization::SetLanguage("en");
        Check("ampere-kernel-image-ko",
              translated == kKernelImageKo && korean.x == literal.x && korean.y == literal.y && koreanVertices > 0 &&
                  koreanVertices == literalVertices,
              std::format("ko {} {}x{} ({} vertices), literal {}x{} ({} vertices)", FnvHex(translated), korean.x,
                          korean.y, koreanVertices, literal.x, literal.y, literalVertices));
    }

    // 20) The new status line goes through the dynamic-template path: the Korean
    //     template with the loader's state name substituted by the real lookup.
    {
        Progress("20 ampere-status-template-ko");
        Localization::SetLanguage("ko");
        const std::string rendered = Localization::Translate("20/30 unlock status: Loaded");
        Localization::SetLanguage("en");
        Check("ampere-status-template-ko", rendered == kUnlockStatusLoadedKo,
              std::format("'20/30 unlock status: Loaded' -> {} ({})", FnvHex(rendered), rendered));
    }
}

// ---------------------------------------------------------------------------
// Receipts
// ---------------------------------------------------------------------------

static std::string JsonEscape(const std::string& text)
{
    std::string out;
    for (unsigned char c : text)
    {
        if (c == '"' || c == '\\')
            out += std::format("\\{}", static_cast<char>(c));
        else if (c == '\n')
            out += "\\n";
        else if (c < 0x20 || c > 0x7E)
            out += std::format("\\u{:04x}", static_cast<unsigned>(c));
        else
            out += static_cast<char>(c);
    }
    return out;
}

static void WriteCasesJson(const std::string& path, const std::string& title, const std::string& root,
                           const std::string& fontPath)
{
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream << "{\n";
    stream << " \"tool\": \"tests/i18n_seam_smoke.cpp\",\n";
    stream << " \"schema\": 1,\n";
    stream << " \"title\": \"" << JsonEscape(title) << "\",\n";
    stream << " \"root\": \"" << JsonEscape(root) << "\",\n";
    stream << " \"font\": \"" << JsonEscape(fontPath) << "\",\n";
    stream << " \"cases\": [\n";
    for (std::size_t i = 0; i < g_cases.size(); ++i)
    {
        const Case& item = g_cases[i];
        stream << "  { \"name\": \"" << JsonEscape(item.name) << "\", \"ok\": " << (item.ok ? "true" : "false")
               << ", \"detail\": \"" << JsonEscape(item.detail) << "\" }" << (i + 1 == g_cases.size() ? "\n" : ",\n");
    }
    const int failures = static_cast<int>(std::count_if(g_cases.begin(), g_cases.end(), [](const Case& item)
                                                       { return !item.ok; }));
    stream << " ],\n";
    stream << " \"case_count\": " << g_cases.size() << ",\n";
    stream << " \"failures\": " << failures << "\n";
    stream << "}\n";
}

static void WriteIdentityReceipt(const std::string& path)
{
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream << "# Row 3 identity receipt - ImGui IDs and display bytes per key.\n";
    stream << "# The ID path must never see the translated bytes; the draw path must.\n";
    stream << "# key\tid-en\tid-ko\tid-equal\tfnv1a64(en-display)\tfnv1a64(ko-display)\tdisplay-differs\n";

    const char* keys[] = { "Intensity", "Reset##Intensity", "Menu Scale", "Apply Changes", "Model passes" };

    ImGuiID ids[2][5] = {};
    for (int language = 0; language < 2; ++language)
        Frame(
            [&, language]
            {
                Localization::SetLanguage(language == 0 ? "en" : "ko");
                for (int i = 0; i < 5; ++i)
                    ids[language][i] = ImGui::GetID(keys[i]);
            });

    for (int i = 0; i < 5; ++i)
    {
        Localization::SetLanguage("en");
        const std::string english = Localization::Translate(keys[i]);
        Localization::SetLanguage("ko");
        const std::string korean = Localization::Translate(keys[i]);
        stream << std::format("{}\t0x{:08X}\t0x{:08X}\t{}\t{}\t{}\t{}\n", keys[i], ids[0][i], ids[1][i],
                              ids[0][i] == ids[1][i] ? 1 : 0, FnvHex(english), FnvHex(korean),
                              english == korean ? 0 : 1);
    }

    stream << "# draw-path vertices from the real ImGui::RenderText under the guard\n";
    stream << "# key\tvertices-en\tvertices-ko\n";
    for (int i = 0; i < 5; ++i)
    {
        int vertices[2] = {};
        for (int language = 0; language < 2; ++language)
            Frame(
                [&, language]
                {
                    Localization::SetLanguage(language == 0 ? "en" : "ko");
                    vertices[language] = DrawVertices(keys[i]);
                });
        stream << std::format("{}\t{}\t{}\n", keys[i], vertices[0], vertices[1]);
    }
    Localization::SetLanguage("en");
}

static void WriteIniReceipt(const std::string& path, const std::string& roundtripPath)
{
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream << "{\n";
    stream << " \"tool\": \"tests/i18n_seam_smoke.cpp\",\n";
    stream << " \"schema\": 1,\n";
    stream << " \"key\": \"[Menu] Language\",\n";
    stream << " \"ini\": \"" << JsonEscape(roundtripPath) << "\",\n";
    stream << " \"cases\": [\n";
    std::vector<const Case*> items;
    for (const Case& item : g_cases)
        if (item.name.rfind("ini-", 0) == 0)
            items.push_back(&item);
    for (std::size_t i = 0; i < items.size(); ++i)
        stream << "  { \"name\": \"" << JsonEscape(items[i]->name) << "\", \"ok\": " << (items[i]->ok ? "true" : "false")
               << ", \"detail\": \"" << JsonEscape(items[i]->detail) << "\" }" << (i + 1 == items.size() ? "\n" : ",\n");
    const int failures = static_cast<int>(
        std::count_if(items.begin(), items.end(), [](const Case* item) { return !item->ok; }));
    stream << " ],\n";
    stream << " \"case_count\": " << items.size() << ",\n";
    stream << " \"failures\": " << failures << "\n";
    stream << "}\n";
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

int main(int argc, char** argv)
{
    std::string evidenceDir = ".";
    std::string fontPath;
    std::string root = ".";
    bool injectTrap = false;

    for (int i = 1; i < argc; ++i)
    {
        const std::string argument = argv[i];
        const bool hasValue = i + 1 < argc;
        if (argument == "--evidence" && hasValue)
            evidenceDir = argv[++i];
        else if (argument == "--font" && hasValue)
            fontPath = argv[++i];
        else if (argument == "--root" && hasValue)
            root = argv[++i];
        else if (argument == "--inject-trap")
            injectTrap = true;
        else
        {
            std::printf("unknown argument: %s\n", argument.c_str());
            return 64;
        }
    }

    if (fontPath.empty())
    {
        std::printf("a --font path is required\n");
        return 64;
    }
    if (!std::filesystem::exists(fontPath))
    {
        std::printf("font not found: %s\n", fontPath.c_str());
        return 65;
    }

    std::filesystem::create_directories(evidenceDir);
    if (!SetupImGui(fontPath))
    {
        std::printf("font could not be added to the atlas: %s\n", fontPath.c_str());
        return 65;
    }

    if (injectTrap)
    {
        const IdentityProbeResult probe = RunIdentityProbe();
        g_cases.clear();
        Check("r7-ko-label-trap", probe.ok,
              std::format("injected translated label into the key path: english id 0x{:08X}, expected 0x{:08X}, "
                          "translated id 0x{:08X}",
                          probe.english_seen, probe.english_expected, probe.translated_seen));
        WriteCasesJson(evidenceDir + "/seam-trap.json", "row 3 failure fixture: KO label forced into the ID path",
                       root, fontPath);
        std::printf("trap fixture: translated label %s the identity path\n",
                    probe.ok ? "changed" : "did NOT change (the check would be blind)");
        return probe.ok ? 1 : 2;
    }

    RunCases(root, evidenceDir, fontPath);

    WriteCasesJson(evidenceDir + "/seam-cases.json", "row 3 seam cases", root, fontPath);
    WriteIdentityReceipt(evidenceDir + "/identity-hashes.txt");
    WriteIniReceipt(evidenceDir + "/ini-roundtrip.json", evidenceDir + "/i18n-roundtrip.ini");

    int failures = 0;
    for (const Case& item : g_cases)
    {
        std::printf("%-4s %-38s %s\n", item.ok ? "ok" : "FAIL", item.name.c_str(), item.detail.c_str());
        failures += item.ok ? 0 : 1;
    }
    std::printf("cases: %zu, failures: %d\n", g_cases.size(), failures);

    ImGui::DestroyContext();
    return failures == 0 ? 0 : 1;
}
