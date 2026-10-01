#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)][string]$PackageRoot,
  [Parameter(Mandatory=$true)][string]$EvidenceDir,
  [Parameter(Mandatory=$true)][string]$CacheRoot
)
$ErrorActionPreference = 'Stop'
$psExe = Join-Path $PSHOME 'powershell.exe'
$tx = Join-Path $PackageRoot 'tools/susemi_transaction.ps1'
$owned = Join-Path $env:TEMP ('susemi-resource-tx-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
New-Item -ItemType Directory -Path $owned -Force | Out-Null
$script:pass = 0; $script:fail = 0; $script:unreaped = $false; $script:invocation = 0
$names = @(
  'OptiScaler/amd_fidelityfx_framegeneration_dx12.dll',
  'OptiScaler/amd_fidelityfx_loader_dx12.dll',
  'OptiScaler/amd_fidelityfx_upscaler_dx12.dll',
  'OptiScaler/amd_fidelityfx_vk.dll',
  'OptiScaler/D3D12_OptiScaler/D3D12Core.dll',
  'OptiScaler/libxell.dll', 'OptiScaler/libxess.dll',
  'OptiScaler/libxess_dx11.dll', 'OptiScaler/libxess_fg.dll'
)
function Assert([bool]$Value, [string]$Name) {
  if ($Value) { $script:pass++; Write-Host ('ASSERT-PASS: '+$Name) }
  else { $script:fail++; Write-Host ('ASSERT-FAIL: '+$Name) }
}
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Snapshot([string]$Root) {
  $map = @{}; $pending = New-Object Collections.Generic.Stack[string]
  $pending.Push($Root)
  while ($pending.Count) {
    $dir = $pending.Pop()
    foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Force)) {
      $rel = $entry.FullName.Substring($Root.Length)
      if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $map['R|'+$rel] = 'reparse'; continue }
      if ($entry.PSIsContainer) { $map['D|'+$rel] = 'directory'; $pending.Push($entry.FullName) }
      else { $map['F|'+$rel] = Sha $entry.FullName }
    }
  }
  return $map
}
function Same($A,$B) {
  if ($A.Count -ne $B.Count) { return $false }
  foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $A[$k] -ne $B[$k]) { return $false } }
  return $true
}
function Run([string[]]$Arguments) {
  $script:invocation++
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $a = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$tx) + $Arguments
  $psi.Arguments = (($a | ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }) -join ' ')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = New-Object Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start()
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(120000)) {
    $p.Kill()
    if (-not $p.WaitForExit(15000)) { $script:unreaped = $true; throw 'transaction child unreaped' }
    throw 'transaction child timeout'
  }
  $r = @{ exit=$p.ExitCode; stdout=[string]$o.Result; stderr=[string]$e.Result }
  $p.Dispose()
  $label = '{0:d3}' -f $script:invocation
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($label+'.stdout.log')), $r.stdout)
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($label+'.stderr.log')), $r.stderr)
  Write-Host ('NATIVE '+$label+' '+($Arguments -join ' ')+' exit='+$r.exit)
  return $r
}
function ReadJournal([string]$Path) { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
function SaveJournal([string]$Path,$Journal) { [IO.File]::WriteAllText($Path, ($Journal|ConvertTo-Json -Depth 14 -Compress)) }
function Plan([string]$Game,[string]$JournalRoot,[switch]$Resources) {
  $a = @('plan','-GameDir',$Game,'-StagedDir',$CacheRoot,'-Route','asi','-IncludeUal',
    '-StagedUalPath',(Join-Path $CacheRoot 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'),'-JournalRoot',$JournalRoot)
  if ($Resources) {
    $ops = @()
    foreach ($name in $names) { $ops += @{target=(Join-Path $Game $name); source=(Join-Path $CacheRoot $name); sha256=(Sha (Join-Path $CacheRoot $name)); resource=$true} }
    $json = Join-Path $owned 'extra.json'
    [IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject $ops -Depth 4 -Compress))
    $a += @('-ExtraJson',$json)
  }
  $r = Run $a
  $path = ''; if ($r.stdout -match 'journal=([^\r\n]+)') { $path=$Matches[1].Trim() }
  return @{ result=$r; path=$path }
}
function NewGame {
  $game = Join-Path $owned 'game'
  New-Item -ItemType Directory -Path $game | Out-Null
  [IO.File]::WriteAllText((Join-Path $game 'save.dat'),'preserve user bytes')
  return $game
}
function Install([string]$Game,[string]$JournalRoot) {
  $p = Plan $Game $JournalRoot -Resources
  Assert ($p.result.exit -eq 0 -and $p.result.stdout -match 'reason=opcount-11') 'pristine resource plan has eleven file operations'
  if ($p.result.exit -ne 0) { throw ('plan failed: '+$p.result.stdout+$p.result.stderr) }
  $j = ReadJournal $p.path
  Assert ($j.schema_version -eq 2 -and @($j.createdDirs).Count -eq 2) 'schema2 records the two missing resource directories'
  $prepare = Run @('prepare','-Journal',$p.path)
  Assert ($prepare.exit -eq 0) 'native prepare succeeds'
  if ($prepare.exit -ne 0) { throw ('prepare failed: '+$prepare.stdout+$prepare.stderr) }
  $apply = Run @('apply','-Journal',$p.path)
  Assert ($apply.exit -eq 0) 'native apply succeeds'
  if ($apply.exit -ne 0) { throw ('apply failed: '+$apply.stdout+$apply.stderr) }
  foreach ($name in $names) { Assert ((Sha (Join-Path $Game $name)) -eq (Sha (Join-Path $CacheRoot $name))) ('live vendor resource '+$name) }
  [IO.File]::WriteAllText((Join-Path $EvidenceDir 'latest-applied.json'), [IO.File]::ReadAllText($p.path))
  return $p.path
}
function ApplyPlan($Plan, [string]$Label) {
  Assert ($Plan.result.exit -eq 0) ($Label+' valid native plan')
  if ($Plan.result.exit -ne 0) { throw ($Label+' plan: '+$Plan.result.stdout+$Plan.result.stderr) }
  $r = Run @('prepare','-Journal',$Plan.path)
  Assert ($r.exit -eq 0) ($Label+' native prepare')
  if ($r.exit -ne 0) { throw ($Label+' prepare: '+$r.stdout+$r.stderr) }
  $r = Run @('apply','-Journal',$Plan.path)
  Assert ($r.exit -eq 0) ($Label+' native apply')
  if ($r.exit -ne 0) { throw ($Label+' apply: '+$r.stdout+$r.stderr) }
  return $Plan.path
}
function ResetCase([string]$Label) {
  if (Test-Path -LiteralPath (Join-Path $owned 'journals')) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $owned 'journals') -File -Filter '*.json')) {
      [IO.File]::WriteAllText((Join-Path $EvidenceDir ($Label+'-'+$f.Name)),[IO.File]::ReadAllText($f.FullName))
    }
  }
  foreach ($leaf in @('game','journals')) {
    $path = Join-Path $owned $leaf
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  }
  return NewGame
}
try {
  $asi = Join-Path $CacheRoot 'OptiScaler.asi'
  if (-not (Test-Path -LiteralPath $asi)) { New-Item -ItemType HardLink -Path $asi -Target (Join-Path $CacheRoot 'OptiScaler.dll') | Out-Null }
  if ((Sha $asi) -ne '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60') { throw 'core cache pin mismatch' }
  $sourceBefore = Snapshot $CacheRoot
  $game = NewGame
  $before = Snapshot $game
  $jr = Join-Path $owned 'journals'
  $journal = Install $game $jr
  $installed = Snapshot $game; $journals = Snapshot $jr
  $noop = Plan $game $jr -Resources
  Assert ($noop.result.exit -eq 0 -and $noop.result.stdout -match 'status=no-op reason=already-installed') 'all-equal native plan is no-op'
  Assert ((Same $installed (Snapshot $game)) -and (Same $journals (Snapshot $jr))) 'no-op creates no shadow journal or file writes'
  $remove = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($remove.exit -eq 0 -and $remove.stdout -match 'status=removed reason=opcount-11') 'valid removal CLI reverses eleven operations'
  Assert (Same $before (Snapshot $game)) 'full file and directory snapshot restored after nested removal'
  Assert ((ReadJournal $journal).phase -eq 'recovered') 'removal journal completion is durable'
  # A late user resource edit refuses the entire group, including earlier root
  # files. This reaches the real removal action, not invalid legacy CLI flags.
  $game = ResetCase 'pristine'
  $journal = Install $game $jr
  $last = Join-Path $game $names[-1]
  [IO.File]::WriteAllText($last,'user-modified resource')
  $beforeRefusal = Snapshot $game; $beforeJournals = Snapshot $jr
  $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($r.exit -eq 1 -and $r.stdout -match 'status=refused reason=target-changed') 'modified last resource reaches valid CLI and refuses whole removal'
  Assert ((Same $beforeRefusal (Snapshot $game)) -and (Same $beforeJournals (Snapshot $jr))) 'modified-resource refusal changes no earlier targets or journals'
  # Equal foreign vendor files and empty preexisting directories are reused
  # without claiming their bytes or directories.
  $game = ResetCase 'modified-resource'
  $nested = Join-Path $game 'OptiScaler/D3D12_OptiScaler'
  New-Item -ItemType Directory -Path $nested -Force | Out-Null
  $foreign = Join-Path $game 'OptiScaler/libxell.dll'
  New-Item -ItemType HardLink -Path $foreign -Target (Join-Path $CacheRoot 'OptiScaler/libxell.dll') | Out-Null
  $beforeForeign = Snapshot $game
  $p = Plan $game $jr -Resources
  $journal = ApplyPlan $p 'equal-foreign'
  $j = ReadJournal $journal
  Assert (@($j.ops).Count -eq 10 -and @($j.reused).Count -eq 1 -and @($j.createdDirs).Count -eq 0) 'equal foreign file and preexisting empty dirs carry no ownership'
  $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($r.exit -eq 0 -and (Same $beforeForeign (Snapshot $game))) 'valid removal preserves foreign equal bytes and preexisting empty dirs'
  # Whole-plan ancestor and resource collision refusals have zero target and
  # journal writes. Only the exact serial fixture leaf exists at a time.
  foreach ($case in @('unknown-resource','zero-resource','file-parent','nested-junction','dangling-junction')) {
    $game = ResetCase $case
    $destination = Join-Path $owned 'junction-target'
    if ($case -in @('unknown-resource','zero-resource')) {
      New-Item -ItemType Directory -Path (Join-Path $game 'OptiScaler') | Out-Null
      $bytes = 'foreign'
      if ($case -eq 'zero-resource') { $bytes = '' }
      [IO.File]::WriteAllText((Join-Path $game $names[-1]),$bytes)
    } elseif ($case -eq 'file-parent') {
      [IO.File]::WriteAllText((Join-Path $game 'OptiScaler'),'parent file')
    } else {
      New-Item -ItemType Directory -Path (Join-Path $game 'OptiScaler') | Out-Null
      New-Item -ItemType Directory -Path $destination | Out-Null
      New-Item -ItemType Junction -Path (Join-Path $game 'OptiScaler/D3D12_OptiScaler') -Target $destination | Out-Null
      if ($case -eq 'dangling-junction') { Remove-Item -LiteralPath $destination -Force }
    }
    $before = Snapshot $game
    $p = Plan $game $jr -Resources
    Assert ($p.result.exit -eq 1 -and $p.result.stdout -match 'status=refused') ($case+' native whole-plan refusal')
    Assert ((Same $before (Snapshot $game)) -and -not (Test-Path -LiteralPath $jr)) ($case+' zero target or journal writes')
    if ($case -like '*-junction') {
      [IO.Directory]::Delete((Join-Path $game 'OptiScaler/D3D12_OptiScaler'))
      if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    }
  }
  foreach ($field in @('tempPath','backupPath','displacedPath')) {
    $game = ResetCase ('collision-'+$field)
    # A replacement makes the backup collision path meaningful.
    [IO.File]::WriteAllText((Join-Path $game 'winmm.dll'),'prior loader bytes')
    $p = Plan $game $jr -Resources
    Assert ($p.result.exit -eq 0) ($field+' initial plan')
    $j = ReadJournal $p.path
    $op = @($j.ops | Where-Object { $_.op -eq 'replace' })[0]
    $collision = [string]$op.$field
    New-Item -ItemType Directory -Path (Split-Path -Parent $collision) -Force | Out-Null
    [IO.File]::WriteAllText($collision,'foreign collision bytes')
    $collisionSha = Sha $collision
    $before = Snapshot $game
    $r = Run @('prepare','-Journal',$p.path)
    Assert ($r.exit -eq 1 -and $r.stdout -match 'reason=transaction-path-collision' -and (Sha $collision) -eq $collisionSha) ($field+' exclusive path collision refuses prepare')
    Assert (Same $before (Snapshot $game)) ($field+' collision never clobbered and whole game snapshot unchanged')
  }
  # A prepared create with an externally appeared equal target remains foreign.
  $game = ResetCase 'collisions'
  $p = Plan $game $jr -Resources
  $r = Run @('prepare','-Journal',$p.path)
  Assert ($r.exit -eq 0) 'appeared equal target prepared before external trigger'
  $appeared = Join-Path $game $names[-1]
  New-Item -ItemType HardLink -Path $appeared -Target (Join-Path $CacheRoot $names[-1]) | Out-Null
  $r = Run @('apply','-Journal',$p.path)
  Assert ($r.exit -eq 1 -and $r.stdout -match 'reason=target-appeared') 'equal appeared target is conflict, not hash-only ownership'
  $r = Run @('recover','-Journal',$p.path)
  Assert ($r.exit -eq 0 -and (Sha $appeared) -eq (Sha (Join-Path $CacheRoot $names[-1]))) 'current recovery preserves the equal external create'
  Assert (-not (Test-Path -LiteralPath (Join-Path $game 'OptiScaler.asi'))) 'whole preapply conflict never wrote an earlier root target'
  # Durable unresolved intent cannot be adopted, deleted, or called recovered
  # merely because the target equals the staged vendor pin.
  $game = ResetCase 'appeared-target'
  $p = Plan $game $jr -Resources
  $r = Run @('prepare','-Journal',$p.path)
  $j = ReadJournal $p.path
  $op = $j.ops[0]
  New-Item -ItemType HardLink -Path $op.target -Target $op.source | Out-Null
  $op.state = 'intent'; $j.phase = 'recovery-required'
  SaveJournal $p.path $j
  $before = Snapshot $game; $beforeJournals = Snapshot $jr
  $r = Run @('recover','-Journal',$p.path)
  Assert ($r.exit -eq 1 -and $r.stdout -match 'status=recovery-required reason=intent-uncertain') 'interrupted matching-byte intent requires recovery and preserves ambiguity'
  Assert ((Same $before (Snapshot $game)) -and (Same $beforeJournals (Snapshot $jr))) 'uncertain intent refuses all undo before writes'
  $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($r.exit -eq 1 -and $r.stdout -match 'reason=recovery-required') 'newer recovery-required record cannot be skipped for removal'
  # Native replacement and byte-exact restore, including empty preimages. These
  # are valid transaction invocations and actually reach backup/promotion code.
  foreach ($case in @('replace-baseline','zero-preimage')) {
    $game = ResetCase $case
    $ual = Join-Path $game 'winmm.dll'
    $value = 'prior unowned loader bytes'
    if ($case -eq 'zero-preimage') { $value = '' }
    [IO.File]::WriteAllText($ual,$value)
    $before = Snapshot $game
    $p = Plan $game $jr -Resources
    $journal = ApplyPlan $p $case
    $j = ReadJournal $journal
    $replace = @($j.ops | Where-Object { $_.op -eq 'replace' })[0]
    Assert ($replace.beforeSha -eq (Sha $replace.backupPath) -and $replace.backupState -eq 'ready') ($case+' exact exclusive preimage backup')
    $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
    Assert ($r.exit -eq 0 -and (Same $before (Snapshot $game))) ($case+' native atomic restore and owned backup-directory cleanup')
  }
  foreach ($case in @('tampered-backup','missing-backup','modified-root-target')) {
    $game = ResetCase $case
    [IO.File]::WriteAllText((Join-Path $game 'winmm.dll'),'prior backup baseline')
    $p = Plan $game $jr -Resources
    $journal = ApplyPlan $p $case
    $j = ReadJournal $journal
    $replace = @($j.ops | Where-Object { $_.op -eq 'replace' })[0]
    if ($case -eq 'tampered-backup') { [IO.File]::WriteAllText($replace.backupPath,'tampered preimage') }
    if ($case -eq 'missing-backup') { Remove-Item -LiteralPath $replace.backupPath -Force }
    if ($case -eq 'modified-root-target') { [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.asi'),'user modified root target') }
    $before = Snapshot $game; $beforeJournals = Snapshot $jr
    $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
    $reason = 'backup-tampered'
    if ($case -eq 'missing-backup') { $reason = 'backup-missing' }
    if ($case -eq 'modified-root-target') { $reason = 'target-changed' }
    Assert ($r.exit -eq 1 -and $r.stdout -match ('status=refused reason='+$reason)) ($case+' reaches whole-group removal preflight')
    Assert ((Same $before (Snapshot $game)) -and (Same $beforeJournals (Snapshot $jr))) ($case+' preserves every nested/root target and journal')
  }
  # A synchronous readable/no-delete handle is established before apply.
  # No sleeps, readiness polls, weak child mocks, or bypass environment.
  $game = ResetCase 'partial-apply'
  $ual = Join-Path $game 'winmm.dll'
  [IO.File]::WriteAllText($ual,'locked original loader')
  $before = Snapshot $game
  $p = Plan $game $jr -Resources
  $r = Run @('prepare','-Journal',$p.path)
  Assert ($r.exit -eq 0) 'partial apply has all backups armed before lock trigger'
  $lock = [IO.File]::Open($ual,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try {
    $r = Run @('apply','-Journal',$p.path)
    Assert ($r.exit -eq 1 -and $r.stdout -match 'status=apply-failed') 'locked replacement fails after earlier native create'
    $j = ReadJournal $p.path
    Assert (@($j.ops | Where-Object { $_.state -eq 'applied' }).Count -eq 1) 'exactly one earlier root create is durably owned'
    $r = Run @('recover','-Journal',$p.path)
    Assert ($r.exit -eq 0 -and (Same $before (Snapshot $game))) 'partial apply reverses current only, restoring full preimage file/directory map'
  } finally { $lock.Dispose() }
  # A prior written-hash owner is established by a REAL earlier native
  # transaction. Synthetic older bytes are not vendor identity or execution.
  $game = ResetCase 'owned-older'
  $original = Snapshot $game
  $oldSource = Join-Path $owned 'older-resource.bin'
  [IO.File]::WriteAllText($oldSource,'synthetic older bytes, never executed')
  $oldTarget = Join-Path $game 'OptiScaler/libxell.dll'
  $oldSpec = Join-Path $owned 'older-extra.json'
  [IO.File]::WriteAllText($oldSpec,(ConvertTo-Json -InputObject @(@{target=$oldTarget;source=$oldSource}) -Compress))
  $oldPlanResult = Run @('plan','-GameDir',$game,'-StagedDir',$CacheRoot,'-Route','asi','-IncludeUal',
    '-StagedUalPath',(Join-Path $CacheRoot 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'),'-JournalRoot',$jr,'-ExtraJson',$oldSpec)
  $oldJournal = ''
  if ($oldPlanResult.stdout -match 'journal=([^\r\n]+)') { $oldJournal=$Matches[1].Trim() }
  $oldPlan = @{result=$oldPlanResult;path=$oldJournal}
  $oldJournal = ApplyPlan $oldPlan 'actual-older-owner'
  $oldSha = Sha $oldTarget
  $beforeRepair = Snapshot $game
  $oldRecord = [IO.File]::ReadAllText($oldJournal)
  $failedRepair = Plan $game $jr -Resources
  $r = Run @('prepare','-Journal',$failedRepair.path)
  Assert ($r.exit -eq 0) 'linked failed-repair backup is prepared before deterministic lock'
  $lock = [IO.File]::Open($oldTarget,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try {
    $r = Run @('apply','-Journal',$failedRepair.path)
    Assert ($r.exit -eq 1 -and $r.stdout -match 'status=apply-failed') 'linked repair fails at locked owned older resource after nested writes'
    $r = Run @('recover','-Journal',$failedRepair.path)
    Assert ($r.exit -eq 0 -and (Same $beforeRepair (Snapshot $game))) 'failed linked repair reverses current writes and directories only'
    Assert ([IO.File]::ReadAllText($oldJournal) -ceq $oldRecord) 'failed repair leaves previous active journal byte-for-byte intact'
  } finally { $lock.Dispose() }
  $p = Plan $game $jr -Resources
  $newJournal = ApplyPlan $p 'owned-resource-repair'
  $new = ReadJournal $newJournal; $old = ReadJournal $oldJournal
  $ownedReplace = @($new.ops | Where-Object { $_.target -eq $oldTarget })[0]
  Assert ($ownedReplace.op -eq 'replace' -and $ownedReplace.beforeSha -eq $oldSha -and (Sha $ownedReplace.backupPath) -eq $oldSha) 'older written-hash resource is replaced with exact old-byte preimage'
  Assert ($new.previous_journal.path -eq $oldJournal -and $new.previous_journal.txid -eq $old.txid) 'partial repair records validated previous path and transaction id'
  $noOpMap = Snapshot $game; $noOpJournals = Snapshot $jr
  $p2 = Plan $game $jr -Resources
  Assert ($p2.result.exit -eq 0 -and $p2.result.stdout -match 'status=no-op' -and
    (Same $noOpMap (Snapshot $game)) -and (Same $noOpJournals (Snapshot $jr))) 'repaired complete set produces no shadow journal'
  foreach ($badLink in @('txid','path','preimage')) {
    $new = ReadJournal $newJournal
    if ($badLink -eq 'txid') { $new.previous_journal.txid = [guid]::NewGuid().ToString('N') }
    if ($badLink -eq 'path') { $new.previous_journal.path = Join-Path $jr 'absent.json' }
    if ($badLink -eq 'preimage') {
      $replace = @($new.ops | Where-Object { $_.target -eq $oldTarget })[0]
      [IO.File]::WriteAllText($replace.backupPath,'different but locally self-consistent preimage')
      $replace.beforeSha=Sha $replace.backupPath; $replace.backupSha=$replace.beforeSha
    }
    SaveJournal $newJournal $new
    $before = Snapshot $game; $beforeJournals = Snapshot $jr
    $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
    Assert ($r.exit -eq 1 -and $r.stdout -match 'status=refused') ($badLink+' invalid continuity reaches native whole-group undo refusal')
    Assert ((Same $before (Snapshot $game)) -and (Same $beforeJournals (Snapshot $jr))) ($badLink+' link/preimage refusal mutates no part of newer or older group')
    if ($badLink -eq 'preimage') {
      Copy-Item -LiteralPath $oldSource -Destination $replace.backupPath -Force
      $replace.beforeSha=$oldSha; $replace.backupSha=$oldSha
    }
    $new.previous_journal.path=$oldJournal; $new.previous_journal.txid=$old.txid
    SaveJournal $newJournal $new
  }
  $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($r.exit -eq 0 -and (Same $original (Snapshot $game))) 'linked removal validates continuity and reverses newest-first to original full map'
  Assert ((ReadJournal $newJournal).phase -eq 'recovered' -and (ReadJournal $oldJournal).phase -eq 'recovered') 'both linked journals durably complete removal'
  # Schema1 remains explicitly removable without inferring directory ownership.
  $game = ResetCase 'schema1'
  New-Item -ItemType Directory -Path (Join-Path $game 'OptiScaler/D3D12_OptiScaler') -Force | Out-Null
  $before = Snapshot $game
  $p = Plan $game $jr -Resources
  $journal = ApplyPlan $p 'schema1-compatible-record'
  $j = ReadJournal $journal; $j.schema_version = 1
  $j | Add-Member -NotePropertyName createdDirs -NotePropertyValue @(@{path=(Join-Path $game 'OptiScaler');state='created'}) -Force
  SaveJournal $journal $j
  $r = Run @('remove','-GameDir',$game,'-JournalRoot',$jr)
  Assert ($r.exit -eq 0 -and (Same $before (Snapshot $game))) 'schema1 removes owned files while ignoring directory ownership metadata'
  # Exact independent QA path shapes, with tiny data only. Each refused input
  # reaches real plan CLI; no prepare/apply is attempted for a refused plan.
  $pathStage = Join-Path $owned 'path-stage'
  [void][IO.Directory]::CreateDirectory($pathStage)
  $pathSource = Join-Path $pathStage 'OptiScaler.asi'
  [IO.File]::WriteAllText($pathSource,'tiny path-budget fixture; never executed')
  foreach ($case in @('temp-262','backup-274','target-275','journal-260')) {
    $length = 187
    if ($case -eq 'backup-274') { $length = 212 }
    if ($case -eq 'target-275') { $length = 220 }
    if ($case -eq 'journal-260') { $length = 120 }
    $pathGame = Join-Path $owned ($case+'-')
    $pathGame += 'x' * ($length - $pathGame.Length)
    [void][IO.Directory]::CreateDirectory($pathGame)
    [IO.File]::WriteAllText((Join-Path $pathGame 'save.dat'),'unchanged user data')
    if ($case -eq 'backup-274') { [IO.File]::WriteAllText((Join-Path $pathGame 'OptiScaler.asi'),'replace preimage') }
    $target = Join-Path $pathGame 'OptiScaler/D3D12_OptiScaler/D3D12Core.dll'
    if ($case -eq 'target-275') { $target = Join-Path $pathGame (('t'*50)+'.dll') }
    if ($case -eq 'journal-260') { $target = Join-Path $pathGame 'extra.bin' }
    $extra = Join-Path $owned 'path-extra.json'
    [IO.File]::WriteAllText($extra,(ConvertTo-Json -InputObject @(@{target=$target;source=$pathSource}) -Compress))
    # These lengths bind the fixtures to the original red observations, not
    # to a mock of the product validator.
    $temp = Join-Path (Split-Path -Parent $target) ('.susemi-'+('0'*32)+'-1.tmp')
    $backup = Join-Path $pathGame ('.susemi-backup/'+('0'*32)+'/0000.preimage')
    Write-Host ('PATH_BUDGET '+$case+' game='+$pathGame.Length+' target='+$target.Length+' temp='+$temp.Length+' backup='+$backup.Length)
    if ($case -eq 'temp-262') { Assert ($temp.Length -eq 262) 'exact QA promotion temp 262' }
    if ($case -eq 'backup-274') { Assert ($backup.Length -eq 274 -and (Split-Path -Parent $backup).Length -eq 260) 'exact QA backup 274 and GUID parent 260' }
    if ($case -eq 'target-275') { Assert ($target.Length -eq 275) 'exact QA target 275' }
    foreach ($existing in @($false,$true)) {
      $pathJr = Join-Path $owned ($case+'-new-journals')
      if ($existing) { $pathJr = $jr }
      if ($case -eq 'journal-260') {
        $pathJr = Join-Path $owned ('journal-'+$existing+'-')
        $pathJr += 'j' * (196 - $pathJr.Length)
        if ($existing) {
          [void][IO.Directory]::CreateDirectory($pathJr)
          [IO.File]::WriteAllText((Join-Path $pathJr 'sentinel.dat'),'unchanged journal bytes')
        }
      }
      $before = Snapshot $pathGame
      $beforeJournals = @{}; if ($existing) { $beforeJournals = Snapshot $pathJr }
      $r = Run @('plan','-GameDir',$pathGame,'-StagedDir',$pathStage,'-Route','asi','-JournalRoot',$pathJr,'-ExtraJson',$extra)
      Assert ($r.exit -eq 1 -and $r.stdout -match 'status=refused reason=path-limit') ($case+' named prewrite refusal existingJournals='+$existing)
      $after = Snapshot $pathGame
      $afterJournals = @{}; if ($existing) { $afterJournals = Snapshot $pathJr }
      Assert ((Same $before $after) -and (Same $beforeJournals $afterJournals) -and
        ($existing -or -not (Test-Path -LiteralPath $pathJr))) ($case+' full game/journal zero writes existingJournals='+$existing)
      [IO.File]::WriteAllText((Join-Path $EvidenceDir ($case+'-'+$existing+'-maps.json')),
        (ConvertTo-Json -InputObject @{game=$pathGame;journalRoot=$pathJr;before=$before;after=$after;
          journalsBefore=$beforeJournals;journalsAfter=$afterJournals;newJournalRootAbsent=(-not (Test-Path -LiteralPath $pathJr))} -Depth 6))
      if ($case -eq 'journal-260' -and $existing) { Remove-Item -LiteralPath $pathJr -Recurse -Force }
    }
    Remove-Item -LiteralPath $pathGame -Recurse -Force
  }
  # Real supported boundary flows exercise promotion/displacement, preimage
  # backups and journal atomic writes rather than merely asserting lengths.
  foreach ($case in @('temp-259','backup-259','journal-259')) {
    $length = 184
    if ($case -eq 'backup-259') { $length = 197 }
    if ($case -eq 'journal-259') { $length = 120 }
    $pathGame = Join-Path $owned ($case+'-')
    $pathGame += 'x' * ($length - $pathGame.Length)
    [void][IO.Directory]::CreateDirectory($pathGame)
    $target = Join-Path $pathGame 'OptiScaler/D3D12_OptiScaler/D3D12Core.dll'
    if ($case -ne 'temp-259') { $target = Join-Path $pathGame 'extra.bin' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [IO.File]::WriteAllText($target,'boundary replacement preimage')
    $before = Snapshot $pathGame
    $extra = Join-Path $owned 'path-extra.json'
    [IO.File]::WriteAllText($extra,(ConvertTo-Json -InputObject @(@{target=$target;source=$pathSource}) -Compress))
    $pathJr = Join-Path $owned ($case+'-journals')
    if ($case -eq 'journal-259') { $pathJr += 'j' * (195 - $pathJr.Length) }
    $r = Run @('plan','-GameDir',$pathGame,'-StagedDir',$pathStage,'-Route','asi','-JournalRoot',$pathJr,'-ExtraJson',$extra)
    $path = ''; if ($r.stdout -match 'journal=([^\r\n]+)') { $path=$Matches[1].Trim() }
    $path = ApplyPlan @{result=$r;path=$path} $case
    $record = ReadJournal $path
    $replace = @($record.ops | Where-Object { $_.op -eq 'replace' })[0]
    if ($case -eq 'temp-259') { Assert ($replace.tempPath.Length -eq 259 -and $replace.displacedPath.Length -eq 259) 'native temp/displaced 259 promotion succeeds' }
    if ($case -eq 'backup-259') { Assert ($replace.backupPath.Length -eq 259 -and (Sha $replace.backupPath) -eq $replace.beforeSha) 'native backup 259 is byte-exact' }
    if ($case -eq 'journal-259') { Assert ($path.Length -eq 259) 'native journal 259 atomic writes succeed' }
    $r = Run @('remove','-GameDir',$pathGame,'-JournalRoot',$pathJr)
    Assert ($r.exit -eq 0 -and (Same $before (Snapshot $pathGame))) ($case+' native undo restores full map')
    [IO.File]::WriteAllText((Join-Path $EvidenceDir ($case+'-recovered.json')),[IO.File]::ReadAllText($path))
    Remove-Item -LiteralPath $pathGame,$pathJr -Recurse -Force
  }
  Assert (Same $sourceBefore (Snapshot $CacheRoot)) 'transaction preserves the single real vendor source cache'
} finally {
  if (-not $script:unreaped) { Remove-Item -LiteralPath $owned -Recurse -Force }
  Write-Output ('TX_QA pass='+$script:pass+' fail='+$script:fail+' scratchAbsent='+(-not (Test-Path -LiteralPath $owned)))
}
if ($script:fail -gt 0) { exit 1 }
exit 0
