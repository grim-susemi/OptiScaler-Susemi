# Native XeFG MFG unlock (change notes)

> English change notes for this fork's native port of the XeFG multi frame generation
> unlock. Korean summary: [설치 안내](../INSTALL-KO.md). Adapted from the upstream
> change notes at commit `bb1619ec` (upstream file `README-XeFG-MFG-Unlock.md`, author
> Coldwood1026, GPL-3.0). Source and hashes: [section 9](#9-source-and-provenance).

This build makes OptiScaler's MFG multiplier control appear and switch in real time on
non-Intel adapters. The unlock is compiled in and patches the provider's mapped image
only. No external ASI unlocker is involved.

> **Do not run the external `XeFGUnlock.asi` alongside this build: if one has already patched `libxess_fg.dll`, the native per-byte checks fail, the whole patch set is rolled back, and the provider stays stock.**

Nothing on disk is changed. No Intel binary is repackaged, and the unlock refuses rather
than corrupts when it meets a provider build it doesn't know.

## 1. Why the control is missing

Intel gates MFG behind an "am I the `igxess_fg.dll` build?" check rather than a hardware
capability query. On a non-Intel adapter that means the provider reports
`maxSupportedInterpolations = 1`, and OptiScaler only draws its MFG combo when the reported
value is above 1. The gate therefore reads as "this GPU has no MFG at all".

| Symptom | Cause |
| --- | --- |
| The MFG multiplier combo doesn't appear | The provider reports `maxSupportedInterpolations = 1`, so OptiScaler's `maxInterpolationCount > 1` gate hides the whole control |
| Stuck at 2X, nothing higher selectable | The init path downgrades the MFG model (17 to 15, 18 to 16) because the check fails |
| Switching the multiplier crashes in similar mods | "Unlocking" and "switching" are coupled through model weight rebuilding |

This port removes the gates on the provider side, which separates unlocking from switching.
Switching then changes an integer and rebuilds nothing.

## 2. What this build changed

Everything below is part of the native port in this tree.

| File | Change |
| --- | --- |
| [`OptiScaler/proxies/XeFGUnlock.h`](../OptiScaler/proxies/XeFGUnlock.h) | New (309 lines). The patch engine: byte tables for the five patches, `.text` bounds checks, per-byte comparison, write-read-back verification, whole-set rollback. Header only, no new translation unit. |
| [`OptiScaler/proxies/XeFGPacing.h`](../OptiScaler/proxies/XeFGPacing.h) | New (1022 lines). Frame pacing above 2X, see [the pacing notes](README-XeFG-Pacing.md). |
| [`OptiScaler/proxies/XeFG_Proxy.h:7`](../OptiScaler/proxies/XeFG_Proxy.h) | `#include "XeFGUnlock.h"` |
| [`OptiScaler/proxies/XeFG_Proxy.h:176`](../OptiScaler/proxies/XeFG_Proxy.h) | Calls `XeFGUnlock::Apply(_dll);` in `HookXeFG()`, after `_dll = libxefgModule;` and before any `xefgSwapChain*` resolution |
| [`OptiScaler/Config.h:696,705-707`](../OptiScaler/Config.h) | `XeFGMaxInterpolations = 31` hard bound, plus `FGXeFGUnlockEnabled{false}` (off), `FGXeFGMaxInterpolatedFrames{5}` (6X), `FGXeFGExtraPacing{true}` |
| [`OptiScaler/Config.cpp:248`](../OptiScaler/Config.cpp) | `FGXeFGInterpolationCount` reload guard widened to `1..XeFGMaxInterpolations`, which also fixes the old `< 1 \|\| > 3` clamp that silently reset 5X and 6X selections on the next launch |
| [`OptiScaler/Config.cpp:259-264`](../OptiScaler/Config.cpp) | Reads `XeFG\UnlockMFG`, `XeFG\MaxInterpolatedFrames` (out of range falls back to the default), `XeFG\ExtraPacing` |
| [`OptiScaler/Config.cpp:1145-1148`](../OptiScaler/Config.cpp) | Writes the three keys back, so an edited value survives the next launch |
| [`OptiScaler.ini:250,254,258`](../OptiScaler.ini) | Config template gains the three keys, all shipped as `auto` |
| [`OptiScaler/menu/menu_common.cpp:4420`](../OptiScaler/menu/menu_common.cpp) | XeFG MFG combo uses named slots `{ "2X", "3X", "4X" }` and `Custom...` (:4466) instead of a dynamic string |
| [`OptiScaler/menu/menu_common.cpp:4514`](../OptiScaler/menu/menu_common.cpp) | The "! Enable VSync" warning shown whenever the effective multiplier goes above 4X |
| [`OptiScaler/menu/menu_common.cpp:4541`](../OptiScaler/menu/menu_common.cpp) | Extra Pacing checkbox |
| [`OptiScaler.vcxproj:528-529`](../OptiScaler/OptiScaler.vcxproj), [`OptiScaler.vcxproj.filters:509-514`](../OptiScaler/OptiScaler.vcxproj.filters) | Register the two new headers |
| [`package_release.ps1`](../package_release.ps1) | The packaging refuse-list now includes `UnlockMFG`, so a release package can't ship with the unlock forced on |

Deliberately not changed: `XeFG_Dx12.cpp` gets the pacing fallback only, no unlock logic.
The provider's reported maximum flows into `xefg_swapchain_d3d12_init_params_t::maxInterpolatedFrames`
at swapchain init already, so raising that number is all the init path needs. No Intel
binary is modified or redistributed, and the file on disk is never touched.

## 3. The five patches

All five are applied to the already-mapped image of `libxess_fg.dll`
(`file offset = RVA - 0xC00`). `N` is `XeFG\MaxInterpolatedFrames`. When `N` is 1, not one
byte is changed.

| # | RVA | Old to new | Effect |
| --- | --- | --- | --- |
| U1 | `0x20DA4F` | `0F 85 CC 00 00 00` to `E9 CD 00 00 00 90` | The per-frame resolver no longer falls back to 2X when it reads the XeLL version as too old |
| U2 | `0x1A5DE4` | `74 09` to `EB 06` | `Settings::mfgAllowed()` always answers true, so init stops downgrading the MFG model |
| U3 | `0x1A517D` | `BB 03 00 00 00` to `BB N 00 00 00` | Raises the default interpolation ceiling |
| U4 | `0x1A45C2` | `C7 87 6C 01 00 00 01 00 00 00` to the same with `N` | The override is pinned to the configured count instead of 1 |
| U5 | `0x20973B` | `B8 01 00 00 00` to `B8 N 00 00 00` | `xefgSwapChainGetProperties` stops reporting 1. This is the one that makes the combo box appear |

Every patch is located by RVA and compared byte for byte before it's written, because
`B8 01 00 00 00` occurs well over a thousand times in `.text` and
`C7 87 6C 01 00 00 01 00 00 00` occurs twice. A pattern-replace implementation would wreck
the module. With all five applied, the provider's reporting paths converge on `N`.

The engine also checks the PE build identity first (`0x69CB0F4D` / `0x015ED000` for
`libxess_fg.dll` 1.3.1.78). An unknown stamp doesn't stop the attempt: it logs a warning and
leans on the per-byte checks instead.

## 4. Configuration

In the `[XeFG]` section of `OptiScaler.ini`:

```ini
[XeFG]
; Native XeFG MFG unlock
; Fork-consistent default stays OFF - shipped packages refuse a true default
; true or false - Default (auto) is false
UnlockMFG=auto

; Caps how many interpolated frames XeFG may emit (6X ceiling)
; 1..31 - Default (auto) is 5
MaxInterpolatedFrames=auto

; Extra frame pacing work for unlocked XeFG modes
; true or false - Default (auto) is true
ExtraPacing=auto
```

Both the unlock and the pacing read their switch once, at provider load, so save and
restart. `MaxInterpolatedFrames=1` is the same as turning the unlock off, and no patch is
applied at all. The hard bound is 31 (`XeFGMaxInterpolations`), and values outside `1..31`
fall back to the default 5.

Two keys do different jobs and are easy to confuse. `MaxInterpolatedFrames` decides how
high the menu can go, since the multiplier is this value plus one. `InterpolationCount`
decides which multiplier the session starts at. They're independent.

The value isn't only a menu bound. The provider's reported maximum is read back into
`maxInterpolatedFrames` at swapchain init, so this number is declared to the provider on
every launch. `1..6` has been exercised; higher is untested, and if the provider sizes
anything from it the symptom would be a failed init or exhausted VRAM. Setting it back to 5
is the way out.

## 5. Building

Same as upstream, no extra dependencies:

```powershell
msbuild OptiScaler.sln /p:Configuration=Release /p:Platform=x64
```

Output: `x64\Release\OptiScaler.dll`.

## 6. Turning it off

Any one of three:

1. **Config only.** Set `XeFG\UnlockMFG=false`, or `XeFG\MaxInterpolatedFrames=1`. The
   second one applies no patch at all, and the provider keeps its factory behaviour.
2. **Back to stock.** Overwrite with a build that has no unlock. The provider DLL on disk
   was never modified, so there's nothing to clean up.
3. **Partial failure is safe.** If a single patch fails its byte comparison, say on a
   different provider build, the engine rolls the whole set back and the provider runs as
   shipped. Failure means no MFG, never a crash. On a build mismatch the log shows
   `unrecognised provider build` and then `rolled back`.

## 7. Verification status

Upstream verified the mechanism in game on 2026-09-11 in Cyberpunk 2077 on an RTX 2060 with
`libxell.dll` 1.3.0: all five patches applied (`5 of 5 patches applied (0 skipped)`), the
reported maximum went from 1 to 5, the combo box appeared with 2X to 6X selectable, and six
consecutive switches in 90 seconds held without a crash.

This tree has not been checked in a game yet. The owner runs the in-game acceptance, and
that result is the first thing that will say whether the port works here. The default
ceiling of 5 keeps the tested envelope. Anything above 6X is untested.

Lines to look for in `OptiScaler.log`:

| Line | Meaning |
| --- | --- |
| `XeFG unlock: 5 of 5 patches applied (0 skipped), MFG enabled up to 5X` | The unlock landed |
| `XeFG unlock: unrecognised provider build ... , relying on per-byte checks` | A build the engine doesn't recognise, so the byte checks alone decide |
| `XeFG unlock: rolled back N patch(es)` | A patch comparison failed and everything was undone. Expected fail-closed outcome, not a crash |
| `Max supported interpolations: 5` | What the provider now reports, which is what makes the menu appear |

## 8. GPL-3.0 modification notice

Per GNU GPL v3 section 5(a): "The work must carry prominent notices stating that you modified
it, and giving a relevant date."

The upstream document this one is adapted from carries its own notice in its section 8, for
the fork that first wrote the unlock (OptiScaler commit `bb1619ec`, Coldwood1026, date of
modification 2026-09-11). This repository is a different modification, so it carries its own:

> This repository is a modified version of [OptiScaler](https://github.com/optiscaler/OptiScaler).
> Date of modification: 2026-09-23. The changes are the native port described in section 2
> above: added `OptiScaler/proxies/XeFGUnlock.h` and `OptiScaler/proxies/XeFGPacing.h`,
> modified `XeFG_Proxy.h`, `XeFG_Dx12.cpp`, `Config.h`, `Config.cpp`, `OptiScaler.ini`,
> `menu_common.cpp`, `OptiScaler.vcxproj`, `OptiScaler.vcxproj.filters` and
> `package_release.ps1`. The unlock engine itself is vendored from upstream commit `bb1619ec`
> and is byte-identical to it.
>
> Copyright in the original work stays with the OptiScaler authors, licensed under GPL-3.0.
> This modified version is likewise licensed under GPL-3.0, with the full licence text in
> [`LICENSE`](../LICENSE). The complete corresponding source for the modifications is this
> repository.

## 9. Source and provenance

Upstream source of the port, pinned to one commit, never a branch head:

| Item | Value |
| --- | --- |
| Repository | `optiscaler/OptiScaler` |
| Commit | `bb1619ec1eac76e8109d3adf9c795d6d37ba1ba4` ("XeFG: unlock multi frame generation and fix >2X pacing", author Coldwood1026, 2026-09-12, parent `5ee53e38`) |
| Upstream document | `README-XeFG-MFG-Unlock.md`, sha256 `b2c68318087b3af692013f246407ac78cba16e2c3b32d71f7560c7d424ec3fc5` |
| Commit patch | sha256 `490fe10354b0d8ec328d4cab5585b8745c15f2895abb4a2d0ca2b3d7d8f5645d` |
| Raw fetch | `https://raw.githubusercontent.com/optiscaler/OptiScaler/bb1619ec1eac76e8109d3adf9c795d6d37ba1ba4/README-XeFG-MFG-Unlock.md` |

How this document differs from the upstream one, so the two can be told apart:

- The line references point at this tree, not the upstream fork (config keys, menu anchors,
  `XeFG_Proxy.h`, `XeFG_Dx12.cpp`).
- The defaults are this fork's: unlock off, ceiling 5, extra pacing on. Upstream shipped the
  unlock on with a ceiling of 31.
- The upstream Chinese translation (`README-XeFG-MFG-Unlock.zh-CN.md`) is not shipped here.
  Korean users get the summary in [INSTALL-KO.md](../INSTALL-KO.md).
- The external ASI conflict warning and the packaging refuse-list entry describe this port.

Related: [frame pacing notes](README-XeFG-Pacing.md), [RTX 40 MFG unlock](RTX40-MFG.md),
[configuration](../Config.md).
