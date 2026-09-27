#pragma once

// Presentation-layer Korean localization for the OptiScaler menu.
//
// The shape of this unit (a content-keyed catalog plus a presentation-range
// guard) is adapted from the NeuRotic OptiScaler fork's menu/Localization unit,
// written by the same author. Only the seam idea and the guard are carried over:
// the catalog and every Korean string in it are authored fresh for this release.
//
// Contract:
//  - only the range handed to the draw and measure layer is substituted;
//  - ImGui label literals, ID hashes, "##" suffixes, INI keys and printf format
//    arguments keep their English bytes;
//  - a missing entry leaves the caller's pointers and content untouched, so
//    English behaviour is identical by construction;
//  - the Hangul source is merged onto the font the menu already has, is never
//    bundled, and a Korean request without it degrades to English without
//    touching the configured value.

#include <string>
#include <string_view>
#include <vector>

struct ImFontAtlas;

namespace Localization
{
struct Language
{
    const char* code;
    const char* name;      // shown in its own language; octal UTF-8 escapes keep this header ASCII
    const char* asciiName; // shown when that script cannot be rendered, so never tofu
};

inline constexpr Language Languages[] = { { "en", "English", "English" },
                                          { "ko", "\355\225\234\352\265\255\354\226\264", "Korean" } };
inline constexpr int LanguageCount = sizeof(Languages) / sizeof(Languages[0]);

/// Canonical code for a configured value: any Korean region suffix is "ko",
/// every other value (including an unknown or absent one) is "en".
std::string NormalizeLanguageCode(std::string_view code);

/// Index into Languages for a configured value. Unknown values resolve to English.
int LanguageIndex(std::string_view code);

/// The Hangul font chain. The production chain is System(); a harness passes a
/// directory that holds no font to exercise the missing-source policy.
struct FontChain
{
    std::vector<std::string> paths;

    /// %WINDIR%\Fonts\malgun.ttf, then gulim.ttc, then the Linux Noto CJK KR
    /// candidates. First existing file wins; nothing is bundled or downloaded.
    static FontChain System();
};

/// Outcome of one registration attempt. Every field is copied out for evidence.
struct FontRegistration
{
    bool available = false;     // a Hangul source is merged into the menu font
    bool baseFontAdded = false; // the atlas had no font, so ImGui's default was added as the merge target
    std::string source;         // resolved Hangul file; empty when nothing resolved
    std::string targetFont;     // name of the font the source merged onto
    int chainTried = 0;         // candidates probed before the chain gave up
    int fontsBefore = 0;        // atlas->Fonts.Size before registration
    int fontsAfter = 0;         // atlas->Fonts.Size after registration
    int sourcesAfter = 0;       // sources on the destination font, Hangul included
};

/// Merges the first resolvable Hangul source onto the font the menu already has,
/// with MergeMode=true, and records the outcome for the fallback policy. The
/// destination font is never replaced or re-added, and a second call on the same
/// atlas is a no-op, so this cannot grow the atlas mid-session.
FontRegistration RegisterHangulFont(ImFontAtlas* atlas, const FontChain& chain);

/// RegisterHangulFont with the production chain: %WINDIR%\Fonts\malgun.ttf, then
/// gulim.ttc, then the Linux Noto CJK KR candidates.
FontRegistration RegisterHangulFont(ImFontAtlas* atlas);

/// True when a probe found and merged a Hangul source. Before any probe the state
/// is unknown and Korean stays allowed; that is the state a harness that never
/// runs MenuCommon::Init sees, and the shipped menu always probes at Init.
bool HangulAvailable();

/// The language actually applied. A Korean request degrades to English when the
/// probe came back empty. The configured value is never modified, so a persisted
/// "ko" survives for a later run.
int EffectiveLanguageIndex();
const char* EffectiveLanguageCode();

/// Entry label for the language switch. An entry whose own script cannot be
/// rendered falls back to its ASCII name, so the selector never draws tofu.
const char* LanguageEntryLabel(int index);

/// The one ASCII sentence that describes a missing Hangul source: the log line at
/// Init and the footer notice are the same sentence. It is English by necessity,
/// because the missing source is exactly why no Korean glyph can be drawn.
const char* MissingFontNotice();

/// Draws the one-shot footer notice. Returns true on the single frame that drew
/// it; the product calls it once per bottom-bar frame.
bool DrawMissingFontNotice();

/// Applies a code for subsequent frames. Never touches the config or the ini.
/// A Korean request with no Hangul source degrades to English, which arms the
/// footer notice once per engagement.
void SetLanguage(std::string_view code);

/// Catalog lookup for one display range. Null on a miss.
const char* Lookup(std::string_view display);

/// Translated copy of a display range. A miss returns the input content unchanged.
std::string Translate(std::string_view display);

/// Presentation-only substitution. The guard repoints the caller's range at the
/// translated bytes and leaves it completely alone when there is nothing to
/// substitute, so an untranslated string keeps the exact input pointer.
class LocalizedRange
{
  public:
    LocalizedRange(const char*& begin, const char*& end);
    ~LocalizedRange();
    LocalizedRange(const LocalizedRange&) = delete;
    LocalizedRange& operator=(const LocalizedRange&) = delete;

  private:
    std::string text;
    bool scoped = false;
};
} // namespace Localization
