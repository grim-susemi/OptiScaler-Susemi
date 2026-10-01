#Requires -Version 5.1
<#
.SYNOPSIS
  run_removal_qa.ps1 - T9 QA harness for the coordinator `remove` action.

  Scenarios a-j from the T9 brief, driven through the REAL coordinator
  (tools/susemi_installer.ps1 remove) after an install through the real
  coordinator (tools/susemi_installer.ps1 install). Every scenario is:
  fixture setup -> install -> (optional tamper/journal mutation) -> remove ->
  assertions on exit codes, machine `status=` lines and SHA maps -> cleanup.

  ISOLATION:
    Every child receives a case-owned LOCALAPPDATA and the pinned source ZIP.
    A real install/remove probe must restore its entire game map and use that
    private journal root. Broken isolation fails; no user-global fallback exists.

  Every child process runs with a hard timeout + kill. Scratch is removed.
  Native process completion uses bounded waits. Run only against released code;
  the remove-body smoke is checked once, never polled.

  EXIT: 0 = all scenarios PASS (real body); 1 = real body, >=1 scenario FAIL;
        3 = PENDING-REAL-BODY (remove body not landed yet).
#>
param(
  [string]$EvidenceDir = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-generic-installer-diagnose/w3/task-9',
  [string]$PackageRoot = '',
  [string]$ScratchRoot = '',
  [string]$Rc2Zip = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip',
  [string]$PingExe = 'C:\Windows\System32\ping.exe'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
$installer = Join-Path $PackageRoot 'tools\susemi_installer.ps1'
$psExe = Join-Path $PSHOME 'powershell.exe'
$pinZip = '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a'
$pinCore = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
$pinUal = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$defaultJournalRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer\journal'

if ([string]::IsNullOrEmpty($ScratchRoot)) { $ScratchRoot = Join-Path $env:TEMP ('susemi-t9-qa-' + [guid]::NewGuid().ToString('N')) }
$rawDir = Join-Path $EvidenceDir 'raw'
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

$script:unreapedOwnedChild = $false
$script:caseName = ''
$script:caseBuf = $null
$script:caseStatuses = $null
$script:rows = New-Object System.Collections.ArrayList
$script:removeLanded = $false
$script:markerLanded = $false
$script:smokeStatus = ''
$script:smokeReason = ''
$script:removeConsentMode = 'yes'
$script:journalMode = 'private-localappdata'
$script:statusLineDefects = 0
$script:noStatusLines = 0
$script:realRootLeaks = 0
$global:qaChildren = @()

# --------------------------------------------------------------- helpers ----

function Sha256([string]$p) {
  try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return '' }
}

function ShaMap([string]$root) {
  $h = @{}
  if (Test-Path -LiteralPath $root -PathType Container) {
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($root.Length).TrimStart('\')
      $h[$rel] = Sha256 $f.FullName
    }
  }
  return $h
}

function MapsEqual($a, $b) {
  if ($a.Count -ne $b.Count) { return $false }
  foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k) -or ($b[$k] -ne $a[$k])) { return $false } }
  return $true
}

function MapText($m) {
  if ($m.Count -eq 0) { return '(empty)' }
  return (($m.Keys | Sort-Object | ForEach-Object { '  {0} = {1}' -f $_, $m[$_] }) -join "`n")
}

function Get-MachineStatus([string]$Text) {
  $st = ''; $rs = ''
  foreach ($ln in ([string]$Text -split "`r?`n")) {
    if ($ln -match '^status=(\S+)\s+reason=(\S+)') { $st = $Matches[1]; $rs = $Matches[2]; break }
  }
  return @{ status = $st; reason = $rs }
}

function Count-StatusLines([string]$Text) {
  return @([string]$Text -split "`r?`n" | Where-Object { $_ -match '^status=' }).Count
}

function Invoke-Child {
  param([string]$FileName, [string[]]$ArgList, $EnvVars, [int]$TimeoutSec = 300)
  $res = [ordered]@{ exit = -1; timedOut = $false; stdout = ''; stderr = ''; cmdline = '' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $parts = @()
  foreach ($a in $ArgList) {
    $s = [string]$a
    if ($s -match '[\s"]') { $parts += ('"' + ($s -replace '"', '\"') + '"') } else { $parts += $s }
  }
  $psi.Arguments = ($parts -join ' ')
  $res.cmdline = $psi.Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  if ($EnvVars) { foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] } }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    $null = $p.Start()
    $null = $p.Handle
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      $res.timedOut = $true
      $killInfo = New-Object Diagnostics.ProcessStartInfo
      $killInfo.FileName = 'taskkill.exe'
      $killInfo.Arguments = '/PID ' + $p.Id + ' /T /F'
      $killInfo.UseShellExecute = $false
      $killInfo.CreateNoWindow = $true
      $killer = [Diagnostics.Process]::Start($killInfo)
      if (-not $killer.WaitForExit(15000)) { $script:unreapedOwnedChild = $true; throw 'Owned tree termination timed out' }
      $killExit = $killer.ExitCode
      $killer.Dispose()
      if ($killExit -ne 0 -or -not $p.WaitForExit(15000)) { $script:unreapedOwnedChild = $true; throw 'Owned tree was not reaped' }
    }
    if (-not $p.HasExited) { $script:unreapedOwnedChild = $true; throw 'Owned child exit was not observed' }
    if (-not $o.Wait(15000) -or -not $e.Wait(15000)) { $script:unreapedOwnedChild = $true; throw 'Owned streams did not close' }
    $res.stdout = [string]$o.Result
    $res.stderr = [string]$e.Result
    $res.exit = [int]$p.ExitCode
  } catch {
    $res.stderr = [string]$_.Exception.Message
  } finally {
    try { $p.Dispose() } catch { }
  }
  return $res
}

