#Requires -Version 5.1
<#
.SYNOPSIS
  run_transaction_qa.ps1 - T7 QA harness for the owned install transaction.

  Scenarios a-h from the T7 brief. Uses ONLY %TEMP% scratch + a run-scoped
  journal root (child-only LOCALAPPDATA), writes raw logs to the evidence
  dir, and cleans up after itself (processes, scratch, journal root).
  Exit 0 only if every scenario assertion passes.

.NOTES
  Lock events are created before child launch. Readiness follows the real lock;
  release and native process completion use bounded waits without polling.
#>
param(
  [string]$EvidenceDir = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-generic-installer-diagnose/w2/task-7',
  [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
  [string]$ScratchRoot = ''
)

$ErrorActionPreference = 'Stop'

$installer   = Join-Path $PackageRoot 'tools\susemi_installer.ps1'
$transaction = Join-Path $PackageRoot 'tools\susemi_transaction.ps1'
$lockHolder  = Join-Path $PSScriptRoot 'lock_holder.ps1'
$psExe       = Join-Path $PSHOME 'powershell.exe'
$zipPath     = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
$pinCore     = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
$pinUal      = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$emptySha    = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$notepadExe  = 'C:\Windows\System32\notepad.exe'
$pingExe     = 'C:\Windows\System32\ping.exe'
$defaultJournalRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer\journal'

if ([string]::IsNullOrEmpty($ScratchRoot)) { $ScratchRoot = Join-Path $env:TEMP ('susemi-t7-qa-' + [guid]::NewGuid().ToString('N')) }
$rawDir = Join-Path $EvidenceDir 'raw'
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
$script:localAppData = Join-Path $ScratchRoot 'local'
$script:journalRoot = Join-Path $script:localAppData 'susemi-installer\journal'
New-Item -ItemType Directory -Path $script:journalRoot -Force | Out-Null
$script:coordEnv = @{ 'LOCALAPPDATA' = $script:localAppData; 'SUSEMI_TX_JOURNAL_ROOT' = ''; 'SUSEMI_RC2_ZIP' = $zipPath }

$script:unreapedOwnedChild = $false
$script:caseName = ''
$script:caseBuf = $null
$script:rows = New-Object System.Collections.ArrayList
$defaultBefore = @(Get-ChildItem -LiteralPath $defaultJournalRoot -File -ErrorAction SilentlyContinue).Count

# --------------------------------------------------------------- helpers ----

function Sha256([string]$p) {
  try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return '' }
}

