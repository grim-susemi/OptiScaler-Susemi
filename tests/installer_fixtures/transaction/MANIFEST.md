# transaction fixtures manifest (T7)

Source-only fixtures for `tools/susemi_transaction.ps1` + the `install` action of
`tools/susemi_installer.ps1`. Nothing here ships in a release package; the runner
writes only under `%TEMP%` and a run-scoped journal root.

## Files

| File | Purpose |
| --- | --- |
| `run_transaction_qa.ps1` | Scenarios a-h from the T7 brief. Runs the real coordinator/transaction as child processes, asserts exit codes, machine `status=` lines, journal phases and SHA maps, writes raw logs to the evidence dir, then cleans up. Exit 0 only if every assertion passes. |
| `lock_holder.ps1` | Scenario (d) fixture: holds a `[IO.File]::Open` handle (`-Share None|Read|ReadWrite`) on one game-folder target, signals readiness by creating `-ReadyFile`, waits (bounded) for `-ReleaseFile`, then closes and exits. |

## Pins used (mirrored from `tools/susemi_stage_helpers.ps1` / the rc2 staging evidence)

| Artifact | Value |
| --- | --- |
| local rc2 ZIP | `C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip` |
| rc2 ZIP sha256 | `42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a` |
| OptiScaler core sha256 (`OptiScaler.dll` -> `OptiScaler.asi` / proxy name) | `0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60` |
| UAL sha256 (`tools/asi-loader/Ultimate-ASI-Loader-x64.dll` -> `winmm.dll`) | `fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7` |
| empty-file sha256 (scenario f zero-byte proof) | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

## Game exe fixtures

- Default: `GameA.exe` = byte copy of `C:\Windows\System32\notepad.exe` (matches the
  preflight fixture convention).
- Scenario (c) running-game fixture: the notepad copy **exits immediately on this host**
  (Windows 11 `notepad.exe` is a Store stub), so the runner uses a byte copy of
  `C:\Windows\System32\ping.exe` launched as `ping -n 120 127.0.0.1`, which keeps the
  image path equal to `<fixture>\GameA.exe` for the diagnosis process check.

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/installer_fixtures/transaction/run_transaction_qa.ps1
```

Optional: `-EvidenceDir <dir>`, `-PackageRoot <repo>`, `-ScratchRoot <dir>`.
The coordinator writes journals to `%TEMP%\<scratch>\journals` because the runner sets
`SUSEMI_TX_JOURNAL_ROOT` for every installer child; the real `%LOCALAPPDATA%` journal
root is asserted untouched.
