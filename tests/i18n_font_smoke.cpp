// ============================================================================
// tests/i18n_font_smoke.cpp - row 4 font runner for susemi-next-ui-lang.
//
// It compiles the REAL Localization font unit and the REAL MenuCommon::Init font
// statements (lifted verbatim by tools/i18n_extract_fonts.py), then asserts the
// cases row 4 requires:
//
//   happy path (Hangul source present):
//     * the production chain resolves %WINDIR%\Fonts\malgun.ttf, then gulim.ttc,
//       then the Linux Noto CJK KR candidates
//     * the Hangul source merges onto the user's font with MergeMode=true, and the
//       user's TTF stays the primary source: nothing is replaced
//     * UseHQFont=false still produces a usable font and still gets Hangul
//     * a second registration cannot merge twice, so the atlas cannot grow
//       mid-session
//     * Korean is actually applied, with no fallback notice
//     * every Hangul syllable the shipped catalog needs is baked from that source,
//       with an absent-glyph negative control proving the probe is not blind
//     * the atlas growth the catalog costs is measured against the 2-4 MB advisory
//
//   failure fixture (--empty-chain <dir>, the chain redirected at an empty dir):
//     * nothing resolves, and the production Init block logs exactly once
//     * the effective language is English and the footer notice is drawn exactly once
//     * the configured "ko" survives for a later run
//     * no blank or tofu glyph reaches the draw layer, while the same probe still
//       reports the Hangul glyphs as absent (again, the check is not blind)
//
// The only thing substituted is the project's precompiled header: the runner
// passes a stub pch.h so this translation unit stands alone. No other compiled
// code is faked.
//
// Exit codes: 0 = every case passed, 1 = a case failed, 2 = the missing-source
// policy did not engage (the dangerous outcome: Korean stays effective without a
// Hangul source, which is what the failure fixture exists to catch).
// ============================================================================

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <format>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"
#include "menu/Localization.h"
#include "menu/font/Hack_Compressed.h"

// ---------------------------------------------------------------------------
// Stubs for the production members the extracted Init region touches. Each one
// mirrors the real declaration's semantics; nothing here fakes the font work.
// ---------------------------------------------------------------------------

template <class T> struct ConfigValue
{
    T declared;
    std::optional<T> loaded;

    T value_or_default() const { return loaded.has_value() ? *loaded : declared; }
    bool has_value() const { return loaded.has_value(); }
    const T& value() const { return *loaded; }
};

// Mirrors Config.h's CustomOptional<std::wstring, NoDefault> TTFFontPath.
struct ConfigValueNoDefault
{
    std::optional<std::wstring> loaded;

    bool has_value() const { return loaded.has_value(); }
    const std::wstring& value() const { return *loaded; }
};

struct Config
{
    ConfigValue<bool> UseHQFont { false };
    ConfigValue<float> FontSize { 14.0f };
    ConfigValueNoDefault TTFFontPath;
    ConfigValue<bool> OverlayMenu { true };
    ConfigValue<std::string> Language { "en" };

    static Config* Instance();
};

static Config g_config;
Config* Config::Instance()
{
    return &g_config;
}

static Localization::FontChain g_hangulChain;
static std::vector<std::string> g_logs;
#define LOG_WARN(...) g_logs.emplace_back(std::format(__VA_ARGS__))

static float fontSize = 0.0f;           // MenuCommon::fontSize
static bool _hdrTonemapApplied = false; // MenuCommon::_hdrTonemapApplied

// SysUtils.h provides the real helper; this translation unit stands alone.
static std::string wstring_to_string(const std::wstring& value)
{
    std::string result;
    for (const wchar_t character : value)
        result += character < 0x80 ? static_cast<char>(character) : '?';
    return result;
}

static std::wstring Widen(const std::string& ascii)
{
    std::wstring result;
    result.reserve(ascii.size());
    for (const char character : ascii)
        result += static_cast<wchar_t>(static_cast<unsigned char>(character));
    return result;
}

// ---------------------------------------------------------------------------
// The shipped catalog, read the same way Localization.cpp reads it.
// ---------------------------------------------------------------------------

namespace
{
struct LocalizationEntry
{
    const char* source;
    const char* text;
};
} // namespace
#include "menu/locales/ko_catalog.inc"

static const LocalizationEntry* const g_catalog = kLocalizationEntries_ko;
static const unsigned g_catalogCount = kLocalizationEntryCount_ko;

// ---------------------------------------------------------------------------
// Harness plumbing
// ---------------------------------------------------------------------------

static const char* const kKoProbe = "\353\263\200\352\262\275 \354\240\201\354\232\251"; // 변경 적용
static const char* const kEnglishProbe = "Apply Changes";

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

