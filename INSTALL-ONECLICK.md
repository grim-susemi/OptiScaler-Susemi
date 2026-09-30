# One-click install: Install_OptiScaler_windows.bat

This document describes the recommended install path for the Susemi package. Run
`Install_OptiScaler_windows.bat` and one session covers language selection, game executable
selection, diagnosis, an optional game advisory, install consent, applying and the result screen.
You don't need to run another install script. Numbered choices have safe Enter defaults;
the executable prompt needs a path, and empty input cancels.
Korean users: a short summary in Korean is at the end of this document.

The package you install from must be rc2 or newer. Do not use the historical rc1. rc1 carried a
removal path that could delete an installed ASI loader when a recorded backup was missing. That
was corrected in rc2, and this tool never uses the unsafe rc1 remover.

## What you need before starting

1. **Game executable**: the path to the 64-bit (.exe) game binary. Close the game and its
   launcher first. The tool stops the install while the game is running.
2. **A Susemi package of rc2 or newer** (see the rc1 warning above).
3. **ReShade (optional)**: the tool never downloads ReShade. It can only be configured alongside
   if you already supply it, either from an official ReShade install or from files you already have.
4. **Neural Rendering (optional)**: you must supply `nvngx_dlssnr.dll` yourself. The full-package
   guide `INSTALL-DLSSNR.md`, which records SHA-256 values for both model variants, is not
   bundled in this slim candidate. Obtain that guide separately and verify the hash of the
   model you obtained. The tool never downloads the model and never turns NR on. NR defaults
   to off and is enabled in the game menu.
5. **Streamline runtime (optional)**: this tool does not fetch it. Only when the game lacks
   Streamline, obtain the official NVIDIA runtime separately, with consent for any download.
   The full-package `Streamline_fetcher_windows.bat` is not bundled in this slim candidate;
   using that resource requires acquiring it separately.

Do not use this package with online games that run anti-cheat.

## Prepare the package

1. Receive the complete rc2-or-newer Susemi package. You should have the full package ZIP,
   not just a BAT file.
2. Extract the entire ZIP into its own folder. The extracted folder should contain
   `Install_OptiScaler_windows.bat`, `OptiScaler.dll` and the `tools` folder.
3. Close the game and its launcher. They must stay closed while installing.

The default install verifies the shipped `OptiScaler.dll` and
`tools/asi-loader/Ultimate-ASI-Loader-x64.dll` against pinned hashes. No developer ZIP path
or download is needed. Don't copy only the BAT or run files from an internal temporary stage.
If either payload is missing or can't be verified, extract a valid complete package into a new
folder and retry. Don't replace your game's loader or INI blindly to get past a refusal.

## The guided install steps

### Step 1: Run the tool

Double-click `Install_OptiScaler_windows.bat` in the extracted package folder.
The language menu appears.

### Step 2: Pick a language

```
[1] 한국어 (Korean, default)
[2] English
Select language [1/2, Enter=1]:
```

Press Enter or 1 for Korean, or type 2 for English. The next screen asks for the game executable.

### Step 3: Select the game executable

A file dialog (title "Select the game executable (.exe)") opens. Where a dialog is unavailable,
the tool switches to a paste-the-path prompt. If you select nothing, the tool exits without
changing anything. The chosen path is echoed back so you can check it.

### Step 4: Read the diagnosis (read-only)

The tool inspects only the folder of the selected executable. It writes nothing, uses no network
and launches no game. It identifies the loader, OptiScaler and ReShade by file content (hashes,
PE information, corroborating configuration), not by filename. Unknown or ambiguous files are
refused with a reason.

Read the reason shown. Only these layouts can reach an install offer in this session:

- A bare first-install layout with `missing-input reason=no-loader-or-optiscaler`, where
  **both** `winmm.dll` and `OptiScaler.asi` paths are genuinely absent and no loader is identified.
- `ready reason=ready` with exactly one positively identified UAL loader, named `winmm.dll`,
  and no unidentified install target. **Not every ready layout is eligible.**

An unknown file, directory or link at either install target stops the guided install.
Competing loaders, or an identified loader under another name such as `dinput8.dll`, also stop
it; the tool doesn't convert or replace them automatically. Other missing-input reasons,
conflicts, unsupported layouts and a running game are terminal. Follow the reason and the
next action in the table below, then retry without forcing an overwrite.

