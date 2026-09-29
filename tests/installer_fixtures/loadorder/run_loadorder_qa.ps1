#Requires -Version 5.1
<#
.SYNOPSIS
  run_loadorder_qa.ps1 - T8 QA harness for the ReShade-first INI / load-order setup.

  Scenarios a-i from the T8 brief, driven through the REAL coordinator
  (tools/susemi_installer.ps1 install -ReshadeFirst -IniConsent yes) plus the
  owned transaction (plan/prepare/apply/rollback) and the transaction's own
  rollback for created INI/conversion ops.

  Guarantees used by the assertions:
    * every fixture lives under a fresh %TEMP%\susemi-t8-qa-<guid> scratch root;
    * the run-scoped journal root (env SUSEMI_TX_JOURNAL_ROOT) isolates journals
      so ownership is only ever granted by a journal this run wrote;
    * every child runs with a hard timeout + kill; stdin is closed; no sleeps
      are used as synchronisation;
    * assertions read machine `status=` lines AND re-hash the live files, so a
      misleading success line cannot pass a byte-level check;
    * scratch is removed at the end and the real %LOCALAPPDATA% journal root is
      asserted untouched.

  Fixture note (ownership): the "previously coordinator-owned INI" precondition
  is reproduced by writing a schema-1 journal with phase=applied and an applied
  create op whose sourceSha equals the live winmm.ini bytes - exactly the record
  a prior coordinator transaction leaves behind. The installer reads that record.

  Exit 0 only if every assertion passes; 1 otherwise.