function ShaMap([string]$root) {
  $h = @{}
  if (Test-Path -LiteralPath $root) {
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
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

function MapsEqualIgnoring($a, $b, [string]$excludeKey) {
  $fa = @{}; foreach ($k in $a.Keys) { if ($k -ne $excludeKey) { $fa[$k] = $a[$k] } }
  $fb = @{}; foreach ($k in $b.Keys) { if ($k -ne $excludeKey) { $fb[$k] = $b[$k] } }
  return (MapsEqual $fa $fb)
}

function MapText($m) {
  if ($m.Count -eq 0) { return '(empty)' }
  return (($m.Keys | Sort-Object | ForEach-Object { '  {0} = {1}' -f $_, $m[$_] }) -join "`n")
}

function Invoke-Child {
  param([string]$FileName, [string[]]$ArgList, [string]$WorkDir, $EnvVars, [int]$TimeoutSec = 180)
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
  if (-not [string]::IsNullOrEmpty($WorkDir)) { $psi.WorkingDirectory = $WorkDir }
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

function Start-Case([string]$name) {
  $script:caseName = $name
  $script:caseBuf = New-Object System.Collections.ArrayList
  Write-Host ("=== " + $name + " ===")
}

function Say([string]$s) {
  [void]$script:caseBuf.Add($s)
  Write-Host $s
}

function Assert([bool]$cond, [string]$msg) {
  if ($cond) { Say ('ASSERT-PASS: ' + $msg) } else { Say ('ASSERT-FAIL: ' + $msg) }
}

function End-Case {
  $fails = @($script:caseBuf | Where-Object { $_ -like 'ASSERT-FAIL:*' }).Count
  $passes = @($script:caseBuf | Where-Object { $_ -like 'ASSERT-PASS:*' }).Count
  $status = 'PASS'; if ($fails -gt 0) { $status = 'FAIL' }
  Say ('CASE-RESULT: ' + $status + ' pass=' + $passes + ' fail=' + $fails)
  [void]$script:rows.Add([pscustomobject]@{ case = $script:caseName; status = $status; pass = $passes; fail = $fails })
  Set-Content -LiteralPath (Join-Path $rawDir ($script:caseName + '.log')) -Value ($script:caseBuf -join "`r`n") -Encoding UTF8
}

function RunInstaller([string]$exePath, [string]$consent, [string]$route, [string]$proxy) {
  $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer, 'install', '-Exe', $exePath, '-Consent', $consent, '-Lang', 'en')
  if (-not [string]::IsNullOrEmpty($route)) { $a += @('-Route', $route) }
  if (-not [string]::IsNullOrEmpty($proxy)) { $a += @('-ProxyName', $proxy) }
  $r = Invoke-Child -FileName $psExe -ArgList $a -EnvVars $script:coordEnv
  Say ('$ powershell -File susemi_installer.ps1 install -Exe <exe> -Consent ' + $consent + ' -Route ' + $route + ' -ProxyName ' + $proxy)
  Say ('exit=' + $r.exit + ' timedOut=' + $r.timedOut)
  if ($r.stdout) { foreach ($ln in ($r.stdout.TrimEnd() -split "`r?`n")) { Say ('  out| ' + $ln) } }
  if ($r.stderr) { foreach ($ln in ($r.stderr.TrimEnd() -split "`r?`n")) { Say ('  err| ' + $ln) } }
  return $r
}

function RunTx([string[]]$txArgs) {
  $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $transaction) + $txArgs
  $r = Invoke-Child -FileName $psExe -ArgList $a
  Say ('$ powershell -File susemi_transaction.ps1 ' + ($txArgs -join ' '))
  Say ('exit=' + $r.exit + ' timedOut=' + $r.timedOut)
  if ($r.stdout) { foreach ($ln in ($r.stdout.TrimEnd() -split "`r?`n")) { Say ('  out| ' + $ln) } }
  if ($r.stderr) { foreach ($ln in ($r.stderr.TrimEnd() -split "`r?`n")) { Say ('  err| ' + $ln) } }
  return $r
}

function Get-JournalPath([string]$out) {
  if ($out -match 'journal=([^\r\n]+)') { return $Matches[1].Trim() }
  return ''
}

function Read-Journal([string]$p) {
  try { return ((Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json) } catch { return $null }
}

function New-Game([string]$dir, [string]$exeSrc) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $dir 'GameA.exe') -Force
}

function New-Stage([string]$dir) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $zipPath).Path)
  try {
    $e1 = @($zip.Entries | Where-Object { $_.FullName -eq 'OptiScaler.dll' })[0]
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e1, (Join-Path $dir 'OptiScaler.asi'), $true)
    $e2 = @($zip.Entries | Where-Object { $_.FullName -eq 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll' })[0]
    [IO.Compression.ZipFileExtensions]::ExtractToFile($e2, (Join-Path $dir 'winmm.dll'), $true)
  } finally { $zip.Dispose() }
}

function Start-Lock([string]$target, [string]$share) {
  $id = 'Local\susemi-lock-' + [guid]::NewGuid().ToString('N')
  $ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($id + '-ready'))
  $release = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, ($id + '-release'))
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $lockHolder + '" -Path "' + $target + '" -ReadyEvent "' + $id + '-ready" -ReleaseEvent "' + $id + '-release" -Share ' + $share
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $state = @{ Process = $p; Ready = $ready; Release = $release }
  $global:qaLocks += $state
  [void]$p.Start()
  # Retain the genuine process handle before waiting or attempting teardown.
  $null = $p.Handle
  $global:qaChildren += $p
  if (-not $ready.WaitOne(20000)) { throw 'Lock holder did not signal readiness' }
  return $state
}

