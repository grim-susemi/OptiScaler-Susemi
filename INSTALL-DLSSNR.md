# Install Neural Rendering

This package carries the OptiScaler NR build (wilsjo2 base with the RTX 40 MFG unlock compiled in) plus a Korean menu localization and two optional helpers: an ASI loader and a Streamline runtime fetcher.

NR is experimental and disabled by default. Do not use injection mods in anti-cheat-protected multiplayer games.

Korean guide: [INSTALL-KO.md](INSTALL-KO.md).

The optional [RTX 40 MFG unlock](docs/RTX40-MFG.md) needs an unlock-enabled build (this one) and its runtime toggle, which still defaults off.

The optional RTX 20/30 (SM75/SM86) MFG unlock ships the sdli1995 payload for Turing and Ampere cards. The section below covers its requirements, the 1..5 multiplier mapping, the 6X caveat and the uninstall steps.

## Quick start

1. Close the game and launcher, then back up any existing OptiScaler files and your INI.
2. Extract the **whole** package into the folder that holds the real game executable (Crimson Desert: `...\Crimson Desert\bin64`). Keep every folder.
3. Install the payload - pick one method:
   - **Proxy (default):** run `setup_windows.bat` and choose a proxy name; `[1] dxgi.dll` unless another injector already uses it. No loader is needed.
   - **ASI (use this when another injector occupies the proxy names, for example XeFG together with ReShade):** run `Install_AsiLoader_windows.bat` and pick `[1]` (installs the bundled Ultimate ASI Loader as `winmm.dll`), then run `setup_windows.bat` and pick `[8] OptiScaler.asi`.
