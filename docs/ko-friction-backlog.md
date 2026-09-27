# KO friction backlog

Row 8 of `.omo/plans/susemi-next-ui-lang.md`. This is a **dev-only** document: it is not a
zip member, it is never shipped, and it records no product change. It hands the known Korean
localization friction found while building the v0.8.7 rtx40-mfg KO build to whoever picks up
the next UI/language pass.

- Plan reference: row 8, dependency row 6, blocks F1, references R1, R8, R9, R10, R12.
- Worktree: `W=C:\omo-research\susemi-next-ui-lang` (detached at
  `a8eac0c4195bb5d2c93a08055c05b584d5c98953`).
- Evidence root: `E=W\.omo\evidence\susemi-next-ui-lang`. Row artifacts live in `%E%\08`.
- Verifier: `python tools\verify_backlog.py --backlog docs\ko-friction-backlog.md --min-items 5
  --require-anchors --evidence "%E%\08\backlog-check.json"`.
- **Every item below is out of scope for this release.** This release ships the seam, one
  `[Menu] Language` key, the switch and the Hangul font chain, and nothing else. No item here
  authorizes an edit, and no item here is claimed as already fixed.

## How an item is judged

The parse contract is fixed, because `tools/verify_backlog.py` reads it literally. Each item is
one `###` heading, and each item carries these field lines:

| Field | Required | Accepted value |
| --- | --- | --- |
| `Anchor` | yes, with `--require-anchors` | one or more `path:line` or `path:start-end` anchors, resolved against the worktree |
| `Category` | yes | `layout`, `font`, `wording`, `residue` or `behavior` |
| `Priority` | yes | `P1` (unreadable or hidden control), `P2` (visible defect, workaround exists), `P3` (cosmetic) |
| `Disposition` | yes | must contain `fix-on-discovery` |
| `Scope` | yes | must contain `out-of-scope-for-this-release` |
| `Evidence` | only for a fixed claim | a receipt path; an already-fixed claim without one fails the check |

An anchor that does not resolve to a real file and line in `W` fails the check. So does an item
that claims an already-fixed state without an evidence receipt.

**Recorded English residue is expected, not a defect (C2, C8, R10).** INI keys, section names,
widget IDs, game/DLL/API names, version strings, numeric values, key names and the `(?)` marker
stay English by contract. Only the friction *around* that residue belongs here.

## Items

### F1. Fixed-width `(?)` tooltips wrap on English line breaks

- Anchor: `OptiScaler/dlssnr/DlssNr_Menu.cpp:113` ; `OptiScaler/include/imgui/imgui.cpp:6812`
- Category: layout
- Priority: P3
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** hover the `(?)` marker next to the NR status line. The tooltip text is one literal
with a hand-placed `\n` tuned to the English sentence ("...including delays while other work
runs.\nCompare FPS to check the effect on game performance."). ImGui sizes a tooltip by
auto-fit up to the work-area clamp, so a Korean catalogue entry whose first line is wider than
the break produces a short first row and an unbalanced second row.

**Impact:** cosmetic only. Nothing is hidden, and no control moves.

**Fix sketch:** move the break out of the literal and let the wrap width do the work, or add a
per-catalog wrap hint. Needs a real in-game look at menu scale `0.5` and `2.0` first.

### F2. Bottom-bar language combo width is a fixed 100 px

- Anchor: `OptiScaler/menu/menu_common.cpp:7543`
- Category: layout
- Priority: P2
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** open the menu at a small menu scale and read the bottom bar. The switch is drawn with
`ImGui::SetNextItemWidth(100.0f * menuResScale)` with a hidden `##Language` label, next to the
Menu Scale combo that uses the same 100 px. The value shown is the language in effect, so a
Korean catalogue entry plus the script label `한국어` can be wider than the box at `0.5` scale
and the entry clips.

**Impact:** visible defect. The combo still opens and both entries are reachable, so a user can
work around it, but the current value is not fully readable.

**Fix sketch:** size the box from `CalcTextSize` of the widest entry plus frame padding, clamped
to a share of the content region, instead of the hard-coded 100 px.

### F3. NR pipeline chart nodes use a fixed node width

- Anchor: `OptiScaler/dlssnr/DlssNr_PipelineUi.h:98` ; `OptiScaler/dlssnr/DlssNr_PipelineUi.h:205`
- Category: layout
- Priority: P3
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** open the DLSS Neural Rendering placement tab and read the pipeline chart. `nodeWidth`
is derived from the available width (`* 0.5f` when split, otherwise `fontSize * 27.0f`, both
clamped), the row height is measured with `CalcTextSize(..., wrapWidth)` where
`wrapWidth = nodeWidth - padding * 2`, and the title is then center-drawn inside the same box.
Korean titles wrap to more lines than the English ones, so a long node (`Generate before
upscale, apply after upscale`) can grow its box or crowd its neighbour on a narrow overlay.

**Impact:** cosmetic, and only on the two split routes, where the width halves.

**Fix sketch:** budget the row height from the measured wrapped height of the widest label in
the row rather than from the node label alone, or raise the split node width floor.

### F4. Missing-font notice wording is a raw file list with no remedy

- Anchor: `OptiScaler/menu/Localization.cpp:158` ; `OptiScaler/menu/menu_common.cpp:7561`
- Category: wording
- Priority: P2
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** run on a host with no Hangul source resolvable and set the language to Korean. The
footer draws the one-shot notice "Korean font not found (malgun.ttf, gulim.ttc, Noto CJK KR) -
the menu stays English". It must stay English (the missing font is exactly why no Korean glyph
can be drawn), but it names internal file candidates instead of what the user should install,
and it shares the footer row with the language combo and the Save/Close buttons.