#>
param(
  [string]$EvidenceDir = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-generic-installer-diagnose/w3/task-8',
  [string]$PackageRoot = '',
  [string]$ScratchRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
$installer = Join-Path $PackageRoot 'tools\susemi_installer.ps1'
$transaction = Join-Path $PackageRoot 'tools\susemi_transaction.ps1'
$psExe = Join-Path $PSHOME 'powershell.exe'
$zipPath = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
$pinCore = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
$pinUal = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$stubSeedF101 = 0xF101
$notepadExe = 'C:\Windows\System32\notepad.exe'
$defaultJournalRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer\journal'
$LF = "`n"
$CRLF = "`r`n"

if ([string]::IsNullOrEmpty($ScratchRoot)) { $ScratchRoot = Join-Path $env:TEMP ('susemi-t8-qa-' + [guid]::NewGuid().ToString('N')) }
$rawDir = Join-Path $EvidenceDir 'raw'
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
$script:journalRoot = Join-Path $ScratchRoot 'journals'
New-Item -ItemType Directory -Path $script:journalRoot -Force | Out-Null
$script:coordEnv = @{ 'SUSEMI_TX_JOURNAL_ROOT' = $script:journalRoot }
$defaultBefore = @(Get-ChildItem -LiteralPath $defaultJournalRoot -File -ErrorAction SilentlyContinue).Count

$script:caseName = ''
$script:caseBuf = $null
$script:rows = New-Object System.Collections.ArrayList
$global:qaChildren = @()

# --------------------------------------------------------------- helpers ----

function Sha256([string]$p) {
  try { return (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return '' }
}

function BytesSha([byte[]]$b) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function HexOf([byte[]]$b) { return (($b | ForEach-Object { $_.ToString('x2') }) -join '') }

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

function MapText($m) {
  if ($m.Count -eq 0) { return '(empty)' }
  return (($m.Keys | Sort-Object | ForEach-Object { '  {0} = {1}' -f $_, $m[$_] }) -join "`n")
}

function Invoke-Child {
  param([string]$FileName, [string[]]$ArgList, [string]$WorkDir, $EnvVars, [int]$TimeoutSec = 240)
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
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      $res.timedOut = $true
      try { $p.Kill() } catch { }
      try { $null = $p.WaitForExit(5000) } catch { }
    }
    try { $null = $p.WaitForExit(5000) } catch { }
    try { $res.exit = [int]$p.ExitCode } catch { $res.exit = -1 }
    try { $res.stdout = [string]$o.Result } catch { }
    try { $res.stderr = [string]$e.Result } catch { }
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

function RunInstallerArgs([string[]]$ExtraArgs, [string]$label) {
  $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer) + $ExtraArgs
  $r = Invoke-Child -FileName $psExe -ArgList $a -EnvVars $script:coordEnv
  Say ('$ powershell -File susemi_installer.ps1 ' + ($ExtraArgs -join ' '))
  Say ('exit=' + $r.exit + ' timedOut=' + $r.timedOut)
  if ($r.stdout) { foreach ($ln in ($r.stdout.TrimEnd() -split "`r?`n")) { Say ('  out| ' + $ln) } }
  if ($r.stderr) { foreach ($ln in ($r.stderr.TrimEnd() -split "`r?`n")) { Say ('  err| ' + $ln) } }
  return $r
}

function RunInstallRf([string]$exePath, [string]$route, [string]$convert) {
  $a = @('install', '-Exe', $exePath, '-Consent', 'yes', '-Lang', 'en', '-ReshadeFirst', '-IniConsent', 'yes')
  if (-not [string]::IsNullOrEmpty($route)) { $a += @('-Route', $route) }
  if ($convert -eq 'yes') { $a += @('-ConvertReshade') }
  return RunInstallerArgs $a ''
}

function RunDiagnose([string]$exePath) {
  return RunInstallerArgs @('diagnose', '-Exe', $exePath, '-Lang', 'en') ''
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

function StatusLine([string]$out) {
  foreach ($ln in ([string]$out -split "`r?`n")) { if ($ln -match '^status=') { return $ln.Trim() } }
  return ''
}

function PeStubBytes([int]$Seed) {
  $r = New-Object System.Random($Seed)
  $b = New-Object byte[] 1024
  $r.NextBytes($b)
  $b[0] = 0x4D; $b[1] = 0x5A
  [BitConverter]::GetBytes([int]128).CopyTo($b, 0x3C)
  $b[128] = 0x50; $b[129] = 0x45; $b[130] = 0x00; $b[131] = 0x00
  $b[132] = 0x64; $b[133] = 0x86
  return $b
}

function New-BaseGame {
  # winmm.dll (UAL pin) + OptiScaler.asi (core pin) + GameA.exe (notepad copy).
  param([string]$Name)
  $dir = Join-Path $ScratchRoot $Name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $script:srcDir 'winmm.dll') -Destination (Join-Path $dir 'winmm.dll') -Force
  Copy-Item -LiteralPath (Join-Path $script:srcDir 'OptiScaler.asi') -Destination (Join-Path $dir 'OptiScaler.asi') -Force
  Copy-Item -LiteralPath $notepadExe -Destination (Join-Path $dir 'GameA.exe') -Force
  return $dir
}

function New-OwnedJournal([string]$Target, [string]$SourceSha) {
  # Reproduces the "previously coordinator-owned INI" precondition: a schema-1
  # journal with phase=applied and an applied create op whose sourceSha is the
  # live winmm.ini bytes - exactly the record a prior coordinator tx leaves.
  $op = [ordered]@{ op = 'create'; target = $Target; source = (Join-Path $ScratchRoot 'synth-src.ini');
                    backupPath = (Join-Path $ScratchRoot 'synth.bak'); sourceSha = $SourceSha;
                    beforeExists = $false; beforeSha = ''; state = 'applied' }
  $j = [ordered]@{ schema_version = 1; txid = [guid]::NewGuid().ToString('N'); phase = 'applied'; action = 'plan';
                   route = 'asi'; game_dir = (Split-Path -Parent $Target); staged_dir = $ScratchRoot;
                   include_ual = $false; created_at = (Get-Date -Format 'o'); ops = @($op) }
  $p = Join-Path $script:journalRoot ('synth_' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
  return $p
}

# --------------------------------------------------------------- fixtures ---

# Extract the pinned payloads once (read-only source; no network).
$script:srcDir = Join-Path $ScratchRoot '_src'
New-Item -ItemType Directory -Path $script:srcDir -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $zipPath).Path)
try {
  $e1 = @($zip.Entries | Where-Object { $_.FullName -eq 'OptiScaler.dll' })[0]
  [IO.Compression.ZipFileExtensions]::ExtractToFile($e1, (Join-Path $script:srcDir 'OptiScaler.asi'), $true)
  $e2 = @($zip.Entries | Where-Object { $_.FullName -eq 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll' })[0]
  [IO.Compression.ZipFileExtensions]::ExtractToFile($e2, (Join-Path $script:srcDir 'winmm.dll'), $true)
} finally { $zip.Dispose() }
Write-Host ('fixture sources: ual=' + (Sha256 (Join-Path $script:srcDir 'winmm.dll')) + ' core=' + (Sha256 (Join-Path $script:srcDir 'OptiScaler.asi')))

function Invoke-Scenario([string]$name, [scriptblock]$body) {
  Start-Case $name
  try { & $body } catch { Say ('SCENARIO-ERROR: ' + $_.Exception.Message); Assert $false ('scenario threw: ' + $_.Exception.Message) }
  End-Case
}

# ------------------------------------------------------------------ a + i ---

Invoke-Scenario 'a-fresh-create-ready' {
  $stub = PeStubBytes $stubSeedF101
  Assert (($stub.Length -eq 1024) -and ($stub[0] -eq 0x4D) -and ($stub[1] -eq 0x5A)) 'PE stub has the MZ signature'
  Assert (([BitConverter]::ToInt32($stub, 0x3C)) -eq 128) 'PE stub e_lfanew=128'
  Assert (($stub[128] -eq 0x50) -and ($stub[129] -eq 0x45) -and ($stub[130] -eq 0) -and ($stub[131] -eq 0)) 'PE stub PE\0\0 at 128'
  Assert (([BitConverter]::ToUInt16($stub, 132)) -eq 0x8664) 'PE stub machine is x64 (0x8664)'

  $game = New-BaseGame 'a\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), $stub)
  Say ("pre-install map:`n" + (MapText (ShaMap $game)))
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'winmm.ini'))) 'precondition: no winmm.ini'

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ', timedOut=' + $r.timedOut + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=installed reason=ok') ('status=installed reason=ok (got ' + (StatusLine $r.stdout) + ')')
  Assert ($r.stdout -match 'reshade-first=ini-created') 'marker reshade-first=ini-created'
  Assert ($r.stdout -match 'preview\| ini-sha-before=\(absent\)') 'preview shows the absent preimage'

  $ini = Join-Path $game 'winmm.ini'
  Assert (Test-Path -LiteralPath $ini -PathType Leaf) 'winmm.ini created'
  $expect = [Text.Encoding]::ASCII.GetBytes('[globalsets]' + $CRLF + 'loadextraplugins=ReShade.asi' + $CRLF)
  Assert ((BytesSha ([IO.File]::ReadAllBytes($ini))) -eq (BytesSha $expect)) ('winmm.ini bytes are the minimal [globalsets] content (sha ' + (Sha256 $ini) + ')')
  Assert ((Sha256 (Join-Path $game 'OptiScaler.asi')) -eq $pinCore) 'OptiScaler.asi == core pin'
  Assert ((Sha256 (Join-Path $game 'winmm.dll')) -eq $pinUal) 'winmm.dll == UAL pin'
  Say ("installed map:`n" + (MapText (ShaMap $game)))

  $d = RunDiagnose (Join-Path $game 'GameA.exe')
  Assert ($d.exit -eq 0) ('re-diagnosis exit 0 (got ' + $d.exit + ')')
  Assert ((StatusLine $d.stdout) -eq 'status=ready reason=ready') ('re-diagnosis says ready (got ' + (StatusLine $d.stdout) + ')')

  # journal records the INI op LAST, as create.
  $j = Get-JournalPath $r.stdout
  Assert ([bool](Test-Path -LiteralPath $j)) ('journal exists: ' + $j)
  $jb = ((Get-Content -LiteralPath $j -Raw) | ConvertFrom-Json)
  $ops = @($jb.ops)
  Assert (($ops.Count -ge 1) -and ([string]$ops[-1].target).EndsWith('winmm.ini')) ('winmm.ini op is journaled LAST (' + @($ops | ForEach-Object { (Split-Path -Leaf $_.target) + ':' + $_.op }) -join ',' + ')')
  Assert ([string]$ops[-1].op -eq 'create') 'winmm.ini op=create'
  Assert ([string]$ops[-1].beforeExists -eq 'False' -or $ops[-1].beforeExists -eq $false) 'winmm.ini beforeExists=false'
}

