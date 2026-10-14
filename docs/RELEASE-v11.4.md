# OptiScaler-Susemi v11.4

One-click installer package with the updated NR-feedback core. Extract the ZIP into its own folder and run `Install_OptiScaler_windows.bat`; see `INSTALL-ONECLICK.md` inside the ZIP.

## What changed since v11.3-installer-a2

- **Core (`OptiScaler.dll`, installed as `OptiScaler.asi`)**: NR addon options in the in-game menu, localized (KO/EN) and resizable menu, and the menu window can now be dragged beyond the game viewport edge (checked in game by the author on one machine).
- **Installer**: same one-click installer as a2 (eleven-file verified deployment, owned recovery, safe removal). Only the pinned core hash changed. Upgrading an a2 install replaces only the core.
- **Package**: 27 members, same layout as a2. Only the core, `tools/susemi_installer.ps1`, `INSTALL-ONECLICK.md` and `SHA256SUMS.txt` differ from a2.

## Not included / limits

- No NVIDIA DLSS, DLSS-FG, NR model or Streamline binaries, no ReShade, and no `OptiScaler.ini` (the core creates its own on first run; your existing INI is never overwritten).
- Not proof that FG or NR works in any given game or GPU. Do not use online or with anti-cheat.
- The legacy `SUSEMI_RC2_ZIP` installer mode still targets the old rc2 core; its success path could not be re-tested because the rc2 archive is no longer available. The default install from the extracted folder is what the tests cover.

## Verification

Installer regression suites (loadorder, transaction, removal, resource stage/removal/transaction, one-entry) all pass against this package; the extracted ZIP was also installed, re-installed, removed and upgraded from a2 on scratch game folders. Check the ZIP against `SHA256SUMS.txt` before use.

## 요약 (Korean)

설치기가 포함된 v11.4입니다. ZIP을 별도 폴더에 풀고 `Install_OptiScaler_windows.bat`을 실행하세요. 코어에 NR 애드온 옵션, 한글 지원·크기 조절 메뉴, 게임 화면 밖으로 창을 옮길 수 있는 수정이 들어갔습니다. NVIDIA 런타임, ReShade, OptiScaler.ini는 포함하지 않으며 기존 INI는 덮어쓰지 않습니다. 특정 게임/GPU에서의 FG/NR 동작을 보장하지 않으니 온라인/안티치트 환경에서는 쓰지 마세요.