function Release-Lock($state) {
  [void]$state.Release.Set()
  if (-not $state.Process.WaitForExit(30000)) { throw 'Lock holder did not exit after release' }
  if ($state.Process.ExitCode -ne 0) { throw ('Lock holder failed: ' + $state.Process.ExitCode) }
  return $true
}

$global:qaChildren = @()
$global:qaLocks = @()

function Invoke-Scenario([string]$name, [scriptblock]$body) {
  Start-Case $name
  try { & $body } catch { Say ('SCENARIO-ERROR: ' + $_.Exception.Message); Assert $false ('scenario threw: ' + $_.Exception.Message) }
  End-Case
}

# --------------------------------------------------------------- scenarios --

$defaultMapBefore = ShaMap $defaultJournalRoot
$defaultExistedBefore = Test-Path -LiteralPath $defaultJournalRoot
if ((Sha256 $zipPath) -ne '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a') { throw 'Pinned ZIP prerequisite is missing or mismatched' }

Invoke-Scenario 'a-happy-asi-ual' {
  $game = Join-Path $ScratchRoot 'a\game'
  New-Game $game $notepadExe
  $pre = ShaMap $game
  Say ("pre-install map:`n" + (MapText $pre))

  $r = RunInstaller (Join-Path $game 'GameA.exe') 'yes' 'asi' $null
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ', timedOut=' + $r.timedOut + ')')
  Assert ($r.stdout -match 'status=installed reason=ok') 'status=installed reason=ok'

  $asi = Join-Path $game 'OptiScaler.asi'
  $ual = Join-Path $game 'winmm.dll'
  Assert ((Sha256 $asi) -eq $pinCore) ('OptiScaler.asi == core pin (' + (Sha256 $asi) + ')')
  Assert ((Sha256 $ual) -eq $pinUal) ('winmm.dll == UAL pin (' + (Sha256 $ual) + ')')

  $j = Get-JournalPath $r.stdout
  Assert ([bool](Test-Path -LiteralPath $j)) ('journal exists: ' + $j)
  $jb = Read-Journal $j
  Assert ($jb.phase -eq 'applied') ('journal phase=applied (got ' + $jb.phase + ')')
  Assert ($jb.include_ual -eq $true) 'journal include_ual=true'
  Say ("installed map:`n" + (MapText (ShaMap $game)))

  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback exit 0 (got ' + $rb.exit + ')')
  $jb2 = Read-Journal $j
  Assert ($jb2.phase -eq 'recovered') ('journal phase=recovered (got ' + $jb2.phase + ')')

  $post = ShaMap $game
  Say ("post-rollback map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'game dir byte-identical to pre-install SHA map'
  Assert (-not (Test-Path -LiteralPath $asi)) 'OptiScaler.asi removed by rollback'
  Assert (-not (Test-Path -LiteralPath $ual)) 'winmm.dll removed by rollback'
}

Invoke-Scenario 'b-consent-no' {
  $game = Join-Path $ScratchRoot 'b\game'
  New-Game $game $notepadExe
  Set-Content -LiteralPath (Join-Path $game 'save.dat') -Value 'SAVE-DATA' -NoNewline
  $pre = ShaMap $game
  $jrBefore = @(Get-ChildItem -LiteralPath $script:journalRoot -Recurse -File -ErrorAction SilentlyContinue).Count

  $r = RunInstaller (Join-Path $game 'GameA.exe') 'no' $null $null
  Assert ($r.exit -eq 1) ('consent no exit 1 (got ' + $r.exit + ')')
  Assert ($r.stdout -match 'status=refused reason=consent-required') 'status=refused reason=consent-required'

  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'zero writes (SHA map equal)'
  $jrAfter = @(Get-ChildItem -LiteralPath $script:journalRoot -Recurse -File -ErrorAction SilentlyContinue).Count
  Assert ($jrAfter -eq $jrBefore) ('no journal written (before=' + $jrBefore + ' after=' + $jrAfter + ')')
}

