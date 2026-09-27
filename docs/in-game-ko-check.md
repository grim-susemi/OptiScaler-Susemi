# In-game KO/EN visual check protocol

Row 6 of `.omo/plans/susemi-next-ui-lang.md`. This is a **dev-only** document: it is not a
zip member, it is never shipped, and it changes no product behavior. It is the owner's
walk list for F2, the final in-game acceptance gate, and it is paired with the static
precheck in `tools/verify_visual_protocol.py`.

- Plan reference: row 6, dependencies row 5, blocks row 8 and F2, references R8, R9, R10, R11.
- Worktree: `W=C:\omo-research\susemi-next-ui-lang` (detached at
  `a8eac0c4195bb5d2c93a08055c05b584d5c98953`).
- Evidence root: `E=W\.omo\evidence\susemi-next-ui-lang`. Row artifacts live in `%E%\06`.
- Scope of this row: protocol wording plus one static precheck. No game launch, no DLL swap,
  no live-install touch. The owner fields in `%E%\06\owner-checklist.json` are left empty on
  purpose: an unfilled owner field is **PENDING**, never PASS.

## What is under test

| Item | Value |
| --- | --- |
| Payload under test (row 6, static) | `x64\Release-RTX40-MFG\OptiScaler.dll`, hash recorded in `%E%\06\protocol-precheck.json` |
| Payload under test (F2, live) | owner-installed proxy in `G=D:\SteamLibrary\steamapps\common\Crimson Desert\bin64`, hash bound in `%E%\F2\owner-verify.json` |
| Language key | `[Menu] Language`, values `auto` / `en` / `ko` (`ko-kr` and other region suffixes normalize to `ko`) |
| Shipped default | the shipped `OptiScaler.ini` carries **no** `Language` key; absent means English, so an untouched install stays English |
| Hangul source | `%WINDIR%\Fonts\malgun.ttf`, then `gulim.ttc`, then a Linux Noto CJK KR path, merged onto the menu font at Init; never bundled |
| Switch surface | the bottom bar, beside the Menu Scale combo (`menu_common.cpp:7538-7557`) |
| Expected residue | dynamic status and version strings; see "Recorded English residue" |

## How a step is judged

Each row of the step table has a language state, an expected result, and three owner cells.
Fill the owner cells as `PASS` or `FAIL` in the Pass/Fail column, and paste or describe what
you actually saw in the Actual result column.

- **Global expectation:** static menu labels, section titles and help text render Korean.
  A static label that renders English is a FAIL **unless** it is named under
  "Recorded English residue" or "Recorded coverage gaps" below.
- **Residue is not a defect.** Dynamic values, version strings, game/DLL/API names, ini keys,
  key names, numeric tokens and the `(?)` marker stay English by contract (C2, C8, R10).
- **No tofu, no blank glyph, no clipped control.** A blank or tofu glyph, or a control hidden
  or clipped by a Korean label, is a FAIL.
- **Instant switch.** Changing the language takes effect on the next drawn frame; no restart
  and no menu reload. A restart being required is a FAIL.
- **Persistence is explicit.** `Save Settings` writes `[Menu] Language`; changing the switch
  never auto-saves. Persistence is proven by the restart steps, not by the precheck.

## Frozen surface inventory

The step table covers every surface row 6 names. The id list is canonical in
`tools/verify_visual_protocol.py` (mapped there to the wording of row 6), so the script refuses a
protocol that omits any of them, either from this table or from the steps below.

