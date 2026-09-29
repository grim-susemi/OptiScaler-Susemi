#Requires -Version 5.1
<#
  lock_holder.ps1 - QA fixture: hold an exclusive/share-limited handle on a file.

  Used by run_transaction_qa.ps1 scenario (d) to make one game-folder target busy
  while the installer runs. Signals readiness by creating -ReadyFile, then waits
  (bounded) for -ReleaseFile before closing the handle and exiting. No fixed
  sleep is used as a synchronisation primitive; the harness polls for the signal
  file and later waits on THIS process object.
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$ReadyFile,
  [Parameter(Mandatory = $true)][string]$ReleaseFile,
  [ValidateSet('None', 'Read', 'ReadWrite')][string]$Share = 'None',
  [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'

$shareMode = [IO.FileShare]::None
switch ($Share) {
  'Read' { $shareMode = [IO.FileShare]::Read }
  'ReadWrite' { $shareMode = [IO.FileShare]::ReadWrite }
  default { $shareMode = [IO.FileShare]::None }
}

$fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareMode)
try {
  Set-Content -LiteralPath $ReadyFile -Value 'ready' -NoNewline
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((-not (Test-Path -LiteralPath $ReleaseFile)) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 100
  }
} finally {
  $fs.Close()
  $fs.Dispose()
}