# Run the coordinator and log the full invocation into the current case buffer.
function Invoke-Cmd {
  param([string]$Label, [string[]]$ArgList, $EnvVars, [int]$TimeoutSec = 300)
  $r = Invoke-Child -FileName $psExe -ArgList $ArgList -EnvVars $EnvVars -TimeoutSec $TimeoutSec
  Say ('$ powershell ' + ($ArgList -join ' '))
  if ($EnvVars) { foreach ($k in $EnvVars.Keys) { if (-not [string]::IsNullOrEmpty([string]$EnvVars[$k])) { Say ('  env| ' + $k + '=' + $EnvVars[$k]) } } }
  Say ('exit=' + $r.exit + ' timedOut=' + $r.timedOut)
  if ($r.stdout) { foreach ($ln in ($r.stdout.TrimEnd() -split "`r?`n")) { Say ('  out| ' + $ln) } }
  if ($r.stderr) { foreach ($ln in ($r.stderr.TrimEnd() -split "`r?`n")) { Say ('  err| ' + $ln) } }
  $n = Count-StatusLines $r.stdout
  if ($n -gt 1) {
    $script:statusLineDefects++
    Say ('DEFECT-OPEN(T4 double-status): label=' + $Label + ' status-lines=' + $n + ' (expected exactly 1)')
  } elseif ($n -eq 0) {
    $script:noStatusLines++
    Say ('NOTE-NO-STATUS-LINE: label=' + $Label + ' status-lines=0 exit=' + $r.exit + ' (no machine line: crash or transient parse error)')
  }
  $ms = Get-MachineStatus $r.stdout
  $r.status = $ms.status; $r.reason = $ms.reason
  [void]$script:caseStatuses.Add($Label + '=' + $ms.status + '/' + $ms.reason + '/exit=' + $r.exit + '/statuslines=' + $n)
  return $r
}

function Install-Args([string]$exe) {
  return @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer, 'install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en')
}

function Remove-Args([string]$exe, [string]$consent = 'auto') {
  $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer, 'remove', '-Exe', $exe, '-Lang', 'en')
  if ($script:removeConsentMode -eq 'yes') {
    $c = 'yes'
    if ($consent -eq 'no') { $c = 'no' }
    $a += @('-Consent', $c)
  }
  return $a
}

function Get-JournalPath([string]$out) {
  if ($out -match 'journal=([^\r\n]+)') { return $Matches[1].Trim() }
  return ''
}

function Read-Journal([string]$p) {
  if ([string]::IsNullOrEmpty($p)) { return $null }
  try { return ((Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json) } catch { return $null }
}

function New-Game([string]$dir) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $PingExe -Destination (Join-Path $dir 'GameA.exe') -Force
}

# active journal root for a case -------------------------------------------------
function New-CaseJournalRoot([string]$case) {
  $jr = Join-Path $ScratchRoot ($case + '\local\susemi-installer\journal')
  New-Item -ItemType Directory -Path $jr -Force | Out-Null
  return $jr
}

function Case-Env([string]$jr) {
  $local = Split-Path -Parent (Split-Path -Parent $jr)
  return @{ 'LOCALAPPDATA' = $local; 'SUSEMI_TX_JOURNAL_ROOT' = ''; 'SUSEMI_RC2_ZIP' = $Rc2Zip }
}

# real journal root snapshot / restore (the T7 before=0/after=0 rule) -------------
function Get-RootSnapshot([string]$root) {
  $res = @{ existed = (Test-Path -LiteralPath $root -PathType Container); count = 0; files = @{} }
  if ($res.existed) {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($root.Length).TrimStart('\')
      $res.files[$rel] = Sha256 $f.FullName
    }
    $res.count = $res.files.Count
  }
  return $res
}

# --------------------------------------------------------- case framework ----

function Start-Case([string]$name) {
  $script:caseName = $name
  $script:caseBuf = New-Object System.Collections.ArrayList
  $script:caseStatuses = New-Object System.Collections.ArrayList
  Write-Host ('=== ' + $name + ' ===')
}

function Say([string]$s) {
  [void]$script:caseBuf.Add($s)
  Write-Host $s
}

function Assert2([bool]$cond, [string]$msg) {
  if ($script:removeLanded) {
    if ($cond) { Say ('ASSERT-PASS: ' + $msg) } else { Say ('ASSERT-FAIL: ' + $msg) }
  } else {
    Say ('PENDING-REAL-BODY: ' + $msg)
  }
}

function End-Case {
  $fails = @($script:caseBuf | Where-Object { $_ -like 'ASSERT-FAIL:*' }).Count
  $passes = @($script:caseBuf | Where-Object { $_ -like 'ASSERT-PASS:*' }).Count
  $pend = @($script:caseBuf | Where-Object { $_ -like 'PENDING-REAL-BODY:*' }).Count
  $status = 'PASS'
  if (-not $script:removeLanded) { $status = 'PENDING-REAL-BODY' }
  elseif ($fails -gt 0) { $status = 'FAIL' }
  Say ('CASE-RESULT: ' + $status + ' pass=' + $passes + ' fail=' + $fails + ' pending=' + $pend)
  [void]$script:rows.Add([pscustomobject]@{
    case = $script:caseName; status = $status; pass = $passes; fail = $fails; pending = $pend;
    observed = ($script:caseStatuses -join '; ')
  })
  Set-Content -LiteralPath (Join-Path $rawDir ($script:caseName + '.log')) -Value ($script:caseBuf -join "`r`n") -Encoding UTF8
}