| # | Surface id | Surface | Anchors (v0.8.7) |
| --- | --- | --- | --- |
| 1 | `core-menu-sections` | the main menu: both columns of section headers and their widget labels, header messages, plot titles | `menu_common.cpp:7338-7362`, `:2351`, section titles at `:2512,2735,3041,3551,3932,4182,4386,5401,5488,5590,5850,6034,6187,6283,6372,6418,6446,6893,6970,7024,7127,7314` |
| 2 | `nr-panel` | the DLSS Neural Rendering panel and its four tabs | `DlssNr_Menu.cpp:135-249`, `DlssNr_PipelineUi.h:39-41` |
| 3 | `nr-enable` | `Enable Neural Rendering` and `Apply model` | `DlssNr_Menu.cpp:146,153` |
| 4 | `nr-placement` | the three placement toggles and the live pipeline chart | `DlssNr_Menu.cpp:168,178,191`, `DlssNr_PipelineUi.h:101-115` |
| 5 | `nr-performance` | the NR status line and the GPU-time timing bar | `DlssNr_Menu.cpp:100-127`, `DlssNr_PipelineUi.h:63-88` |
| 6 | `nr-model-passes` | pass count, pass selector and the per-pass tuning block | `DlssNr_MenuControls.cpp:165-242` |
| 7 | `nr-colour` | the colour / detail / skin controls of the final edit | `DlssNr_MenuControls.cpp:244-284` |
| 8 | `nr-precision` | input scale and every numeric readout (percent, ms, multiplier) | `DlssNr_MenuControls.cpp:39-122` |
| 9 | `nr-compare` | compare mode, the compare controls and the on-screen side tags | `DlssNr_MenuControls.cpp:286-330`, `DlssNr_MenuOverlay.cpp:34-35,55-56` |
| 10 | `nr-debug` | debug view, hold frame, inspect-window warnings | `DlssNr_MenuControls.cpp:286-330` |
| 11 | `tooltips` | every `(?)` marker, `HelpMarker` and `SetTooltip` body, including NR helpers | `DlssNr_MenuSections.h:10-24`, `menu_common.cpp:327-343` |
| 12 | `keybinds` | the Keybinds panel and its notes | `menu_common.cpp:7309-7337` |
| 13 | `fg-status` | Frame Generation selection, input/output requirements and runtime status | `menu_common.cpp:3311-3345` |
| 14 | `mfg-status` | RTX 40 MFG unlock toggle, Ada options and the unlock status lines | `menu_common.cpp:3184-3307` |
| 15 | `bottom-bar` | Menu Scale, the language switch, Save Settings / Close / Open Wiki, resolution readout | `menu_common.cpp:7478-7620` |
| 16 | `splash` | the startup splash window | `menu_common.cpp:1692-1762`, `:91`, `:1656` |
| 17 | `toast` | notifications and toasts (update notice, startup warnings) | `menu_common.cpp:1578-1652`, `:1771` |
| 18 | `persistence-restart` | menu reopen, Save Settings round trip, game restart | `menu_common.cpp:7538-7557`, `Config.cpp` `[Menu]` load/save |

## Steps

Language state is what the switch is set to when the step is run. `en->ko` and `ko->en` mean
the step covers the transition itself. Fill the last three columns.