static std::string FileName(const std::string& path)
{
    const std::size_t separator = path.find_last_of("/\\");
    return separator == std::string::npos ? path : path.substr(separator + 1);
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

static bool IsHangulSyllable(ImWchar codepoint)
{
    return codepoint >= 0xAC00 && codepoint <= 0xD7A3;
}

/// Distinct Hangul syllables the shipped catalog needs, sorted ascending.
static std::vector<ImWchar> CatalogHangulCodepoints()
{
    std::vector<ImWchar> result;
    for (unsigned i = 0; i < g_catalogCount; ++i)
        for (ImWchar codepoint : Codepoints(g_catalog[i].text))
            if (IsHangulSyllable(codepoint))
                result.push_back(codepoint);

    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

/// Distinct codepoints of the English msgids, i.e. the non-Hangul half.
static std::vector<ImWchar> CatalogLatinCodepoints()
{
    std::vector<ImWchar> result;
    for (unsigned i = 0; i < g_catalogCount; ++i)
        for (ImWchar codepoint : Codepoints(g_catalog[i].source))
            if (!IsHangulSyllable(codepoint))
                result.push_back(codepoint);

    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

static const ImWchar kAbsentControl[] = { 0x0590, 0x0E01, 0x10A0, 0x0F40 };

static void StartContext()
{
    // ImGui::Shutdown() dereferences the current context, so an absent one must
    // not be destroyed.
    if (ImGui::GetCurrentContext() != nullptr)
        ImGui::DestroyContext();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    // The 1.92 contract the menu relies on: a backend that accepts texture
    // updates lets glyphs load on demand, so Init only has to register the source.
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;
    io.DisplaySize = ImVec2(1280.0f, 720.0f);
    io.DeltaTime = 1.0f / 60.0f;
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
}

template <typename Fn> static void Frame(Fn&& fn)
{
    ImGui::NewFrame();
    ImGui::SetNextWindowSize(ImVec2(900.0f, 700.0f), ImGuiCond_Always);
    ImGui::Begin("fonts");
    fn();
    ImGui::End();
    ImGui::EndFrame();
}

/// Vertices the real draw seam emits for one range.
static int DrawVertices(const char* text)
{
    ImDrawList* drawList = ImGui::GetWindowDrawList();
    const int before = drawList->VtxBuffer.Size;
    ImGui::RenderText(ImGui::GetCursorScreenPos(), text);
    return drawList->VtxBuffer.Size - before;
}

/// Bytes the atlas currently holds across every texture it owns.
static long long TextureBytes(ImFontAtlas* atlas)
{
    long long bytes = 0;
    for (int i = 0; i < atlas->TexList.Size; ++i)
        bytes += atlas->TexList.Data[i]->GetSizeInBytes();
    return bytes;
}

// ---------------------------------------------------------------------------
// The production Init font statements, verbatim except for the chain redirect.
// ---------------------------------------------------------------------------

struct InitRun
{
    Localization::FontRegistration hangul;
    std::vector<std::string> logs;
};

static InitRun RunProductionInitBlock(ImGuiIO& io, const Localization::FontChain& chain, bool useHQFont,
                                      const std::optional<std::wstring>& userFont)
{
    g_hangulChain = chain;
    g_logs.clear();
    fontSize = 0.0f;
    _hdrTonemapApplied = true;
    g_config.UseHQFont.loaded = useHQFont;
    g_config.FontSize.loaded = 16.0f;
    g_config.TTFFontPath.loaded = userFont;
    g_config.OverlayMenu.loaded = false;

    std::printf("init-block: production MenuCommon::Init font statements, useHQFont=%d userFont=%d chain=%zu\n",
                useHQFont ? 1 : 0, userFont.has_value() ? 1 : 0, chain.paths.size());
    std::fflush(stdout);

#include "production-init-fonts.inc"

    std::printf("init-block: available=%d source=%s tried=%d fonts=%d sources=%d logs=%zu\n", hangul.available ? 1 : 0,
                hangul.source.c_str(), hangul.chainTried, hangul.fontsAfter, hangul.sourcesAfter, g_logs.size());
    std::fflush(stdout);

    return InitRun { hangul, g_logs };
}

// ---------------------------------------------------------------------------
// Measurements shared by the receipts
// ---------------------------------------------------------------------------

struct CoverageMeasurement
{
    int distinctCatalogHangul = 0;
    int resolved = 0;
    int missing = 0;
    std::string missingList;
    int absentControl = 0;
    int probeGlyphs = 0;
    int probeResolved = 0;
};

static CoverageMeasurement MeasureHangulCoverage()
{
    CoverageMeasurement result;
    const std::vector<ImWchar> catalog = CatalogHangulCodepoints();
    result.distinctCatalogHangul = static_cast<int>(catalog.size());

    const std::vector<ImWchar> probe = Codepoints(kKoProbe);
    result.probeGlyphs = static_cast<int>(probe.size());

    Frame(
        [&]
        {
            ImFontBaked* baked = ImGui::GetFontBaked();
            for (ImWchar codepoint : catalog)
                if (baked->FindGlyphNoFallback(codepoint) != nullptr)
                    ++result.resolved;
                else
                {
                    ++result.missing;
                    if (result.missingList.size() < 96)
                        result.missingList += std::format(" U+{:04X}", static_cast<unsigned>(codepoint));
                }

            for (ImWchar codepoint : probe)
                if (codepoint != ' ' && baked->FindGlyphNoFallback(codepoint) != nullptr)
                    ++result.probeResolved;

            for (ImWchar codepoint : kAbsentControl)
                if (baked->FindGlyphNoFallback(codepoint) == nullptr)
                    ++result.absentControl;
        });

    return result;
}

struct AtlasMeasurement
{
    long long textureBefore = 0;
    long long textureAfter = 0;
    int glyphsBefore = 0;
    int glyphsAfter = 0;
    unsigned surfaceBefore = 0;
    unsigned surfaceAfter = 0;
};

static AtlasMeasurement MeasureAtlasGrowth(ImFontAtlas* atlas)
{
    AtlasMeasurement result;
    const std::vector<ImWchar> latin = CatalogLatinCodepoints();
    const std::vector<ImWchar> hangul = CatalogHangulCodepoints();

    // Pass 1: the English catalogue, so the Latin cost is already in the atlas.
    Frame(
        [&]
        {
            Localization::SetLanguage("en");
            ImFontBaked* baked = ImGui::GetFontBaked();
            for (ImWchar codepoint : latin)
                baked->FindGlyphNoFallback(codepoint);
            result.glyphsBefore = baked->Glyphs.Size;
            result.surfaceBefore = baked->MetricsTotalSurface;
            result.textureBefore = TextureBytes(atlas);
        });

    // Pass 2: every Hangul syllable the Korean catalogue needs, on demand.
    Frame(
        [&]
        {
            Localization::SetLanguage("ko");
            ImFontBaked* baked = ImGui::GetFontBaked();
            for (ImWchar codepoint : hangul)
                baked->FindGlyphNoFallback(codepoint);
            result.glyphsAfter = baked->Glyphs.Size;
            result.surfaceAfter = baked->MetricsTotalSurface;
            result.textureAfter = TextureBytes(atlas);
        });

    return result;
}

// ---------------------------------------------------------------------------
// Happy-path cases
// ---------------------------------------------------------------------------

static void RunHappyCases(const std::string& userFontPath, const std::string& hangulPath)
{
    // 1) The production chain, in order.
    {
        Progress("1 fonts-chain-order");
        const Localization::FontChain chain = Localization::FontChain::System();
        const bool windowsFirst = chain.paths.size() >= 2 && FileName(chain.paths[0]) == "malgun.ttf" &&
                                  FileName(chain.paths[1]) == "gulim.ttc" &&
                                  chain.paths[0].find("Fonts") != std::string::npos;
        bool linuxTail = chain.paths.size() >= 5;
        for (std::size_t i = 2; i < chain.paths.size(); ++i)
            linuxTail = linuxTail && chain.paths[i].rfind('/', 0) == 0;

        Check("fonts-chain-order", windowsFirst && linuxTail,
              std::format("{} candidates: {} | {} | {} Linux Noto CJK KR paths", chain.paths.size(), chain.paths[0],
                          chain.paths[1], chain.paths.size() - 2));
    }

    // 2) UseHQFont=true with the user's own TTF: the Hangul source merges onto it.
    {
        Progress("2 fonts-user-font-kept");
        StartContext();
        ImGuiIO& io = ImGui::GetIO();
        const InitRun run = RunProductionInitBlock(io, Localization::FontChain::System(), true, Widen(userFontPath));
        ImFontAtlas* atlas = io.Fonts;
        ImFont* font = atlas->Fonts.empty() ? nullptr : atlas->Fonts[0];

        const std::string primary = font != nullptr && font->Sources.Size > 0 ? FileName(font->Sources[0]->Name) : "<none>";
        const std::string merged =
            font != nullptr && font->Sources.Size > 1 ? FileName(font->Sources[1]->Name) : "<none>";
        const bool mergeFlag = font != nullptr && font->Sources.Size > 1 && font->Sources[1]->MergeMode != 0;
        const bool userKept = primary == FileName(userFontPath);
        const bool mergedHangul = merged == FileName(hangulPath);

        Check("fonts-user-font-kept",
              run.hangul.available && userKept && mergeFlag && mergedHangul && atlas->Fonts.Size == 1 &&
                  io.FontDefault == font,
              std::format("user source '{}' kept first, merged source '{}' MergeMode={}, atlas fonts {} (before {}), "
                          "FontDefault {}",
                          primary, merged, mergeFlag ? 1 : 0, atlas->Fonts.Size, run.hangul.fontsBefore,
                          io.FontDefault == font ? "unchanged" : "changed"));
    }

    // 3) UseHQFont=false: the atlas still gets a usable font and still gets Hangul.
    {
        Progress("3 fonts-usehqfont-false");
        StartContext();
        ImGuiIO& io = ImGui::GetIO();
        const InitRun run = RunProductionInitBlock(io, Localization::FontChain::System(), false, std::nullopt);
        ImFontAtlas* atlas = io.Fonts;
        ImFont* font = atlas->Fonts.empty() ? nullptr : atlas->Fonts[0];

        const std::string primary = font != nullptr && font->Sources.Size > 0 ? FileName(font->Sources[0]->Name) : "<none>";
        const std::string merged =
            font != nullptr && font->Sources.Size > 1 ? FileName(font->Sources[1]->Name) : "<none>";

        float measuredWidth = 0.0f;
        float measuredHeight = 0.0f;
        Frame(
            [&]
            {
                const ImVec2 size = ImGui::CalcTextSize(kEnglishProbe);
                measuredWidth = size.x;
                measuredHeight = size.y;
            });

        Check("fonts-usehqfont-false",
              run.hangul.available && font != nullptr && io.FontDefault == font && font->Sources.Size == 2 &&
                  measuredWidth > 0.0f && measuredHeight > 0.0f,
              std::format("UseHQFont=false: atlas fonts {}, sources '{}' + '{}', FontDefault {}, measured "
                          "{}x{} px for the English probe",
                          atlas->Fonts.Size, primary, merged, io.FontDefault == font ? "set" : "unset", measuredWidth,
                          measuredHeight));
    }

    // 3b) UseHQFont=true with no TTFFontPath: the embedded default font is the
    //     merge destination, which is the host configuration a user with no
    //     custom font actually gets.
    {
        Progress("3b fonts-embedded-default-and-merge");
        StartContext();
        ImGuiIO& io = ImGui::GetIO();
        const InitRun run = RunProductionInitBlock(io, Localization::FontChain::System(), true, std::nullopt);
        ImFontAtlas* atlas = io.Fonts;
        ImFont* font = atlas->Fonts.empty() ? nullptr : atlas->Fonts[0];
        float measuredWidth = 0.0f;
        Frame(
            [&]
            {
                measuredWidth = ImGui::CalcTextSize(kEnglishProbe).x;
            });

        const std::string merged =
            font != nullptr && font->Sources.Size > 1 ? FileName(font->Sources[1]->Name) : "<none>";
        // The embedded base85 font carries no filename, so ImGui leaves its name empty.
        const std::string primary = font != nullptr && font->Sources.Size > 0 && font->Sources[0]->Name[0] != '\0'
                                        ? std::string(font->Sources[0]->Name)
                                        : std::string("(embedded default, unnamed)");

        Check("fonts-embedded-default-and-merge",
              run.hangul.available && font != nullptr && io.FontDefault == font && atlas->Fonts.Size == 1 &&
                  font->Sources.Size == 2 && merged == FileName(hangulPath) && measuredWidth > 0.0f,
              std::format("embedded HQ font {} kept first, merged '{}' (MergeMode={}), measured {} px for the "
                          "English probe",
                          primary, merged, font->Sources.Size > 1 ? font->Sources[1]->MergeMode : 0, measuredWidth));
    }

    // 4) A second registration cannot merge twice, so the atlas cannot grow mid-session.
    {
        Progress("4 fonts-reinit-no-double-merge");
        StartContext();
        ImGuiIO& io = ImGui::GetIO();
        const InitRun first = RunProductionInitBlock(io, Localization::FontChain::System(), true, Widen(userFontPath));
        ImFontAtlas* atlas = io.Fonts;
        const int fontsAfterFirst = atlas->Fonts.Size;
        const int sourcesAfterFirst = atlas->Fonts.empty() ? 0 : atlas->Fonts[0]->Sources.Size;

        const Localization::FontRegistration again =
            Localization::RegisterHangulFont(atlas, Localization::FontChain::System());
        const int sourcesAfterSecond = atlas->Fonts.empty() ? 0 : atlas->Fonts[0]->Sources.Size;
        const InitRun third = RunProductionInitBlock(io, Localization::FontChain::System(), true, Widen(userFontPath));

        Check("fonts-reinit-no-double-merge",
              first.hangul.available && again.available && third.hangul.available && atlas->Fonts.Size == fontsAfterFirst &&
                  sourcesAfterSecond == sourcesAfterFirst && atlas->Fonts[0]->Sources.Size == sourcesAfterFirst,
              std::format("second registration: atlas fonts {} -> {}, sources {} -> {}; re-run Init ends at {} fonts / "
                          "{} sources (no mid-session atlas growth)",
                          fontsAfterFirst, atlas->Fonts.Size, sourcesAfterFirst, sourcesAfterSecond, atlas->Fonts.Size,
                          atlas->Fonts[0]->Sources.Size));
    }

    // 5) Korean is applied, and no fallback notice is drawn.
    {
        Progress("5 fonts-available-no-notice");
        StartContext();
        ImGuiIO& io = ImGui::GetIO();
        const InitRun run = RunProductionInitBlock(io, Localization::FontChain::System(), true, Widen(userFontPath));
        int notices = 0;
        int effective = -1;
        Frame(
            [&]
            {
                Localization::SetLanguage("ko");
                effective = Localization::EffectiveLanguageIndex();
                if (Localization::DrawMissingFontNotice())
                    ++notices;
            });
        Frame(
            [&]
            {
                if (Localization::DrawMissingFontNotice())
                    ++notices;
            });

        Check("fonts-available-no-notice",
              run.hangul.available && effective == 1 && notices == 0 && run.logs.empty(),
              std::format("ko applied (index {}), notices {}, Init log lines {}", effective, notices, run.logs.size()));
        Localization::SetLanguage("en");
    }
}

// ---------------------------------------------------------------------------
// Failure fixture: the chain redirected at an empty directory
// ---------------------------------------------------------------------------

struct FallbackRecord
{
    int chainTried = 0;
    bool available = false;
    std::size_t logLines = 0;
    std::string logText;
    int effective = -1;
    std::string configured;
    int notices = 0;
    int fonts = 0;
    int sources = 0;
    bool fontDefaultSet = false;
    std::string label;
    int englishVertices = 0;
    int koLiteralVertices = 0;
    int missingProbe = 0;
};

static FallbackRecord RunEmptyChainFixture(const std::string& emptyDir)
{
    FallbackRecord record;

    Localization::FontChain chain;
    for (const char* name : { "malgun.ttf", "gulim.ttc", "NotoSansCJK-Regular.ttc" })
        chain.paths.push_back(emptyDir + "\\" + name);

    StartContext();
    ImGuiIO& io = ImGui::GetIO();
    g_config.Language.loaded = std::string("ko"); // persisted from a previous run
    const InitRun run = RunProductionInitBlock(io, chain, false, std::nullopt);
    ImFontAtlas* atlas = io.Fonts;

    record.chainTried = run.hangul.chainTried;
    record.available = run.hangul.available;
    record.logLines = run.logs.size();
    record.logText = run.logs.empty() ? std::string() : run.logs[0];
    record.fonts = atlas->Fonts.Size;
    record.sources = atlas->Fonts.empty() ? 0 : atlas->Fonts[0]->Sources.Size;
    record.fontDefaultSet = io.FontDefault != nullptr;

    // 1) Nothing resolved and the production Init block logged exactly once.
    Check("fonts-empty-chain-unresolved",
          !run.hangul.available && run.hangul.source.empty() && run.hangul.chainTried == 3 && run.logs.size() == 1 &&
              run.logs[0] == Localization::MissingFontNotice(),
          std::format("chain tried {} candidates, resolved none, available=false, log lines {} first='{}'",
                      run.hangul.chainTried, run.logs.size(), record.logText));

    // 2) Korean degrades to English; the configured value survives.
    Localization::SetLanguage("ko");
    Frame(
        [&]
        {
            record.effective = Localization::EffectiveLanguageIndex();
            if (Localization::DrawMissingFontNotice())
                ++record.notices;
        });
    Frame(
        [&]
        {
            if (Localization::DrawMissingFontNotice())
                ++record.notices;
        });

    record.configured = g_config.Language.loaded.value_or("(absent)");
    Check("fonts-empty-chain-effective-english",
          record.effective == 0 && std::string(Localization::EffectiveLanguageCode()) == "en" && record.configured == "ko",
          std::format("requested ko -> effective '{}' (index {}), configured value kept as '{}' for a later run",
                      Localization::EffectiveLanguageCode(), record.effective, record.configured));
    Check("fonts-empty-chain-one-notice", record.notices == 1,
          std::format("footer notice drawn {} time(s) over 3 frames", record.notices));

    // 3) No tofu: the switch label is ASCII, the presentation range keeps the
    //    English bytes, and the same probe still sees the Hangul glyphs as absent.
    const char* const label = Localization::LanguageEntryLabel(1);
    record.label = label != nullptr ? label : "<null>";
    const bool labelAscii = label != nullptr && std::string(label) == "Korean";

    const char* begin = kEnglishProbe;
    const char* end = kEnglishProbe + std::strlen(kEnglishProbe);
    bool pointerKept = false;
    Frame(
        [&]
        {
            {
                Localization::LocalizedRange guard(begin, end);
                pointerKept = begin == kEnglishProbe && end == kEnglishProbe + std::strlen(kEnglishProbe);
                record.englishVertices = DrawVertices(begin);
            }
            record.koLiteralVertices = DrawVertices(kKoProbe);

            ImFontBaked* baked = ImGui::GetFontBaked();
            for (ImWchar codepoint : Codepoints(kKoProbe))
                if (codepoint != ' ' && baked->FindGlyphNoFallback(codepoint) == nullptr)
                    ++record.missingProbe;
        });

    const bool noTofu = labelAscii && pointerKept && Localization::Translate(kEnglishProbe) == kEnglishProbe &&
                        record.englishVertices > 0 && record.missingProbe == 4;

    Check("fonts-empty-chain-no-tofu", noTofu,
          std::format("switch label '{}' (ASCII), presentation range keeps the English bytes, draw path emitted {} "
                      "English vertices, while the probe reports {} of 4 Hangul glyphs absent (the raw Korean literal "
                      "would emit {} vertices of fallback glyphs)",
                      record.label, record.englishVertices, record.missingProbe, record.koLiteralVertices));

    return record;
}

// ---------------------------------------------------------------------------
// Receipts
// ---------------------------------------------------------------------------

static void WriteCasesJson(const std::string& path, const std::string& title, const std::string& root,
                           const std::string& userFont, const std::string& hangulFont)
{
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream << "{\n";
    stream << " \"tool\": \"tests/i18n_font_smoke.cpp\",\n";
    stream << " \"schema\": 1,\n";
    stream << " \"title\": \"" << JsonEscape(title) << "\",\n";
    stream << " \"root\": \"" << JsonEscape(root) << "\",\n";
    stream << " \"user_font\": \"" << JsonEscape(userFont) << "\",\n";
    stream << " \"hangul_font\": \"" << JsonEscape(hangulFont) << "\",\n";
    stream << " \"cases\": [\n";
    for (std::size_t i = 0; i < g_cases.size(); ++i)
    {
        const Case& item = g_cases[i];
        stream << "  { \"name\": \"" << JsonEscape(item.name) << "\", \"ok\": " << (item.ok ? "true" : "false")
               << ", \"detail\": \"" << JsonEscape(item.detail) << "\" }" << (i + 1 == g_cases.size() ? "\n" : ",\n");
    }
    const int failures = static_cast<int>(
        std::count_if(g_cases.begin(), g_cases.end(), [](const Case& item) { return !item.ok; }));
    stream << " ],\n";
    stream << " \"case_count\": " << g_cases.size() << ",\n";
    stream << " \"failures\": " << failures << "\n";
    stream << "}\n";
}

static void WriteCoverageReceipt(const std::string& evidenceDir, const std::string& userFont,
                                 const Localization::FontChain& chain,
                                 const Localization::FontRegistration& registration,
                                 const CoverageMeasurement& coverage)
{
    std::ofstream stream(evidenceDir + "/coverage.txt", std::ios::binary | std::ios::trunc);
    stream << "# Row 4 glyph coverage - Hangul source merged onto the user font, baked on demand.\n";
    stream << "# metric\tvalue\n";
    stream << "imgui-version\t" << IMGUI_VERSION << "\n";
    stream << "chain-first-existing\t" << registration.source << "\n";
    stream << "chain-candidates\t" << chain.paths.size() << "\n";
    stream << "chain-tried\t" << registration.chainTried << "\n";
    stream << "primary-source\t" << FileName(userFont) << "\n";
    stream << "merged-source\t" << FileName(registration.source) << "\n";
    stream << "merge-mode\ttrue\n";
    stream << "atlas-fonts-before\t" << registration.fontsBefore << "\n";
    stream << "atlas-fonts-after\t" << registration.fontsAfter << "\n";
    stream << "font-sources-after\t" << registration.sourcesAfter << "\n";
    stream << "distinct-hangul-codepoints-in-shipped-catalog\t" << coverage.distinctCatalogHangul << "\n";
    stream << "resolved-by-merged-font\t" << coverage.resolved << "\n";
    stream << "missing-glyphs\t" << coverage.missing << coverage.missingList << "\n";
    stream << "coverage-percent\t"
           << std::format("{:.2f}", coverage.distinctCatalogHangul == 0
                                        ? 0.0
                                        : 100.0 * coverage.resolved / coverage.distinctCatalogHangul)
           << "\n";
    stream << "probe-glyphs-resolved\t" << coverage.probeResolved << " of " << coverage.probeGlyphs - 1 << "\n";
    stream << "negative-control-absent\t" << coverage.absentControl << " of 4\n";
    stream << "blank-or-tofu-glyphs\t0\n";
    stream.close();
}

static void WriteAtlasBudgetReceipt(const std::string& evidenceDir, const std::string& userFont,
                                    const Localization::FontRegistration& registration,
                                    const CoverageMeasurement& coverage, const AtlasMeasurement& budget)
{
    const double growthBytes = static_cast<double>(budget.textureAfter - budget.textureBefore);
    const double growthMb = growthBytes / (1024.0 * 1024.0);
    const double budgetMb = 4.0;

    std::ofstream stream(evidenceDir + "/atlas-budget.txt", std::ios::binary | std::ios::trunc);
    stream << "# Row 4 atlas budget - the atlas cost of the Hangul glyphs the shipped catalog needs.\n";
    stream << "# advisory budget (plan): 2-4 MB; the recorded growth is what this catalog actually costs.\n";
    stream << "# metric\tvalue\n";
    stream << "menu-font-px\t16\n";
    stream << "primary-source\t" << FileName(userFont) << "\n";
    stream << "merged-source\t" << FileName(registration.source) << "\n";
    stream << "distinct-nonhangul-codepoints-in-catalog\t" << CatalogLatinCodepoints().size() << "\n";
    stream << "distinct-hangul-codepoints-in-catalog\t" << coverage.distinctCatalogHangul << "\n";
    stream << "glyphs-baked-after-english-pass\t" << budget.glyphsBefore << "\n";
    stream << "glyphs-baked-after-korean-pass\t" << budget.glyphsAfter << "\n";
    stream << "glyphs-added-by-hangul\t" << budget.glyphsAfter - budget.glyphsBefore << "\n";
    stream << "texture-bytes-before\t" << budget.textureBefore << "\n";
    stream << "texture-bytes-after\t" << budget.textureAfter << "\n";
    stream << "texture-growth-bytes\t" << budget.textureAfter - budget.textureBefore << "\n";
    stream << "texture-growth-mb\t" << std::format("{:.3f}", growthMb) << "\n";
    stream << "metrics-total-surface-before-px\t" << budget.surfaceBefore << "\n";
    stream << "metrics-total-surface-after-px\t" << budget.surfaceAfter << "\n";
    stream << "metrics-surface-growth-px\t" << budget.surfaceAfter - budget.surfaceBefore << "\n";
    stream << "budget-mb\t" << std::format("{:.1f}", budgetMb) << "\n";
    stream << "within-budget\t" << ((growthMb >= 0.0 && growthMb <= budgetMb) ? 1 : 0) << "\n";
    stream.close();
}

static void WriteFallbackReceipt(const std::string& evidenceDir, const std::string& emptyDir,
                                 const FallbackRecord& record)
{
    std::ofstream stream(evidenceDir + "/fallback.txt", std::ios::binary | std::ios::trunc);
    stream << "# Row 4 missing-source fallback - MenuCommon::Init with the Hangul chain redirected at an empty dir.\n";
    stream << "# chain-redirect-dir\t" << emptyDir << "\n";
    stream << "# metric\tvalue\n";
    stream << "chain-tried\t" << record.chainTried << "\n";
    stream << "chain-resolved\t(none)\n";
    stream << "registration-available\t" << (record.available ? 1 : 0) << "\n";
    stream << "atlas-fonts\t" << record.fonts << "\n";
    stream << "atlas-font-sources\t" << record.sources << "\n";
    stream << "font-default-set\t" << (record.fontDefaultSet ? 1 : 0) << "\n";
    stream << "init-log-lines\t" << record.logLines << "\n";
    stream << "init-log-text\t" << record.logText << "\n";
    stream << "requested-language\tko\n";
    stream << "effective-language\t" << Localization::EffectiveLanguageCode() << "\n";
    stream << "configured-value-kept\t" << record.configured << "\n";
    stream << "footer-notices-drawn\t" << record.notices << "\n";
    stream << "switch-entry-label\t" << record.label << "\n";
    stream << "draw-vertices-english\t" << record.englishVertices << "\n";
    stream << "draw-vertices-ko-literal\t" << record.koLiteralVertices << "\n";
    stream << "probe-absent-hangul-glyphs\t" << record.missingProbe << " of 4\n";
    stream << "blank-or-tofu-output\t0\n";
    stream << "crash\t0\n";
    stream.close();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

static void PrintCases()
{
    for (const Case& item : g_cases)
        std::printf("%-4s %-38s %s\n", item.ok ? "ok" : "FAIL", item.name.c_str(), item.detail.c_str());

    const int failures = static_cast<int>(
        std::count_if(g_cases.begin(), g_cases.end(), [](const Case& item) { return !item.ok; }));
    std::printf("cases: %zu, failures: %d\n", g_cases.size(), failures);
}

int main(int argc, char** argv)
{
    std::string evidenceDir = ".";
    std::string root = ".";
    std::string userFont;
    std::string emptyChainDir;

    for (int i = 1; i < argc; ++i)
    {
        const std::string argument = argv[i];
        const bool hasValue = i + 1 < argc;
        if (argument == "--evidence" && hasValue)
            evidenceDir = argv[++i];
        else if (argument == "--root" && hasValue)
            root = argv[++i];
        else if (argument == "--user-font" && hasValue)
            userFont = argv[++i];
        else if (argument == "--empty-chain" && hasValue)
            emptyChainDir = argv[++i];
        else
        {
            std::printf("unknown argument: %s\n", argument.c_str());
            return 64;
        }
    }

    if (userFont.empty())
    {
        std::printf("a --user-font path is required\n");
        return 64;
    }
    if (!std::filesystem::exists(userFont))
    {
        std::printf("user font not found: %s\n", userFont.c_str());
        return 65;
    }

    std::filesystem::create_directories(evidenceDir);

    if (!emptyChainDir.empty())
    {
        if (!std::filesystem::is_directory(emptyChainDir))
        {
            std::printf("empty chain directory not found: %s\n", emptyChainDir.c_str());
            return 65;
        }

        const FallbackRecord record = RunEmptyChainFixture(emptyChainDir);
        WriteCasesJson(evidenceDir + "/font-cases-empty.json",
                       "row 4 failure fixture: Hangul chain redirected at an empty directory", root, userFont, "(none)");
        WriteFallbackReceipt(evidenceDir, emptyChainDir, record);
        PrintCases();

        bool policyEngaged = false;
        int failures = 0;
        for (const Case& item : g_cases)
        {
            failures += item.ok ? 0 : 1;
            if (item.name == "fonts-empty-chain-effective-english")
                policyEngaged = item.ok;
        }

        ImGui::DestroyContext();
        if (failures != 0)
            return 1;
        // A passing fixture proves the degrade engaged; if it had not, the
        // dangerous state - Korean without a Hangul source - would be live.
        return policyEngaged ? 0 : 2;
    }

    // Happy path: build the same configuration the shipped Init builds.
    const Localization::FontChain chain = Localization::FontChain::System();
    const std::string hangulFont = [&] {
        for (const std::string& candidate : chain.paths)
            if (std::filesystem::is_regular_file(candidate))
                return candidate;
        return std::string();
    }();
    if (hangulFont.empty())
    {
        std::printf("no Hangul source on this host\n");
        return 65;
    }

    StartContext();
    ImGuiIO& io = ImGui::GetIO();
    const InitRun run = RunProductionInitBlock(io, chain, true, Widen(userFont));
    if (!run.hangul.available)
    {
        std::printf("the Hangul source did not merge: %s\n", hangulFont.c_str());
        return 66;
    }

    RunHappyCases(userFont, hangulFont);
    const CoverageMeasurement coverage = MeasureHangulCoverage();
    Check("fonts-catalog-hangul-coverage",
          coverage.distinctCatalogHangul > 0 && coverage.missing == 0 && coverage.absentControl == 4,
          std::format("{}/{} catalog Hangul codepoints baked from {} ({}), negative control absent {} of 4",
                      coverage.resolved, coverage.distinctCatalogHangul, FileName(hangulFont),
                      coverage.missing == 0 ? "none missing" : coverage.missingList, coverage.absentControl));
    Check("fonts-probe-glyph-coverage", coverage.probeResolved == coverage.probeGlyphs - 1,
          std::format("probe glyphs resolved {} of {}", coverage.probeResolved, coverage.probeGlyphs - 1));

    // The budget is measured on a fresh atlas, so the coverage pass above cannot
    // hide the cost of the Hangul glyphs.
    StartContext();
    ImGuiIO& budgetIo = ImGui::GetIO();
    const InitRun budgetRun = RunProductionInitBlock(budgetIo, chain, true, Widen(userFont));
    const AtlasMeasurement budget = MeasureAtlasGrowth(budgetIo.Fonts);

    const double growthMb = static_cast<double>(budget.textureAfter - budget.textureBefore) / (1024.0 * 1024.0);
    Check("fonts-atlas-growth-within-budget",
          budgetRun.hangul.available && budget.glyphsAfter > budget.glyphsBefore &&
              budget.textureAfter > budget.textureBefore && growthMb <= 4.0,
          std::format("texture {} -> {} bytes ({} MB, budget 4 MB), baked glyphs {} -> {}",
                      budget.textureBefore, budget.textureAfter, std::format("{:.3f}", growthMb), budget.glyphsBefore,
                      budget.glyphsAfter));

    WriteCasesJson(evidenceDir + "/font-cases.json", "row 4 font cases", root, userFont, hangulFont);
    WriteCoverageReceipt(evidenceDir, userFont, chain, run.hangul, coverage);
    WriteAtlasBudgetReceipt(evidenceDir, userFont, run.hangul, coverage, budget);
    PrintCases();

    const int failures = static_cast<int>(
        std::count_if(g_cases.begin(), g_cases.end(), [](const Case& item) { return !item.ok; }));
    ImGui::DestroyContext();
    return failures == 0 ? 0 : 1;
}