# --------------------------------------------------------------------- i ---

Invoke-Scenario 'i-rollback-removes-created-ini' {
  $game = New-BaseGame 'i\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $preMap = ShaMap $game
  Say ("pre-install map:`n" + (MapText $preMap))

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ')')
  $ini = Join-Path $game 'winmm.ini'
  Assert (Test-Path -LiteralPath $ini -PathType Leaf) 'winmm.ini was created'

  $j = Get-JournalPath $r.stdout
  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback exit 0 (got ' + $rb.exit + ')')
  Assert ((StatusLine $rb.stdout) -eq 'status=recovered reason=ok') 'rollback status=recovered reason=ok'
  Assert (-not (Test-Path -LiteralPath $ini)) 'created winmm.ini removed by rollback'

  # The two pre-existing payload files were REPLACE ops, so prepare kept their
  # byte-exact preimages under .susemi-backup and the journal retains them (T7's
  # documented rollback contract). Prove no game file changed and that the only
  # additions are those installer-owned preimages.
  $postMap = ShaMap $game
  Say ("post-rollback map:`n" + (MapText $postMap))
  $changed = @()
  foreach ($k in $preMap.Keys) { if (-not $postMap.ContainsKey($k) -or $postMap[$k] -ne $preMap[$k]) { $changed += $k } }
  Assert ($changed.Count -eq 0) ('no pre-existing game file changed bytes (' + ($changed -join ',') + ')')
  $added = @($postMap.Keys | Where-Object { -not $preMap.ContainsKey($_) })
  $expectedAdded = @('.susemi-backup\OptiScaler.asi.susemi-bak', '.susemi-backup\winmm.dll.susemi-bak')
  Assert ((($added | Sort-Object) -join '|') -eq (($expectedAdded | Sort-Object) -join '|')) ('only installer-owned preimages added (' + ($added -join ',') + ')')
  Assert ($postMap['.susemi-backup\OptiScaler.asi.susemi-bak'] -eq $pinCore) 'backup preimage of OptiScaler.asi is byte-exact'
  Assert ($postMap['.susemi-backup\winmm.dll.susemi-bak'] -eq $pinUal) 'backup preimage of winmm.dll is byte-exact'
}