### Step 5: Choose the game advisory

For a valid x64 selection, answer the advisory question after diagnosis:

```
[1] Other / not sure (default)  [2] GTA V Enhanced
```

Press Enter or 1 for Other, or type 2 only if this is GTA V Enhanced. Only 2 shows the GTA5E
caution. This is your selection, not automatic game identification or install consent.
It doesn't change the install route or settings. A terminal diagnosis still stops after this
question; an eligible layout continues to consent.

### Step 6: Consent to the install

```
Proceed with install? [1] No (default)  [2] Yes
```

Enter or 1 means no: the tool exits and nothing is installed. 2 means yes. The guided flow
installs in the ASI configuration (`OptiScaler.asi` plus the loader `winmm.dll`).

After Yes, the tool may offer a separate ReShade-first question when eligible.

```
Also set winmm.ini so ReShade loads first? [1] No (default)  [2] Yes
```

Answering yes also serves as consent for the winmm.ini change. If it is already configured
correctly, the tool writes nothing and says so. If the conditions are not met, this question is
skipped and the skip reason is shown.

The tool checks the folder again after all consent questions, immediately before applying.
If a target has changed or the layout is no longer safe, it refuses with
`status=refused reason=guided-target-conflict`. Yes doesn't bypass that fresh check.

### Step 7: Read the result

Progress appears as `trace|` lines, and the exact ReShade-first change (target file and inserted
key) appears as `preview|` lines before it is applied. After applying, the tool verifies the
installed bytes itself and leaves one machine-readable result line (`status=...`). On success a
result screen follows.

```
== Install result ==
In-game confirmation is owner-only: launch the game and verify OptiScaler loads
yourself.
Backup location: <game folder>\.susemi-backup
To remove: Install_OptiScaler_windows.bat remove -Exe "<game exe path>" -Consent yes
```

Read the final `status=... reason=...` line and the explanation, including refusals or failures.
Success confirms installed bytes, not working FG or game compatibility.

### Step 8: Close the window

Press Enter when the close prompt appears. Normally reported guided outcomes, including
cancellation and refusal, wait once only in a usable real console with neither input nor output
redirected. Argument modes and piped sessions don't hold. Ctrl+C interrupts without a second
wait; it isn't proof of a successful install or game verification.

## Diagnosis results and what to do next

| Diagnosis or outcome | Meaning | Plain next action |
| --- | --- | --- |
| Ready | Diagnosis is ready, but the guided safety gate still applies | Continue only with the single identified winmm loader and no unknown target described in Step 4. A non-winmm or competing loader is terminal even if diagnosis says ready. |
| Missing input: no-loader-or-optiscaler | No loader or OptiScaler was identified | If both install target paths are genuinely absent, the same guided session offers installation. Otherwise it refuses; inspect the existing targets rather than copying over them. |
| Missing input: exe-not-found | The chosen executable can't be found | Select the correct game's x64 .exe again. |
| Missing input: ReShade referenced but absent or unverified | The named configuration needs a verified ReShade file | Supply the referenced file from a verified source; don't force the install or replace an INI blindly. |
| Refused: guided-target-conflict | A target is unknown, a directory/link exists there, inspection failed, or the post-consent check is unsafe | Inspect the named targets and existing loaders. Nothing is installed through this offer. |
| Conflict | Loader or configuration conflict | Inspect the named loader/configuration. The tool won't delete competing loaders, revert loadplugins=0 / loadfromscriptsonly=1, or edit another file's loadextraplugins key. |
| Unsupported | Not x64, or an unsupported existing layout | Choose an x64 executable, or inspect the existing mod/loader layout. A recognized non-winmm loader isn't converted automatically. |
| Game verification required | The game is running | Close the game and launcher, then retry. This is not an in-game compatibility verdict. |
| Cancelled / consent-required | No executable selected, or install declined | Nothing was installed. Run the BAT again when ready. |
| Package payload missing / SHA mismatch | The shipped core/UAL pair is missing or unverifiable | Re-extract a valid complete package into a new folder, then retry. |

## GTA V Enhanced notes and a diagnostic reply