| # | Surface | Language | Expected result | Actual result | Pass/Fail | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | core-menu-sections | en | Menu opens; the window title line keeps the product name and shows the game name and version as English residue; no missing glyph | | | |
| 2 | core-menu-sections | ko | Every `SeparatorText` and section header in both columns renders Korean (see the inventory anchors); a title listed under coverage gaps may stay English | | | |
| 3 | core-menu-sections | ko | Widget labels, combo entries, checkboxes, buttons and tree nodes in those sections render Korean where catalogued | | | |
| 4 | core-menu-sections | ko | Header/status messages above the table render Korean, with English residue only for DLL/API/game names and versions | | | |
| 5 | core-menu-sections | ko | Plot titles and their dynamic readouts: static words Korean, numbers and units as residue | | | |
| 6 | nr-panel | ko | `DLSS Neural Rendering` header opens; the header text itself is intentionally Latin | | | |
| 7 | nr-panel | ko | The four section tabs render Korean: Placement, Input, Model passes, Apply NR edit | | | |
| 8 | nr-enable | ko | Coverage gap: `Enable Neural Rendering` and `Apply model` stay English (wrapper-passed labels). Nothing else on this row is expected Korean | | | |
| 9 | nr-enable | ko | Both tooltips behind the two toggles render Korean; the `(?)` marker stays `(?)` | | | |
| 10 | nr-placement | ko | Coverage gap: the three placement toggle labels stay English (wrapper-passed): `Generate model before upscale`, `Apply NR to the finished picture`, `Generate before upscale, apply after upscale`. Their tooltips render Korean | | | |
| 11 | nr-placement | ko | Every pipeline chart node title and detail renders Korean, including the dynamic pass count and percentage | | | |
| 12 | nr-performance | ko | The NR status line renders Korean with the dynamic values in place: `Running ... ms elapsed`, `NR off.`, `Waiting for the upscaler to run.`, `Retry` | | | |
| 13 | nr-performance | en | The timing bar readout (`NR ... ms \| Rest of frame ~ ... ms`, `Rendered frame: ... ms`) may keep English wording: dynamic GPU-time status is residue | | | |
| 14 | nr-performance | ko | The failure reason line from the status producers renders Korean; DLL/API names inside it stay Latin | | | |
| 15 | nr-model-passes | ko | `Model passes`, `Unlock up to 10 passes`, `Edit pass` and the inactive-pass note render Korean | | | |
| 16 | nr-model-passes | ko | `Auto skin mask` renders Korean; the tuning labels stay English (wrapper-passed): `Intensity`, `Local structure`, `Local tone`, `Skin structure`. `Style` stays English (ini-name drop). Their `(?)` help bodies render Korean | | | |
| 17 | nr-colour | ko | The `Skin and environment (final edit)` tree and the `(?)` help bodies render Korean. Coverage gap: `Colour strength`, `Detail strength` and `Highlight guard` stay English (wrapper-passed) | | | |
| 18 | nr-colour | ko | Coverage gap: the four skin/environment slider labels stay English (wrapper-passed): `Skin detail / lighting`, `Skin colour`, `Environment detail / lighting`, `Environment colour`. Their `(?)` help bodies render Korean | | | |
| 19 | nr-colour | ko | Coverage gap: `History confidence threshold` stays English when the residual path is active (wrapper-passed label) | | | |
| 20 | nr-precision | ko | Input scale labels render Korean; numeric tokens (`%d%%`, `%.2f`, `%.3fx`) stay numeric and correctly formatted | | | |
| 21 | nr-precision | ko | `White point source`, `HDR mapping (experimental)`, `Downscaler (NR)` and `Enlargement` render Korean; coverage gap: `Exposure trim`, `Highlight protection`, `Restore sharpness`, `Paper white` stay English (wrapper-passed) | | | |
| 22 | nr-compare | ko | Compare mode and its controls render Korean where catalogued: Side by side, Wipe, Swap sides, Label the sides; `Compare`, `Label size`, `Zoom`, `Split` are a coverage gap | | | |
| 23 | nr-compare | en | The on-screen side tags `DLSS NR : ON` / `DLSS NR : OFF` stay English: they are drawn with the draw list, outside the guarded ImGui text seams | | | |
| 24 | nr-debug | ko | `Debug view` and its three entries render Korean, including `Proxy (what the model sees)` and `Difference (amplified)` | | | |
| 25 | nr-debug | ko | `Hold frame` and its tooltip render Korean | | | |
| 26 | nr-debug | ko | The inspect-window warning about the separate edit-upscale path renders Korean | | | |
| 27 | tooltips | ko | Every catalogued `(?)` tooltip body in the walked sections renders Korean and wraps inside the panel: no clipped help, no hidden control. Coverage gap: the two DLSSG Ada help bodies (frame timing fix, software frame pacing) stay English | | | |
| 28 | tooltips | en | The `(?)` marker itself stays `(?)`; key names and ini keys inside tooltips stay Latin | | | |
| 29 | keybinds | ko | The Keybinds panel notes render Korean: `Key combinations are currently NOT supported!`, `Escape to cancel, Backspace to unbind` | | | |
| 30 | keybinds | en | Key names and bound keys stay Latin: Escape, Backspace, Alt+, Ctrl+, and the captured key labels | | | |
| 31 | keybinds | ko | Four keybind rows render Korean: FPS Overlay, FPS Overlay Cycle, Frame Generation, Neural Rendering. Coverage gap: the `Menu` row stays English (ini section-name drop) | | | |
| 32 | fg-status | ko | The Frame Generation section title renders Korean. Coverage gap: the FG input / output / Nvngx combo titles and their three requirement tooltips stay English (helper-call misses) | | | |
| 33 | fg-status | ko | FG runtime status renders Korean with dynamic values in place; API and runtime names stay Latin | | | |
| 34 | mfg-status | ko | `RTX 40 MFG unlock (restart)` and `RTX 40 (Ada) MFG Unlock Options` render Korean | | | |
| 35 | mfg-status | ko | The unlock status lines render Korean with the DLSSG version in place: applied, unavailable, plugin ceiling, `Save Settings and restart to apply this change.` | | | |
| 36 | mfg-status | ko | Ada option labels render Korean; `Applied:` / `Not applied:` values keep the method names and counts as residue | | | |
| 37 | bottom-bar | ko | `Menu Scale` and its entries render Korean; `Auto` and the numeric scales stay as they are | | | |
| 38 | bottom-bar | en->ko | The language combo shows each language in its own script (`English`, `한국어`); selecting `한국어` switches the menu on the next frame, with no restart and no menu reload | | | |
| 39 | bottom-bar | ko | `Save Settings`, `Close` and `Open Wiki` render Korean; the wiki tooltip renders Korean with the URL unchanged | | | |
| 40 | bottom-bar | ko->en | Selecting `English` returns every surface above to its English wording immediately; no Korean residue is left behind | | | |
| 41 | bottom-bar | en | The resolution readout and frame counter stay numeric residue; the layout does not clip the language combo or the buttons | | | |
| 42 | splash | ko | The splash line renders Korean with the key name in place: `OptiScaler - <key> for menu`; the splash appears before the menu opens | | | |
| 43 | splash | en | The splash flavour lines stay English: they are free-form jokes, recorded as residue, not as defects | | | |
| 44 | toast | ko | Toast bodies render Korean: the update notice content (`Press %s for more info`), the renamed-DLL warning, the FSR 4 FP8 notice | | | |
| 45 | toast | en | Toast titles stay English (`OptiScaler Update available`, `Late Streamline hook detected`, `Silly goose detected`), recorded as residue | | | |
| 46 | toast | ko | A toast raised with the language set to Korean does not show tofu or a blank line | | | |
| 47 | persistence-restart | ko | Select `한국어`, close the menu with `Close`, reopen it: still Korean, no restart, no atlas rebuild | | | |
| 48 | persistence-restart | ko | Press `Save Settings`, restart the game, open the menu: still Korean; `[Menu] Language` is present in `OptiScaler.ini` | | | |
| 49 | persistence-restart | en | With a fresh `OptiScaler.ini` (no `Language` key) the menu opens in English, and `[Menu] Language` reads nothing until you press Save Settings | | | |
| 50 | persistence-restart | ko | Toggling the language several times does not grow the font atlas mid-session and does not blank the menu | | | |