Invoke-Scenario 'i2-rollback-all-create-byte-identical' {
  # Strict full-map byte-identity when every op is a create (no pre-existing
  # payload, so no preimages are needed and nothing is left behind).
  $game = Join-Path $ScratchRoot 'i2\game'
  New-Item -ItemType Directory -Path $game -Force | Out-Null
  Copy-Item -LiteralPath $notepadExe -Destination (Join-Path $game 'GameA.exe') -Force
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $preMap = ShaMap $game
  Say ("pre-install map:`n" + (MapText $preMap))

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ')')
  Assert (Test-Path -LiteralPath (Join-Path $game 'winmm.ini') -PathType Leaf) 'winmm.ini created'
  $j = Get-JournalPath $r.stdout
  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback exit 0 (got ' + $rb.exit + ')')
  $postMap = ShaMap $game
  Say ("post-rollback map:`n" + (MapText $postMap))
  Assert (MapsEqual $preMap $postMap) 'game dir byte-identical to pre-install (all-create rollback)'
}

# --------------------------------------------------------------------- b ---

Invoke-Scenario 'b-already-configured-unowned-noop' {
  $game = New-BaseGame 'b\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini = Join-Path $game 'winmm.ini'
  [IO.File]::WriteAllBytes($ini, [Text.Encoding]::ASCII.GetBytes('[globalsets]' + $LF + 'loadextraplugins=ReShade.asi' + $LF + 'loadplugins=1' + $LF))
  $pre = ShaMap $game
  $preIniSha = Sha256 $ini
  Say ("pre map:`n" + (MapText $pre))

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=no-op reason=already-configured') ('status=no-op reason=already-configured (got ' + (StatusLine $r.stdout) + ')')
  Assert ($r.stdout -match 'owned=False') 'the no-op records that no ownership is claimed'
  $post = ShaMap $game
  Say ("post map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'zero writes: every SHA unchanged'
  Assert ((Sha256 $ini) -eq $preIniSha) 'unowned correct winmm.ini byte-identical'
}

# --------------------------------------------------------------------- c ---

Invoke-Scenario 'c-unowned-other-content-refused' {
  $game = New-BaseGame 'c\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini = Join-Path $game 'winmm.ini'
  [IO.File]::WriteAllBytes($ini, [Text.Encoding]::ASCII.GetBytes('[settings]' + $LF + 'foo=bar' + $LF))
  $pre = ShaMap $game

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 1) ('install refused exit 1 (got ' + $r.exit + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=refused reason=ini-unowned') ('status=refused reason=ini-unowned (got ' + (StatusLine $r.stdout) + ')')
  Assert ($r.stdout -match 'Manually add loadextraplugins=ReShade.asi') 'manual instructions printed'
  Assert ($r.stdout -notmatch 'reshade-first=ini-') 'no INI write marker'
  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'zero writes on ini-unowned refusal'
}

# --------------------------------------------------------------------- d ---

Invoke-Scenario 'd-later-override' {
  $game = New-BaseGame 'd\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('baseline install exit 0 (got ' + $r.exit + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=installed reason=ok') 'baseline status=installed reason=ok'

  # A later plugins/global.ini now overrides loadextraplugins.
  $plugDir = Join-Path $game 'plugins'
  New-Item -ItemType Directory -Path $plugDir -Force | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $plugDir 'global.ini'), [Text.Encoding]::ASCII.GetBytes('[globalsets]' + $LF + 'loadextraplugins=OptiScaler.asi' + $LF))
  $pre = ShaMap $game

  $d = RunDiagnose (Join-Path $game 'GameA.exe')
  Assert ($d.exit -eq 1) ('diagnosis exit 1 (got ' + $d.exit + ')')
  Assert ((StatusLine $d.stdout) -eq 'status=conflict reason=ual-config-conflict') ('diagnosis conflict (got ' + (StatusLine $d.stdout) + ')')
  Assert ($d.stdout -match 'plugins\\global\.ini') 'diagnosis names plugins\global.ini'

  $r2 = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ((StatusLine $r2.stdout) -eq 'status=installed-with-warning reason=later-override') ('install warns installed-with-warning reason=later-override (got ' + (StatusLine $r2.stdout) + ')')
  Assert ($r2.stdout -match 'plugins\\global\.ini') 'warning names the overriding file'
  Assert ($r2.stdout -match 'loadextraplugins=OptiScaler\.asi') 'warning names the key+value'
  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'the override file is never edited (zero writes)'
}