For **offline mod use**, the [official GTA V Enhanced wiki](https://github.com/optiscaler/OptiScaler/wiki/Grand-Theft-Auto-V-Enhanced)
requires BattlEye to be disabled. Don't use the mod online. The installer only shows advice;
it doesn't disable BattlEye or change FG settings.

**The reported freeze cause and XeFG compatibility are unconfirmed.** Disable the failing FG
route for now while collecting evidence. Native DLSS-FG existing in the game isn't, by itself,
proof of a conflict or a blanket XeFG ban. The [upstream README's OptiFG + HUDfix section](https://github.com/optiscaler/OptiScaler/blob/45a2001303ddff632e279f77aef85ceede5832cb/README.md#optifg--hudfix-experimental-hud-ghosting-fix)
describes that experimental route for games without native FG, or as a last resort when native
FG isn't working properly. That guidance isn't a diagnosis of this freeze.

The wiki currently lists Last Tested Version 0.9 and filenames `dxgi.dll` / `winmm.dll`, with
an FG note about Nukem's route after native DLSS-FG was added. Those upstream observations
don't verify this package's XeFG route or this reporter's build. This guided installer keeps
the same ASI route for every game; the filename list isn't an instruction to replace a loader.
DirectStorageFix appears there as an **INI-save issue note only**. This installer doesn't
apply it automatically, and this guide doesn't prescribe it as a freeze fix.
Historical issues describe different symptoms or builds, not proof for this report.
No release date or game compatibility is promised.

A useful diagnostic reply is:

- GPU model:
- Exact Susemi package and OptiScaler core build:
- FG input and FG output selected:
- Native in-game FG toggle (on/off):
- HDR (on/off) and window mode:
- What happened when FG was enabled, and when it failed:
- Full relevant `OptiScaler.log` section around enabling and failure, with surrounding context.
  The first 30 lines alone may miss the failure; attach the full log if the relevant span is unclear.

## Loading ReShade first (ReShade-first)

This follows the official OptiScaler ASI method. The ASI loader's configuration file
`winmm.ini` gains `[globalsets]` `loadextraplugins=ReShade.asi`, which makes the loader read
ReShade before ordinary ASI plugins. Because the loader reads ReShade.asi directly, this method
keeps proxy names such as dxgi.dll free for other injectors.

- **Only verified files are converted.** A ReShade proxy DLL named dxgi.dll is touched only
  when its content verifies (PE structure, ReShade version information, corroborating traces
  such as ReShade.ini or a reshade-shaders folder). Unknown files are never converted. The
  guided flow offers this setting only when ReShade.asi already exists and passes verification;
  conversion of a verified proxy is available only through `-ConvertReshade` in the
  command-line mode.
- **Conversion is always a copy.** `ReShade.asi` is created as a copy of the original proxy
  file and the original stays in place. The game may load both files afterwards, so if the
  original serves another purpose, sort that out yourself. The tool never moves or renames it.
- **winmm.ini rules.** A missing file is created. An existing file is extended only when this
  installer created or modified it earlier, and the existing bytes are preserved. An INI this
  installer does not own, or one that already defines loadextraplugins, is never edited; the
  tool explains why. If a later-read global.ini overrides the key, that file is never edited
  and a warning is recorded instead.

## Command-line mode (advanced users, automation)

```
Install_OptiScaler_windows.bat diagnose -Exe <game.exe path> [-Lang ko|en]
Install_OptiScaler_windows.bat install  -Exe <game.exe path> -Consent yes|no
                                        [-Route asi|proxy] [-ProxyName <name>]
                                        [-ReshadeFirst [-IniConsent yes|no] [-ConvertReshade]] [-Lang ...]
Install_OptiScaler_windows.bat remove   -Exe <game.exe path> -Consent yes [-Lang ...]
```

Argument modes don't show the guided advisory or wait for Enter. Redirected/piped guided
sessions also don't hold; they can still show the advisory if explicitly answered 2.

Advanced source override: an explicit nonempty `SUSEMI_RC2_ZIP` selects the pinned local ZIP
instead of the shipped pair. An absent or invalid override is refused, with **no fallback**
to the extracted package. Ordinary users should leave this unset or empty, not configure a
developer-machine path.

- `diagnose`: read-only diagnosis only, then it exits.
- `install`: proceeds unless the game is running, a conflict exists, or the executable cannot
  be found or is not 64-bit. It is always refused with `-Consent no`. `-Route proxy` (default proxy name
  dxgi.dll, changeable with `-ProxyName`) places the core as a proxy DLL. `-ReshadeFirst` works
  only with the ASI route and needs `-IniConsent yes`.
- `remove`: `-Consent yes` is required.
- Exit codes: **0** success/ready, **1** refused/failed/cancelled, **2** invalid invocation
  (argument error).
- Output: the final `status=...` line is the machine-readable result. Preceding `trace|` lines
  are progress detail, and `preview|` lines are the pre-apply preview.

## Real invocation examples (actual results on an empty game folder in a temp directory)

```
> Install_OptiScaler_windows.bat diagnose -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe"
status=missing-input reason=no-loader-or-optiscaler
missing input: no UAL loader/OptiScaler identified (C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX; 0 *.dll/*.asi files).
```
Exit 1, no folder change.

```
> Install_OptiScaler_windows.bat install -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe" -Consent no -Lang en
status=refused reason=consent-required
Consent required: re-run with -Consent yes.
```
Exit 1, nothing installed.

```
> Install_OptiScaler_windows.bat remove -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe" -Consent yes -Lang en
status=missing-input reason=no-install-record
No install record found for this game directory.
```
Exit 1, nothing changed.

An invalid invocation (unknown action) is refused with exit code 2:
`status=invalid-invocation reason=unknown-action`. With the default Korean output (`-Lang ko`)
the same result lines are produced alongside Korean detail text.

## How to remove

In the current version removal is a command-line action (the result screen of a successful
install shows the same command).

```
Install_OptiScaler_windows.bat remove -Exe "<game exe path>" -Consent yes
```

- Only files this installer created or modified are removed. Originals are restored exactly as
  kept in `game folder\.susemi-backup`, and files the installer created are deleted. Other
  mods' files are never touched.
- If a target changed after the install, a backup is missing or tampered with, or there is no
  install record, the tool changes nothing and refuses with a reason.
- Running it again after a successful removal ends as "nothing to do". If files reappear at
  recorded paths through anything other than this tool after a removal, the delete is refused.

## Safety principles when something fails

- The tool only targets files it created or modified. Other mods' DLLs and configuration files
  are never deleted or edited.
- Originals are preserved byte-for-byte in `.susemi-backup` inside the game folder, and the
  install history is recorded under `%LOCALAPPDATA%\susemi-installer\journal`. Removal proceeds
  only on the basis of that record.
- If applying fails partway, the tool runs its own recovery to restore the recorded originals.
  A refusal (missing consent, conflict, unowned INI) happens before any
  write, so the folder stays unchanged.

## What install success means, and verifying in-game (your part)

Install success means the installed bytes were verified, nothing more. Whether NR, the ReShade
effect or XeFG actually show up on screen is not judged by the tool. Launching the game and
looking is yours to do, and the success screen says so explicitly.

## Limits

- No guarantee for every game. Loader and injection differ per game, so even a layout the tool
  judges healthy may not work in the game.
- 32-bit games are not supported.
- No automatic download of the NR model or ReShade, no game launch, no editing of other mods'
  configuration files. The Streamline runtime is also outside this tool's scope.

## Legacy scripts (for advanced users)

`setup_windows.bat` (standalone) is included in this slim candidate. The full-package scripts
`Install_AsiLoader_windows.bat` and `Streamline_fetcher_windows.bat` are not bundled here;
users who need those resources must acquire them separately. The one-click tool does not
require these scripts; it is the recommended path. Only a missing Streamline runtime needs
the official NVIDIA fetch, after consent.

## 설치 요약 (Korean summary)

세부 규칙과 진단 표는 위 본문을 참고하세요.

이 슬림 후보 패키지에는 `INSTALL-DLSSNR.md`, `Install_AsiLoader_windows.bat`, `Streamline_fetcher_windows.bat`가 동봉되지 않습니다. 필요한 전체 패키지 자료는 별도로 구해야 합니다. 선택 사항인 NR 모델은 직접 준비하고 별도로 구한 가이드의 해시로 검증하세요. 게임에 Streamline이 없을 때만 공식 NVIDIA 런타임을 별도로 구하며 다운로드에는 동의가 필요합니다. `setup_windows.bat`는 동봉되어 있지만 원클릭 설치에는 필요하지 않습니다.

1. rc2 이상 전체 ZIP을 받아 전용 폴더에 압축 해제하세요. BAT만 복사하지 마세요. 기본 설치는 동봉된 코어와 UAL을 검증하며 개발자 ZIP 경로나 다운로드가 필요 없습니다. 누락/검증 실패 시 올바른 전체 패키지를 새 폴더에 다시 푸세요.
2. 게임과 런처를 종료하세요. 설치 중에는 닫힌 상태를 유지하세요.
3. 압축 해제한 폴더의 `Install_OptiScaler_windows.bat`를 실행하세요. 언어 메뉴가 표시됩니다.
4. Enter 또는 1(한국어), 2(English)를 선택하세요. 실행 파일 선택으로 넘어갑니다.
5. x64 게임 .exe를 선택하거나 대화상자가 없으면 전체 경로를 붙여넣으세요. 경로가 다시 표시되며 취소하면 설치하지 않습니다.
6. 읽기 전용 진단을 확인하세요. `missing-input/no-loader-or-optiscaler`이고 winmm.dll과 OptiScaler.asi 경로가 모두 없으면 같은 세션에서 설치를 제안합니다. ready는 단일 winmm UAL이 확실히 식별되고 모르는 설치 대상이 없을 때만 진행합니다. 모르는 대상 파일, 디렉터리/링크, 경쟁 로더나 non-winmm 로더, 다른 입력 부족/충돌/미지원 상태는 중단됩니다. 기존 로더나 INI를 무작정 교체하지 마세요.
7. x64 진단 뒤 게임 안내를 선택하세요. Enter/1은 기타/확실하지 않음, 2는 GTA V Enhanced 주의사항입니다. 자동 판별이나 설치 동의가 아니며 경로/설정을 바꾸지 않습니다.
8. 설치 질문에서 Enter/1(아니요) 또는 2(예)를 선택하세요. 예는 ASI 방식으로 진행하며 ReShade-first INI 질문은 별도 동의가 필요합니다. 모든 동의 뒤 재검사에서 대상이 바뀌거나 안전하지 않으면 거부됩니다.
9. 마지막 `status=... reason=...`와 설명을 읽으세요. 성공은 설치 바이트 검증일 뿐 게임/FG 동작 확인이 아닙니다.
10. 실제 콘솔의 종료 안내에서 Enter를 누르세요. 명령행/파이프 세션은 기다리지 않으며 명령행은 게임 안내도 없습니다. 파이프 안내는 2를 명시한 경우만 나옵니다. Ctrl+C 뒤 두 번째 대기는 없습니다.

GTA5E는 오프라인 모드 사용 시 BattlEye를 꺼야 하며 온라인에는 사용하지 마세요. 프리즈 원인과 XeFG 호환성은 미확인입니다. 실패한 FG 경로를 끄고 GPU, 정확한 패키지/코어 빌드, FG 입력/출력, 네이티브 FG 토글, HDR/창 모드, 활성화/실패 주변의 전체 관련 OptiScaler.log 구간을 보내세요(첫 30줄만으로는 부족할 수 있음). 네이티브 DLSS-FG 존재만으로 원인을 단정하지 않습니다. README 안내는 OptiFG+HUDfix에 관한 내용이며 DirectStorageFix는 상위 INI 저장 문제 참고일 뿐 자동 적용/프리즈 처방이 아닙니다. 과거 이슈는 이 보고의 증거가 아니며 호환성/출시일을 보장하지 않습니다.

일반 사용자는 `SUSEMI_RC2_ZIP`을 비워 두세요. 명시한 비어 있지 않은 값은 고정 해시 ZIP 검증을 유지하며 실패해도 동봉 파일로 대체하지 않습니다. NR 모델/ReShade 다운로드나 자동 설정은 하지 않습니다. 제거는 `Install_OptiScaler_windows.bat remove -Exe "<게임 exe 경로>" -Consent yes`이며 설치 기록/백업을 검증해 설치기가 만든 변경만 되돌립니다.
