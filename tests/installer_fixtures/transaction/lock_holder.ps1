#Requires -Version 5.1
<#
  lock_holder.ps1 - QA fixture: hold an exclusive/share-limited handle on a file.

  Used by run_transaction_qa.ps1 scenario (d) to make one game-folder target busy
  while the installer runs. Opens the parent's precreated named events, signals
  readiness only after taking the requested lock, and waits for release.
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$ReadyEvent,
  [Parameter(Mandatory = $true)][string]$ReleaseEvent,
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

$ready = [Threading.EventWaitHandle]::OpenExisting($ReadyEvent)
$release = [Threading.EventWaitHandle]::OpenExisting($ReleaseEvent)
$fs = $null
try {
  $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $shareMode)
  [void]$ready.Set()
  if (-not $release.WaitOne($TimeoutSec * 1000)) { throw 'Lock release event timed out' }
} finally {
  if ($null -ne $fs) { $fs.Dispose() }
  $release.Dispose()
  $ready.Dispose()
}
