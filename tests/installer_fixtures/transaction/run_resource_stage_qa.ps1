#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)][string]$PackageRoot,
  [Parameter(Mandatory=$true)][string]$EvidenceDir,
  [Parameter(Mandatory=$true)][string]$CacheRoot,
  [string]$Rc2Zip = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
)
$ErrorActionPreference = 'Stop'
$psExe = Join-Path $PSHOME 'powershell.exe'
$pins = [ordered]@{
  'OptiScaler/amd_fidelityfx_framegeneration_dx12.dll' = '02297beedd285e822d3a64f314cf00faf378dcec0edc47ff0c4dd71b3a8c2f18'
  'OptiScaler/amd_fidelityfx_loader_dx12.dll' = 'e2d85aa05a9bd9ed8b38935fdf5199372cca6f74c12015143bb6f945ee1608aa'
  'OptiScaler/amd_fidelityfx_upscaler_dx12.dll' = 'd0dcccc74a43c44ba435b7a369b456e0970d8a4464e4bd683119b374f2c9fb46'
  'OptiScaler/amd_fidelityfx_vk.dll' = 'a1624cc4238fef046f30c4d80ce3f47be63fc5f5373f49e3ee9edb9960f54c78'
  'OptiScaler/D3D12_OptiScaler/D3D12Core.dll' = '07d286c306f8117321422affd9e6388c12d0fb4be1c7fc689d9e899324feeb24'
  'OptiScaler/libxell.dll' = 'd2030dcd694fda8f2ec7e044b13e6db8f0b56d4ba9113a5efad334e3f3ded8c7'
  'OptiScaler/libxess.dll' = '251659dd84a3e84de67c886a4186e01f3eca49b00641906fe38bb6b807e5d5b7'
  'OptiScaler/libxess_dx11.dll' = 'c7cfe86f0c9d94e4fb3696d3cd5035e2bbb6a8b1b0572f8b7395a4cdfd0c625e'
  'OptiScaler/libxess_fg.dll' = 'ec5e0c65e075570c6ede72618bb666d0be0c2e10b2ea9762c0fe8cb8e375ab27'
}
$allPins = [ordered]@{}
foreach ($name in $pins.Keys) { $allPins[$name] = $pins[$name] }
$allPins['OptiScaler.dll'] = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
$allPins['tools/asi-loader/Ultimate-ASI-Loader-x64.dll'] = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$owned = Join-Path $EvidenceDir ('owned-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $owned -Force | Out-Null
$script:passed = 0; $script:failed = 0; $script:unreaped = $false
function Assert([bool]$Value, [string]$Name) {
  if ($Value) { $script:passed++; Write-Output ('ASSERT-PASS: ' + $Name) }
  else { $script:failed++; Write-Output ('ASSERT-FAIL: ' + $Name) }
}
function Sha([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Map([string]$Root) {
  $m = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
    $m[$f.FullName.Substring($Root.Length)] = Sha $f.FullName
  }
  return $m
}
function Same($A, $B) {
  if ($A.Count -ne $B.Count) { return $false }
  foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $A[$k] -ne $B[$k]) { return $false } }
  return $true
}
function RunHelper([string[]]$Arguments, [string]$Label) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $parts = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:helper) + $Arguments
  $psi.Arguments = (($parts | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(120000)) {
    $p.Kill()
    if (-not $p.WaitForExit(15000)) { $script:unreaped = $true; throw 'helper child unreaped' }
    throw 'helper child timeout'
  }
  $r = @{ exit=$p.ExitCode; stdout=[string]$o.Result; stderr=[string]$e.Result }
  $p.Dispose()
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($Label + '.stdout.log')), $r.stdout)
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($Label + '.stderr.log')), $r.stderr)
  Write-Host ('NATIVE '+$Label+' exit='+$r.exit)
  return $r
}
function CheckNine($Result, [string]$Stage, [string]$Label) {
  $line = @($Result.stdout -split "`r?`n" | Where-Object { $_.StartsWith('resource_ops_json=') })
  Assert ($Result.exit -eq 0 -and $line.Count -eq 1) ($Label + ' native success and one metadata array')
  $ops = @()
  if ($line.Count -eq 1) { $ops = @($line[0].Substring(18) | ConvertFrom-Json) }
  # PS5.1 ConvertFrom-Json emits its array as one pipeline object.
  if ($ops.Count -eq 1 -and $ops[0] -is [array]) { $ops = $ops[0] }
  Assert ($ops.Count -eq 9) ($Label + ' exactly nine metadata entries')
  foreach ($op in $ops) {
    $name = [string]$op.relative
    Assert ($pins.Contains($name) -and $op.sha256 -eq $pins[$name] -and (Sha (Join-Path $Stage $name)) -eq $pins[$name]) ($Label + ' pinned ' + $name)
  }
  Assert (@(Get-ChildItem -LiteralPath $Stage -Recurse -File).Count -eq 9) ($Label + ' no settings licenses or other payloads copied')
}
try {
  # One extraction cache persists across material revisions and later resource
  # tests. Never copy the archive or make a full vendor tree per fixture.
  if (-not (Test-Path -LiteralPath $CacheRoot)) {
    if ((Sha $Rc2Zip) -ne '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a') { throw 'cache archive pin mismatch' }
    New-Item -ItemType Directory -Path $CacheRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Rc2Zip)
    try {
      foreach ($name in $allPins.Keys) {
        $entry = @($z.Entries | Where-Object { $_.FullName -ceq $name })
        if ($entry.Count -ne 1) { throw ('cache entry absent/duplicate: '+$name) }
        $path = Join-Path $CacheRoot $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0], $path, $false)
      }
    } finally { $z.Dispose() }
  }
  foreach ($name in $allPins.Keys) { if ((Sha (Join-Path $CacheRoot $name)) -ne $allPins[$name]) { throw ('cache pin mismatch: '+$name) } }
  $script:helper = Join-Path $CacheRoot 'tools/susemi_stage_helpers.ps1'
  Copy-Item -LiteralPath (Join-Path $PackageRoot 'tools/susemi_stage_helpers.ps1') -Destination $script:helper -Force
  $sourceMap = Map $CacheRoot
  # The default is exercised by an actual -File invocation at this package's
  # real PSScriptRoot, not an AST-defined function with an explicit root.
  foreach ($mode in @('default-directory', 'explicit-directory', 'pinned-zip')) {
    $stage = Join-Path $owned 'stage'
    New-Item -ItemType Directory -Path $stage | Out-Null
    $a = @('resources', '-StageDir', $stage)
    if ($mode -eq 'explicit-directory') { $a += @('-PackageRoot', $CacheRoot) }
    if ($mode -eq 'pinned-zip') { $a += @('-Rc2Zip', $Rc2Zip) }
    $r = RunHelper $a $mode
    CheckNine $r $stage $mode
    $v = RunHelper @('resources-verify', '-StageDir', $stage) ($mode + '-verify')
    CheckNine $v $stage ($mode + '-verify')
    Assert (Same $sourceMap (Map $CacheRoot)) ($mode + ' source bytes unchanged')
    if ($mode -eq 'default-directory') {
      $last = Join-Path $stage 'OptiScaler/libxess_fg.dll'
      $saved = Join-Path $owned 'saved-stage-resource'
      [IO.File]::Move($last, $saved)
      try {
        $v = RunHelper @('resources-verify', '-StageDir', $stage) 'verify-missing-last'
        Assert ($v.exit -eq 1 -and $v.stdout -match 'reason=resource-stage-missing' -and $v.stdout -notmatch 'resource_ops_json=') 'verify refuses a missing staged member'
        [IO.File]::WriteAllText($last, 'tampered stage')
        $v = RunHelper @('resources-verify', '-StageDir', $stage) 'verify-tampered-last'
        Assert ($v.exit -eq 1 -and $v.stdout -match 'reason=resource-stage-pin-mismatch' -and $v.stdout -notmatch 'resource_ops_json=') 'verify refuses a tampered staged member'
      } finally {
        if (Test-Path -LiteralPath $last) { Remove-Item -LiteralPath $last -Force }
        [IO.File]::Move($saved, $last)
      }
      $nested = Join-Path $stage 'OptiScaler/D3D12_OptiScaler'
      $savedDir = Join-Path $owned 'saved-stage-directory'
      [IO.Directory]::Move($nested, $savedDir)
      New-Item -ItemType Junction -Path $nested -Target $savedDir | Out-Null
      try {
        $v = RunHelper @('resources-verify', '-StageDir', $stage) 'verify-nested-reparse'
        Assert ($v.exit -eq 1 -and $v.stdout -match 'reason=resource-path-reparse' -and $v.stdout -notmatch 'resource_ops_json=') 'verify refuses a nested staged reparse ancestor with otherwise equal vendor bytes'
      } finally { [IO.Directory]::Delete($nested); [IO.Directory]::Move($savedDir, $nested) }
    }
    Remove-Item -LiteralPath $stage -Recurse -Force
  }
  foreach ($case in @('missing-zip', 'wrong-zip', 'empty-zip', 'missing-last', 'tampered-last', 'zero-last', 'unreadable-last', 'output-collision', 'file-parent', 'live-junction', 'dangling-junction')) {
    $stage = Join-Path $owned 'stage'
    New-Item -ItemType Directory -Path $stage | Out-Null
    $a = @('resources', '-StageDir', $stage)
    $last = Join-Path $CacheRoot 'OptiScaler/libxess_fg.dll'
    $saved = Join-Path $CacheRoot 'saved-resource'
    $handle = $null; $junctionTarget = Join-Path $owned 'junction-destination'
    try {
      if ($case -eq 'missing-zip') { $a += @('-Rc2Zip', (Join-Path $owned 'absent.zip')) }
      if ($case -eq 'wrong-zip') {
        $bad = Join-Path $owned 'wrong.zip'; [IO.File]::WriteAllText($bad, 'not the pinned archive'); $a += @('-Rc2Zip', $bad)
      }
      if ($case -eq 'empty-zip') { $a += @('-Rc2Zip', '') }
      if ($case -eq 'missing-last' -or $case -eq 'tampered-last' -or $case -eq 'zero-last') {
        [IO.File]::Move($last, $saved)
        if ($case -eq 'tampered-last') { [IO.File]::WriteAllText($last, 'tampered') }
        if ($case -eq 'zero-last') { [IO.File]::WriteAllBytes($last, [byte[]]@()) }
      }
      if ($case -eq 'unreadable-last') { $handle = [IO.File]::Open($last, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
      if ($case -eq 'output-collision') {
        New-Item -ItemType Directory -Path (Join-Path $stage 'OptiScaler') | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'OptiScaler/libxess_fg.dll'), 'foreign')
      }
      if ($case -eq 'file-parent') { [IO.File]::WriteAllText((Join-Path $stage 'OptiScaler'), 'foreign parent file') }
      if ($case -like '*-junction') {
        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $stage 'OptiScaler') -Target $junctionTarget | Out-Null
        if ($case -eq 'dangling-junction') { Remove-Item -LiteralPath $junctionTarget -Force }
      }
      $before = Map $stage
      $r = RunHelper $a $case
      Assert ($r.exit -eq 1 -and $r.stdout -match 'status=refused' -and $r.stdout -notmatch 'resource_ops_json=') ($case + ' actual refusal without success metadata')
      Assert (Same $before (Map $stage)) ($case + ' whole input refusal before staged writes')
    } finally {
      if ($handle) { $handle.Dispose() }
      if (Test-Path -LiteralPath $saved) {
        if (Test-Path -LiteralPath $last) { Remove-Item -LiteralPath $last -Force }
        [IO.File]::Move($saved, $last)
      }
      if ($case -like '*-junction') { [IO.Directory]::Delete((Join-Path $stage 'OptiScaler')) }
      Remove-Item -LiteralPath $stage -Recurse -Force
      if (Test-Path -LiteralPath $junctionTarget) { Remove-Item -LiteralPath $junctionTarget -Force }
    }
  }
  # Deterministic partial copy: an ordinary readable nested destination has
  # CreateFiles denied before trigger. Preflight sees no collision/reparse;
  # four real resources copy before the fifth exclusive create fails.
  $stage = Join-Path $owned 'stage'
  $denied = Join-Path $stage 'OptiScaler/D3D12_OptiScaler'
  New-Item -ItemType Directory -Path $denied -Force | Out-Null
  $originalAcl = Get-Acl -LiteralPath $denied
  $acl = Get-Acl -LiteralPath $denied
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::CreateFiles, [Security.AccessControl.AccessControlType]::Deny)
  $acl.AddAccessRule($rule); Set-Acl -LiteralPath $denied -AclObject $acl
  try {
    $r = RunHelper @('resources', '-StageDir', $stage) 'partial-copy'
    Assert ($r.exit -eq 1 -and $r.stdout -match 'status=failed reason=resource-stage-copy-failed' -and $r.stdout -notmatch 'resource_ops_json=') 'partial native copy is failure, not success'
    Assert (@(Get-ChildItem -LiteralPath $stage -Recurse -File).Count -eq 4) 'partial copy retains exactly the four established owned stage files'
  } finally { Set-Acl -LiteralPath $denied -AclObject $originalAcl; Remove-Item -LiteralPath $stage -Recurse -Force }
  Assert (Same $sourceMap (Map $CacheRoot)) 'all native staging cases preserve the single verified source cache'
} finally {
  if (-not $script:unreaped) { Remove-Item -LiteralPath $owned -Recurse -Force }
  Write-Output ('STAGE_QA pass='+$script:passed+' fail='+$script:failed+' scratchAbsent='+(-not (Test-Path -LiteralPath $owned))+' cache='+$CacheRoot)
}
if ($script:failed -gt 0) { exit 1 }
exit 0
