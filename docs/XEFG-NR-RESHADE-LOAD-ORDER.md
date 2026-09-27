# ReShade first with XeFG finished-picture NR

This is a reversible, narrow ASI load-order setup, not a packaged default or a general fix for injector conflicts. The new A-only release candidate does not bundle the RTX 20/30 B payload, NVIDIA runtime, or derived SM75 kernels. Historical v11.1 B instructions are not installation instructions for this candidate. See the [English install guide](../INSTALL-DLSSNR.md) or [Korean install guide](../INSTALL-KO.md). This procedure has **not** been verified in a game on the recovered R2 branch.

## Check before changing anything

1. Close the game and launcher. Use the 64-bit Ultimate ASI Loader (UAL) v9.7.4 supplied as `winmm.dll` and the ASI route, with `ReShade.asi` and `OptiScaler.asi` beside the real game executable. Don't replace an existing third-party loader just to follow this recipe.
2. Back up the exact bytes of any existing `winmm.dll`, `ReShade.asi`, `OptiScaler.asi`, `winmm.ini`, `OptiScaler.ini` and relevant ReShade INIs before installing or editing. Keep the backups outside the game directory and record hashes. Also back up any existing UAL configuration files that you inspect below. Never treat retyping an INI as a byte-exact restore.
3. Inspect UAL configuration in this order: `winmm.ini`, `global.ini`, `scripts/global.ini`, `plugins/global.ini`, `update/global.ini`, relative to the executable directory. The first existing file in this list is read first; later `global.ini` files may override its global settings. Don't add a root `winmm.ini` to a ZIP. This is a local, user-owned edit only.

Proceed with the simple case only when `winmm.ini` has no `[globalsets]` section or has that section without `loadextraplugins`, none of the four later `global.ini` files defines a conflicting `loadextraplugins`, and there are no existing extra plugins, implicit `modloader/modloader.asi` dependency, or multiple competing loaders. If any condition fails, **stop** and review that installation individually. Do not append another value to an existing list, erase an existing key, or assume the first INI wins over later global settings. UAL uses `|` to separate multiple `loadextraplugins` entries, not a comma; this simple case has only one entry.

## Opt in, then verify

1. After the checks above, add the missing section or missing key to your local `winmm.ini`, without changing other entries:

   ```ini
   [globalsets]
   loadextraplugins=ReShade.asi
   ```

   UAL loads this explicit extra plugin before its ordinary ASI search, allowing ReShade to initialize before OptiScaler. Confirm both ASIs still load; the setting alone doesn't prove that XeFG or NR works.
2. If you choose finished-picture NR, supply a compatible `nvngx_dlssnr.dll` separately and set these **user opt-in example** values in your local `OptiScaler.ini`:

   ```ini
   [DlssNr]
   Enabled=true
   FinishedPicture=true
   Passes=2
   ```

   Do not copy these into a shipped INI. The package default leaves NR off, `FinishedPicture=false`, `[XeFG] UnlockMFG=auto` (built-in default false), and `[ProcessFilter] TargetProcessName=auto`. Keep frame generation on for the XeFG handoff. Consult [NR placement and XeFG caveats](../INSTALL-DLSSNR.md#nr-under-xefg-frame-generation).
3. Check loader order and NR application in a rendered scene, not just menu presence or submitted-picture counts. If it fails, stop and restore the saved files rather than stacking another loader or changing unrelated settings.

## What the earlier run established

In the earlier R12 failure, OptiScaler loaded ahead of ReShade and NR was not applied: the XeFG queue device and NR producer device differed. The previous local NR keys were `Enabled=auto`, `FinishedPicture=auto`, `Passes=auto`. In the successful later run, ReShade loaded first and the user observed NR on screen; the NR keys were changed **at the same time** to `true`, `true`, and `2`. The captured application records showed finished-picture NR application, but changing load order and three NR keys together does **not** isolate a single cause. Those runs used earlier game-local binaries, not a new R2 package. They don't prove this candidate in-game or validate every XeFG/ReShade setup.

## Restore exact bytes

Close the game and launcher. Restore the original `winmm.ini`, `OptiScaler.ini`, other edited INIs, `winmm.dll`, `ReShade.asi`, and `OptiScaler.asi` from your byte-for-byte backups, or remove only a file you can prove you created where none existed. Compare hashes against the backups before restarting. If the installer created its own backup or receipt, follow its documented removal route only for files it owns; don't remove another mod's loader. A failed hash comparison is a stop condition, not permission to recreate an INI by hand.
