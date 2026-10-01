# One-click install: v11.3-installer-a2

Run `Install_OptiScaler_windows.bat` from the extracted ZIP. One session covers
language, game EXE selection, diagnosis, advisory, consent, install and result.
A brief Korean summary follows.

This is an installer release on the unchanged rc2-lineage core, not a new stable
core or proof of working FG. Don't use the historical rc1 installer/remover;
a2 keeps the corrected rc2 removal lineage.

## Before you start

Extract the complete **v11.3-installer-a2 ZIP** into a separate package folder,
not over the game or another package. Keep the BAT, `OptiScaler.dll`, `OptiScaler/`,
`tools/` and licenses together. Don't copy only the BAT. No developer ZIP path
or download is needed for the default install.

Select the actual **x64 game EXE**. Close the game and launcher before install or
removal. Don't use this mod online or with anti-cheat. The tool doesn't launch games.
Default installation doesn't copy a source `OptiScaler.ini`, overwrite your
`OptiScaler.ini` or change user FG settings.

## Default payload

The ASI route places the pinned core as `OptiScaler.asi` and pinned Ultimate ASI
Loader (UAL) as `winmm.dll` beside the selected EXE. It also deploys these **nine
pinned bundled DLLs**, preserving their relative paths:

- `OptiScaler/libxess.dll`
- `OptiScaler/libxess_dx11.dll`
- `OptiScaler/libxess_fg.dll`
- `OptiScaler/libxell.dll`
- `OptiScaler/amd_fidelityfx_framegeneration_dx12.dll`
- `OptiScaler/amd_fidelityfx_loader_dx12.dll`
- `OptiScaler/amd_fidelityfx_upscaler_dx12.dll`
- `OptiScaler/amd_fidelityfx_vk.dll`
- `OptiScaler/D3D12_OptiScaler/D3D12Core.dll`

The checks cover the **whole set** before game-folder/journal writes,
after apply and before an already-installed/no-change result. Core/UAL alone
isn't enough. Unknown existing targets, reparse points/conflicting ancestors and
unsafe configuration refuse rather than force an overwrite. Included Intel, AMD,
DirectX, project and UAL licenses stay preserved. No new redistribution decision
is made here. Licenses stay in the package; the installer doesn't overwrite
game-root `LICENSE`. A pristine ASI install has eleven file operations: core/UAL
and the nine resources. An equal no-change result creates no shadow journal
and claims no new ownership. Equal pre-existing files can be reused without
becoming installer-owned; removal leaves those files in place. A mismatched
resource without valid recorded ownership is refused, not adopted or overwritten.

**NVIDIA DLSS, DLSS-FG, NR model and Streamline vendor binaries aren't bundled or
automatically acquired.** Supply required optional runtimes/models from official
sources under their terms and verification instructions. `nvngx_dlssnr.dll` is
user-provided; NR isn't enabled by the installer. ReShade is also user-provided.
Optional runtimes remain your responsibility. Not every route is available:
game, API, GPU, input/output and optional runtimes still matter.

## Guided install

1. **Run the BAT.** Enter/1 selects Korean; 2 selects English. The EXE selector opens.
2. **Choose the actual x64 EXE.** If no dialog is available, paste its full path.
   Check the echoed path. Cancelling makes no installation changes.
3. **Read the diagnosis.** No install, network access or game launch occurs here.
   Bare layouts can receive an offer. Existing layouts need identity/configuration
   checks; ready still needs the guided safety gate. Unknown targets, competing
   loaders and recognized non-winmm loaders aren't converted automatically.
4. **Choose the advisory.** Enter/1 is Other / not sure. Choose 2 yourself for GTA V
   Enhanced. This isn't automatic identification, consent or a settings change.
   A terminal diagnosis still stops installation.
5. **Check the path and consent.** Enter/1 declines; 2 accepts the ASI install.
   ReShade-first, if offered, has separate opt-in and INI consent.
6. **Read the final result and warnings.** Targets/configuration are checked again
   after consent. Success confirms complete installed bytes and checked
   static configuration, not a loaded game or working FG.
7. **Press Enter at the close prompt.** Argument/redirected sessions don't hold.
   Ctrl+C isn't proof of installation success.

## Refusals and recovery

