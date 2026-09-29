# loadorder fixtures (T8: ReShade-first INI / load order)

Source-only fixtures for the `-ReshadeFirst` install path of
`tools/susemi_installer.ps1` (INI load order) and the `-ExtraJson` extra-op path of
`tools/susemi_transaction.ps1`. Nothing here ships in a release package; the runner
writes only under `%TEMP%` plus a run-scoped journal root.

## Files

| File | Purpose |
| --- | --- |
| `run_loadorder_qa.ps1` | Scenarios a-i (plus the CLI contract and adversarial checks) from the T8 brief. Drives the real coordinator `install -ReshadeFirst -IniConsent yes`, re-hashes every fixture file, asserts machine `status=` lines and the journal's op order, writes raw logs to the evidence dir, and cleans up. Exit 0 only if every assertion passes. |

## Layouts (all generated at run time under `%TEMP%\susemi-t8-qa-<guid>\`)

| Case | Layout | Expected |
| --- | --- | --- |
| a | GameA.exe (notepad x64 copy) + pinned `winmm.dll` + pinned `OptiScaler.asi` + 1 KB x64 PE-stub `ReShade.asi`, **no INI** | `status=installed reason=ok`, `winmm.ini` created with `[globalsets]\r\nloadextraplugins=ReShade.asi\r\n`; re-diagnosis `ready`; journal op order ends with the INI `create` |
| b | (a) + unowned `winmm.ini` already `loadextraplugins=ReShade.asi` (LF) | `status=no-op reason=already-configured`, every SHA unchanged, ownership not claimed |
| c | (a) + unowned `winmm.ini` with unrelated content | `status=refused reason=ini-unowned` + manual instructions, zero writes |
| d | (a) install, then add `plugins/global.ini` = `loadextraplugins=OptiScaler.asi` | `diagnose` -> `status=conflict reason=ual-config-conflict` naming `plugins\global.ini`; `install -ReshadeFirst` -> `status=installed-with-warning reason=later-override` naming file+key; the global is never edited |
| e | pinned `winmm.dll` + pinned `OptiScaler.asi` + `dxgi.dll` x64 PE stub + `ReShade.ini`, no `ReShade.asi` | `-ConvertReshade` -> `ReShade.asi` created as a byte-identical COPY, `dxgi.dll` untouched; rollback removes the created `ReShade.asi`/`winmm.ini` and changes no pre-existing byte |
| f | (e) with `dxgi.dll` = random bytes (no PE) | `status=refused reason=convert-identity-unverified`, zero writes |
| g | owned `winmm.ini` = UTF-8 BOM + Korean comments + `[settings]`, no `[globalsets]` | byte diff is exactly the appended `[globalsets]` insert, BOM + comments preserved; an owned UTF-16 INI -> `status=refused reason=ini-encoding-utf16`, zero writes |
| h | owned LF INI with an existing `[globalsets]` header; owned CRLF INI without one | insert after the header uses LF; the appended section uses CRLF; all other bytes preserved |
| i / i2 | rollback after an install | created `winmm.ini` removed; every pre-existing game file byte-identical; for a layout with pre-existing payload targets the only additions are the installer-owned `.susemi-backup\*.susemi-bak` preimages; an all-create layout restores a fully byte-identical map |
| y | CLI contract | `-ReshadeFirst` requires `-IniConsent yes` (else `refused reason=ini-consent-required`); `-IniConsent` without `-ReshadeFirst`, `-ConvertReshade` without `-ReshadeFirst` and `-ReshadeFirst` on `diagnose` are `invalid-invocation` (exit 2); zero writes |
| z | adversarial | a child held past a 3 s bound is killed and reported `timedOut`; the worktree has exactly the pre-existing T5 `setup_windows.bat` tracked modification |

## Ownership fixture

Scenarios g/h need a *previously coordinator-owned* INI. `New-OwnedJournal` writes a
schema-1 journal (`phase=applied`, one applied `create` op whose `sourceSha` equals
the live `winmm.ini` bytes) into the run-scoped journal root - exactly the record a
prior coordinator transaction leaves behind, which `Get-IniOwnership` reads.

## Pins (mirrored from `tools/susemi_stage_helpers.ps1` / rc2 evidence)

| Artifact | Value |
| --- | --- |
| local rc2 ZIP | `C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip` |
| rc2 ZIP sha256 | `42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a` |
| OptiScaler core sha256 | `0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60` |
| UAL sha256 | `fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7` |

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/installer_fixtures/loadorder/run_loadorder_qa.ps1
```

Optional: `-EvidenceDir <dir>`, `-PackageRoot <repo>`, `-ScratchRoot <dir>`.
Children get `SUSEMI_TX_JOURNAL_ROOT` pointing at the scratch journals, so the real
`%LOCALAPPDATA%\susemi-installer\journal` root is asserted untouched.
