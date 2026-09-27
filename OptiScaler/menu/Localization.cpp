#include "pch.h"

#include "Localization.h"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <filesystem>
#include <regex>
#include <system_error>
#include <unordered_map>
#include <vector>

#include <Windows.h>
#include <imgui/imgui.h>

namespace Localization
{
namespace
{
// The generated include declares the entries with this type and expects the
// translation unit to provide it. It is pure ASCII with octal UTF-8 escapes, so
// the build needs no /utf-8 flag, no BOM and no codepage dependency.
struct LocalizationEntry
{
    const char* source;
    const char* text;
};
#include "locales/ko_catalog.inc"
static constexpr const LocalizationEntry* kCatalog = kLocalizationEntries_ko;
static constexpr unsigned kCatalogCount = kLocalizationEntryCount_ko;

// printf tokens and brace tokens. Anything between them is literal text.
const std::regex Format(R"(%(?:[-+#0]*\d*(?:\.\d+)?(?:hh|ll|[hljztL]|I64)?[diuoxXfFeEgGaAcsp]|%)|\{(?::[^{}]*)?\})");

std::string Normalize(std::string_view value)
{
    std::string result;
    bool space = false;
    for (unsigned char c : value)
    {
        if (std::isspace(c))
        {
            space = !result.empty();
            continue;
        }
        if (space)
            result += ' ';
        result += static_cast<char>(c);
        space = false;
    }
    return result;
}

std::string Escape(std::string_view text)
{
    std::string result;
    for (char c : text)
    {
        if (std::string_view(R"(\.^$|()[]{}*+?)").find(c) != std::string_view::npos)
            result += '\\';
        result += c;
    }
    return result;
}

struct Pattern
{
    std::string prefix;
    std::regex match;
    const LocalizationEntry* entry;
};

// Exact hits first, then the dynamic status templates whose literal parts are
// long enough to be a real sentence rather than a bare "%s"/"%d" value.
struct CatalogIndex
{
    std::unordered_map<std::string, const LocalizationEntry*> exact;
    std::vector<Pattern> patterns;