4. Start the game and press `Insert` to open the overlay (`Alt+Insert` on layouts that remap Insert).
5. Optional, Neural Rendering: place `nvngx_dlssnr.dll` beside the game executable, then enable NR in the overlay and start with one pass. See [Requirements](#requirements).
6. Optional, frame-generation runtime: run `Streamline_fetcher_windows.bat` to download NVIDIA's official Streamline release into `OptiScaler\streamline`; do this only when the game does not already provide a suitable runtime.
7. Optional, RTX 40 (Ada) MFG unlock: enable **RTX 40 MFG unlock (restart)** under frame-generation settings, save and restart. RTX 40 only, and it needs a supported DLSSG runtime.
8. Optional, RTX 20/30 MFG unlock: enable **Enable SM75/SM86 MFG (experimental; restart)** under frame-generation settings, save and restart. RTX 20/30 only; the payload ships with this build, so there's nothing extra to download. See [RTX 20/30 (SM75/SM86) MFG unlock](#rtx-2030-sm75sm86-mfg-unlock-optional) below.
9. Removal: run `Remove_OptiScaler.bat` (created by `setup_windows.bat`), and `Install_AsiLoader_windows.bat` -> `[4]` to remove the ASI loader; it restores the file it backed up.

On upgrades, replace the **proxy the game loads**: adding `OptiScaler.dll` beside an old `dxgi.dll` does not update it. Preserve your INI and other mods' loaders.

## Requirements

- A 64-bit game using an OptiScaler D3D12 path, a supported D3D11/Vulkan bridge, or native Vulkan NR.
- An NVIDIA driver whose installed NGX core supports NR (feature 18).
- The complete OptiScaler package and a separately supplied `nvngx_dlssnr.dll`.
- The NVIDIA Streamline runtime used by frame generation; the bundled `Streamline_fetcher_windows.bat` installs it into `OptiScaler\streamline`.

NR runs inside OptiScaler. No NR helper DLL is required; remove the obsolete `nvngx.dll_dlssnr.dll` when upgrading. Keep the package's ordinary backend dependencies.

### Runtime identification

These are the 310.8 variants used during development, not a verified GPU support matrix. The installed driver must accept the runtime.

| Variant | Intended GPUs | SHA-256 |
| --- | --- | --- |
| Original NVIDIA-signed | RTX 50 | `E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E` |
| ShortFuse compatibility | RTX 20/30/40; retains RTX 50 path | `E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A` |

The compatibility runtime is available in [ShortFuse's RenoDX thread](https://discord.com/channels/1408098019194310818/1545049227321810974). Modification invalidates its NVIDIA signature: verify the hash and keep security protection enabled. Its RTX 20/30 path is substantially heavier. The RenoDX add-on itself is not needed; two NR injectors can conflict.

```powershell
Get-FileHash .\nvngx_dlssnr.dll -Algorithm SHA256
```

### ASI installation in detail

The ASI method needs an ASI loader; without one an `OptiScaler.asi` file is never loaded. The package carries the MIT-licensed Ultimate ASI Loader v9.7.4 under `tools\asi-loader\`.

1. Run `Install_AsiLoader_windows.bat` and pick `[1]` to place the loader as `winmm.dll` (or `[2]` for another name the game loads).
2. Run `setup_windows.bat` and pick `[8] OptiScaler.asi`.
3. The helper backs up any file it replaces and can undo itself with `[4]`.

Use this when another injector already occupies the default proxy names, or when the game runs XeFG together with ReShade.

### Known game layouts

| Game | Executable directory | Tested/configured route |
| --- | --- | --- |
| Crimson Desert | `bin64` | ASI: `OptiScaler.asi` via `winmm.dll` (Ultimate ASI Loader) |
| Baldur's Gate 3 | `bin` | DX11: `Dx11Upscaler=dlss_12`; native Vulkan: `VulkanUpscaler=dlss` (gameplay unverified) |
| Hogwarts Legacy | `Phoenix/Binaries/Win64` | `dxgi.dll` |
| Cyberpunk 2077 | `bin/x64` | `dbghelp.dll`; existing loaders may need chaining |

Keep `[ProcessFilter] TargetProcessName=auto` for portable configurations. A different executable name intentionally disables injection, including the menu.

```ini
[DlssNr]
Enabled=true
RunBeforeSR=true
Passes=1
WorkingScale=1.0
```

For native Vulkan, enable NR in the INI before launch so device/swapchain support is prepared.

## RTX 20/30 (SM75/SM86) MFG unlock (optional)

This build bundles the `sdli1995/dlssg_for_sm86` payload (v0.3.5) for RTX 20 (Turing, SM75) and RTX 30 (Ampere, SM86) cards. The module ships inside the package at `OptiScaler\dlssg_sm86\` and OptiScaler loads it at game start: there's no extra download and no manual sideload step. Keep that folder when you extract the package.

### Requirements

- **RTX 20 or RTX 30 only** (Turing SM75, Ampere SM86). On RTX 40 use the [RTX 40 MFG unlock](docs/RTX40-MFG.md) instead; the two unlockers must never be active together.
- **Driver R580 or newer recommended.** Older drivers aren't refused, but R580+ is the baseline the payload's author reports.
- **The payload ships with this build**, so there's nothing to fetch: `OptiScaler\dlssg_sm86\dlssg_sm86.dll`, its companion `dlssg_sm86.ini` and `THIRD_PARTY_NOTICES.txt` are all in the package.
- A game whose frame generation runs through NVIDIA Streamline. The payload hands its generated frames to the game's own DLSS-G plugin, so the game's FG menu picks the multiplier.
- The unlock is off by default, and changing it needs a restart.

### Enable

In the menu, under frame-generation settings, open the **RTX 20 / 30 (SM75 / SM86) MFG unlock** section:

1. Tick **Enable SM75/SM86 MFG (experimental; restart)**. External FG turns on with it, and the game's own FG menu then selects the multiplier.
2. Set **Max Generated Frames** (1 to 5) if you want more than the default 4X.
3. Pick a **Kernel Image** only if Auto misbehaves: Auto resolves the format from your card, PTX is the safe choice on RTX 20, and Cubin needs an exact physical match on Windows.
4. Optional, RTX 30 only: **Hardware Bilinear** trades exact output for about 2 to 4 percent lower GPU latency.
5. Save Settings and restart the game. The status line in that section reports the loader's state (`Disabled`, `Ineligible`, `Conflict`, `Loaded` and so on), with the reason underneath it.

Or set the keys in the INI before launch:

```ini
[DLSSG]
AmpereMfgUnlock=true
AmpereMfgMaxFrames=3
AmpereMfgKernelImage=auto
AmpereMfgHardwareBilinear=false
```

| Key | Values | Default | Meaning |
| --- | --- | --- | --- |
| `AmpereMfgUnlock` | true/false | false | Turns the 20/30 unlock on. Read once at startup. |
| `AmpereMfgMaxFrames` | 1 to 5 | 3 | Advertised maximum multiplier: **1 = 2X, 2 = 3X, 3 = 4X, 4 = 5X, 5 = 6X**. The game still picks the actual multiplier from its own FG menu. |
| `AmpereMfgKernelImage` | auto, PTX, Cubin | auto | Kernel format. Auto resolves it from the physical GPU. |
| `AmpereMfgHardwareBilinear` | true/false | false | RTX 30 (SM86) only: approximate hardware bilinear sampling, about 2 to 4 percent lower GPU latency. |

**6X caveat:** 5 (6X) works only when the game ships a Streamline frame-generation plugin 2.11.1 or newer. With an older plugin the payload clamps the request (its log records `limit_clamped`) and you get the highest multiplier that plugin supports. The game also has to ask for that many frames itself.

Every setting here is read once, at startup. Save Settings and restart the game; nothing in this section applies live.

### Verification gap

**No RTX 20/30 hardware was available for this build.** This project's build and test host carries an RTX 4090, so the 20/30 path was verified at the loader, configuration, packaging and arming-order level only. How a real RTX 20 or RTX 30 card behaves with it is **externally reported** (field reports from the payload's users), not measured here. Treat the multiplier and performance behaviour on 20/30 as unverified.

### Disable and remove

1. Set `[DLSSG] AmpereMfgUnlock=false` (or clear the checkbox), Save Settings and restart.
2. Turn External FG off as well if you don't want it any more. The unlock enables it, and it keeps its stored value after the unlock is disabled.
3. Delete `OptiScaler\dlssg_sm86\` to remove the module, its companion INI and its `logs\` folder. Nothing else is added, and no registry key is written.
4. `Remove_OptiScaler.bat` removes the whole package as usual.

### Attribution

The bundled payload is `sdli1995/dlssg_for_sm86` v0.3.5 (pinned commit `9621db5`), shipped unmodified from https://github.com/sdli1995/dlssg_for_sm86

NVIDIA's runtime and model components and the SM75 kernel family inside that payload carry their own terms. The upstream notices ship with the package as `OptiScaler\dlssg_sm86\THIRD_PARTY_NOTICES.txt`, plus a copy under `Licenses\`. Upstream states GPLv3 in prose but the repository carries no `LICENSE` file; that licensing gap is recorded here instead of being hidden. The payload is self-signed (`CN=DLSSG for SM86`), so SmartScreen shows an unknown publisher.

## Placement and resolution

| Setting | Behaviour |
| --- | --- |
| Generate model before upscale | Edit the active input before SR or RR+SR. Off runs NR afterward. |
| Generate before upscale, apply after upscale | Upscale NR's edit separately; the game reconstructs its clean input. |
| Apply NR to the finished picture | Apply after effects/HUD. With early generation enabled, carry the edit to presentation. |

Model resolution is relative to the image at the selected stage. At 1440p input/4K output, 100% means 1440p before SR and 4K afterward. Lower percentages reduce NR work without changing the game's upscaler preset. See [pipeline controls](docs/NR-PIPELINE-UI.md) and [enlargement](docs/NR-DLSS-ENLARGEMENT.md).

Below 100% model resolution, the Enlargement setting picks how the model's answer is enlarged. **Lighting + colour** (`Transfer=3`) resizes lighting gain and colour changes separately with bilinear reconstruction, on DX12 and native Vulkan. **Lighting + colour + DLSS** (`Transfer=4`) enlarges the same fields through private DLSS SR and needs post-upscale DX12 processing, including the existing DX12 bridges; it is not available before the game upscaler or in native Vulkan processing. The default stays Matched residual (`Transfer=1`); Classic, Matched residual and Matched residual + DLSS keep their existing algorithms, and native/supersampled model processing bypasses the new reconstruction. The [v0.8.8 release note](docs/RELEASE-v0.8.8.md) carries the upstream validation detail.

Finished-picture NR supports D3D12, its D3D11 bridge and native Vulkan with supported SDR/HDR10/scRGB formats. It can alter HUD/menus. Early generation plus finished-picture application requires D3D12 or the D3D11 bridge; Vulkan cannot carry that private edit. Unsupported frames retain the game image. See [bridges](docs/NR-FINISHED-BRIDGES.md).

SR and RR share pass count, profiles and model resolution. Separate-edit placement stays manual. Keep genuine `nvngx_dlssd.dll` (RR) separate from `nvngx_dlssnr.dll` (NR). If Cyberpunk's RR option is unavailable with a `d3d12.dll` proxy, [a reported workaround](https://github.com/Dagherbou/OptiScaler_DLSSNR/issues/8) is `dxgi.dll`; check existing loaders first.

Turning off **Apply model** hides the edit while NR still runs; the master switch stops NR. GPU timings measure elapsed work and can overlap other work; compare total frame time for performance. A private upscaler adds cost beyond the NR model timer.

### NR under XeFG frame generation

XeFG placement is its own route. The config-only path below needs no new build and keeps the deferred carrier working while frame generation is on. Frame generation stays ON throughout. The finished-picture handoff under XeFG is covered by [the bridges note](docs/NR-FINISHED-BRIDGES.md): this build ships the owned application-frame handoff, so the finished-picture path is available under XeFG. In-game verification is still pending.

| Setting | Value | Where |
| --- | --- | --- |
| Enlargement | Matched residual (`Transfer=1`) | Prepare NR input |
| Model resolution | 75% (`WorkingScale=0.75`) | Prepare NR input |
| Generate before upscale, apply after upscale | ON | NR pipeline |
| Apply NR to the finished picture | OFF for the config-only path; the new handoff ships in this build, so the finished-picture path is available under XeFG | NR pipeline |
| Private NR upscaler | DLSS (`PrivateUpscaler=0`) | NR pipeline |
| Apply model | ON | NR pipeline |
| Compare / Debug view / skin-mask preview | OFF | Inspect NR |
| HdrTransfer | auto (false) | INI |

Transfer=1 drops the DLSS-carried enlargement (composed by the shader instead); WorkingScale=100% is the alternative that keeps Transfer=2 at ~+78% model pixels.

With `[Log] LogToFile=true` and `LogLevel=2`, the placement reports itself:

- Deferred carrier: `DLSS-NR deferred upscale: running: <dimensions> contribution -> private DLSS RR -> <dimensions>; applied after SR`
- Finished-picture handoff: `DLSS-NR finished picture: <N> frames, <W>x<H>, OptiScaler FG true, same producer queue true, game-frame handoff true`
- Cold start on the XeFG path: `NR_XEFG_ROUTE streamline_registered=0 source=app_proxy queue_source=xefg_application format=<DXGI_FORMAT> colorspace=<DXGI_COLOR_SPACE>`
- After the original proxy Present: `NR_XEFG_PRESENT generation=<G> frame=<F> enabled=1 framegen_result=0 frames_presented=6`

Three caveats:

- Keep frame generation on: no FG-OFF workaround exists.
- The bundled XeFG SDK supports HDR10 (`R10G10B10A2_UNORM`) only: no FP16/scRGB.
- frames_presented counts submitted pictures, not verified scanout.

These placement paths are not verified in-game on this machine: it has no RTX 20/30 hardware and runs no XeFG session. The owner runs the in-game acceptance.

## Files in this package

| File | Purpose |
| --- | --- |
| `OptiScaler.dll` | The payload; `setup_windows.bat` renames it to the proxy or ASI name you pick. |
| `OptiScaler.ini` | Settings. Keep it when upgrading. |
| `setup_windows.bat`, `setup_linux.sh` | Installer and uninstaller generator. |
| `Install_AsiLoader_windows.bat` | Installs or removes the bundled Ultimate ASI Loader (MIT). |
| `Streamline_fetcher_windows.bat` | Downloads NVIDIA's official Streamline runtime when the game lacks it. |
| `tools\` | Scripts used by the two helpers; `tools\asi-loader\` carries the loader and its license. |
| `docs\`, `Licenses\` | Detailed notes and third-party licenses. |

## Troubleshooting

Enable `[Log] LogToFile=true` and `LogLevel=2`, then enter a rendered scene.

- **No log/menu:** check executable directory, loaded proxy, process filter, quarantine and loader conflicts. For ASI installs confirm the loader is present (`Install_AsiLoader_windows.bat` -> `[3]`). Try `Alt+Insert` for alternate keyboard layouts.
- **Menu opens but ignores input:** try `[Hotfix] ManualInputPolling=true` and disable conflicting overlays.
- **Model initialization fails:** check runtime hash and driver support; include the exact log error in a report.
- **Unexpected model size:** inspect active/target/model dimensions and fallback messages; [padded input](docs/PADDED-PRESR.md) explains supported rectangles.
- **XeFG together with ReShade:** the proxy method can collide with other injectors; use the ASI method above.

Follow [upstream OptiFG guidance](https://github.com/optiscaler/OptiScaler/wiki/OptiFG) for frame generation. NR success alone does not establish FG compatibility. See [tested games and remaining issues](docs/NR-UPSTREAM-REVIEW.md).
