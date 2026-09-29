#Requires -Version 5.1
<#
.SYNOPSIS
  T2 fixture runner for the one-entry installer (Install_OptiScaler_windows.bat).

  For each named case: stages a fake game layout under -FixtureRoot, snapshots
  SHA-256 of every file, runs the launcher through cmd.exe when -InstallerPath
  exists (else emits SKIP-MISSING-LAUNCHER), re-hashes, asserts the expected
  outcome, and emits one JSON row:
    {case, command, exit, expected, actual, pass, reason}

  Outer exit: 0 only if every case passes; 3 if the launcher BAT is missing
  (SKIP path, legitimate pre-T3); 1 on any real FAIL.

  Two layouts: GameA/bin64/GameA.exe (winmm.dll + OptiScaler.asi + ReShade.asi)
  and GameB/Engine/Binaries/Win64/GameB-Win64-Shipping.exe (dxgi.dll collision).
  Game binaries are 1 KB deterministic pseudo-random bytes (fixed seeds); no
  real DLL is needed at T2.

  Creates files only under -FixtureRoot. No sleeps; every child runs bounded
  (60 s) with stdin closed and kill-on-timeout; failures are captured verbatim.
#>
param(
  [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$InstallerPath = '',
  [string]$FixtureRoot = (Join-Path $env:TEMP 'susemi-inst-fixture')
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
  $InstallerPath = Join-Path $PackageRoot 'Install_OptiScaler_windows.bat'
}
$launcherExists = Test-Path -LiteralPath $InstallerPath

$runId = [guid]::NewGuid().ToString('N')
$scratch = Join-Path $FixtureRoot "run-$runId"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$TimeoutMs = 60000
$script:failCount = 0
$script:caseCount = 0

function New-FakeBytes {
  param([int]$Seed)
  $r = New-Object System.Random($Seed)
  $b = New-Object byte[] 1024
  $r.NextBytes($b)
  return $b
}

function New-GameFixture {
  param([string]$CaseName, [string]$ExeRel, [string[]]$Siblings, [int]$SeedBase)
  $root = Join-Path $scratch $CaseName
  $exePath = Join-Path $root $ExeRel
  $binDir = Split-Path -Parent $exePath
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  [IO.File]::WriteAllBytes($exePath, (New-FakeBytes ($SeedBase + 1)))
  $i = 10
  foreach ($s in $Siblings) {
    [IO.File]::WriteAllBytes((Join-Path $binDir $s), (New-FakeBytes ($SeedBase + $i)))
    $i++
  }
  return @{ Root = $root; Exe = $exePath; BinDir = $binDir }
}

function Get-Snapshot {
  param([string]$Root)
  $snap = @{}
  foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($Root.Length + 1)
    $snap[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }
  return $snap
}

function Test-SameSnapshot {
  param($Before, $After)
  if ($Before.Count -ne $After.Count) { return $false }
  foreach ($k in $Before.Keys) {
    if (-not $After.ContainsKey($k)) { return $false }
    if ($After[$k] -ne $Before[$k]) { return $false }
  }
  return $true
}

function Invoke-BoundedCmd {
  param([string]$Inner, [string]$WorkDir)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = '/d /c "' + $Inner + '"'
  $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  try { $p.StandardInput.Close() } catch {}
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutMs)) {
    $timedOut = $true
    try { $p.Kill() } catch {}
    [void]$p.WaitForExit(15000)
  }
  return @{ Exit = $p.ExitCode; TimedOut = $timedOut;
            Stdout = $p.StandardOutput.ReadToEnd(); Stderr = $p.StandardError.ReadToEnd() }
}

function Emit-Row {
  param($Case, $Command, $Exit, $Expected, $Actual, $Pass, $Reason)
  $script:caseCount++
  if (-not $Pass) { $script:failCount++ }
  $row = [ordered]@{ case = $Case; command = $Command; exit = $Exit;
                     expected = $Expected; actual = $Actual; pass = $Pass; reason = $Reason }
  Write-Output ($row | ConvertTo-Json -Compress)
}