| Problem | Next action |
| --- | --- |
| Package missing/hash mismatch | Extract a valid complete a2 ZIP into a new folder. Don't substitute a random DLL. |
| Missing/wrong EXE or architecture | Select the actual x64 game EXE. |
| Game running | Close the game and launcher, then retry. |
| Unknown target, competing loader, directory/reparse conflict | Inspect the named path and existing mod installation. Don't delete it to force installation. |
| UAL configuration conflict | Review the named INI and loader instructions. Foreign/global INIs aren't rewritten automatically. |
| Path too long / `ual-config-path-limit` | Use a shorter package path and the launcher's supported game-library move option. Retry with the actual EXE at its new path. Long-path support isn't guaranteed. |
| Cancelled/consent declined | Nothing was installed through that offer. Run the BAT again when ready. |
| Apply/recovery failure | Keep reported paths, backup and record. Resolve the failure before retrying. |

Preflight refusal makes no game-folder changes. Apply failure is different: the
transaction must recover recorded changes. Read its recovery result; don't assume
nothing remains or delete the backup/journal.

## UAL configuration and ReShade-first

The static check models native Windows profile reads. For adjacent `winmm.dll`,
file priority is `winmm.ini`, `global.ini`, `scripts/global.ini`,
`plugins/global.ini`, then `update/global.ini`. Later present keys override earlier
files; missing keys retain the prior value. **Within a file, the first duplicate
key wins.** `loadplugins` uses integer semantics, not literal string `1`.

Bare installs also need prospective configuration preflight. Disabled loading,
or scripts-only loading without accounting for the root OptiScaler ASI, mustn't
receive a success claim. Unreadable/unsupported configuration can't be assumed safe.
Foreign/global INIs aren't automatically changed to resolve conflicts.

**ReShade-first is optional.** With separate consent and verified `ReShade.asi`,
the requested setting is `[globalsets] loadextraplugins=ReShade.asi` in `winmm.ini`.
Pinned UAL processes configured extra plugins before ordinary ASIs. A missing INI
can be created; only an eligible installer-owned existing INI can be extended.
An already-effective setting is a no-change result, even in a foreign INI,
and claims no ownership. An unowned INI needing a change or an existing key
isn't overwritten. Final later-file
overrides are reported without editing those files. An earlier conflict alone
isn't a final override when a still-later file restores the goal.

This is **statically configured expected order**, not observed game module order.
It doesn't guarantee freedom from duplicate injectors/hooks. Advanced
`-ConvertReshade` copies a verified proxy to `ReShade.asi`; the original stays and
may also load. Resolve that possibility using the existing mod's instructions.

## Remove and restore

Close the game and launcher, then run from the extracted package:

```bat
Install_OptiScaler_windows.bat remove -Exe "<game exe path>" -Consent yes
```

Removal validates the whole linked recorded group before writes, restores
preimages from `game folder\.susemi-backup`, and deletes only recorded created
files whose installed bytes still match. Only installer-created **empty**
directories are removed, nonrecursively. User/changed files and pre-existing directories stay
intact, including pre-existing empty directories.

Changed targets, missing/tampered backups or a missing install record cause refusal,
not guessed restoration or partial group deletion. Keep files, backups and records.
Don't replace user changes just to pass a hash check; review the named conflict.
History is under `%LOCALAPPDATA%\susemi-installer\journal`. New schema2 records
track owned created directories and link previous journals for repair/removal.
Linked removal checks preimage continuity and restores newest-first. A broken
link, uncertain write state or invalid backup refuses the whole undo group before
mutation. Historical schema1 removal remains supported without inferring directory
ownership. An incomplete recovery reports `recovery-required`; keep its record
and remaining files.

## Advanced commands

```bat
Install_OptiScaler_windows.bat diagnose -Exe "<game.exe path>" -Lang en
Install_OptiScaler_windows.bat install -Exe "<game.exe path>" -Consent yes -Lang en
Install_OptiScaler_windows.bat remove -Exe "<game.exe path>" -Consent yes -Lang en
```

Diagnosis is read-only. Argument modes don't show the guided advisory. Existing
advanced options include `-Route asi|proxy`, `-ProxyName`, `-ReshadeFirst`,
`-IniConsent yes|no` and `-ConvertReshade`. ReShade-first needs ASI and INI consent.
Leave `SUSEMI_RC2_ZIP` unset/empty normally. A nonempty value selects a separately
pinned local rc2 ZIP, with no fallback if absent/invalid. It isn't a download URL.