Invoke-Scenario 'c-game-running' {
  $game = Join-Path $ScratchRoot 'c\game'
  New-Game $game $pingExe
  $exe = Join-Path $game 'GameA.exe'
  $pre = ShaMap $game
  Say 'fixture note: the System32 notepad.exe copy exits immediately on this host (Store stub),'
  Say 'so the "game running" fixture is a byte copy of System32\ping.exe held open by -n 120.'

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = '-n 120 127.0.0.1'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $null = $proc.Handle
  $global:qaChildren += $proc
  Assert (-not $proc.HasExited) ('fixture process running pid=' + $proc.Id)
  Say ('  path=' + $proc.MainModule.FileName)

  $r = RunInstaller $exe 'yes' $null $null
  Assert ($r.exit -eq 1) ('install refused exit 1 (got ' + $r.exit + ')')
  Assert ($r.stdout -match 'status=game-verification-required reason=game-running') 'status=game-verification-required reason=game-running'

  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'zero writes while game running'

  $proc.Kill()
  Assert ($proc.WaitForExit(15000)) ('fixture process stopped (pid=' + $proc.Id + ')')
}

Invoke-Scenario 'd-locked-target' {
  # d1: FileShare.Read -> reads/backup succeed, replace is blocked mid-apply.
  $game = Join-Path $ScratchRoot 'd\game'
  New-Game $game $notepadExe
  $ual = Join-Path $game 'winmm.dll'
  Set-Content -LiteralPath $ual -Value 'PRIOR-UAL-CONTENT' -NoNewline
  $preWin = Sha256 $ual
  $lock = Start-Lock $ual 'Read'
  Assert ($lock.Ready.WaitOne(0)) 'lock holder ready (FileShare.Read)'
  Say ('lock holder pid=' + $lock.Process.Id + ' mode=Read target=' + $ual)

  $r = RunInstaller (Join-Path $game 'GameA.exe') 'yes' 'asi' $null
  Assert ($r.exit -ne 0) ('install reported failure (got ' + $r.exit + ')')
  Assert ($r.stdout -match 'status=failed reason=') 'honest failure status=failed reason=...'
  Say ('failure status line: ' + (@($r.stdout -split "`r?`n" | Where-Object { $_ -like 'status=*' }) -join ' | '))

  $j = Get-JournalPath $r.stdout
  $jb = Read-Journal $j
  Assert ($jb.phase -eq 'recovered') ('journal phase recorded honestly after coordinator recover (got ' + $jb.phase + ')')
  Assert ((Sha256 $ual) -eq $preWin) 'locked winmm.dll untouched (sha unchanged)'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler.asi'))) 'created OptiScaler.asi recovered (absent)'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'winmm.dll.susemi-tmp'))) 'no stray .susemi-tmp left behind'
  Say ("game dir after failure/recover:`n" + (MapText (ShaMap $game)))

  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback after failure exit 0 (got ' + $rb.exit + ')')
  Assert ((Sha256 $ual) -eq $preWin) 'locked file still untouched after rollback'

  Assert (Release-Lock $lock) 'lock holder child released + exited'

  # d2: FileShare.None -> existing target bytes unreadable -> refuse at plan, zero writes.
  $game2 = Join-Path $ScratchRoot 'd\game2'
  New-Game $game2 $notepadExe
  $ual2 = Join-Path $game2 'winmm.dll'
  Set-Content -LiteralPath $ual2 -Value 'PRIOR-UAL-2' -NoNewline
  $pre2 = ShaMap $game2
  $lock2 = Start-Lock $ual2 'None'
  Assert ($lock2.Ready.WaitOne(0)) 'lock holder ready (FileShare.None)'
  $r2 = RunInstaller (Join-Path $game2 'GameA.exe') 'yes' $null $null
  Assert ($r2.exit -ne 0) ('install refused under FileShare.None (got ' + $r2.exit + ')')
  Assert ($r2.stdout -match 'status=refused reason=before-sha-read-failure') 'status=refused reason=before-sha-read-failure'
  Assert (Release-Lock $lock2) 'lock holder child 2 released + exited'
  # Re-hash now that the FileShare.None handle is gone: a still-locked file hashes to
  # '' (read denied), which is a harness artifact, not a write.
  $post2 = ShaMap $game2
  Say ("pre map:`n" + (MapText $pre2) + "`npost map (lock released):`n" + (MapText $post2))
  Assert (MapsEqual $pre2 $post2) 'zero writes when the baseline is unreadable'
}