function Invoke-Scenario([string]$name, [scriptblock]$body) {
  Start-Case $name
  $snap = Get-RootSnapshot $defaultJournalRoot
  try { & $body } catch {
    Say ('SCENARIO-ERROR: ' + $_.Exception.Message)
    if ($script:removeLanded) { Say ('ASSERT-FAIL: scenario threw: ' + $_.Exception.Message) }
    else { Say ('PENDING-REAL-BODY: scenario threw under stub: ' + $_.Exception.Message) }
  }
  $after = Get-RootSnapshot $defaultJournalRoot
  $iso = (MapsEqual $snap.files $after.files) -and ($snap.existed -eq $after.existed)
  if (-not $iso) { $script:realRootLeaks++ }
  Assert2 $iso 'user-global journal file map and existence unchanged (read-only audit)'
  Say (('ISOLATION ' + $(if ($iso) { 'PASS' } else { 'FAIL' }) + ': real journal root before=' + $snap.count + ' after=' + $after.count + ' existed_before=' + $snap.existed))
  End-Case
}

# ------------------------------------------------ one-shot smoke + probe ----

function Test-RemoveLandedOnce {
  $inst = ''
  try { $inst = [string](Get-Content -LiteralPath $installer -Raw -ErrorAction Stop) } catch { $inst = '' }
  # Syntax marker: the stub token must be gone from the dispatch body. A stale
  # docstring mention can keep it present, so this signal is only informational;
  # the behavioural smoke below is authoritative.
  $markerGone = -not ($inst -match 'remove-pending-T9')
  $sg = Join-Path $ScratchRoot 'landing\game'
  New-Game $sg
  $sr = New-CaseJournalRoot 'landing'
  $sm = Invoke-Child -FileName $psExe -ArgList (Remove-Args (Join-Path $sg 'GameA.exe')) -EnvVars (Case-Env $sr) -TimeoutSec 120
  $ms = Get-MachineStatus $sm.stdout
  $smokeStub = ($ms.status -eq 'pending') -or ($ms.reason -like '*remove-pending*')
  $smokeUsable = $sm.exit -eq 1 -and -not $sm.timedOut -and $ms.status -eq 'missing-input' -and $ms.reason -eq 'no-install-record'
  return @{ marker = $markerGone; smokeStatus = $ms.status; smokeReason = $ms.reason; smokeStub = $smokeStub; smokeUsable = $smokeUsable; landed = ($smokeUsable -and (-not $smokeStub)) }
}

function Test-RemoveReady {
  $last = Test-RemoveLandedOnce
  $script:markerLanded = $last.marker
  $script:smokeStatus = $last.smokeStatus
  $script:smokeReason = $last.smokeReason
  $script:removeLanded = $last.landed
  return $last
}

