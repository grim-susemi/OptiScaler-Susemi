# One-click install: Install_OptiScaler_windows.bat

This document describes the recommended install path for the Susemi package. Run
`Install_OptiScaler_windows.bat` and one session covers language selection, game executable
selection, diagnosis, install consent, applying and the result screen. You do not need to run any
other install script. Each screen asks one question, and Enter always picks the safe default.
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
4. **Neural Rendering (optional)**: you must supply `nvngx_dlssnr.dll` yourself. The SHA-256
   values for both model variants are recorded in [INSTALL-DLSSNR.md](INSTALL-DLSSNR.md), so
   verify the hash of the file you obtained. The tool never downloads the model and never turns
   NR on. NR defaults to off and is enabled in the game menu.
5. **Streamline runtime (optional)**: this tool does not fetch it. Only when the game lacks
   Streamline, use the separate script described under "Legacy scripts" below to download the
   official NVIDIA release (consent required).

Do not use this package with online games that run anti-cheat.

## The 5 install steps (exactly the on-screen order)

### Step 1: Run the tool and pick a language

Run `Install_OptiScaler_windows.bat`.

```
[1] 한국어 (Korean, default)
[2] English
Select language [1/2, Enter=1]:
```

Enter picks Korean, 2 picks English. This screen has exactly one question.

### Step 2: Select the game executable

A file dialog (title "Select the game executable (.exe)") opens. Where a dialog is unavailable,
the tool switches to a paste-the-path prompt. If you select nothing, the tool exits without
changing anything. The chosen path is echoed back so you can check it.

### Step 3: Read the diagnosis (read-only)

The tool inspects only the folder of the selected executable. It writes nothing, uses no network
and launches no game. It identifies the loader, OptiScaler and ReShade by file content (hashes,
PE information, corroborating configuration), not by filename. Unknown or ambiguous files are
refused with a reason.

If the result is **ready**, the flow continues to step 4. Every other result stops the session
here (nothing is installed). Plain next actions for each outcome are under "Diagnosis results
and what to do next" below.

### Step 4: Consent to the install

```
Proceed with install? [1] No (default)  [2] Yes
```

Enter or 1 means no: the tool exits and nothing is installed. 2 means yes. The guided flow
installs in the ASI configuration (`OptiScaler.asi` plus the loader `winmm.dll`).

When the layout can also load ReShade first, one more question follows.

```
Also set winmm.ini so ReShade loads first? [1] No (default)  [2] Yes
```

Answering yes also serves as consent for the winmm.ini change. If it is already configured
correctly, the tool writes nothing and says so. If the conditions are not met, this question is
skipped and the skip reason is shown.

### Step 5: Apply and read the result

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

## Diagnosis results and what to do next

| Diagnosis result | Meaning | Plain next action |
| --- | --- | --- |
| Ready | The layout is installable | Continue to the step 4 consent screen |
| Missing input | A required file is absent or cannot be found | Prepare what the tool names. If the executable was not found, pick the correct game .exe. If the folder has no loader or OptiScaler yet, install with the command-line install mode (below) or set up the basics with the legacy scripts first. If winmm.ini references ReShade.asi but the file is absent, supply a verified ReShade file yourself. |
| Conflict | Another mod's files or settings are in the way | Fix the file and setting named in the reason, then run again. The tool will not delete competing loaders, revert loadplugins=0 / loadfromscriptsonly=1, or edit another file's loadextraplugins key. Keep one loader and undo the blocking setting yourself. |
| Game verification required | The game is running | Close the game and its launcher, then run again. |

In addition, 32-bit (x86) executables are refused as unsupported.

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

## Legacy scripts (still present, for advanced users)

`setup_windows.bat` (standalone), `Install_AsiLoader_windows.bat` and
`Streamline_fetcher_windows.bat` remain for existing users. The one-click tool does not require
them; it is the recommended path. Only a missing Streamline runtime needs the official NVIDIA fetch, after consent.

## 설치 요약 (Korean summary)

한국어 사용자용 요약입니다. 세부 규칙과 예외는 위 본문을 참고하세요. 같은 5단계 흐름을 압축했습니다.

1. 게임과 런처를 종료하고, rc2 이상 패키지의 루트에서 `Install_OptiScaler_windows.bat`를 실행합니다. 언어는 Enter(한국어) 또는 2(English)로 고릅니다.
2. 파일 선택 대화상자에서 64비트 게임 .exe를 고릅니다. 선택 없이 창을 닫으면 아무 것도 바뀌지 않고 종료하며, 고른 경로는 다시 표시되어 확인할 수 있습니다.
3. 진단은 읽기 전용입니다(네트워크 없음, 게임 실행 없음). 결과가 준비(ready)면 4단계 동의 화면으로 진행하고, 그 외 결과(입력 부족 · 충돌 · 게임 확인 필요)는 표의 다음 행동을 직접 마친 뒤 다시 실행합니다. 32비트 실행 파일은 거부됩니다.
4. `설치를 진행할까요?`에서 2(예)를 고르면 ASI 방식(`OptiScaler.asi` + `winmm.dll`)으로 설치됩니다. ReShade를 먼저 로드하려면 이어지는 winmm.ini 질문에 동의하세요. 검증된 파일만 다루며, 프록시 변환은 사본 방식이라 원본이 그대로 남습니다.
5. 진행은 `trace|` 줄, 적용 전 미리보기는 `preview|` 줄로 보이고 마지막 `status=...` 준이 기계 판독용 결과입니다. 성공 확인은 도구 몫이 아니라 게임을 직접 실행하는 사용자 몫입니다.
6. NR은 도구가 내려받지 않습니다. `nvngx_dlssnr.dll`을 직접 준비하고 [INSTALL-DLSSNR.md](INSTALL-DLSSNR.md)의 SHA-256으로 해시를 확인하세요. NR은 기본 꺼짐이며 게임 메뉴에서 켭니다.
7. 제거는 명령행으로 합니다: `Install_OptiScaler_windows.bat remove -Exe "<게임 exe 경로>" -Consent yes`. 설치기가 만들거나 바꾼 파일만 되돌리고 다른 모드의 파일은 만지지 않으며, 백업과 설치 기록을 근거로 진행됩니다.
8. 실패하면 자체 복구로 기록된 원본을 되돌립니다. 안티치트가 있는 온라인 게임에는 사용하지 마세요. ReShade와 Streamline 런타임은 도구가 내려받지 않으니 필요하면 본문 "레거시 스크립트" 절을 참고하세요.