## Recorded English residue (expected, never a FAIL)

1. Dynamic values and version strings: game/DLL/NGX/DLSSG version strings, frame counters,
   GPU times, percentages, ratios, resolutions, ini keys and key names (C8, R10).
2. `(?)` markers and API/runtime tokens (`DLSS`, `FSR`, `XeSS`, `DXVK`, `Streamline`, `DLSSG`).
3. Numeric tokens inside translated templates: only the literal words change, the format
   tokens keep their sequence (C3).
4. The compare overlay tags `DLSS NR : ON` / `DLSS NR : OFF`, built at
   `DlssNr_MenuOverlay.cpp:34-35` and drawn with `ImDrawList::AddText` at `:55-56`, outside the
   guarded ImGui text seams listed in R3.
5. 82 splash flavour lines (`menu_common.cpp:91`) and the 3 toast titles
   (`menu_common.cpp:1609,1631,1641`). These are free-form English flavour text, not menu
   terminology; the shipped catalog carries no entries for them. Recorded, not repaired, in
   this release. An owner who wants them Korean can raise it as a friction item in row 8.

## Recorded coverage gaps (static findings of the row 6 precheck)

These are visible labels the shipped `ko_catalog.inc` (811 entries) has no entry for, so they
render English even with `한국어` selected. They come from row 1's extraction rules, found
statically by `tools/verify_visual_protocol.py`; fixing them is a product change and is out of
row 6's scope. Every label is listed in `%E%\06\protocol-precheck.json` under `findings`
with a `file:line` anchor. `verify_visual_protocol.py` reports them as non-blocking findings,
so the static precheck stays honest about what it does and does not prove.

An owner-run FAIL on any of these rows is a correct FAIL: it names a real gap, not a false
alarm. Counts measured on this worktree: 24 wrapper-passed labels, 14 ini-name title labels,
64 other helper-call misses.

- **Wrapper-passed labels (24).** Labels handed to the NR panel's local label helpers, which
  row 1's extractor cannot see because it keys its scan on ImGui function names: `Slider` and
  `DeferredSlider` in `DlssNr_MenuControls.cpp`, the `slider` lambda in `RenderBlend`, and
  `PipelineUi::CheckboxWrapped` in `DlssNr_Menu.cpp`. The list:
  `Enable Neural Rendering`, `Apply model`, `Generate model before upscale`,
  `Apply NR to the finished picture`, `Generate before upscale, apply after upscale`,
  `Restore sharpness`, `Exposure trim`, `Highlight protection`, `Paper white`, `Intensity`,
  `Local structure`, `Local tone`, `Skin structure`, `History confidence threshold`,
  `Detail strength`, `Colour strength`, `Skin detail / lighting`, `Skin colour`,
  `Environment detail / lighting`, `Environment colour`, `Highlight guard`, `Label size`,
  `Zoom`, `Split`.
