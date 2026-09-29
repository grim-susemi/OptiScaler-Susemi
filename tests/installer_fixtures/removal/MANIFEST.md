# removal fixtures manifest (T9)

Source-only fixtures for the coordinator `remove` action of
`tools/susemi_installer.ps1` (after an install through the same coordinator).
Nothing here ships in a release package. The runner writes only under `%TEMP%`
plus, in the hardcoded-root fallback, the real
`%LOCALAPPDATA%\susemi-installer\journal` root (snapshot/restored around every
case), and it writes evidence to the task evidence dir.

## Files

| File | Purpose |
| --- | --- |
| `run_removal_qa.ps1` | Scenarios a-j from the T9 brief. Runs the real coordinator `install` + `remove` as bounded child processes, asserts exit codes, machine `status=` lines, journal phases and SHA maps, writes raw logs + `qa-summary.csv` + `removal.md` to the evidence dir, then cleans up. |
| `MANIFEST.md` | This file. |

## Concurrent-producer behaviour (sibling T9a)

The remove body is implemented concurrently by T9a. The runner polls for it with
two independent signals:

1. syntax marker: `tools/susemi_installer.ps1` no longer contains the stub token
   `remove-pending-T9` (informational only - a stale docstring mention keeps the
   token present even after the body lands);
2. behavioural smoke (authoritative): `remove` on a folder with no install record
   must stop returning `status=pending reason=remove-pending-T9`. Once the body
   lands the smoke returns a real dispatch line (e.g. an install-style
   `invalid-invocation reason=missing-consent` when `-Consent` is required).

Landed is decided by the smoke; the marker is reported alongside it. Until the
smoke shows a real body, every scenario is reported as `PENDING-REAL-BODY`
(never pass or fail) and the process exits 3. Re-run after T9a lands to get real
`PASS`/`FAIL`.

## Consent surface detection

The brief invokes remove with `-Consent yes`/`-Consent no`. The landed body
follows the install contract: `remove` requires `-Consent` (rejecting a missing
value with `invalid-invocation reason=missing-consent`). The runner probes
whether the landed remove accepts `-Consent`; if it does, every remove runs with
an explicit consent value and scenario (i) exercises the `consent-required`
refusal. If it does not, removes run without `-Consent` and scenario (i) fails
explicitly (the consent gate from the brief is not expressible through the CLI).

## Journal isolation

Preference is a run-scoped journal root via env `SUSEMI_TX_JOURNAL_ROOT` (the
install path honours it, and the landed `Invoke-RemoveTransaction` reads it via
`Get-JournalRoot`; T7 relies on this). A startup probe verifies the landed
remove honours it too by checking an install+remove actually reverses; if not,
the runner falls back to the real `%LOCALAPPDATA%\susemi-installer\journal` root
and snapshot/restores it around every case (the T7 before=0/after=0 rule).

## Pins (mirrored from the rc2 staging evidence / `tools/susemi_installer.ps1`)

| Artifact | Value |
| --- | --- |
| local rc2 ZIP | `C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip` |
| rc2 ZIP sha256 | `42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a` |
| OptiScaler core sha256 (`OptiScaler.dll` -> `OptiScaler.asi`) | `0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60` |
| UAL sha256 (`tools/asi-loader/Ultimate-ASI-Loader-x64.dll` -> `winmm.dll`) | `fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7` |

## Game exe fixtures

`GameA.exe` is a byte copy of `C:\Windows\System32\ping.exe` (an x64 PE whose
copy stays quiet). A copy of `notepad.exe` is **never** used: on this host the
Windows 11 `notepad.exe` is a Store stub that exits immediately (T7 finding),
which would break the diagnosis process check if it ever ran.

Scenario (b) also seeds `ReShade.asi` as a byte copy of `ping.exe`, i.e. a
structurally valid x64 PE (that is all `Test-ReshadeFirstEligible` needs for
`reshadeValid`), with `winmm.ini` absent.

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/installer_fixtures/removal/run_removal_qa.ps1
```

Optional: `-EvidenceDir <dir>`, `-PackageRoot <repo>`, `-ScratchRoot <dir>`,
`-PollSeconds <n>`, `-Rc2Zip <path>`, `-PingExe <path>`.

Exit code: 0 = all scenarios pass, 1 = landed but a scenario failed,
3 = remove body not landed (PENDING-REAL-BODY).