Invoke-Scenario 'e-race-probe' {
  $stage = Join-Path $ScratchRoot 'e\stage'
  New-Stage $stage
  Assert ((Sha256 (Join-Path $stage 'OptiScaler.asi')) -eq $pinCore) 'e1 stage asi == core pin'
  Assert ((Sha256 (Join-Path $stage 'winmm.dll')) -eq $pinUal) 'e1 stage winmm == UAL pin'

  $game = Join-Path $ScratchRoot 'e\game'
  New-Game $game $notepadExe
  $pre = ShaMap $game
  $jr = Join-Path $ScratchRoot 'e\jr'
  $plan = RunTx @('plan', '-GameDir', $game, '-StagedDir', $stage, '-Route', 'asi', '-IncludeUal', '-StagedUalPath', (Join-Path $stage 'winmm.dll'), '-JournalRoot', $jr)
  Assert ($plan.exit -eq 0) ('e1 plan exit 0 (got ' + $plan.exit + ')')
  $j = Get-JournalPath $plan.stdout
  $probe = Join-Path $game 'winmm.dll'
  $apply = RunTx @('apply', '-Journal', $j, '-RaceProbe', $probe)
  Assert ($apply.exit -eq 1) ('e1 apply conflict exit 1 (got ' + $apply.exit + ')')
  Assert ($apply.stdout -match 'status=conflict reason=target-appeared') 'e1 status=conflict reason=target-appeared'
  $probeSha = Sha256 $probe
  Say ('probe file written with sha256=' + $probeSha)
  Assert ($probeSha -ne $pinUal) 'probe file is NOT the staged UAL (external writer)'

  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('e1 rollback exit 0 (got ' + $rb.exit + ')')
  Assert ((Sha256 $probe) -eq $probeSha) 'e1 probe file sha unchanged across rollback'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler.asi'))) 'e1 installer-created OptiScaler.asi removed by rollback'
  $post = ShaMap $game
  Say ("e1 pre map:`n" + (MapText $pre) + "`ne1 post-rollback map:`n" + (MapText $post))
  Assert (MapsEqualIgnoring $pre $post 'winmm.dll') 'e1 game dir byte-identical to pre-install apart from the external probe file'

  # e2: probe on the FIRST op -> nothing applied -> rollback leaves the probe untouched.
  $game2 = Join-Path $ScratchRoot 'e\game2'
  New-Game $game2 $notepadExe
  $pre2 = ShaMap $game2
  $plan2 = RunTx @('plan', '-GameDir', $game2, '-StagedDir', $stage, '-Route', 'asi', '-IncludeUal', '-StagedUalPath', (Join-Path $stage 'winmm.dll'), '-JournalRoot', $jr)
  $j2 = Get-JournalPath $plan2.stdout
  $probe2 = Join-Path $game2 'OptiScaler.asi'
  $apply2 = RunTx @('apply', '-Journal', $j2, '-RaceProbe', $probe2)
  Assert ($apply2.exit -eq 1) ('e2 apply conflict exit 1 (got ' + $apply2.exit + ')')
  Assert ($apply2.stdout -match 'status=conflict reason=target-appeared') 'e2 status=conflict reason=target-appeared'
  $probe2Sha = Sha256 $probe2
  $rb2 = RunTx @('rollback', '-Journal', $j2)
  Assert ($rb2.exit -eq 0) ('e2 rollback exit 0 (got ' + $rb2.exit + ')')
  Assert ((Sha256 $probe2) -eq $probe2Sha) 'e2 probe file sha unchanged'
  $post2 = ShaMap $game2
  Say ("e2 pre map:`n" + (MapText $pre2) + "`ne2 post-rollback map:`n" + (MapText $post2))
  Assert (MapsEqualIgnoring $pre2 $post2 'OptiScaler.asi') 'e2 game dir byte-identical to pre-install apart from the external probe file'
}