    CatalogIndex()
    {
        exact.reserve(kCatalogCount);
        for (unsigned i = 0; i < kCatalogCount; ++i)
        {
            const LocalizationEntry& entry = kCatalog[i];
            const std::string source = Normalize(entry.source);
            exact.emplace(source, &entry);

            std::sregex_iterator it(source.begin(), source.end(), Format), end;
            if (it == end)
                continue;

            const std::string prefix = source.substr(0, it->position());
            std::string expression = "^";
            std::size_t previous = 0, literalSize = 0;
            for (; it != end; ++it)
            {
                const std::size_t pos = it->position();
                expression += Escape(source.substr(previous, pos - previous));
                literalSize += pos - previous;
                const auto token = it->str();
                if (token == "%%")
                    expression += '%';
                else
                {
                    const char type = token.back();
                    expression += (type == 's' || type == '}') ? "(.*?)" : "([ +0-9a-fA-FxX.eE-]+)";
                }
                previous = pos + it->length();
            }
            expression += Escape(source.substr(previous)) + '$';
            literalSize += source.size() - previous;

            // Bare values such as %s/%d are not translation templates.
            if (literalSize >= 4)
                patterns.push_back({ prefix, std::regex(expression, std::regex::optimize), &entry });
        }

        // Specific messages win over broad suffix/prefix templates.
        std::stable_sort(patterns.begin(), patterns.end(),
                         [](const auto& a, const auto& b) { return a.prefix.size() > b.prefix.size(); });
    }
};

const CatalogIndex& Index()
{
    static const CatalogIndex index;
    return index;
}

struct Context
{
    int language = 0;
    int depth = 0;
    std::unordered_map<std::string, std::string> cache;
};
thread_local Context context;

// Hangul source state. The probe stays unknown until RegisterHangulFont runs,
// which MenuCommon::Init always does before the menu can draw, so the shipped
// menu decides the effective language at Init. A harness that never registers a
// source keeps the pre-existing behaviour and Korean stays allowed.
enum class FontProbe
{
    NotProbed,
    Available,
    Unavailable
};

FontProbe fontProbe = FontProbe::NotProbed;
bool missingFontNoticeArmed = false;
bool missingFontNoticeShown = false;

// One sentence, English by necessity: the missing source is exactly why no Korean
// glyph can be drawn. The log line at Init and the footer notice share it.
constexpr const char* kMissingFontNotice =
    "Korean font not found (malgun.ttf, gulim.ttc, Noto CJK KR) - the menu stays English";

std::string TranslateNormalized(const std::string& source, int recursion)
{
    const auto& index = Index();
    if (auto it = index.exact.find(source); it != index.exact.end())
        return it->second->text;
    if (recursion > 1)
        return source;

    for (const auto& pattern : index.patterns)
    {
        if (!source.starts_with(pattern.prefix))
            continue;

        std::smatch captures;
        if (!std::regex_match(source, captures, pattern.match))
            continue;

        const std::string target = pattern.entry->text;
        std::string result;
        std::size_t previous = 0, argument = 1;
        for (std::sregex_iterator it(target.begin(), target.end(), Format), end; it != end; ++it)
        {
            result += target.substr(previous, it->position() - previous);
            if (it->str() == "%%")
                result += '%';
            else if (argument < captures.size())
            {
                // Dynamic values keep their own bytes; a status sentence nested
                // inside a template is translated through the same catalog.
                const std::string value = captures[argument++].str();
                const std::size_t first = value.find_first_not_of(" \r\n\t");
                const std::size_t last = value.find_last_not_of(" \r\n\t");
                if (first == std::string::npos)
                    result += value;
                else
                    result += value.substr(0, first) + TranslateNormalized(Normalize(value), recursion + 1) +
                              value.substr(last + 1);
            }
            previous = it->position() + it->length();
        }
        result += target.substr(previous);
        return result;
    }

    return source;
}
} // namespace

namespace
{
// Windows first, then the two Linux Noto CJK KR candidates. Only the first
// existing file is merged; nothing is bundled or downloaded.
std::vector<std::string> SystemFontCandidates()
{
    std::vector<std::string> candidates;

    wchar_t windows[MAX_PATH] = {};
    if (GetWindowsDirectoryW(windows, MAX_PATH) > 0)
    {
        const std::filesystem::path fonts = std::filesystem::path(windows) / L"Fonts";
        candidates.push_back((fonts / L"malgun.ttf").string());
        candidates.push_back((fonts / L"gulim.ttc").string());
    }

    for (const char* path : { "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                              "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                              "/usr/share/fonts/opentype/noto/NotoSansCJKkr-Regular.otf" })
        candidates.emplace_back(path);

    return candidates;
}

std::string FileName(std::string_view path)
{
    const std::size_t separator = path.find_last_of("/\\");
    return std::string(separator == std::string_view::npos ? path : path.substr(separator + 1));
}
} // namespace

FontChain FontChain::System()
{
    return FontChain { SystemFontCandidates() };
}

FontRegistration RegisterHangulFont(ImFontAtlas* atlas, const FontChain& chain)
{
    FontRegistration result;

    if (atlas == nullptr)
        return result;

    result.fontsBefore = atlas->Fonts.Size;

    // With UseHQFont=false the atlas has no font yet and ImGui would add its own
    // default on the first frame. Adding it here is that same font one frame
    // earlier, and it gives the merge a destination: the menu's font is never
    // replaced by the Hangul source.
    if (atlas->Fonts.empty())
    {
        atlas->AddFontDefault();
        result.baseFontAdded = true;
    }

    if (atlas->Fonts.empty())
    {
        fontProbe = FontProbe::Unavailable;
        return result;
    }

    ImFont* const target = atlas->Fonts.back();
    result.targetFont = target->Sources.empty() ? std::string() : FileName(target->Sources[0]->Name);
    result.fontsAfter = atlas->Fonts.Size;
    result.sourcesAfter = target->Sources.Size;

    for (const std::string& candidate : chain.paths)
    {
        ++result.chainTried;

        std::error_code error;
        if (candidate.empty() || !std::filesystem::is_regular_file(candidate, error))
            continue;

        result.source = candidate;
        break;
    }

    if (result.source.empty())
    {
        fontProbe = FontProbe::Unavailable;
        return result;
    }

    // A re-init, or a second call from a harness, must not merge twice: a second
    // source would be the only way this feature could grow the atlas after Init.
    for (const ImFontConfig* source : target->Sources)
        if (source->MergeMode && FileName(source->Name) == FileName(result.source))
        {
            result.available = true;
            fontProbe = FontProbe::Available;
            return result;
        }

    const float size = target->Sources.empty() ? target->DefaultSize : target->Sources[0]->SizePixels;

    ImFontConfig config;
    config.MergeMode = true;
    // Following the destination font's own size makes the merged glyphs 1:1 with
    // the text around them at every baked size, the scaled menu sizes included.
    ImFont* const merged = atlas->AddFontFromFileTTF(result.source.c_str(), size, &config);

    result.available = merged != nullptr;
    result.fontsAfter = atlas->Fonts.Size;
    result.sourcesAfter = target->Sources.Size;
    fontProbe = result.available ? FontProbe::Available : FontProbe::Unavailable;

    return result;
}

FontRegistration RegisterHangulFont(ImFontAtlas* atlas)
{
    return RegisterHangulFont(atlas, FontChain::System());
}

bool HangulAvailable()
{
    return fontProbe == FontProbe::Available;
}

int EffectiveLanguageIndex()
{
    return context.language;
}

const char* EffectiveLanguageCode()
{
    return Languages[EffectiveLanguageIndex()].code;
}

const char* LanguageEntryLabel(int index)
{
    if (index < 0 || index >= LanguageCount)
        return Languages[0].name;

    // An entry whose own script cannot be rendered is shown by its ASCII name,
    // so the selector itself never draws tofu.
    return (index != 0 && fontProbe == FontProbe::Unavailable) ? Languages[index].asciiName : Languages[index].name;
}

const char* MissingFontNotice()
{
    return kMissingFontNotice;
}

bool DrawMissingFontNotice()
{
    if (!missingFontNoticeArmed)
        return false;

    missingFontNoticeArmed = false;
    ImGui::TextColored(ImVec4(1.0f, 0.72f, 0.2f, 1.0f), "%s", kMissingFontNotice);
    return true;
}

std::string NormalizeLanguageCode(std::string_view code)
{
    std::string base;
    for (char c : code)
    {
        if (c == '-' || c == '_')
            break; // region suffix: ko-KR, ko_KR and ko all mean the same catalog
        const auto uc = static_cast<unsigned char>(c);
        if (std::isspace(uc))
            continue;
        base += static_cast<char>(std::tolower(uc));
    }

    for (const auto& language : Languages)
        if (base == language.code)
            return base;

    return Languages[0].code;
}

int LanguageIndex(std::string_view code)
{
    const std::string normalized = NormalizeLanguageCode(code);
    for (int i = 0; i < LanguageCount; ++i)
        if (normalized == Languages[i].code)
            return i;

    return 0;
}

void SetLanguage(std::string_view code)
{
    const int requested = LanguageIndex(code);
    // A Korean request with no Hangul source degrades to English. The configured
    // value is never modified here, so a "ko" read from the ini survives the run
    // and a later run can use it once the source is there.
    const bool degraded = requested != 0 && fontProbe == FontProbe::Unavailable;
    const int effective = degraded ? 0 : requested;

    if (degraded)
    {
        if (!missingFontNoticeShown)
        {
            missingFontNoticeArmed = true;
            missingFontNoticeShown = true;
        }
    }
    else
        missingFontNoticeShown = false;

    if (context.language == effective)
        return;

    context.language = effective;
    context.cache.clear();
}

const char* Lookup(std::string_view display)
{
    const auto& index = Index();
    if (auto it = index.exact.find(Normalize(display)); it != index.exact.end())
        return it->second->text;

    return nullptr;
}

std::string Translate(std::string_view source)
{
    if (context.language == 0 || source.empty())
        return std::string(source);

    const auto key = Normalize(source);
    if (auto found = context.cache.find(key); found != context.cache.end())
        return found->second;

    // The cache is bounded; clearing it wholesale is cheap and rare because a
    // frame only ever looks up a few hundred distinct strings.
    if (context.cache.size() >= 2048)
        context.cache.clear();

    const auto result = TranslateNormalized(key, 0);
    context.cache.emplace(key, result);
    return result;
}

LocalizedRange::LocalizedRange(const char*& begin, const char*& end)
{
    if (begin == nullptr || context.language == 0 || context.depth != 0)
        return;

    const std::string_view source =
        end != nullptr ? std::string_view(begin, static_cast<std::size_t>(end - begin)) : std::string_view(begin);
    if (source.empty())
        return;

    std::string translated = Translate(source);
    if (translated == source)
        return; // a miss keeps the caller's pointer and content exactly as they were

    text = std::move(translated);
    begin = text.c_str();
    end = begin + text.size();
    ++context.depth;
    scoped = true;
}

LocalizedRange::~LocalizedRange()
{
    if (scoped)
        --context.depth;
}
} // namespace Localization