- **Ini-name title labels (14).** Visible titles reached a scanned ImGui call but were dropped
  by row 1's do-not-translate rule because the same word is a shipped ini key or section
  name: `Compare` (`DlssNr_MenuControls.cpp:299`), `Style` (`:228`), `Contrast`
  (`menu_common.cpp:5784`), `HDR` (`:6105`), `HUDFix` (`:4518`), `MotionSharpness` (`:5811`),
  `Scale` (`:6947`), `Sharpness` (`:5618`), `Size` (`:6199`), and the five section names
  `Framerate` (`:5284`), `Magnifier` (`:6187`), `Menu` (`:7323`), `Upscalers` (`:2512`),
  `fakenvapi` (`:5401`). `Menu` is the keybind row below the Keybinds notes.
- **Other helper-call misses (64).** A wider static class: first-argument literals of helper
  shapes the extractor cannot see, `PopulateCombo`, `ShowTooltip`, `showHelp`, `setTitle`,
  `AddResourceBarrier`, `InputText`, `InputInt`, `InputFloat`, `InputScalar`, `RadioButton`,
  `ColorEdit3`, `AddDLSSDRenderPreset` and its siblings, `tool`, `formatFg`. It mixes real
  gaps with strings this protocol already declares residue (the three toast titles, the two
  DLSSG Ada help bodies), so it is carried in the receipt with anchors and not repeated here
  in full. The steps that meet its members name them: the Keybinds `Menu` row, the FG input /
  output / backend combo titles and their requirement tooltips, the DLSSG Ada help bodies,
  the `Trim anchors` field, the HUDless resource-barrier combos, and `Downscaler`.

## Reproduce the static precheck

```bat
set "W=C:\omo-research\susemi-next-ui-lang"
set "E=%W%\.omo\evidence\susemi-next-ui-lang"
cd /d "%W%"
python tools\verify_visual_protocol.py ^
  --protocol docs\in-game-ko-check.md ^
  --checklist "%E%\06\owner-checklist.json" ^
  --dll x64\Release-RTX40-MFG\OptiScaler.dll ^
  --ini release\susemi-next-ko\OptiScaler.ini ^
  --evidence "%E%\06\protocol-precheck.json"
```

Exit 0 means every hard static check passed and the owner cells are still PENDING. Exit 1 means
a hard check failed and the failing item is named in the output and in the receipt. The F2 gate
adds `--require-owner` and the installed DLL path; there, an empty or non-PASS owner cell fails,
and the installed DLL hash must match the hash the checklist records.

What the precheck asserts, and what it does not:

| Check | Kind | What it proves |
| --- | --- | --- |
| `surface-in-inventory`, `surface-has-steps` | hard | every surface **row 6 names** (the canonical list is in the script, mapped to the ids in the inventory table above) appears in the inventory and is walked by at least one step |
| `step-language-state`, `step-expectation`, `step-owner-cells-empty` | hard | each step carries a language state, an expectation and empty owner cells |
| `dll-sentinel` | hard | the payload carries 11 sentinels: 8 Korean catalog entries read from the shipped `ko_catalog.inc` (one per walked group), the `한국어` entry label from `Localization.h`, the hidden `##Language` combo label, and the missing-font notice sentence |
| `ini-language-key-absent` | hard | the shipped `OptiScaler.ini` has a `[Menu]` section and no `Language` key anywhere in the file |
| `owner-checklist` | hard (F2 mode) | the owner name, date, DLL hash and a PASS verdict per step; without `--require-owner`, a template that reads as acceptance fails instead |
| `findings` | non-blocking | the catalog coverage gaps below, with a `file:line` anchor per label |

It does not prove that the Korean text renders, fits, or switches live. Only F2 on real hardware
can show that, which is why `%E%\06\owner-checklist.json` ships with empty owner fields.

The failure side of the tool is exercised by
`%E%\06\negative\run-protocol-negative.py`, which mutates this protocol, the shipped ini, the
payload and the checklist and records that each mutant exits 1 with the offending item named.