function Probe-JournalMode {
    $pg = Join-Path $ScratchRoot 'probe\game'; New-Game $pg
    $exe = Join-Path $pg 'GameA.exe'
    $pr = New-CaseJournalRoot 'probe'
    $env1 = Case-Env $pr
    $pre = ShaMap $pg
    $i = Invoke-Child -FileName $psExe -ArgList (Install-Args $exe) -EnvVars $env1 -TimeoutSec 300
    if ($i.exit -ne 0 -or $i.timedOut) { throw ('Isolation probe install failed: ' + $i.exit + ' ' + $i.stdout + ' ' + $i.stderr) }
    $jp = Get-JournalPath $i.stdout
    if ([string]::IsNullOrEmpty($jp) -or
        -not ([IO.Path]::GetFullPath($jp).StartsWith([IO.Path]::GetFullPath($pr) + '\', [StringComparison]::OrdinalIgnoreCase))) {
      throw 'Isolation probe journal escaped the compulsory private root'
    }
    $ra = Remove-Args $exe
    $r = Invoke-Child -FileName $psExe -ArgList $ra -EnvVars $env1 -TimeoutSec 120
    $post = ShaMap $pg
    if ($r.exit -ne 0 -or $r.timedOut -or -not (MapsEqual $pre $post)) {
      throw ('Isolation probe removal failed: ' + $r.exit + ' ' + $r.stdout + ' ' + $r.stderr)
    }
    return 'private-localappdata'
}

# ================================================================ run =======

Write-Host ('removal QA: installer=' + $installer)
Write-Host ('removal QA: scratch=' + $ScratchRoot)
Write-Host ('removal QA: evidence=' + $EvidenceDir)
Write-Host ('removal QA: rc2 zip pin=' + $pinZip + ' present=' + (Test-Path -LiteralPath $Rc2Zip -PathType Leaf))
if ((Sha256 $Rc2Zip) -ne $pinZip) { throw 'Pinned ZIP prerequisite is missing or mismatched' }

$pingOk = Test-Path -LiteralPath $PingExe -PathType Leaf
Write-Host ('removal QA: game exe fixture=' + $PingExe + ' present=' + $pingOk)

$gitBefore = ''
try { $gitBefore = [string](& git -C $PackageRoot status --short 2>$null | Out-String) } catch { $gitBefore = '' }

Write-Host ''
Write-Host '=== released-code smoke ==='
$land = Test-RemoveReady
Write-Host ('landing: marker_gone=' + $land.marker + ' smoke_status=' + $land.smokeStatus + ' smoke_reason=' + $land.smokeReason + ' smoke_usable=' + $land.smokeUsable + ' landed=' + $land.landed)
if ($land.landed -and (-not $land.marker)) { Write-Host 'landing-note: smoke says the body landed but the stub token is still present (stale docstring text); smoke is authoritative.' }

if ($script:removeLanded) {
  Write-Host ('remove consent mode: ' + $script:removeConsentMode)
  $script:journalMode = Probe-JournalMode
  Write-Host ('journal isolation mode: ' + $script:journalMode)
} else {
  Write-Host 'remove body NOT landed (stub still active) -> all scenarios report PENDING-REAL-BODY'
  throw 'Released remove body is not ready; no scenarios launched'
}

# --------------------------------------------------------------- scenarios --

Invoke-Scenario 'a-install-remove-happy' {
  $game = Join-Path $ScratchRoot 'a\game'; New-Game $game
  $pre = ShaMap $game
  Say ("pre-install map:`n" + (MapText $pre))
  $jr = New-CaseJournalRoot 'a'; $env = Case-Env $jr
  $inst = Invoke-Cmd 'install-a' (Install-Args (Join-Path $game 'GameA.exe')) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ', timedOut=' + $inst.timedOut + ')')
  Assert2 ($inst.stdout -match 'status=installed reason=ok') 'install status=installed reason=ok'
  $asi = Join-Path $game 'OptiScaler.asi'; $ual = Join-Path $game 'winmm.dll'
  Assert2 ((Sha256 $asi) -eq $pinCore) ('OptiScaler.asi == core pin (' + (Sha256 $asi) + ')')
  Assert2 ((Sha256 $ual) -eq $pinUal) ('winmm.dll == UAL pin (' + (Sha256 $ual) + ')')
  $j = Get-JournalPath $inst.stdout
  Assert2 ([bool](Test-Path -LiteralPath $j)) ('journal exists: ' + $j)
  $jb = Read-Journal $j
  Assert2 ($null -ne $jb -and $jb.phase -eq 'applied') ('journal phase=applied (got ' + $jb.phase + ')')
  Say ("installed map:`n" + (MapText (ShaMap $game)))

  $rm = Invoke-Cmd 'remove-a' (Remove-Args (Join-Path $game 'GameA.exe')) $env
  Assert2 ($rm.exit -eq 0) ('remove exit 0 (got ' + $rm.exit + ', timedOut=' + $rm.timedOut + ')')
  Assert2 ($rm.exit -eq 0 -and $rm.status -notin @('pending', 'refused', 'failed', 'invalid-invocation')) ('remove success status (got ' + $rm.status + '/' + $rm.reason + ')')
  Assert2 (-not (Test-Path -LiteralPath $asi)) 'OptiScaler.asi absent after remove'
  Assert2 (-not (Test-Path -LiteralPath $ual)) 'winmm.dll absent after remove'
  $post = ShaMap $game
  Say ("post-remove map:`n" + (MapText $post))
  Assert2 (MapsEqual $pre $post) 'full-dir SHA map identical to pre-install'
  $jb2 = Read-Journal $j
  Assert2 ($null -ne $jb2 -and $jb2.phase -eq 'recovered') ('journal phase=recovered (got ' + $jb2.phase + ')')
}

Invoke-Scenario 'b-reshade-first-ini' {
  $game = Join-Path $ScratchRoot 'b\game'; New-Game $game
  Copy-Item -LiteralPath $PingExe -Destination (Join-Path $game 'ReShade.asi') -Force
  $pre = ShaMap $game
  Say ("pre-install map:`n" + (MapText $pre))
  $jr = New-CaseJournalRoot 'b'; $env = Case-Env $jr
  $ini = Join-Path $game 'winmm.ini'
  Assert2 (-not (Test-Path -LiteralPath $ini)) 'winmm.ini absent before install'
  $exe = Join-Path $game 'GameA.exe'
  $rfArgs = Install-Args $exe; $rfArgs += @('-ReshadeFirst', '-IniConsent', 'yes')
  $inst = Invoke-Cmd 'install-b-reshade-first' $rfArgs $env
  $iniCreated = (Test-Path -LiteralPath $ini)
  if (($inst.exit -eq 0) -and $iniCreated) {
    Assert2 $true 'install -ReshadeFirst -IniConsent yes created winmm.ini'
    $rm = Invoke-Cmd 'remove-b' (Remove-Args $exe) $env
    Assert2 ($rm.exit -eq 0) ('remove exit 0 (got ' + $rm.exit + ')')
    Assert2 (-not (Test-Path -LiteralPath $ini)) 'winmm.ini absent again after remove'
    $post = ShaMap $game
    Say ("post-remove map:`n" + (MapText $post))
    Assert2 (MapsEqual $pre $post) 'byte-identity incl. absence (ReShade-first INI)'
  } else {
    Assert2 $false 'ReShade-first INI install must succeed; plain fallback cannot certify this scenario'
    Say ('OBSERVED: -ReshadeFirst install not usable here (exit=' + $inst.exit + ' ini_created=' + $iniCreated + ' status=' + $inst.status + '/' + $inst.reason + ')')
    Say 'PENDING-INI: -ReshadeFirst/winmm.ini path not exercised; running the plain-install fallback and recording the INI part PENDING.'
    $inst2 = Invoke-Cmd 'install-b-plain' (Install-Args $exe) $env
    Assert2 ($inst2.exit -eq 0) ('fallback plain install exit 0 (got ' + $inst2.exit + ')')
    $rm = Invoke-Cmd 'remove-b-plain' (Remove-Args $exe) $env
    Assert2 ($rm.exit -eq 0) ('remove exit 0 (got ' + $rm.exit + ')')
    $post = ShaMap $game
    Say ("post-remove map:`n" + (MapText $post))
    Assert2 (MapsEqual $pre $post) 'byte-identity incl. absence (plain install fallback)'
  }
}

Invoke-Scenario 'c-repeat-then-noop' {
  $game = Join-Path $ScratchRoot 'c\game'; New-Game $game
  $pre = ShaMap $game
  $jr = New-CaseJournalRoot 'c'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $i1 = Invoke-Cmd 'install-c-1' (Install-Args $exe) $env
  Assert2 ($i1.exit -eq 0) ('install #1 exit 0 (got ' + $i1.exit + ')')
  $r1 = Invoke-Cmd 'remove-c-1' (Remove-Args $exe) $env
  Assert2 ($r1.exit -eq 0) ('remove #1 exit 0 (got ' + $r1.exit + ')')
  $i2 = Invoke-Cmd 'install-c-2' (Install-Args $exe) $env
  Assert2 ($i2.exit -eq 0) ('install #2 exit 0 (got ' + $i2.exit + ')')
  $r2 = Invoke-Cmd 'remove-c-2' (Remove-Args $exe) $env
  Assert2 ($r2.exit -eq 0) ('remove #2 exit 0 (got ' + $r2.exit + ')')
  $pre3 = ShaMap $game
  $r3 = Invoke-Cmd 'remove-c-3' (Remove-Args $exe) $env
  Assert2 ($r3.exit -eq 0) ('remove #3 exit 0 (got ' + $r3.exit + ')')
  Assert2 ($r3.status -eq 'no-op' -and $r3.reason -eq 'already-removed') ('remove #3 status=no-op reason=already-removed (got ' + $r3.status + '/' + $r3.reason + ')')
  $post3 = ShaMap $game
  Assert2 (MapsEqual $pre3 $post3) 'remove #3 zero writes (SHA map equal)'
  $post = ShaMap $game
  Assert2 (MapsEqual $pre $post) 'full-dir SHA map identical to pre-install after cycle'
}

Invoke-Scenario 'd-tampered-target' {
  $game = Join-Path $ScratchRoot 'd\game'; New-Game $game
  $jr = New-CaseJournalRoot 'd'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $inst = Invoke-Cmd 'install-d' (Install-Args $exe) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ')')
  $asi = Join-Path $game 'OptiScaler.asi'
  [System.IO.File]::WriteAllBytes($asi, [System.Text.Encoding]::ASCII.GetBytes('TAMPERED-ASI-BYTES-D'))
  $tamperedSha = Sha256 $asi
  Say ('tampered OptiScaler.asi sha=' + $tamperedSha)
  $before = ShaMap $game
  Say ("map before refused remove:`n" + (MapText $before))
  $rm = Invoke-Cmd 'remove-d' (Remove-Args $exe) $env
  Assert2 ($rm.exit -eq 1) ('remove refused exit 1 (got ' + $rm.exit + ')')
  Assert2 ($rm.status -eq 'refused' -and $rm.reason -eq 'target-changed') ('status=refused reason=target-changed (got ' + $rm.status + '/' + $rm.reason + ')')
  $post = ShaMap $game
  Assert2 (MapsEqual $before $post) 'zero writes (SHA map equal incl. tampered file)'
  Assert2 ((Sha256 $asi) -eq $tamperedSha) 'tampered OptiScaler.asi bytes untouched'
}