Invoke-Scenario 'f-zero-byte-target' {
  $game = Join-Path $ScratchRoot 'f\game'
  New-Game $game $notepadExe
  $ual = Join-Path $game 'winmm.dll'
  [IO.File]::WriteAllText($ual, '')
  Assert ((Get-Item -LiteralPath $ual).Length -eq 0) 'pre-existing winmm.dll is 0 bytes'
  Assert ((Sha256 $ual) -eq $emptySha) 'pre-existing winmm.dll sha == empty-file hash'

  $r = RunInstaller (Join-Path $game 'GameA.exe') 'yes' $null $null
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ')')
  Assert ((Sha256 $ual) -eq $pinUal) 'winmm.dll replaced with the pinned UAL'

  $j = Get-JournalPath $r.stdout
  $jb = Read-Journal $j
  $op = @($jb.ops | Where-Object { $_.target -like '*winmm.dll' })[0]
  Assert ($null -ne $op) 'journal has the winmm.dll op'
  Assert ($op.op -eq 'replace') ("winmm.dll op=replace (got " + $op.op + ")")
  Assert ($op.beforeExists -eq $true) 'winmm.dll beforeExists=true'
  Assert ($op.beforeSha -eq $emptySha) 'winmm.dll beforeSha == empty-file hash'

  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback exit 0 (got ' + $rb.exit + ')')
  Assert (Test-Path -LiteralPath $ual) 'winmm.dll still exists after rollback (not deleted)'
  Assert ((Get-Item -LiteralPath $ual).Length -eq 0) 'winmm.dll restored as 0 bytes'
  Assert ((Sha256 $ual) -eq $emptySha) 'restored winmm.dll sha == empty-file hash'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler.asi'))) 'OptiScaler.asi removed by rollback'
}

Invoke-Scenario 'g-path-escape' {
  $game = Join-Path $ScratchRoot 'g\game'
  New-Game $game $notepadExe
  $pre = ShaMap $game
  $traverse = Join-Path $game '..\game\GameA.exe'
  Say ('traversal exe arg: ' + $traverse)
  $r = RunInstaller $traverse 'yes' $null $null
  Assert (($r.exit -eq 1) -or ($r.exit -eq 2)) ('path-escape exit 1/2 (got ' + $r.exit + ')')
  Assert ($r.stdout -match 'status=refused reason=path-escape') 'status=refused reason=path-escape'
  $post = ShaMap $game
  Assert (MapsEqual $pre $post) 'zero writes on path-escape refusal'
}

Invoke-Scenario 'h-repeat-after-rollback' {
  $game = Join-Path $ScratchRoot 'h\game'
  New-Game $game $notepadExe
  $ual = Join-Path $game 'winmm.dll'
  Set-Content -LiteralPath $ual -Value 'ORIGINAL-BASELINE' -NoNewline
  $origSha = Sha256 $ual

  $r1 = RunInstaller (Join-Path $game 'GameA.exe') 'yes' $null $null
  Assert ($r1.exit -eq 0) ('install #1 exit 0 (got ' + $r1.exit + ')')
  $j1 = Get-JournalPath $r1.stdout
  $jb1 = Read-Journal $j1
  $tx1 = [string]$jb1.txid
  $op1 = @($jb1.ops | Where-Object { $_.target -like '*winmm.dll' })[0]
  Assert ($op1.beforeSha -eq $origSha) 'tx1 winmm beforeSha == original'

  $rb1 = RunTx @('rollback', '-Journal', $j1)
  Assert ($rb1.exit -eq 0) ('rollback #1 exit 0 (got ' + $rb1.exit + ')')
  Assert ((Sha256 $ual) -eq $origSha) 'baseline restored byte-exactly after rollback #1'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler.asi'))) 'OptiScaler.asi removed by rollback #1'

  $r2 = RunInstaller (Join-Path $game 'GameA.exe') 'yes' $null $null
  Assert ($r2.exit -eq 0) ('install #2 exit 0 (got ' + $r2.exit + ')')
  $j2 = Get-JournalPath $r2.stdout
  $jb2 = Read-Journal $j2
  $tx2 = [string]$jb2.txid
  Assert ($tx1 -ne $tx2) ('new txid for the repeat install (tx1=' + $tx1 + ' tx2=' + $tx2 + ')')
  $op2 = @($jb2.ops | Where-Object { $_.target -like '*winmm.dll' })[0]
  Assert ($op2.beforeExists -eq $true) 'tx2 winmm beforeExists=true'
  Assert ($op2.beforeSha -eq $origSha) 'tx2 earliest baseline == original (not overwritten)'

  $rb2 = RunTx @('rollback', '-Journal', $j2)
  Assert ($rb2.exit -eq 0) ('rollback #2 exit 0 (got ' + $rb2.exit + ')')
  Assert ((Sha256 $ual) -eq $origSha) 'baseline restored byte-exactly after rollback #2'
}