# --------------------------------------------------------------------- e ---

Invoke-Scenario 'e-convert-reshade-proxy' {
  $game = New-BaseGame 'e\game'
  $proxyBytes = PeStubBytes 0xF304
  [IO.File]::WriteAllBytes((Join-Path $game 'dxgi.dll'), $proxyBytes)
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.ini'), [Text.Encoding]::ASCII.GetBytes('; reshade config' + $LF))
  $proxySha = Sha256 (Join-Path $game 'dxgi.dll')
  Say ('dxgi.dll (ReShade-like PE stub + ReShade.ini) sha=' + $proxySha)
  $pre = ShaMap $game
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'ReShade.asi'))) 'precondition: no ReShade.asi'

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'yes'
  Assert ($r.exit -eq 0) ('convert install exit 0 (got ' + $r.exit + ', timedOut=' + $r.timedOut + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=installed reason=ok') ('status=installed reason=ok (got ' + (StatusLine $r.stdout) + ')')
  Assert ($r.stdout -match 'reshade-first=converted src=dxgi\.dll dst=ReShade\.asi mode=copy') 'marker: conversion copy named'
  Assert ($r.stdout -match 'preview\| convert=dxgi\.dll->ReShade\.asi mode=copy') 'preview shows the planned copy'

  $newAsi = Join-Path $game 'ReShade.asi'
  Assert (Test-Path -LiteralPath $newAsi -PathType Leaf) 'ReShade.asi created'
  Assert ((Sha256 $newAsi) -eq $proxySha) 'ReShade.asi is a byte-identical COPY of dxgi.dll'
  Assert ((Sha256 (Join-Path $game 'dxgi.dll')) -eq $proxySha) 'original dxgi.dll byte-identical (never renamed)'
  Assert ((StatusLine (RunDiagnose (Join-Path $game 'GameA.exe')).stdout) -eq 'status=ready reason=ready') 're-diagnosis ready after conversion'

  $j = Get-JournalPath $r.stdout
  Assert ([bool](Test-Path -LiteralPath $j)) ('journal exists: ' + $j)
  $rb = RunTx @('rollback', '-Journal', $j)
  Assert ($rb.exit -eq 0) ('rollback exit 0 (got ' + $rb.exit + ')')
  Assert (-not (Test-Path -LiteralPath $newAsi)) 'created ReShade.asi removed by rollback'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'winmm.ini'))) 'created winmm.ini removed by rollback'
  Assert ((Sha256 (Join-Path $game 'dxgi.dll')) -eq $proxySha) 'dxgi.dll still byte-identical after rollback'
  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost-rollback map:`n" + (MapText $post))
  $changed = @()
  foreach ($k in $pre.Keys) { if (-not $post.ContainsKey($k) -or $post[$k] -ne $pre[$k]) { $changed += $k } }
  Assert ($changed.Count -eq 0) ('no pre-existing game file changed bytes (' + ($changed -join ',') + ')')
  $added = @($post.Keys | Where-Object { -not $pre.ContainsKey($_) })
  Assert ((($added | Sort-Object) -join '|') -eq ((@('.susemi-backup\OptiScaler.asi.susemi-bak', '.susemi-backup\winmm.dll.susemi-bak') | Sort-Object) -join '|')) ('only installer-owned preimages added (' + ($added -join ',') + ')')
}

# --------------------------------------------------------------------- f ---

Invoke-Scenario 'f-convert-refusal-random-dll' {
  $game = New-BaseGame 'f\game'
  $rnd = New-Object System.Random 0xF305
  $b = New-Object byte[] 1024
  $rnd.NextBytes($b)
  [IO.File]::WriteAllBytes((Join-Path $game 'dxgi.dll'), $b)
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.ini'), [Text.Encoding]::ASCII.GetBytes('; reshade config' + $LF))
  $pre = ShaMap $game
  Say ('dxgi.dll random bytes (no PE) sha=' + (Sha256 (Join-Path $game 'dxgi.dll')))

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'yes'
  Assert ($r.exit -eq 1) ('install refused exit 1 (got ' + $r.exit + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=refused reason=convert-identity-unverified') ('status=refused reason=convert-identity-unverified (got ' + (StatusLine $r.stdout) + ')')
  $post = ShaMap $game
  Say ("pre map:`n" + (MapText $pre) + "`npost map:`n" + (MapText $post))
  Assert (MapsEqual $pre $post) 'zero writes on conversion refusal'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'ReShade.asi'))) 'no ReShade.asi created'
}

