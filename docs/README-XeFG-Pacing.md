# XeFG frame pacing (change notes)

> English change notes for the pacing half of this fork's native XeFG port. Korean summary:
> [설치 안내](../INSTALL-KO.md). Adapted from the upstream change notes at commit
> `bb1619ec` (upstream file `README-XeFG-Pacing.md`, author Coldwood1026, GPL-3.0). Source
> and hashes: [section 9](#9-source-and-provenance).

Above 2X the provider hands every generated frame of a burst to the swapchain back to back
and only spaces the burst as a whole. The frames arrive bunched up, and the frame time the
provider is given is self-referential, so the "real" frame stretches as the multiplier
climbs. This port paces each generated frame through the provider's own scheduler and hands
over a frame time with its own blocking taken back out.

The pacing is behind `XeFG\ExtraPacing`, on by default. It installs from the unlock's apply
pass and only does anything above 2X, so it needs [the MFG unlock](README-XeFG-MFG-Unlock.md)
to be on.

## 1. The problem

`xefg_swapchain.h` documents `frameRenderTime` as the time the current frame took to render,
and the provider sizes the generated interval from it. Nothing fills `_ftDelta` on the XeFG
backend, since `SetFrameTimeDelta` is only wired up for the FSR and Streamline paths. The
fallback used to be `state.lastFGFrameTime`, the present to present delta.

That value brackets the whole of the previous present, the pacing included. Above 2X, where
the provider really does space the frames out, it is circular: the frames are asked to fill
a period that only exists because they were asked to fill it. The fixed point works out as

```
period = renderTime + period * count / (count + 1)
```

so the real frame period settles at `renderTime * (count + 1)` instead of coming down towards
the time the game actually spends rendering. The higher the multiplier, the longer the frame
gets, and that's where the input latency came from.

The second half of the problem is ordering. Once per burst the provider works out the spacing
it wants (`duration / (count + 1)`), but the loop that follows submits every generated frame
immediately and doesn't consume that value. The value is only read afterwards, by a limiter
block that holds the *last* frame of the burst back. So a burst goes out as fast as the
swapchain accepts it and then stalls, which reads as frames arriving bunched up and out of
order.

## 2. What changed

| File | Change |
| --- | --- |
| [`OptiScaler/framegen/xefg/XeFG_Dx12.cpp:3`](../OptiScaler/framegen/xefg/XeFG_Dx12.cpp) | `#include <proxies/XeFGPacing.h>` |
| [`OptiScaler/framegen/xefg/XeFG_Dx12.cpp:1010-1016`](../OptiScaler/framegen/xefg/XeFG_Dx12.cpp) | `frameRenderTime` fallback chain: `_ftDelta` first, then `XeFGPacing::RenderTimeMs()`, then `state.lastFGFrameTime` |
| [`OptiScaler/framegen/xefg/XeFG_Dx12.cpp:1035`](../OptiScaler/framegen/xefg/XeFG_Dx12.cpp) | `XeFGPacing::NoteFedFrameTime(constData.frameRenderTime)` records what the provider actually got |
| [`OptiScaler/framegen/xefg/XeFG_Dx12.cpp:1039-1041`](../OptiScaler/framegen/xefg/XeFG_Dx12.cpp) | The debug line reports input, measured and set frame time together |
| [`OptiScaler/proxies/XeFGPacing.h`](../OptiScaler/proxies/XeFGPacing.h) | The pacing itself, installed from `XeFGUnlock.h:182` only when the unlock landed and the multiplier is above 2 |

The `state.lastFGFrameTime` fallback stays as the last resort. `RenderTimeMs()` returns 0
until the pacing has seen a burst, so early frames behave exactly as before.

## 3. How the pacing works

### 3.1 The three hooks

| Hook | Site | Purpose |
| --- | --- | --- |
| Present thunk | RVA `0x25C0` | Redirects every generated-frame present through the detour, which paces the two burst call sites and forwards the thunk's other two callers untouched |
| Scheduler thunk | RVA `0x3100` | Puts each paced frame through the provider's own frame scheduler instead of inventing a spacing |
| Timestamp thunk | RVA `0x3430` | Repairs the provider's deadline arithmetic so a burst's frames get distinct times |

All offsets come from `libxess_fg.dll` 1.3.1.78, the same build the unlock targets.

The present thunk is five bytes of `jmp` followed by eleven bytes of `int3` padding: sixteen
bytes containing nothing but a jump. That's room for a 14 byte `jmp qword ptr [rip+0]`, so
the thunk can be redirected anywhere without relocating an instruction and without a code
cave. The detour sorts callers by `_ReturnAddress()`, and only the two burst sites are paced.

The spacing isn't invented here. The provider has a frame scheduler of its own, and it calls
it for the burst's last frame only. Each paced present is handed to that scheduler with the
arguments the present path already has, so the provider computes the presentation time.

### 3.2 Why the burst's last frame has its own site

The last generated frame of a burst isn't presented from the loop. It goes out after the loop
and after the provider submitted the burst, from a different call site, so it needs pacing of
its own. Left alone, every burst ends with two frames carrying the same timestamp: at 4X the
pattern comes out `0, i, 2i, 2i` instead of `0, i, 2i, 3i`.

The provider does space that frame itself, but only from its limiter block, and only when
three conditions hold (its limiter enabled, the burst count above 2, and its per-burst field
at zero). The pacing mirrors that condition so exactly one of the two waits is ever placed on
that frame. Two waits would stack into one long frame.

### 3.3 The deadline repair

The timestamp hook re-anchors a burst's schedule when the burst base is stale, and adds back
whatever the provider's `min()` clamp took away. Without it the burst's own arithmetic can
land two frames on the same deadline, which is half of the ordering trouble.

### 3.4 The gate

Pacing is skipped entirely at 2X. That's the multiplier where the provider's own handling is
enough, and holding a frame there would only add latency. Above 2X, each generated frame of a
burst is paced, and the provider's own limiter still owns the last one.

### 3.5 The fallback, and the fence wait that was removed

If the scheduler thunk can't be hooked, the pacing falls back to a wall clock: a target QPC
that advances by the burst interval, with `Sleep(0)` and `YieldProcessor` spinning until it's
reached. `Sleep(1)` is deliberately avoided, because its granularity is a full timer tick,
coarser than the interval being hit.

Waiting on the provider's own D3D12 fence as well was implemented and then removed. A short
`WaitForSingleObject` timeout rounds up to the system timer tick, so every expired wait
overshot by about 7 ms and the measured gap between generated frames ended up 30 to 40 per
cent above target. Reinstating it means re-measuring, not just re-enabling.

### 3.6 The frame time handed to the provider

The burst period the pacing measures is taken at the present, so it contains the blocking the
pacing itself did. `NoteFrame` subtracts this burst's own blocking from the measured period
and exposes the remainder through `RenderTimeMs()`. That's the part of the frame the game
actually got to spend rendering, which is the quantity the provider means by
`frameRenderTime`.

It's an upper bound rather than an equality, since the provider's own wait on the burst's
last frame happens inside the same window and isn't measured. Over-reporting just leaves some
of the lock in place. Under-reporting would be the dangerous direction, because it would ask
for a burst shorter than the frames can be produced in.

`FTInput` sets which value goes to the provider, as a runtime A/B switch:

| `[XeFG] FTInput` | Value handed over |
| --- | --- |
| `Input` (default) | The fallback chain above, so the pacing estimate when there is one |
| `Opti` | `state.lastFGFrameTime`, the old behaviour |
| `Zero` | `0.0` |

## 4. Configuration

| Where | Option | Default | Notes |
| --- | --- | --- | --- |
| `OptiScaler.ini`, `[XeFG]` | `ExtraPacing` | `true` | Master switch. Read once at provider load, so save and restart |
| in-game menu, frame generation | **Extra Pacing** | on | Same switch. Needs a restart, because the install pass rewrites the present thunk at provider init |
| `OptiScaler.ini`, `[XeFG]` | `FTInput` | `Input` | Which frame time the provider gets, see section 3.6 |
| `OptiScaler.ini`, `[XeFG]` | `MaxInterpolatedFrames` | `5` | The multiplier menu's ceiling, multiplier being this value plus one |

The in-game multiplier combo lists **2X / 3X / 4X** by name and then **Custom...**. 2X to 4X
are the multipliers that hold up on their own. 5X and above go through the custom slot, which
takes a free-form multiplier clamped to the provider's reported maximum. **Above 4X the menu
shows a VSync warning, and it isn't decoration:** at those multipliers the burst is presented
faster than the display refreshes, and nothing inside the provider can pull that back. It
needs the present rate capped from outside by VSync or a frame-rate cap, otherwise the extra
frames tear and judder.

## 5. Limits

- **The MFG unlock is required.** The pacing installs from the unlock's apply pass and only
  makes sense above 2X, which the unlock is what makes reachable. A stock build never gets
  here.
- **Tied to one provider build.** The offsets come from `libxess_fg.dll` 1.3.1.78 (build
  identity `0x69CB0F4D`). A different provider build means different offsets. The thunk byte
  comparisons fail and the pacing declines to install rather than corrupt anything, but the
  offsets would have to be re-derived.
- **Above 4X needs an external cap** (section 4).
- **The old fence wait is gone on purpose** (section 3.5). Reinstating it means re-measuring.
- **The provider's hard ceiling stands.** When the present rate runs past the refresh rate,
  no amount of intra-burst scheduling fixes it.

## 6. Observability and maintenance

One INFO line every 5 seconds carries everything the pacing did:

```
XeFG pacing: {mult}X, real frame {:.2f} ms ({:.1f} fps), target {:.2f} ms/frame;
gap {:.2f} avg / {:.2f} min / {:.2f} max ms over {} frames;
scheduler {} calls, {} refused, {:.2f} ms avg inside;
deadlines {} calls, {} rebased, {} clamped; render-est {:.2f} ms, fed {:.2f} ms
```

How to read it:

| Field | Meaning |
| --- | --- |
| `real frame` / `target` | The measured period and the period the pacing is aiming at |
| `gap ... avg / min / max` | Spacing between consecutive paced frames, the only direct evidence that they come out evenly. If `max` is a multiple of `target`, frames are still clumping |
| `scheduler ... calls / refused` | A refused call and a completed one look identical from outside. This is what separates them. If `refused` equals `calls`, the scheduler was doing nothing and the wall clock should have been pacing |
| `deadlines ... calls / rebased / clamped` | How often the provider's own arithmetic had to be corrected |
| `render-est` vs `real frame` | The decisive pair. If `render-est` sits clearly below `real frame`, section 1's lock was real and has been broken. If they're about equal, the measured period is set by the GPU or the display |
| `fed` | What was actually handed to the provider. With the default `FTInput` it should track `render-est`; if it tracks `real frame`, `RenderTimeMs()` returned 0 and the fallback was used |

### A format-string error here kills the pacing silently

This is the one maintenance hazard that has already cost a full test run, so it's worth
stating in full.

That `LOG_INFO` runs on the present thread and has no `try`/`catch` around it. `fmt` ignores
surplus arguments, so an over-supplied call is harmless, but a type specifier landing on the
wrong argument is fatal: it throws `fmt::format_error` at runtime, and the throw unwinds
straight out of the hook. The statistics are reset after the report is emitted, so the first
throw leaves the deadline permanently in the past and every later call throws too. The pacing
is then dead for the rest of the session.

What makes it worth a section is that it's silent. The line that would have reported the
problem is the line that throws, so the log simply stops mentioning pacing, which is easy to
mistake for "the pacing had no effect".

Before touching that report line, count the placeholders. The upstream tree carries a script
for exactly that, `_analysis/check_reportstats_args.py`, which pairs the format placeholders
with the argument list and flags a float specifier landing on a counter.

## 7. Provenance

Upstream developed the pacing over nine measured rounds against a live Cyberpunk 2077 session
on an RTX 2060, checking each round's prediction against the previous round's log. Several
earlier conclusions were refuted by measurement and withdrawn: the fence wait (section 3.5),
and the assumption that the function at `0x21EE30` was a fence wait at all. It's the frame
scheduler, which is what made this approach possible.

This tree vendors that mechanism from the same pinned commit as the unlock, with no change to
the pacing logic.

## 8. GPL-3.0 modification notice

Per GNU GPL v3 section 5(a): "The work must carry prominent notices stating that you modified
it, and giving a relevant date."

The upstream document this one is adapted from carries its own notice in section 8 of
`README-XeFG-MFG-Unlock.md` at commit `bb1619ec` (Coldwood1026, date of modification
2026-09-11). This repository is a different modification, so it carries its own:

> This repository is a modified version of [OptiScaler](https://github.com/optiscaler/OptiScaler).
> Date of modification: 2026-09-23. The changes are the native port of the XeFG MFG unlock and
> its pacing, described in [the unlock notes](README-XeFG-MFG-Unlock.md) section 2 and in
> section 2 above. The pacing engine is vendored from upstream commit `bb1619ec` and is
> byte-identical to it.
>
> Copyright in the original work stays with the OptiScaler authors, licensed under GPL-3.0.
> This modified version is likewise licensed under GPL-3.0, with the full licence text in
> [`LICENSE`](../LICENSE). The complete corresponding source for the modifications is this
> repository.

## 9. Source and provenance

| Item | Value |
| --- | --- |
| Repository | `optiscaler/OptiScaler` |
| Commit | `bb1619ec1eac76e8109d3adf9c795d6d37ba1ba4` ("XeFG: unlock multi frame generation and fix >2X pacing", author Coldwood1026, 2026-09-12, parent `5ee53e38`) |
| Upstream document | `README-XeFG-Pacing.md`, sha256 `110ec7e78ab20c05346e8948a8f69d4a98373dd4548abe6a1405ef635af28267` |
| Commit patch | sha256 `490fe10354b0d8ec328d4cab5585b8745c15f2895abb4a2d0ca2b3d7d8f5645d` |
| Raw fetch | `https://raw.githubusercontent.com/optiscaler/OptiScaler/bb1619ec1eac76e8109d3adf9c795d6d37ba1ba4/README-XeFG-Pacing.md` |

How this document differs from the upstream one:

- Section references in the code comments (`08-PACING.md` in the upstream fork) point at
  upstream's own analysis tree, which isn't shipped here.
- The defaults are this fork's: extra pacing on, ceiling 5, unlock off.
- The upstream Chinese translation (`README-XeFG-Pacing.zh-CN.md`) is not shipped here.

Related: [native XeFG MFG unlock](README-XeFG-MFG-Unlock.md), [RTX 40 MFG unlock](RTX40-MFG.md),
[configuration](../Config.md).