Invoke-Scenario 'e-missing-backup' {
  $game = Join-Path $ScratchRoot 'e\game'; New-Game $game
  [System.IO.File]::WriteAllBytes((Join-Path $game 'OptiScaler.asi'), [System.Text.Encoding]::ASCII.GetBytes('PRIOR-ASI-BASELINE-E'))
  $jr = New-CaseJournalRoot 'e'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $inst = Invoke-Cmd 'install-e' (Install-Args $exe) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ')')
  $j = Get-JournalPath $inst.stdout
  $jb = Read-Journal $j
  $op = $null
  if ($null -ne $jb) { $op = @($jb.ops | Where-Object { $_.target -like '*OptiScaler.asi' })[0] }
  $bak = ''
  if ($null -ne $op) { $bak = [string]$op.backupPath }
  Assert2 ($null -ne $op -and $op.op -eq 'replace') ('journal has a replace op for OptiScaler.asi (got ' + $(if ($null -ne $op) { $op.op } else { '<none>' }) + ')')
  Assert2 (-not [string]::IsNullOrEmpty($bak) -and (Test-Path -LiteralPath $bak)) ('backup preimage exists: ' + $bak)
  if (-not [string]::IsNullOrEmpty($bak) -and (Test-Path -LiteralPath $bak)) { Remove-Item -LiteralPath $bak -Force }
  $before = ShaMap $game
  Say ("map after deleting the backup preimage:`n" + (MapText $before))
  $rm = Invoke-Cmd 'remove-e' (Remove-Args $exe) $env
  Assert2 ($rm.exit -eq 1) ('remove refused exit 1 (got ' + $rm.exit + ')')
  Assert2 ($rm.status -eq 'refused' -and $rm.reason -eq 'backup-missing') ('status=refused reason=backup-missing (got ' + $rm.status + '/' + $rm.reason + ')')
  $post = ShaMap $game
  Assert2 (MapsEqual $before $post) 'zero writes (SHA map equal with backup deleted)'
}