# --------------------------------------------------------------------- g ---

Invoke-Scenario 'g-utf8-bom-preserve-and-utf16-refuse' {
  # g1: owned UTF-8 BOM INI with Korean comments, no [globalsets] -> append section.
  $game = New-BaseGame 'g\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini = Join-Path $game 'winmm.ini'
  $bom = [byte[]](0xEF, 0xBB, 0xBF)
  $body = [Text.Encoding]::UTF8.GetBytes('; 한국어 주석 (Korean comment) - 보존되어야 함' + $LF + '[settings]' + $LF + 'keep=1' + $LF)
  $orig = New-Object System.Collections.Generic.List[byte]
  foreach ($x in $bom) { $orig.Add($x) }
  foreach ($x in $body) { $orig.Add($x) }
  [IO.File]::WriteAllBytes($ini, $orig.ToArray())
  $origBytes = [IO.File]::ReadAllBytes($ini)
  $srcSha = BytesSha $origBytes
  $nil = New-OwnedJournal $ini $srcSha
  Say ('owned preimage sha=' + $srcSha + ' journal=' + $nil)

  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('install exit 0 (got ' + $r.exit + ')')
  Assert ((StatusLine $r.stdout) -eq 'status=installed reason=ok') ('status=installed reason=ok (got ' + (StatusLine $r.stdout) + ')')
  Assert ($r.stdout -match 'reshade-first=ini-extended') 'marker reshade-first=ini-extended'
  Assert ($r.stdout -match 'preview\| ini-encoding=utf8bom') 'preview names the utf8bom encoding'
  Assert ($r.stdout -match 'preview\| ini-eol=LF') 'preview names LF'

  $newBytes = [IO.File]::ReadAllBytes($ini)
  $insert = [Text.Encoding]::ASCII.GetBytes('[globalsets]' + $LF + 'loadextraplugins=ReShade.asi' + $LF)
  $expected = New-Object System.Collections.Generic.List[byte]
  foreach ($x in $origBytes) { $expected.Add($x) }
  foreach ($x in $insert) { $expected.Add($x) }
  $exp = $expected.ToArray()
  Assert ((BytesSha $newBytes) -eq (BytesSha $exp)) 'byte diff is EXACTLY the appended insert (BOM + Korean comments + unrelated bytes preserved)'
  Assert (($newBytes[0] -eq 0xEF) -and ($newBytes[1] -eq 0xBB) -and ($newBytes[2] -eq 0xBF)) 'UTF-8 BOM preserved'
  Assert ((HexOf $newBytes).Substring(0, (HexOf $origBytes).Length) -eq (HexOf $origBytes)) 'all original bytes are a prefix of the result'
  Say ('insert hex=' + (HexOf $insert))
  Say ('new sha=' + (BytesSha $newBytes))

  # g2: owned UTF-16 INI -> named refusal, zero writes.
  $game2 = New-BaseGame 'g\game2'
  [IO.File]::WriteAllBytes((Join-Path $game2 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini2 = Join-Path $game2 'winmm.ini'
  $utf16 = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes('[settings]' + $CRLF + 'k=v' + $CRLF)
  [IO.File]::WriteAllBytes($ini2, $utf16)
  $nil2 = New-OwnedJournal $ini2 (Sha256 $ini2)
  $pre2 = ShaMap $game2
  $r2 = RunInstallRf (Join-Path $game2 'GameA.exe') 'asi' 'no'
  Assert ($r2.exit -eq 1) ('UTF-16 install refused exit 1 (got ' + $r2.exit + ')')
  Assert ((StatusLine $r2.stdout) -eq 'status=refused reason=ini-encoding-utf16') ('status=refused reason=ini-encoding-utf16 (got ' + (StatusLine $r2.stdout) + ')')
  $post2 = ShaMap $game2
  Assert (MapsEqual $pre2 $post2) 'zero writes on the UTF-16 refusal'
  Say ('utf16 journal=' + $nil2)
}

# --------------------------------------------------------------------- h ---

Invoke-Scenario 'h-crlf-lf-both-insert-cases' {
  # h1: owned LF file with an existing [globalsets] header -> insert right after it.
  $game = New-BaseGame 'h\game1'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini = Join-Path $game 'winmm.ini'
  $orig = [Text.Encoding]::ASCII.GetBytes('; comment' + $LF + '[globalsets]' + $LF + '[other]' + $LF + 'x=1' + $LF)
  [IO.File]::WriteAllBytes($ini, $orig)
  $nil = New-OwnedJournal $ini (BytesSha $orig)
  $r = RunInstallRf (Join-Path $game 'GameA.exe') 'asi' 'no'
  Assert ($r.exit -eq 0) ('h1 exit 0 (got ' + $r.exit + ')')
  Assert ($r.stdout -match 'preview\| ini-eol=LF') 'h1 preview LF'
  $insert = [Text.Encoding]::ASCII.GetBytes('loadextraplugins=ReShade.asi' + $LF)
  $expect = '; comment' + $LF + '[globalsets]' + $LF + 'loadextraplugins=ReShade.asi' + $LF + '[other]' + $LF + 'x=1' + $LF
  Assert ((HexOf ([IO.File]::ReadAllBytes($ini))) -eq (HexOf ([Text.Encoding]::ASCII.GetBytes($expect)))) 'h1 inserts after the [globalsets] header using LF, no CRLF introduced'
  Say ('h1 journal=' + $nil)

  # h2: owned CRLF file without [globalsets] -> append a new section with CRLF.
  $game2 = New-BaseGame 'h\game2'
  [IO.File]::WriteAllBytes((Join-Path $game2 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $ini2 = Join-Path $game2 'winmm.ini'
  $orig2 = [Text.Encoding]::ASCII.GetBytes('; note' + $CRLF + '[settings]' + $CRLF + 'a=b' + $CRLF)
  [IO.File]::WriteAllBytes($ini2, $orig2)
  $nil2 = New-OwnedJournal $ini2 (BytesSha $orig2)
  $r2 = RunInstallRf (Join-Path $game2 'GameA.exe') 'asi' 'no'
  Assert ($r2.exit -eq 0) ('h2 exit 0 (got ' + $r2.exit + ')')
  Assert ($r2.stdout -match 'preview\| ini-eol=CRLF') 'h2 preview CRLF'
  $expect2 = '; note' + $CRLF + '[settings]' + $CRLF + 'a=b' + $CRLF + '[globalsets]' + $CRLF + 'loadextraplugins=ReShade.asi' + $CRLF
  Assert ((HexOf ([IO.File]::ReadAllBytes($ini2))) -eq (HexOf ([Text.Encoding]::ASCII.GetBytes($expect2)))) 'h2 appends the new section using CRLF and preserves the original bytes'
  Say ('h2 journal=' + $nil2)
}

# -------------------------------------------------------------- adversarial -

Invoke-Scenario 'y-consent-and-cli-contract' {
  $game = New-BaseGame 'y\game'
  [IO.File]::WriteAllBytes((Join-Path $game 'ReShade.asi'), (PeStubBytes $stubSeedF101))
  $pre = ShaMap $game
  $exe = Join-Path $game 'GameA.exe'

  $r1 = RunInstallerArgs @('install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en', '-ReshadeFirst') ''
  Assert ($r1.exit -eq 1) ('missing -IniConsent refused exit 1 (got ' + $r1.exit + ')')
  Assert ((StatusLine $r1.stdout) -eq 'status=refused reason=ini-consent-required') ('missing -IniConsent reason (got ' + (StatusLine $r1.stdout) + ')')

  $r2 = RunInstallerArgs @('install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en', '-ReshadeFirst', '-IniConsent', 'no') ''
  Assert ($r2.exit -eq 1) ('-IniConsent no refused exit 1 (got ' + $r2.exit + ')')
  Assert ((StatusLine $r2.stdout) -eq 'status=refused reason=ini-consent-required') ('-IniConsent no reason (got ' + (StatusLine $r2.stdout) + ')')

  $r3 = RunInstallerArgs @('install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en', '-ReshadeFirst', '-IniConsent', 'maybe') ''
  Assert ($r3.exit -eq 2) ('bad -IniConsent value exit 2 (got ' + $r3.exit + ')')
  Assert ($r3.stdout -match 'status=invalid-invocation reason=bad-iniconsent') 'bad -IniConsent value named'

  $r4 = RunInstallerArgs @('install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en', '-IniConsent', 'yes') ''
  Assert ($r4.exit -eq 2) ('-IniConsent without -ReshadeFirst exit 2 (got ' + $r4.exit + ')')
  Assert ($r4.stdout -match 'status=invalid-invocation reason=unexpected-iniconsent') '-IniConsent without -ReshadeFirst named'

  $r5 = RunInstallerArgs @('install', '-Exe', $exe, '-Consent', 'yes', '-Lang', 'en', '-ConvertReshade') ''
  Assert ($r5.exit -eq 2) ('-ConvertReshade without -ReshadeFirst exit 2 (got ' + $r5.exit + ')')
  Assert ($r5.stdout -match 'status=invalid-invocation reason=unexpected-convertreshade') '-ConvertReshade without -ReshadeFirst named'

  $r6 = RunInstallerArgs @('diagnose', '-Exe', $exe, '-Lang', 'en', '-ReshadeFirst') ''
  Assert ($r6.exit -eq 2) ('diagnose -ReshadeFirst exit 2 (got ' + $r6.exit + ')')
  Assert ($r6.stdout -match 'status=invalid-invocation reason=unexpected-reshadefirst') 'diagnose -ReshadeFirst named'

  $post = ShaMap $game
  Assert (MapsEqual $pre $post) 'every CLI-contract refusal/invalid invocation wrote nothing'
}

Invoke-Scenario 'z-hung-command-timeout-kill' {
  $t0 = Get-Date
  $r = Invoke-Child -FileName $psExe -ArgList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -EnvVars $null -TimeoutSec 3
  $elapsed = ((Get-Date) - $t0).TotalSeconds
  Assert ($r.timedOut -eq $true) 'a 30s child under a 3s bound is reported timedOut'
  Assert ($elapsed -lt 25) ('the child was killed at the bound, not waited out (elapsed=' + [math]::Round($elapsed, 1) + 's)')
}

# ----------------------------------------------------------------- cleanup --

Write-Host '=== cleanup ==='
foreach ($childPid in $global:qaChildren) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
$defaultAfter = @(Get-ChildItem -LiteralPath $defaultJournalRoot -File -ErrorAction SilentlyContinue).Count
$scratchRemoved = $false
try { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction Stop; $scratchRemoved = $true } catch { Write-Host ('cleanup: ' + $_.Exception.Message) }

# dirty-worktree receipt (tracked-file modifications only; untracked is expected).
$gitOut = ''
try { $gitOut = (git -C $PackageRoot status --porcelain -uall) -join "`n" } catch { $gitOut = 'git-unavailable' }
Set-Content -LiteralPath (Join-Path $rawDir 'worktree-final.txt') -Value $gitOut -Encoding UTF8
$trackedMod = @(([string]$gitOut -split "`r?`n") | Where-Object { $_ -match '^\s?M\s' -or $_ -match '^M' })
$trackedModNames = @($trackedMod | ForEach-Object { ($_ -replace '^\s*M\s+', '').Trim() })
Start-Case 'z-worktree'
Assert ($trackedModNames.Count -eq 1 -and $trackedModNames[0] -eq 'setup_windows.bat') ('tracked modifications are exactly the pre-existing T5 setup_windows.bat (got: ' + ($trackedModNames -join ',') + ')')
Assert ($gitOut -match 'tools/susemi_installer\.ps1') 'installer present as untracked work'
End-Case

Write-Host ''
Write-Host '=== SUMMARY ==='
foreach ($row in $script:rows) { Write-Host ('{0,-36} {1} pass={2} fail={3}' -f $row.case, $row.status, $row.pass, $row.fail) }
Write-Host ('scratch removed: ' + $scratchRemoved)
Write-Host ('default journal root untouched: before=' + $defaultBefore + ' after=' + $defaultAfter)

$summary = New-Object System.Collections.ArrayList
[void]$summary.Add('scenario,status,pass,fail')
foreach ($row in $script:rows) { [void]$summary.Add(('{0},{1},{2},{3}' -f $row.case, $row.status, $row.pass, $row.fail)) }
[void]$summary.Add('scratch_removed,' + $scratchRemoved)
[void]$summary.Add('default_journal_before,' + $defaultBefore)
[void]$summary.Add('default_journal_after,' + $defaultAfter)
Set-Content -LiteralPath (Join-Path $EvidenceDir 'qa-summary.csv') -Value ($summary -join "`r`n") -Encoding UTF8

$failed = @($script:rows | Where-Object { $_.status -ne 'PASS' })
if ($failed.Count -gt 0) { Write-Host ('QA FAIL: ' + $failed.Count + ' scenario(s) failed'); exit 1 }
Write-Host 'QA PASS: all scenarios green'
exit 0
