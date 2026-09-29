# T2 fixtures (generated at runtime — this file documents, runner stages)

Runner: `tests/installer_one_entry.ps1`. No binary blobs are stored here;
every run stages fresh fixture dirs under `$env:TEMP\susemi-inst-fixture\run-<guid>\`
and snapshots SHA-256 of every file before/after the launcher call.

Layouts (deterministic 1 KB pseudo-random bytes via System.Random fixed seeds):

- GameA (cases a, b, d, e): `GameA/bin64/GameA.exe` + `winmm.dll` +
  `OptiScaler.asi` + `ReShade.asi`. Seeds: a=0xA001 b=0xA011 d=0xA021 e=0xA031.
- GameB (case c): `GameB/Engine/Binaries/Win64/GameB-Win64-Shipping.exe` +
  `dxgi.dll` collision + `plugins/global.ini` containing `[loader]` /
  `override=dxgi.dll`. Seed 0xB001.

Case extras:

- (d) missing-backup-refusal: pre-seeds `_susemi_install_receipt.json`
  (version 1, owner susemi_installer.ps1) whose `backupDir`
  `_susemi_backup_missing` is never created.
- (e) stale-uninstaller-false-pass: drops a stale `Remove_OptiScaler.bat`
  (`@echo off` + `echo stale uninstaller`) in the bindir and hashes it
  separately; exit 0 with untouched bytes counts as `false-pass` FAIL.

Invocation: every child runs via cmd.exe with stdin closed and a 60 s
kill-on-timeout (no sleeps anywhere). Current stub stage: the coordinator
returns named pending/refusal exits (1) with zero writes, so refusal cases
assert `exit != 0 AND bytes-unchanged`; (e) additionally fails a quiet
`exit 0 + no writes` as a false pass.