**Impact:** visible defect in the degraded path only. The language still falls back cleanly to
English and nothing is hidden, but the message does not tell the user what to do.

**Fix sketch:** rewrite the sentence around a user-facing remedy, and give the notice its own
row so a long message cannot push the footer buttons. Wording is an owner call.

### F5. Half-width toggle column wraps Korean labels onto a second line

- Anchor: `OptiScaler/dlssnr/DlssNr_PipelineUi.h:46` ; `OptiScaler/dlssnr/DlssNr_Menu.cpp:143`
- Category: layout
- Priority: P2
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** open the NR panel. `RenderMenu` splits the content region in half
(`toggleWidth = (avail - gap) * 0.5f`) and `CheckboxWrapped` wraps the clickable label at
`right = cursorX + width`. The four top-level toggles are English strings today; their Korean
catalogue entries are shorter in characters but no narrower in pixels, so a pair that fits on
one row in English can wrap to two lines in Korean and leave the two columns out of step.

**Impact:** visible defect. The label stays readable and the toggle stays clickable, but the
row pairing the layout promises is lost.

**Fix sketch:** measure both labels of a pair and only halve the row when both fit on one line,
otherwise stack them; or shorten the Korean labels.

### F6. Dynamic NR status text keeps English producer vocabulary

- Anchor: `OptiScaler/dlssnr/DlssNr_Menu.cpp:102` ; `OptiScaler/dlssnr/DlssNr_Menu.cpp:95`
- Category: residue
- Priority: P3
- Disposition: fix-on-discovery
- Scope: out-of-scope-for-this-release (later UI pass)

**Repro:** open the NR performance tab while NR runs. The templates translate through the
catalog, but two English fragments ride inside the format string and are not catalogue keys of
their own: the run suffix `"  (model running, edit hidden)"` concatenated at
`DlssNr_Menu.cpp:95`, and the vocabulary the DX12/Vulkan producers push through `%s` as the
failure, readiness or finished-picture reason (R10 producers). Both are expected English
residue under C8 and are explicitly **not** reported as defects by the row 6 protocol.

**Impact:** expected residue. Listed here only so a later release can decide whether to key the
producer vocabulary, and so the next reviewer does not re-litigate it as a defect.

**Fix sketch:** none inside this release. A future change would have to give the producer
vocabulary its own keys on the `DlssNr_Status` seam, which is a behavior-adjacent change with
its own review.

## Not in this backlog

- Anything that would change NR, FG, MFG, hook, input, wrapped or default-value behavior.
- Any shipped member, the installer, the manifest, the uninstaller or `OptiScaler.ini`
  defaults (C1c, R12).
- The stock uninstaller's pre-existing residue, recorded in `%E%\07\residue-set.json` and
  repaired by nobody in this release.
- A new language beyond `en` and `ko`, auto-save on toggle, or a bundled font.