The final `status=...` line is machine-readable; `trace|` shows progress and
`preview|` proposed changes. Read the explanation too. Exit codes are 0 for
success/ready, 1 for refused/failed/cancelled and 2 for invalid invocation.
`setup_payloads=verified` requires all eleven live trusted hashes, with
`setup_expected=11 setup_verified=11 resources_expected=9 resources_verified=9`.
It isn't runtime evidence: `game_load_order=UNVERIFIED fg_runtime=UNVERIFIED`
remain explicit. `installed-with-warning` needs attention even when bytes match.

## GTA V Enhanced caution and evidence

Choose this advisory only if **you know this is GTA V Enhanced**. For offline mod
use, the [official wiki](https://github.com/optiscaler/OptiScaler/wiki/Grand-Theft-Auto-V-Enhanced)
requires BattlEye disabled. Don't use the mod online. The installer doesn't disable
BattlEye or change FG settings.

**The reported black screen/freeze cause is unknown.** No same-run logs/module
evidence establish it. Deploying missing resources fixes an installer omission,
not a proven game failure. Disable the failing FG route while collecting evidence.
Native DLSS-FG alone proves neither a conflict nor blanket XeFG incompatibility.

The [upstream OptiFG + HUDfix guidance](https://github.com/optiscaler/OptiScaler/blob/45a2001303ddff632e279f77aef85ceede5832cb/README.md#optifg--hudfix-experimental-hud-ghosting-fix)
describes that experimental route for games without native FG, or as a last resort
when native FG isn't working properly. It isn't a diagnosis of this report.
DirectStorageFix's wiki mention concerns INI saving, not a prescribed freeze fix.
Other owners' data or historical issues don't establish this run's cause.

Include GPU, exact package/core build, FG input/output, native FG toggle, HDR/window
mode, failure timing and the full relevant `OptiScaler.log` span around enabling FG
and failure. Include same-run module paths/hashes if available. The first 30 log
lines alone may miss the failure.

## Your in-game check

After successful install, launch the game yourself only where mod use is allowed.
Check OptiScaler loads, then verify your selected input/output and required optional
runtimes in that run. The installer doesn't validate loaded modules, actual ReShade
order or gameplay/FG compatibility. This installer release isn't stable-core
promotion or gameplay acceptance.

## 설치 요약 (Korean summary)

a2는 기존 rc2 계열 코어를 유지한 설치기 릴리스입니다. 새 안정 코어 승격이나
게임/FG 성공 기록이 아닙니다.

1. a2 전체 ZIP을 별도 폴더에 풀고 게임과 런처를 종료하세요. BAT만 복사하거나
   게임 폴더 위에 압축을 풀지 마세요.
2. BAT를 실행해 언어와 실제 x64 게임 EXE를 선택하세요. 진단에서 거부하면
   표시된 대상/설정을 확인하고 강제로 덮어쓰지 마세요.
3. GTA5E 안내는 해당 게임임을 아는 경우에만 선택하세요. 설치 동의와
   ReShade-first INI 동의는 별개이며 Enter 기본값은 거절입니다.
4. 기본 설치는 코어/UAL과 Intel/AMD/DirectX DLL 9개, 총 11개를 설치 전후와
   변경 없는 결과에서도 검증합니다. 기존 OptiScaler.ini와 FG 설정은 바꾸지 않습니다.
5. NVIDIA DLSS/NR/Streamline과 ReShade는 동봉/자동 다운로드하지 않습니다.
   NR 모델은 직접 준비하세요. 모든 선택 경로의 사용 가능성을 보장하지 않습니다.
6. 최종 결과/경고를 읽으세요. 성공은 파일/정적 설정 확인이며 실제 로드 순서나
   게임/FG 검증이 아닙니다. GTA5E 검정 화면/멈춤 원인은 아직 미확인입니다.
7. 제거: `Install_OptiScaler_windows.bat remove -Exe "<게임 exe 경로>" -Consent yes`.
   연결된 기록 전체를 먼저 검사하고 원본을 복원합니다. 설치기가 소유한 파일과
   만든 빈 폴더만 정리하며 폴더는 재귀 삭제하지 않습니다. 기존 동일 파일을
   사용해도 소유권을 얻지 않습니다. 사용자 변경 파일과 기존 폴더는 보존하며
   충돌/백업/기록 연결 문제 시 전체 제거를 거부합니다.
8. 경로 길이 오류가 나면 패키지 경로를 짧게 하고 런처의 게임 폴더 이동 기능을
   사용하세요. 새 위치의 실제 EXE를 선택하세요. 긴 경로 지원은 보장하지 않습니다.
