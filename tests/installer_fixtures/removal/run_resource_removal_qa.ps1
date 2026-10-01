#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)][string]$PackageRoot,
  [Parameter(Mandatory=$true)][string]$EvidenceDir,
  [Parameter(Mandatory=$true)][string]$CacheRoot,
  [string]$Rc2Zip = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$owned = Join-Path $env:TEMP ('susemi-resource-entry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $owned | Out-Null
$script:pass=0; $script:fail=0; $script:unreaped=$false; $script:count=0
$defaultRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer/journal'
function Assert([bool]$Value,[string]$Name) {
  if ($Value) { $script:pass++; Write-Host ('ASSERT-PASS: '+$Name) }
  else { $script:fail++; Write-Host ('ASSERT-FAIL: '+$Name) }
}
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Map([string]$Root) {
  $map=@{}
  if (-not (Test-Path -LiteralPath $Root)) { return $map }
  $stack=New-Object Collections.Generic.Stack[string]; $stack.Push($Root)
  while ($stack.Count) {
    foreach ($f in @(Get-ChildItem -LiteralPath $stack.Pop() -Force)) {
      $rel=$f.FullName.Substring($Root.Length)
      if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { $map['R|'+$rel]='reparse'; continue }
      if ($f.PSIsContainer) { $map['D|'+$rel]='directory'; $stack.Push($f.FullName) }
      else { $map['F|'+$rel]=Sha $f.FullName }
    }
  }
  return $map
}
function Same($A,$B) {
  if ($A.Count -ne $B.Count) { return $false }
  foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $A[$k] -ne $B[$k]) { return $false } }
  return $true
}
function NewGame([string]$Name) {
  $game=Join-Path $owned 'game'; New-Item -ItemType Directory -Path $game | Out-Null
  $data=New-Object byte[] 1024
  $data[0]=0x4d;$data[1]=0x5a;[BitConverter]::GetBytes([int]128).CopyTo($data,60)
  $data[128]=0x50;$data[129]=0x45;$data[132]=0x64;$data[133]=0x86
  [IO.File]::WriteAllBytes((Join-Path $game 'Game.exe'),$data)
  [IO.File]::WriteAllText((Join-Path $game 'save.dat'),'preserve unrelated bytes '+$Name)
  return $game
}
function Run([string]$Action,[string]$Game,[string]$Zip,[string[]]$Extra=@()) {
  $script:count++
  $exe=Join-Path $game 'Game.exe'
  $args=$Action+' -Exe "'+$exe+'" -Consent yes -Lang en'
  if ($Extra.Count) { $args+=' '+($Extra -join ' ') }
  $inner='"'+(Join-Path $CacheRoot 'Install_OptiScaler_windows.bat')+'" '+$args
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName='cmd.exe';$psi.Arguments='/d /c "'+$inner+'"'
  $psi.WorkingDirectory=$CacheRoot;$psi.UseShellExecute=$false
  $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.EnvironmentVariables['SUSEMI_TX_JOURNAL_ROOT']=Join-Path $owned 'journals'
  if ($null -eq $Zip) { $psi.EnvironmentVariables.Remove('SUSEMI_RC2_ZIP') }
  else { $psi.EnvironmentVariables['SUSEMI_RC2_ZIP']=$Zip }
  $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$p.StandardInput.Close()
  $o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(180000)) {
    $p.Kill()
    if (-not $p.WaitForExit(15000)) { $script:unreaped=$true;throw 'entrypoint child unreaped' }
    throw 'entrypoint timeout'
  }
  $r=@{exit=$p.ExitCode;stdout=[string]$o.Result;stderr=[string]$e.Result};$p.Dispose()
  $label='{0:d3}' -f $script:count
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($label+'.stdout.log')),$r.stdout)
  [IO.File]::WriteAllText((Join-Path $EvidenceDir ($label+'.stderr.log')),$r.stderr)
  Write-Host ('BAT '+$label+' '+$args+' exit='+$r.exit)
  Assert (@($r.stdout -split "`r?`n"|Where-Object{$_ -match '^status='}).Count -eq 1) ($label+' exactly one final machine status')
  return $r
}
function Reset([string]$Label) {
  $jr=Join-Path $owned 'journals'
  foreach ($f in @(Get-ChildItem -LiteralPath $jr -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
    [IO.File]::WriteAllText((Join-Path $EvidenceDir ($Label+'-'+$f.Name)),[IO.File]::ReadAllText($f.FullName))
  }
  foreach ($leaf in @('game','journals')) {
    $path=Join-Path $owned $leaf
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  }
}
try {
  # Support scripts only are copied into the already-extracted single cache.
  # Real core/UAL/nine resources are reused, never duplicated into package trees.
  foreach ($name in @('Install_OptiScaler_windows.bat','setup_windows.bat','tools/susemi_installer.ps1','tools/susemi_transaction.ps1','tools/susemi_stage_helpers.ps1')) {
    $dest=Join-Path $CacheRoot $name
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination $dest -Force
  }
  $source=Map $CacheRoot;$default=Map $defaultRoot
  foreach ($mode in @('default-directory','explicit-pinned-zip')) {
    $game=NewGame $mode;$before=Map $game;$zip=$null
    if ($mode -eq 'explicit-pinned-zip') { $zip=$Rc2Zip }
    $r=Run 'install' $game $zip
    Assert ($r.exit -eq 0 -and $r.stdout -match 'status=installed reason=ok') ($mode+' actual BAT installs')
    Assert ($r.stdout -match 'setup_payloads=verified setup_expected=11 setup_verified=11 resources_expected=9 resources_verified=9' -and
      $r.stdout -match 'game_load_order=UNVERIFIED fg_runtime=UNVERIFIED') ($mode+' bytes and actual runtime claims separated')
    $jr=Join-Path $owned 'journals';$files=@(Get-ChildItem -LiteralPath $jr -File -Filter '*.json')
    Assert ($files.Count -eq 1) ($mode+' one transaction journal')
    if ($files.Count -ne 1) { throw ('install did not journal: '+$r.stdout+$r.stderr) }
    $j=[IO.File]::ReadAllText($files[0].FullName)|ConvertFrom-Json
    Assert ($j.schema_version -eq 2 -and $j.phase -eq 'applied' -and @($j.ops).Count -eq 11) ($mode+' pristine eleven applied file operations')
    $installed=Map $game;$journals=Map $jr
    $again=Run 'install' $game $zip
    Assert ($again.exit -eq 0 -and $again.stdout -match 'status=no-op reason=already-installed') ($mode+' repeated BAT install no-op')
    Assert ((Same $installed (Map $game)) -and (Same $journals (Map $jr))) ($mode+' no shadow journal or target mutation')
    $remove=Run 'remove' $game $zip
    Assert ($remove.exit -eq 0 -and $remove.stdout -match 'status=removed reason=opcount-11') ($mode+' valid BAT remove reaches whole linked undo')
    Assert (Same $before (Map $game)) ($mode+' full original file/directory map restored')
    Assert (-not (Test-Path -LiteralPath $j.staged_dir)) ($mode+' confirmed exited-child stage cleaned')
    Reset $mode
  }
  # Source refusal still applies when all eleven live bytes are already equal.
  $game=NewGame 'invalid-explicit';$r=Run 'install' $game $null
  $before=Map $game;$jr=Join-Path $owned 'journals';$journals=Map $jr
  $bad=Join-Path $owned 'wrong.zip';[IO.File]::WriteAllText($bad,'wrong explicit zip')
  $r=Run 'install' $game $bad
  Assert ($r.exit -eq 1 -and $r.stdout -match 'reason=rc2-zip-sha-mismatch') 'explicit invalid ZIP refuses even on otherwise satisfied deployment'
  Assert ((Same $before (Map $game)) -and (Same $journals (Map $jr))) 'invalid ZIP does not fall back, create a shadow journal, or change live bytes'
  $last=Join-Path $game 'OptiScaler/libxess_fg.dll'
  [IO.File]::WriteAllText($last,'user modified resource')
  $before=Map $game;$journals=Map $jr
  $r=Run 'remove' $game $null
  Assert ($r.exit -eq 1 -and $r.stdout -match 'status=refused reason=target-changed') 'valid BAT removal refuses changed nested resource'
  Assert ((Same $before (Map $game)) -and (Same $journals (Map $jr))) 'BAT refusal preserves whole group including root files'
  Reset 'invalid-explicit'
  # ReShade-first final restored goal continues to be a complete-set no-op.
  $game=NewGame 'restored-goal';$r=Run 'install' $game $null
  Copy-Item -LiteralPath (Join-Path $game 'Game.exe') -Destination (Join-Path $game 'ReShade.asi')
  [IO.File]::WriteAllText((Join-Path $game 'winmm.ini'),"[globalsets]`nloadextraplugins=ReShade.asi`n")
  [IO.File]::WriteAllText((Join-Path $game 'global.ini'),"[globalsets]`nloadextraplugins=OptiScaler.asi`n")
  New-Item -ItemType Directory -Path (Join-Path $game 'plugins') | Out-Null
  [IO.File]::WriteAllText((Join-Path $game 'plugins/global.ini'),"[globalsets]`nloadextraplugins=ReShade.asi`n")
  $before=Map $game;$journals=Map (Join-Path $owned 'journals')
  $r=Run 'install' $game $null @('-ReshadeFirst','-IniConsent','yes')
  Assert ($r.exit -eq 0 -and $r.stdout -match 'status=no-op reason=already-configured') 'restored final-effective ReShade goal remains no-op through actual BAT'
  Assert ((Same $before (Map $game)) -and (Same $journals (Map (Join-Path $owned 'journals')))) 'restored goal preserves every resource INI and journal byte'
  Assert ((Same $source (Map $CacheRoot)) -and (Same $default (Map $defaultRoot))) 'native BAT cases preserve package source and default journal maps'
} finally {
  if (-not $script:unreaped) { Remove-Item -LiteralPath $owned -Recurse -Force }
  Write-Output ('ENTRY_QA pass='+$script:pass+' fail='+$script:fail+' scratchAbsent='+(-not (Test-Path -LiteralPath $owned)))
}
if ($script:fail -gt 0) { exit 1 }
exit 0