function Invoke-FixtureCase {
  # Stages snapshot, runs launcher (or SKIP row), returns @{Command,Exit,TimedOut,Same,Stdout,Stderr,Skipped}.
  param([string]$Case, [string]$LauncherArgs, [hashtable]$Fx)
  $before = Get-Snapshot -Root $Fx.Root
  $cmd = '"' + $InstallerPath + '" ' + $LauncherArgs
  if (-not $launcherExists) {
    Emit-Row $Case $cmd $null 'skip-no-launcher' 'SKIP-MISSING-LAUNCHER' $true `
      'launcher BAT not present yet; fixture staged and snapshotted, nothing executed'
    return @{ Skipped = $true }
  }
  $r = Invoke-BoundedCmd -Inner $cmd -WorkDir $Fx.Root
  $after = Get-Snapshot -Root $Fx.Root
  return @{ Skipped = $false; Command = $cmd; Exit = $r.Exit; TimedOut = $r.TimedOut;
            Same = (Test-SameSnapshot $before $after); Stdout = $r.Stdout; Stderr = $r.Stderr }
}

# (a) diagnose-no-writes — layout A, diagnose must leave every byte untouched.
$fx = New-GameFixture 'diagnose-no-writes' 'GameA/bin64/GameA.exe' @('winmm.dll', 'OptiScaler.asi', 'ReShade.asi') 0xA001
$st = Invoke-FixtureCase 'diagnose-no-writes' ('diagnose -Exe "' + $fx.Exe + '"') $fx
if (-not $st.Skipped) {
  if ($st.TimedOut) {
    Emit-Row 'diagnose-no-writes' $st.Command $st.Exit 'bytes-unchanged' 'timeout' $false `
      ('child exceeded 60000 ms and was killed; stdout=[' + $st.Stdout + '] stderr=[' + $st.Stderr + ']')
  } else {
    $actual = if ($st.Same) { 'bytes-unchanged' } else { 'bytes-changed' }
    Emit-Row 'diagnose-no-writes' $st.Command $st.Exit 'bytes-unchanged' $actual $st.Same `
      ('diagnose must be read-only; exit=' + $st.Exit)
  }
}

# (b) cancel-preserves — layout A, install with -Consent no must change nothing.
$fx = New-GameFixture 'cancel-preserves' 'GameA/bin64/GameA.exe' @('winmm.dll', 'OptiScaler.asi', 'ReShade.asi') 0xA011
$st = Invoke-FixtureCase 'cancel-preserves' ('install -Exe "' + $fx.Exe + '" -Consent no') $fx
if (-not $st.Skipped) {
  if ($st.TimedOut) {
    Emit-Row 'cancel-preserves' $st.Command $st.Exit 'bytes-unchanged' 'timeout' $false `
      ('child exceeded 60000 ms and was killed; stdout=[' + $st.Stdout + '] stderr=[' + $st.Stderr + ']')
  } else {
    $actual = if ($st.Same) { 'bytes-unchanged' } else { 'bytes-changed' }
    Emit-Row 'cancel-preserves' $st.Command $st.Exit 'bytes-unchanged' $actual $st.Same `
      ('consent-no cancel must preserve every byte; exit=' + $st.Exit)
  }
}

# (c) conflict-refusal — layout B (dxgi.dll collision) + plugins/global.ini override.
$fx = New-GameFixture 'conflict-refusal' 'GameB/Engine/Binaries/Win64/GameB-Win64-Shipping.exe' @('dxgi.dll') 0xB001
$plugDir = Join-Path $fx.Root 'plugins'
New-Item -ItemType Directory -Path $plugDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $plugDir 'global.ini') -Value "[loader]`noverride=dxgi.dll" -Encoding Ascii
$st = Invoke-FixtureCase 'conflict-refusal' ('install -Exe "' + $fx.Exe + '" -Consent yes') $fx
if (-not $st.Skipped) {
  if ($st.TimedOut) {
    Emit-Row 'conflict-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'timeout' $false `
      ('child exceeded 60000 ms and was killed; stdout=[' + $st.Stdout + '] stderr=[' + $st.Stderr + ']')
  } elseif (($st.Exit -ne 0) -and $st.Same) {
    Emit-Row 'conflict-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'refusal-bytes-unchanged' $true `
      'dxgi.dll collision + plugins/global.ini override refused with zero writes'
  } elseif ($st.Exit -eq 0) {
    Emit-Row 'conflict-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'unexpected-success' $false `
      'conflict must refuse (nonzero exit); launcher reported success'
  } else {
    Emit-Row 'conflict-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'refusal-but-bytes-changed' $false `
      'refused but fixture bytes changed; refusal must be write-free'
  }
}

# (d) missing-backup-refusal — pre-seeded receipt whose backup dir does not exist.
$fx = New-GameFixture 'missing-backup-refusal' 'GameA/bin64/GameA.exe' @('winmm.dll', 'OptiScaler.asi', 'ReShade.asi') 0xA021
$missingBackup = Join-Path $fx.BinDir '_susemi_backup_missing'
$receiptObj = [ordered]@{ version = 1; exe = 'GameA.exe'; backupDir = $missingBackup;
                          installedUtc = '2026-09-27T00:00:00Z'; owner = 'susemi_installer.ps1' }
($receiptObj | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $fx.BinDir '_susemi_install_receipt.json') -Encoding UTF8
$st = Invoke-FixtureCase 'missing-backup-refusal' ('remove -Exe "' + $fx.Exe + '"') $fx
if (-not $st.Skipped) {
  if ($st.TimedOut) {
    Emit-Row 'missing-backup-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'timeout' $false `
      ('child exceeded 60000 ms and was killed; stdout=[' + $st.Stdout + '] stderr=[' + $st.Stderr + ']')
  } elseif (($st.Exit -ne 0) -and $st.Same) {
    Emit-Row 'missing-backup-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'refusal-bytes-unchanged' $true `
      'receipt present but backup dir missing; remove refused with zero writes'
  } elseif ($st.Exit -eq 0) {
    Emit-Row 'missing-backup-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'unexpected-success' $false `
      'missing backup must refuse (nonzero exit); launcher reported success'
  } else {
    Emit-Row 'missing-backup-refusal' $st.Command $st.Exit 'refusal-bytes-unchanged' 'refusal-but-bytes-changed' $false `
      'refused but fixture bytes changed; refusal must be write-free'
  }
}

# (e) stale-uninstaller-false-pass — stale Remove_OptiScaler.bat must NOT read as success.
$fx = New-GameFixture 'stale-uninstaller-false-pass' 'GameA/bin64/GameA.exe' @('winmm.dll', 'OptiScaler.asi', 'ReShade.asi') 0xA031
$staleBat = Join-Path $fx.BinDir 'Remove_OptiScaler.bat'
Set-Content -LiteralPath $staleBat -Value "@echo off`r`necho stale uninstaller`r`n" -Encoding Ascii
$staleSha = (Get-FileHash -LiteralPath $staleBat -Algorithm SHA256).Hash
$st = Invoke-FixtureCase 'stale-uninstaller-false-pass' ('remove -Exe "' + $fx.Exe + '"') $fx
if (-not $st.Skipped) {
  $staleSame = ((Get-FileHash -LiteralPath $staleBat -Algorithm SHA256).Hash -eq $staleSha)
  if ($st.TimedOut) {
    Emit-Row 'stale-uninstaller-false-pass' $st.Command $st.Exit 'no-false-pass' 'timeout' $false `
      ('child exceeded 60000 ms and was killed; stdout=[' + $st.Stdout + '] stderr=[' + $st.Stderr + ']')
  } elseif (($st.Exit -eq 0) -and $st.Same) {
    Emit-Row 'stale-uninstaller-false-pass' $st.Command $st.Exit 'no-false-pass' 'false-pass' $false `
      'exit 0 with bytes untouched while stale Remove_OptiScaler.bat sits in bindir: must not count as success'
  } elseif (($st.Exit -ne 0) -and $st.Same -and $staleSame) {
    Emit-Row 'stale-uninstaller-false-pass' $st.Command $st.Exit 'no-false-pass' 'no-false-pass' $true `
      ('nonzero exit, stale uninstaller byte-identical, no other writes; exit=' + $st.Exit)
  } else {
    Emit-Row 'stale-uninstaller-false-pass' $st.Command $st.Exit 'no-false-pass' 'bytes-changed' $false `
      ('fixture bytes changed (same=' + $st.Same + ' staleSame=' + $staleSame + '); exit=' + $st.Exit)
  }
}

$passed = $script:caseCount - $script:failCount
Write-Output ("SUMMARY pass={0}/{1} launcherExists={2} scratch={3}" -f $passed, $script:caseCount, $launcherExists, $scratch)
if (-not $launcherExists) { exit 3 }
if ($script:failCount -gt 0) { exit 1 }
exit 0