# ----------------------------------------------------------------- cleanup --

Write-Host '=== cleanup ==='
if ($script:unreapedOwnedChild) { throw 'Owned child tree unconfirmed; scratch retained' }
foreach ($state in $global:qaLocks) { [void]$state.Release.Set() }
foreach ($child in $global:qaChildren) {
  if (-not $child.HasExited) {
    if (-not $child.WaitForExit(30000)) { $child.Kill(); if (-not $child.WaitForExit(15000)) { throw 'Owned child unreaped; scratch retained' } }
  }
  $null = $child.ExitCode
  $child.Dispose()
}
foreach ($state in $global:qaLocks) { $state.Ready.Dispose(); $state.Release.Dispose() }
$defaultAfter = @(Get-ChildItem -LiteralPath $defaultJournalRoot -File -ErrorAction SilentlyContinue).Count
$defaultUnchanged = (MapsEqual $defaultMapBefore (ShaMap $defaultJournalRoot)) -and ($defaultExistedBefore -eq (Test-Path -LiteralPath $defaultJournalRoot))
$scratchRemoved = $false
try { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction Stop; $scratchRemoved = $true } catch { Write-Host ('cleanup: ' + $_.Exception.Message) }

# ----------------------------------------------------------------- summary --

$failed = @($script:rows | Where-Object { $_.status -ne 'PASS' })
Write-Host ''
Write-Host '=== SUMMARY ==='
foreach ($row in $script:rows) { Write-Host ('{0,-24} {1} pass={2} fail={3}' -f $row.case, $row.status, $row.pass, $row.fail) }
Write-Host ('scratch removed: ' + $scratchRemoved)
Write-Host ('default journal root untouched: before=' + $defaultBefore + ' after=' + $defaultAfter)

$summary = New-Object System.Collections.ArrayList
[void]$summary.Add('scenario,status,pass,fail')
foreach ($row in $script:rows) { [void]$summary.Add(('{0},{1},{2},{3}' -f $row.case, $row.status, $row.pass, $row.fail)) }
[void]$summary.Add('scratch_removed,' + $scratchRemoved)
[void]$summary.Add('default_journal_before,' + $defaultBefore)
[void]$summary.Add('default_journal_after,' + $defaultAfter)
[void]$summary.Add('default_journal_map_unchanged,' + $defaultUnchanged)
Set-Content -LiteralPath (Join-Path $EvidenceDir 'qa-summary.csv') -Value ($summary -join "`r`n") -Encoding UTF8

if ($failed.Count -gt 0 -or -not $defaultUnchanged -or -not $scratchRemoved) { Write-Host ('QA FAIL: ' + $failed.Count + ' scenario(s) failed; default map unchanged=' + $defaultUnchanged + '; scratch removed=' + $scratchRemoved); exit 1 }
Write-Host 'QA PASS: all scenarios green'
exit 0