Invoke-Scenario 'f-malformed-journal' {
  $game = Join-Path $ScratchRoot 'f\game'; New-Game $game
  [System.IO.File]::WriteAllBytes((Join-Path $game 'OptiScaler.asi'), [System.Text.Encoding]::ASCII.GetBytes('PRIOR-ASI-BASELINE-F'))
  $jr = New-CaseJournalRoot 'f'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $inst = Invoke-Cmd 'install-f' (Install-Args $exe) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ')')
  $j = Get-JournalPath $inst.stdout
  $mutPath = ''
  $hideDir = Join-Path $ScratchRoot 'f\hidden'
  New-Item -ItemType Directory -Path $hideDir -Force | Out-Null
  try {
    $jb = Read-Journal $j
    $op = @($jb.ops | Where-Object { $_.op -eq 'replace' })[0]
    Assert2 ($null -ne $op -and -not [string]::IsNullOrEmpty([string]$op.beforeSha)) 'journal replace op carries a beforeSha'
    $op.backupPath = ''   # rc1-era dangerous shape: replace op with no backup path, beforeSha kept
    $mutPath = Join-Path $jr ('j_' + (Get-Date -Format 'yyyyMMddHHmmss_fff') + '_plan.json')
    [System.IO.File]::WriteAllText($mutPath, ($jb | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $j -Destination (Join-Path $hideDir (Split-Path -Leaf $j)) -Force
    Say ('mutated journal placed as newest: ' + $mutPath)
    Say ('original journal moved away to: ' + (Join-Path $hideDir (Split-Path -Leaf $j)))
    $before = ShaMap $game
    $rm = Invoke-Cmd 'remove-f' (Remove-Args $exe) $env
    Assert2 ($rm.exit -eq 1) ('remove refused exit 1 (got ' + $rm.exit + ')')
    Assert2 ($rm.status -eq 'refused' -and $rm.reason -in @('backup-missing', 'journal-unknown')) ('status=refused reason=backup-missing|journal-unknown (got ' + $rm.status + '/' + $rm.reason + ')')
    $post = ShaMap $game
    Assert2 (MapsEqual $before $post) 'zero writes on malformed journal (SHA map equal)'
  } finally {
    if (-not [string]::IsNullOrEmpty($mutPath) -and (Test-Path -LiteralPath $mutPath)) { Remove-Item -LiteralPath $mutPath -Force -ErrorAction SilentlyContinue }
    $hidden = Join-Path $hideDir (Split-Path -Leaf $j)
    if (Test-Path -LiteralPath $hidden) { Move-Item -LiteralPath $hidden -Destination $j -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $hideDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-Scenario 'g-no-journal' {
  $game = Join-Path $ScratchRoot 'g\game'; New-Game $game
  Set-Content -LiteralPath (Join-Path $game 'random1.bin') -Value 'RANDOM-1' -NoNewline
  New-Item -ItemType Directory -Path (Join-Path $game 'sub') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $game 'sub\random2.txt') -Value 'RANDOM-2' -NoNewline
  $pre = ShaMap $game
  Say ("pre-remove map:`n" + (MapText $pre))
  $jr = New-CaseJournalRoot 'g'; $env = Case-Env $jr
  Say ('journal root for this case has no install record: ' + $jr)
  $rm = Invoke-Cmd 'remove-g' (Remove-Args (Join-Path $game 'GameA.exe')) $env
  Assert2 ($rm.exit -eq 1) ('remove refused exit 1 (got ' + $rm.exit + ')')
  Assert2 ($rm.status -eq 'missing-input' -and $rm.reason -eq 'no-install-record') ('status=missing-input reason=no-install-record (got ' + $rm.status + '/' + $rm.reason + ')')
  $post = ShaMap $game
  Assert2 (MapsEqual $pre $post) 'zero writes with no install record (SHA map equal)'
}

Invoke-Scenario 'h-path-escape' {
  $game = Join-Path $ScratchRoot 'h\game'; New-Game $game
  [System.IO.File]::WriteAllBytes((Join-Path $game 'OptiScaler.asi'), [System.Text.Encoding]::ASCII.GetBytes('PRIOR-ASI-BASELINE-H'))
  $jr = New-CaseJournalRoot 'h'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $inst = Invoke-Cmd 'install-h' (Install-Args $exe) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ')')
  $j = Get-JournalPath $inst.stdout
  $mutPath = ''
  $hideDir = Join-Path $ScratchRoot 'h\hidden'
  New-Item -ItemType Directory -Path $hideDir -Force | Out-Null
  $escape = $game + '\..\evil.dll'
  try {
    $jb = Read-Journal $j
    $op = @($jb.ops | Where-Object { $_.target -like '*OptiScaler.asi' })[0]
    Assert2 ($null -ne $op) 'journal has an OptiScaler.asi op to mutate'
    $op.target = $escape
    $mutPath = Join-Path $jr ('j_' + (Get-Date -Format 'yyyyMMddHHmmss_fff') + '_plan.json')
    [System.IO.File]::WriteAllText($mutPath, ($jb | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $j -Destination (Join-Path $hideDir (Split-Path -Leaf $j)) -Force
    Say ('mutated op target = ' + $escape)
    Say ('mutated journal placed as newest: ' + $mutPath)
    $before = ShaMap $game
    $rm = Invoke-Cmd 'remove-h' (Remove-Args $exe) $env
    Assert2 ($rm.exit -eq 1) ('remove refused exit 1 (got ' + $rm.exit + ')')
    Assert2 ($rm.status -eq 'refused' -and $rm.reason -eq 'path-escape') ('status=refused reason=path-escape (got ' + $rm.status + '/' + $rm.reason + ')')
    $post = ShaMap $game
    Assert2 (MapsEqual $before $post) 'zero writes on path-escape (SHA map equal)'
    Assert2 (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $game) 'evil.dll'))) 'no evil.dll written outside the game dir'
  } finally {
    if (-not [string]::IsNullOrEmpty($mutPath) -and (Test-Path -LiteralPath $mutPath)) { Remove-Item -LiteralPath $mutPath -Force -ErrorAction SilentlyContinue }
    $hidden = Join-Path $hideDir (Split-Path -Leaf $j)
    if (Test-Path -LiteralPath $hidden) { Move-Item -LiteralPath $hidden -Destination $j -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $hideDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Invoke-Scenario 'i-consent-no' {
  $game = Join-Path $ScratchRoot 'i\game'; New-Game $game
  $jr = New-CaseJournalRoot 'i'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $inst = Invoke-Cmd 'install-i' (Install-Args $exe) $env
  Assert2 ($inst.exit -eq 0) ('install exit 0 (got ' + $inst.exit + ')')
  $before = ShaMap $game
  if ($script:removeConsentMode -eq 'yes') {
    $rm = Invoke-Cmd 'remove-i-consent-no' (Remove-Args $exe 'no') $env
    Assert2 ($rm.exit -eq 1) ('remove -Consent no exit 1 (got ' + $rm.exit + ')')
    Assert2 ($rm.status -eq 'refused' -and $rm.reason -eq 'consent-required') ('status=refused reason=consent-required (got ' + $rm.status + '/' + $rm.reason + ')')
    $post = ShaMap $game
    Assert2 (MapsEqual $before $post) 'zero writes on consent refusal (SHA map equal)'
  } else {
    Say ('OBSERVED: remove does not accept -Consent (consent mode=' + $script:removeConsentMode + '); the consent gate cannot be expressed through the current CLI surface.')
    Assert2 $false 'remove exposes a -Consent yes|no surface so the consent gate can be tested'
  }
}

Invoke-Scenario 'j-reinstalled-since-removal' {
  $game = Join-Path $ScratchRoot 'j\game'; New-Game $game
  $jr = New-CaseJournalRoot 'j'; $env = Case-Env $jr
  $exe = Join-Path $game 'GameA.exe'
  $i1 = Invoke-Cmd 'install-j' (Install-Args $exe) $env
  Assert2 ($i1.exit -eq 0) ('install exit 0 (got ' + $i1.exit + ')')
  $r1 = Invoke-Cmd 'remove-j-1' (Remove-Args $exe) $env
  Assert2 ($r1.exit -eq 0) ('first remove exit 0 (got ' + $r1.exit + ')')
  $asi = Join-Path $game 'OptiScaler.asi'
  [System.IO.File]::WriteAllBytes($asi, [System.Text.Encoding]::ASCII.GetBytes('REINSTALLED-ASI-J'))
  $reSha = Sha256 $asi
  Say ('recreated OptiScaler.asi sha=' + $reSha)
  $before = ShaMap $game
  $rm = Invoke-Cmd 'remove-j-2' (Remove-Args $exe) $env
  Assert2 ($rm.exit -eq 1) ('second remove refused exit 1 (got ' + $rm.exit + ')')
  Assert2 ($rm.status -eq 'refused' -and $rm.reason -eq 'reinstalled-since-removal') ('status=refused reason=reinstalled-since-removal (got ' + $rm.status + '/' + $rm.reason + ')')
  Assert2 ((Sha256 $asi) -eq $reSha) 'recreated OptiScaler.asi not deleted (sha unchanged)'
  $post = ShaMap $game
  Assert2 (MapsEqual $before $post) 'zero writes on reinstalled-since-removal (SHA map equal)'
}

# ----------------------------------------------------------------- cleanup --

Write-Host ''
Write-Host '=== cleanup ==='
if ($script:unreapedOwnedChild) { throw 'Owned child tree unconfirmed; scratch retained' }
foreach ($childPid in $global:qaChildren) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
$scratchRemoved = $false
try { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction Stop; $scratchRemoved = $true } catch { Write-Host ('cleanup: ' + $_.Exception.Message) }
$realRootAfter = Get-RootSnapshot $defaultJournalRoot

$gitAfter = ''
try { $gitAfter = [string](& git -C $PackageRoot status --short 2>$null | Out-String) } catch { $gitAfter = '' }
$gitStable = ($gitBefore -eq $gitAfter)

# ------------------------------------------------------------------ summary --

Write-Host ''
Write-Host '=== SUMMARY ==='
foreach ($row in $script:rows) { Write-Host ('{0,-28} {1,-18} pass={2} fail={3} pending={4}' -f $row.case, $row.status, $row.pass, $row.fail, $row.pending) }
Write-Host ('remove landed: ' + $script:removeLanded + ' (marker_gone=' + $script:markerLanded + ' smoke=' + $script:smokeStatus + '/' + $script:smokeReason + ')')
Write-Host ('remove consent mode: ' + $script:removeConsentMode)
Write-Host ('journal isolation mode: ' + $script:journalMode)
Write-Host ('status-line defects observed: ' + $script:statusLineDefects)
Write-Host ('invocations with no status line (crash/parse): ' + $script:noStatusLines)
Write-Host ('real journal root leaks: ' + $script:realRootLeaks)
Write-Host ('scratch removed: ' + $scratchRemoved)
Write-Host ('worktree git status stable across run: ' + $gitStable)

$failed = @($script:rows | Where-Object { $_.status -eq 'FAIL' })
$pending = @($script:rows | Where-Object { $_.status -eq 'PENDING-REAL-BODY' })

$summary = New-Object System.Collections.ArrayList
[void]$summary.Add('scenario,status,pass,fail,pending,observed')
foreach ($row in $script:rows) { [void]$summary.Add(('{0},{1},{2},{3},{4},"{5}"' -f $row.case, $row.status, $row.pass, $row.fail, $row.pending, ($row.observed -replace '"', "'"))) }
[void]$summary.Add('remove_landed,' + $script:removeLanded)
[void]$summary.Add('landing_marker,' + $script:markerLanded)
[void]$summary.Add('landing_smoke,' + $script:smokeStatus + '/' + $script:smokeReason)
[void]$summary.Add('remove_consent_mode,' + $script:removeConsentMode)
[void]$summary.Add('journal_isolation_mode,' + $script:journalMode)
[void]$summary.Add('status_line_defects,' + $script:statusLineDefects)
[void]$summary.Add('no_status_line_invocations,' + $script:noStatusLines)
[void]$summary.Add('real_journal_root_leaks,' + $script:realRootLeaks)
[void]$summary.Add('scratch_removed,' + $scratchRemoved)
[void]$summary.Add('git_status_stable,' + $gitStable)
Set-Content -LiteralPath (Join-Path $EvidenceDir 'qa-summary.csv') -Value ($summary -join "`r`n") -Encoding UTF8

# removal.md ---------------------------------------------------------------
$md = New-Object System.Collections.ArrayList
[void]$md.Add('# T9 removal QA - remove action')
[void]$md.Add('')
[void]$md.Add('Generated by `tests/installer_fixtures/removal/run_removal_qa.ps1` (worktree `' + $PackageRoot + '`).')
[void]$md.Add('')
[void]$md.Add('## Verdict')
[void]$md.Add('')
if (-not $script:removeLanded) {
  [void]$md.Add('**PENDING-REAL-BODY** - the coordinator `remove` body has not landed yet:')
  [void]$md.Add('')
  [void]$md.Add('- syntax marker `remove-pending-T9` still present in `tools/susemi_installer.ps1`: marker_gone=' + $script:markerLanded)
  [void]$md.Add('- behavioural smoke (`remove` on a folder with no install record): status=' + $script:smokeStatus + ' reason=' + $script:smokeReason)
  [void]$md.Add('')
  [void]$md.Add('Every scenario below ran fixture setup + the real install and then invoked the real `remove`; all removal assertions are reported as `PENDING-REAL-BODY`, never as pass/fail. Re-run after T9a lands.')
} elseif ($failed.Count -gt 0) {
  [void]$md.Add('**FAIL** - ' + $failed.Count + ' scenario(s) failed against the landed remove body.')
} else {
  [void]$md.Add('**PASS** - all ' + $script:rows.Count + ' scenarios green against the landed remove body.')
}
[void]$md.Add('')
[void]$md.Add('## Environment')
[void]$md.Add('')
[void]$md.Add('| item | value |')
[void]$md.Add('| --- | --- |')
[void]$md.Add('| installer | `' + $installer + '` |')
[void]$md.Add('| rc2 zip | `' + $Rc2Zip + '` (sha pin `' + $pinZip + '`) |')
[void]$md.Add('| game exe fixture | `' + $PingExe + '` copied as `GameA.exe` |')
[void]$md.Add('| remove landed | ' + $script:removeLanded + ' |')
[void]$md.Add('| remove consent surface | ' + $script:removeConsentMode + ' |')
[void]$md.Add('| journal isolation | ' + $script:journalMode + ' |')
[void]$md.Add('| status-line defects (T4 double-status) | ' + $script:statusLineDefects + ' |')
[void]$md.Add('| invocations with no status line (crash/parse) | ' + $script:noStatusLines + ' |')
[void]$md.Add('| real LOCALAPPDATA journal root leaks | ' + $script:realRootLeaks + ' |')
[void]$md.Add('')
[void]$md.Add('## Scenarios')
[void]$md.Add('')
[void]$md.Add('| scenario | status | pass | fail | pending | observed status lines |')
[void]$md.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($row in $script:rows) {
  [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $row.case, $row.status, $row.pass, $row.fail, $row.pending, ($row.observed -replace '\|', '/')))
}
[void]$md.Add('')
[void]$md.Add('Raw per-scenario logs: `raw/<scenario>.log`. Machine summary: `qa-summary.csv`.')
[void]$md.Add('')
[void]$md.Add('## Scenario intent')
[void]$md.Add('')
[void]$md.Add('| scenario | fixture -> expectation |')
[void]$md.Add('| --- | --- |')
[void]$md.Add('| a | install(consent yes, route asi) -> remove(consent yes): exit 0; OptiScaler.asi + winmm.dll absent; full-dir SHA map == pre-install; journal phase=recovered |')
[void]$md.Add('| b | install -ReshadeFirst -IniConsent yes (absent winmm.ini) -> remove: winmm.ini absent; byte-identity incl. absence (plain-install fallback + PENDING-INI if the flag path is unusable) |')
[void]$md.Add('| c | install -> remove -> install -> remove -> remove: last remove status=no-op reason=already-removed exit 0 |')
[void]$md.Add('| d | tamper OptiScaler.asi after install -> remove: refused target-changed exit 1, zero writes incl. tampered file |')
[void]$md.Add('| e | delete one backup preimage -> remove: refused backup-missing, zero writes |')
[void]$md.Add('| f | rc1-era malformed journal (replace op with backupPath removed, beforeSha kept, placed newest) -> remove: refused backup-missing/journal-unknown, zero writes |')
[void]$md.Add('| g | no journal (fresh dir + random files + GameA.exe) -> remove: missing-input no-install-record exit 1, zero writes |')
[void]$md.Add('| h | mutated journal with target ..\evil.dll -> remove: refused path-escape, zero writes, no evil.dll |')
[void]$md.Add('| i | remove -Consent no -> refused consent-required exit 1, zero writes |')
[void]$md.Add('| j | install -> remove -> recreate OptiScaler.asi -> remove: refused reinstalled-since-removal exit 1, recreated file not deleted |')
Set-Content -LiteralPath (Join-Path $EvidenceDir 'removal.md') -Value ($md -join "`r`n") -Encoding UTF8

Write-Host ''
if (-not $script:removeLanded) { Write-Host 'QA PENDING-REAL-BODY: remove body not landed'; exit 3 }
if ($failed.Count -gt 0 -or $script:realRootLeaks -gt 0 -or -not $scratchRemoved) { Write-Host ('QA FAIL: ' + $failed.Count + ' scenario(s) failed; global leaks=' + $script:realRootLeaks + '; scratch removed=' + $scratchRemoved); exit 1 }
Write-Host 'QA PASS: all scenarios green'
exit 0
