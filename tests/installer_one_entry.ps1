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
$script:exitCode = 0
$script:liveChildren = New-Object System.Collections.ArrayList

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

function Test-OwnedChildrenReaped {
  # True only when every tracked invocation-owned child is confirmed exited
  # (HasExited true). An unreadable/untracked handle is conservatively treated
  # as NOT reaped, so scratch is never removed while a child may be alive.
  param([object[]]$Children)
  foreach ($c in @($Children)) {
    if ($null -eq $c) { continue }
    $exited = $false
    try { $exited = [bool]$c.HasExited } catch { return $false }
    if (-not $exited) { return $false }
  }
  return $true
}

function Remove-OwnedScratch {
  # Ownership- and lifecycle-bounded teardown. Removes ONLY the exact generated
  # scratch leaf, and only when no invocation-owned child is unreaped. Never
  # removes the parent root, a pre-existing sibling, or scratch while an owned
  # child may still be running.
  param([string]$ScratchPath, [string]$ExpectedLeaf, [object[]]$Children)
  if (-not (Test-OwnedChildrenReaped -Children $Children)) {
    return @{ Removed = $false; Withheld = $true; Reason = 'unreaped-owned-child' }
  }
  if ([IO.Path]::GetFileName($ScratchPath) -ne $ExpectedLeaf) {
    return @{ Removed = $false; Withheld = $true; Reason = 'leaf-mismatch' }
  }
  if (-not (Test-Path -LiteralPath $ScratchPath)) {
    return @{ Removed = $false; Withheld = $false; Reason = 'absent' }
  }
  Remove-Item -LiteralPath $ScratchPath -Recurse -Force
  return @{ Removed = $true; Withheld = $false; Reason = 'removed' }
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
  [void]$script:liveChildren.Add($p)
  try { $p.StandardInput.Close() } catch {}
  $timedOut = $false
  $killError = $null
  $reaped = $false
  try { $reaped = $p.WaitForExit($TimeoutMs) } catch { $reaped = $false }
  if (-not $reaped) {
    $timedOut = $true
    try { $p.Kill() } catch { $killError = $_.Exception.Message }
    try { $reaped = $p.WaitForExit(15000) } catch { $reaped = $false }
  }
  $exit = $null
  $stdout = ''
  $stderr = ''
  if ($reaped) {
    # WaitForExit/ HasExited confirmed the child exited: only now is ExitCode and
    # stream draining valid. An ExitCode/stream error is never treated as exit.
    try { $exit = $p.ExitCode } catch { $exit = $null }
    try { $stdout = $p.StandardOutput.ReadToEnd() } catch { $stdout = '' }
    try { $stderr = $p.StandardError.ReadToEnd() } catch { $stderr = '' }
    [void]$script:liveChildren.Remove($p)
    try { $p.Dispose() } catch {}
  }
  return @{ Exit = $exit; TimedOut = $timedOut; Reaped = $reaped; KillError = $killError;
            Stdout = $stdout; Stderr = $stderr }
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

function New-X64Fixture {
  param([string]$Name, [string]$ExeName = 'Fixture.exe')
  $root = Join-Path $scratch $Name
  New-Item -ItemType Directory -Path $root | Out-Null
  $exe = Join-Path $root $ExeName
  $b = New-Object byte[] 1024
  $b[0] = 0x4d; $b[1] = 0x5a
  [BitConverter]::GetBytes([int]128).CopyTo($b, 0x3c)
  $b[128] = 0x50; $b[129] = 0x45
  $b[132] = 0x64; $b[133] = 0x86
  [IO.File]::WriteAllBytes($exe, $b)
  return @{ Root = $root; Exe = $exe; BinDir = $root }
}

function Get-FullMap {
  param([string]$Root)
  $map = @{}
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)) {
    $key = $item.FullName.Substring($Root.Length + 1)
    $value = [string]$item.Attributes
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $value += ':' + ($item.Target -join '|')
    } elseif (-not $item.PSIsContainer) {
      $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
      if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid measured hash: $key" }
      $value += ':' + $hash
    }
    $map[$key] = $value
  }
  return $map
}

function Invoke-GuidedChild {
  param([string[]]$Answers, [string]$JournalRoot, [string]$Arguments = '')
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = '/d /c ""' + $InstallerPath + '" ' + $Arguments + '"'
  $psi.WorkingDirectory = $PackageRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['SUSEMI_TX_JOURNAL_ROOT'] = $JournalRoot
  $psi.EnvironmentVariables.Remove('SUSEMI_RC2_ZIP')
  if ($null -ne $script:PortableOverride) { $psi.EnvironmentVariables['SUSEMI_RC2_ZIP'] = $script:PortableOverride }
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $p.EnableRaisingEvents = $true
  $eventId = 'guided-exit-' + [guid]::NewGuid().ToString('N')
  $subscription = Register-ObjectEvent -InputObject $p -EventName Exited -SourceIdentifier $eventId
  try {
    [void]$p.Start()
    [void]$script:liveChildren.Add($p)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    foreach ($answer in $Answers) { $p.StandardInput.WriteLine($answer) }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($TimeoutMs)) {
      # Kill the owned cmd tree, retaining the native process handle for ExitCode.
      $killInfo = New-Object Diagnostics.ProcessStartInfo
      $killInfo.FileName = 'taskkill.exe'
      $killInfo.Arguments = '/PID ' + $p.Id + ' /T /F'
      $killInfo.UseShellExecute = $false
      $killInfo.CreateNoWindow = $true
      $killer = [Diagnostics.Process]::Start($killInfo)
      if (-not $killer.WaitForExit(15000)) {
        [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-tree' })
        throw 'Owned child tree termination timed out'
      }
      $killExit = $killer.ExitCode
      $killer.Dispose()
      if ($killExit -ne 0 -or -not $p.WaitForExit(15000)) {
        [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-tree' })
        throw 'Owned child tree was not reaped'
      }
      throw 'Guided child exceeded 60000 ms'
    }
    if (-not $stdout.Wait(15000) -or -not $stderr.Wait(15000)) {
      [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-stream-owner' })
      throw 'Owned child streams did not close'
    }
    $result = @{ exit = $p.ExitCode; stdout = $stdout.Result; stderr = $stderr.Result;
                 command = 'cmd.exe ' + $psi.Arguments; pid = $p.Id; reaped = $p.HasExited }
    [void]$script:liveChildren.Remove($p)
    $p.Dispose()
    return $result
  } finally {
    Unregister-Event -SourceIdentifier $eventId
    Remove-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
  }
}

function Invoke-GuidedOpenStdinChild {
  # h1 helper: same ownership/lifecycle rules as Invoke-GuidedChild, but stdin is
  # DELIBERATELY left OPEN after the guided answers are written. A hold that
  # ignored the console condition would block here and hit the 60 s bound (FAIL)
  # instead of being hidden by an EOF. Exited is subscribed BEFORE Start and both
  # async drains are started BEFORE writing answers, so no answer can be lost to
  # a missing reader. Invoke-GuidedChild itself is unchanged.
  param([string[]]$Answers, [string]$JournalRoot, [string]$Arguments = '')
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'
  $psi.Arguments = '/d /c ""' + $InstallerPath + '" ' + $Arguments + '"'
  $psi.WorkingDirectory = $PackageRoot
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['SUSEMI_TX_JOURNAL_ROOT'] = $JournalRoot
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $p.EnableRaisingEvents = $true
  $eventId = 'guided-openstdin-exit-' + [guid]::NewGuid().ToString('N')
  $subscription = Register-ObjectEvent -InputObject $p -EventName Exited -SourceIdentifier $eventId
  try {
    [void]$p.Start()
    [void]$script:liveChildren.Add($p)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    foreach ($answer in $Answers) { $p.StandardInput.WriteLine($answer) }
    # stdin is intentionally NOT closed here: an extra read must time out.
    if (-not $p.WaitForExit($TimeoutMs)) {
      $killInfo = New-Object Diagnostics.ProcessStartInfo
      $killInfo.FileName = 'taskkill.exe'
      $killInfo.Arguments = '/PID ' + $p.Id + ' /T /F'
      $killInfo.UseShellExecute = $false
      $killInfo.CreateNoWindow = $true
      $killer = [Diagnostics.Process]::Start($killInfo)
      if (-not $killer.WaitForExit(15000)) {
        [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-tree' })
        throw 'Open-stdin owned child tree termination timed out'
      }
      $killExit = $killer.ExitCode
      $killer.Dispose()
      if ($killExit -ne 0 -or -not $p.WaitForExit(15000)) {
        [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-tree' })
        throw 'Open-stdin owned child tree was not reaped'
      }
      throw 'Open-stdin child exceeded 60000 ms; an extra stdin read was not tolerated'
    }
    if (-not $stdout.Wait(15000) -or -not $stderr.Wait(15000)) {
      [void]$script:liveChildren.Add(@{ HasExited = $false; Reason = 'unknown-owned-stream-owner' })
      throw 'Open-stdin owned child streams did not close'
    }
    try { $p.StandardInput.Close() } catch { }
    $result = @{ exit = $p.ExitCode; stdout = $stdout.Result; stderr = $stderr.Result;
                 command = 'cmd.exe ' + $psi.Arguments; pid = $p.Id; reaped = $p.HasExited }
    [void]$script:liveChildren.Remove($p)
    $p.Dispose()
    return $result
  } finally {
    Unregister-Event -SourceIdentifier $eventId
    Remove-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
  }
}

function Write-GuidedReceipt {
  param([string]$Name, $Child, [bool]$Pass, $Evidence)
  $script:caseCount++
  if (-not $Pass) { $script:failCount++ }
  [ordered]@{ case = $Name; command = $Child.command; exit = $Child.exit;
    pass = $Pass; stdout = $Child.stdout; stderr = $Child.stderr;
    reaped = $Child.reaped; evidence = $Evidence } | ConvertTo-Json -Depth 20 -Compress | Write-Output
}

function Test-FinalStatus {
  param($Child, [int]$Code, [string]$Status, [string]$Reason)
  $lines = @($Child.stdout -split '\r?\n' | Where-Object { $_ -match '^status=' })
  return ($Child.exit -eq $Code -and $lines.Count -eq 1 -and
    $lines[0] -eq "status=$Status reason=$Reason" -and [string]::IsNullOrWhiteSpace($Child.stderr))
}

function Get-AstExpression {
  # Unwrap the PipelineAst/CommandExpressionAst wrapper the parser puts around a
  # hashtable-entry value, returning the inner expression AST.
  param($Node)
  $v = $Node
  if ($v -is [Management.Automation.Language.PipelineAst] -and $v.PipelineElements.Count -eq 1) { $v = $v.PipelineElements[0] }
  if ($v -is [Management.Automation.Language.CommandExpressionAst]) { $v = $v.Expression }
  return $v
}

function Get-MessageValue {
  # Actual $Messages dictionary lookup via AST: returns the localized value for
  # Lang/Key, or $null. Lets hold tests read the shipped strings instead of
  # pinning prompt prose in the test file.
  param($Ast, [string]$Lang, [string]$Key)
  $assign = $Ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'Messages' }, $true)
  if ($null -eq $assign) { return $null }
  $outer = Get-AstExpression -Node $assign.Right
  if ($outer -isnot [Management.Automation.Language.HashtableAst]) { return $null }
  foreach ($kv in $outer.KeyValuePairs) {
    $k = $null; try { $k = [string](Get-AstExpression -Node $kv.Item1).SafeGetValue() } catch { }
    if ($k -ne $Lang) { continue }
    $inner = Get-AstExpression -Node $kv.Item2
    if ($inner -isnot [Management.Automation.Language.HashtableAst]) { return $null }
    foreach ($ikv in $inner.KeyValuePairs) {
      $ik = $null; try { $ik = [string](Get-AstExpression -Node $ikv.Item1).SafeGetValue() } catch { }
      if ($ik -eq $Key) { try { return [string](Get-AstExpression -Node $ikv.Item2).SafeGetValue() } catch { return $null } }
    }
  }
  return $null
}

function Get-SoleStatusLine {
  param($Child)
  return @($Child.stdout -split '\r?\n' | Where-Object { $_ -match '^status=' })[0]
}

function Test-NoHoldLine {
  # True when neither actual (AST-parsed) localized hold prompt appears as a
  # standalone output line. The compared strings come from the coordinator's own
  # dictionaries, so no prompt prose is pinned here.
  param($Child, [string[]]$HoldTexts)
  $lines = @($Child.stdout -split '\r?\n')
  foreach ($h in @($HoldTexts)) {
    if (-not [string]::IsNullOrWhiteSpace($h) -and ($lines -contains $h)) { return $false }
  }
  return $true
}

function Get-HintMarkers {
  # Exact advisory machine-marker count on stdout (machine value, not prose).
  param($Child)
  return @($Child.stdout -split '\r?\n' | Where-Object { $_ -eq 'hint| game=gtav-enhanced source=user' }).Count
}

function Get-MessageRaw {
  # AST $Messages lookup returning the RAW localized value (string or array) so
  # array-valued guidance can be reviewed element-by-element.
  param($Ast, [string]$Lang, [string]$Key)
  $assign = $Ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'Messages' }, $true)
  if ($null -eq $assign) { return $null }
  $outer = Get-AstExpression -Node $assign.Right
  if ($outer -isnot [Management.Automation.Language.HashtableAst]) { return $null }
  foreach ($kv in $outer.KeyValuePairs) {
    $k = $null; try { $k = [string](Get-AstExpression -Node $kv.Item1).SafeGetValue() } catch { }
    if ($k -ne $Lang) { continue }
    $inner = Get-AstExpression -Node $kv.Item2
    if ($inner -isnot [Management.Automation.Language.HashtableAst]) { return $null }
    foreach ($ikv in $inner.KeyValuePairs) {
      $ik = $null; try { $ik = [string](Get-AstExpression -Node $ikv.Item1).SafeGetValue() } catch { }
      if ($ik -eq $Key) { try { return (Get-AstExpression -Node $ikv.Item2).SafeGetValue() } catch { return $null } }
    }
  }
  return $null
}

function Invoke-HoldEpilogueCases {
  $tokens = $null; $errors = $null
  $coordinator = Join-Path $PackageRoot 'tools/susemi_installer.ps1'
  $ast = [Management.Automation.Language.Parser]::ParseFile($coordinator, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw 'Coordinator parse errors' }

  # h3 - the actual ko/en dictionaries must define a NONEMPTY HoldPrompt.
  $ko = Get-MessageValue -Ast $ast -Lang 'ko' -Key 'HoldPrompt'
  $en = Get-MessageValue -Ast $ast -Lang 'en' -Key 'HoldPrompt'
  $holdTexts = @([string]$ko, [string]$en)
  $h3 = (-not [string]::IsNullOrWhiteSpace($ko)) -and (-not [string]::IsNullOrWhiteSpace($en))
  Write-GuidedReceipt 'h3-holdprompt-keys' @{ command = 'AST $Messages HoldPrompt'; exit = 0; stdout = ''; stderr = ''; reaped = $true } $h3 @{ ko = $ko; en = $en }

  # h2 - real BAT argument modes: same status/code and no hold line.
  $fx = New-X64Fixture 'hold-arg-install-no'
  $journal = Join-Path $scratch 'hold-arg-install-no-journals'
  New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ('install -Exe "' + $fx.Exe + '" -Consent no -Lang en')
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $pass = (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja) -and (Test-NoHoldLine $r $holdTexts)
  Write-GuidedReceipt 'h2-arg-install-no' $r $pass @{ before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  $fx = New-X64Fixture 'hold-arg-remove-no'
  $journal = Join-Path $scratch 'hold-arg-remove-no-journals'
  New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ('remove -Exe "' + $fx.Exe + '" -Consent no -Lang en')
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $pass = (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja) -and (Test-NoHoldLine $r $holdTexts)
  Write-GuidedReceipt 'h2-arg-remove-no' $r $pass @{ before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  $readyRoot = Join-Path $PackageRoot 'tests/installer_fixtures/preflight/F1-ready'
  $readyExe = Join-Path $readyRoot 'GameA/bin64/GameA.exe'
  if (-not (Test-Path -LiteralPath $readyExe -PathType Leaf)) { throw 'Missing pinned ready fixture GameA.exe' }
  $journal = Join-Path $scratch 'hold-arg-diagnose-journals'
  New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $readyRoot
  $r = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ('diagnose -Exe "' + $readyExe + '" -Lang en')
  $after = Get-FullMap $readyRoot
  $pass = (Test-FinalStatus $r 0 'ready' 'ready') -and (Test-SameSnapshot $before $after) -and (Test-NoHoldLine $r $holdTexts)
  Write-GuidedReceipt 'h2-arg-diagnose-ready' $r $pass @{ before = $before; after = $after }

  # h1 - guided session with stdin kept OPEN must still exit within the bound with
  # the SAME machine status/code as the closed-stdin (EOF) path.
  $fxOpen = New-X64Fixture 'hold-open-stdin'
  $fxEof = New-X64Fixture 'hold-eof-stdin'
  $jOpen = Join-Path $scratch 'hold-open-stdin-journals'; New-Item -ItemType Directory -Path $jOpen | Out-Null
  $jEof = Join-Path $scratch 'hold-eof-stdin-journals'; New-Item -ItemType Directory -Path $jEof | Out-Null
  $beforeOpen = Get-FullMap $fxOpen.Root
  $rEof = Invoke-GuidedChild -Answers @('2', $fxEof.Exe, '1') -JournalRoot $jEof
  $rOpen = $null; $openErr = $null
  try { $rOpen = Invoke-GuidedOpenStdinChild -Answers @('2', $fxOpen.Exe, '1', '1') -JournalRoot $jOpen } catch { $openErr = $_.Exception.Message }
  if ($null -eq $rOpen) {
    Write-GuidedReceipt 'h1-open-stdin-guided' @{ command = 'cmd open-stdin guided'; exit = $null; stdout = ''; stderr = [string]$openErr; reaped = $false } $false @{ failure = $openErr; eofExit = $rEof.exit }
  } else {
    $afterOpen = Get-FullMap $fxOpen.Root
    $openStatus = Get-SoleStatusLine $rOpen
    $eofStatus = Get-SoleStatusLine $rEof
    $pass = (Test-FinalStatus $rOpen 1 'refused' 'consent-required') -and (Test-FinalStatus $rEof 1 'refused' 'consent-required') -and ($openStatus -eq $eofStatus) -and (Test-SameSnapshot $beforeOpen $afterOpen) -and (Test-NoHoldLine $rOpen $holdTexts)
    Write-GuidedReceipt 'h1-open-stdin-guided' $rOpen $pass @{ eofExit = $rEof.exit; eofStatus = $eofStatus; openStatus = $openStatus; before = $beforeOpen; after = $afterOpen; eofStdout = $rEof.stdout }
  }

  # h1b - argument mode with stdin kept OPEN must not hold either.
  $jArg = Join-Path $scratch 'hold-open-stdin-arg-journals'; New-Item -ItemType Directory -Path $jArg | Out-Null
  $rOpenArg = $null; $openArgErr = $null
  try { $rOpenArg = Invoke-GuidedOpenStdinChild -Answers @() -JournalRoot $jArg -Arguments ('diagnose -Exe "' + $readyExe + '" -Lang en') } catch { $openArgErr = $_.Exception.Message }
  if ($null -eq $rOpenArg) {
    Write-GuidedReceipt 'h1-open-stdin-argmode' @{ command = 'cmd open-stdin diagnose'; exit = $null; stdout = ''; stderr = [string]$openArgErr; reaped = $false } $false @{ failure = $openArgErr }
  } else {
    $pass = (Test-FinalStatus $rOpenArg 0 'ready' 'ready') -and (Test-NoHoldLine $rOpenArg $holdTexts)
    Write-GuidedReceipt 'h1-open-stdin-argmode' $rOpenArg $pass @{ status = (Get-SoleStatusLine $rOpenArg) }
  }

  # h4 - actual AST-extracted pure eligibility function, its production wiring,
  # and the truth table. No production seam/override is used.
  $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-SessionHoldEligible' }, $true)
  $holdCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-SessionHoldEligible' }, $true))
  $readCalls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-SessionHold' }, $true))
  $noArg = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -gt 0 -and $n.Clauses[0].Item1.Extent.Text -eq '$argv.Count -eq 0' }, $true)
  $wired = $false
  if ($null -ne $noArg) {
    $exitStmt = $noArg.Find({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true)
    foreach ($c in $holdCalls) {
      if ($c.Extent.StartOffset -gt $noArg.Extent.StartOffset -and $c.Extent.EndOffset -lt $noArg.Extent.EndOffset -and $null -ne $exitStmt -and $c.Extent.StartOffset -lt $exitStmt.Extent.StartOffset) { $wired = $true }
    }
    $wired = $wired -and ($holdCalls.Count -eq 1) -and ($readCalls.Count -eq 1)
  }
  if ($null -eq $fn) {
    Write-GuidedReceipt 'h4-hold-eligibility-truth' @{ command = 'AST Test-SessionHoldEligible'; exit = 0; stdout = ''; stderr = 'missing function'; reaped = $true } $false @{ missing = 'Test-SessionHoldEligible' }
  } else {
    . ([scriptblock]::Create($fn.Extent.Text))
    $defaults = @()
    $pb = $fn.Body.ParamBlock
    if ($null -ne $pb) { foreach ($pm in $pb.Parameters) { if ($null -ne $pm.DefaultValue) { $defaults += $pm.DefaultValue.Extent.Text } } }
    $defaultText = ($defaults -join ' ')
    $reuse = ($defaultText -match 'Test-InteractiveInputAvailable') -and ($defaultText -match 'Test-InstallProgressConsole')
    $noOverride = -not ($fn.Extent.Text -match '\$env:')
    $truth = @(
      @{ name = 'guided-usable-consolehost'; got = [bool](Test-SessionHoldEligible -Guided -InputAvailable $true -OutputAvailable $true); want = $true },
      @{ name = 'input-redirected'; got = [bool](Test-SessionHoldEligible -Guided -InputAvailable $false -OutputAvailable $true); want = $false },
      @{ name = 'output-redirected'; got = [bool](Test-SessionHoldEligible -Guided -InputAvailable $true -OutputAvailable $false); want = $false },
      @{ name = 'null-or-unusable-host'; got = [bool](Test-SessionHoldEligible -Guided -InputAvailable $false -OutputAvailable $false); want = $false },
      @{ name = 'argument-mode'; got = [bool](Test-SessionHoldEligible -InputAvailable $true -OutputAvailable $true); want = $false }
    )
    $mismatch = @($truth | Where-Object { $_.got -ne $_.want })
    $pass = $wired -and $reuse -and $noOverride -and ($mismatch.Count -eq 0)
    Write-GuidedReceipt 'h4-hold-eligibility-truth' @{ command = 'AST Test-SessionHoldEligible truth table'; exit = 0; stdout = ''; stderr = ''; reaped = $true } $pass @{ wired = $wired; reuse = $reuse; noEnvOverride = $noOverride; defaults = $defaults; truth = $truth; holdCalls = $holdCalls.Count; readCalls = $readCalls.Count }
  }
}

function Invoke-GuidedSafetyCases {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot 'tools/susemi_installer.ps1'), [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw 'Coordinator parse errors' }
  foreach ($name in @('Get-PeValid', 'Get-DiagnosisContext', 'Test-GuidedInstallEligible')) {
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "Missing actual function: $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
  }
  $ual = Join-Path $PackageRoot 'tests/installer_fixtures/preflight/F1-ready/GameA/bin64/winmm.dll'
  $core = Join-Path $PackageRoot 'tests/installer_fixtures/preflight/F1-ready/GameA/bin64/OptiScaler.asi'
  if ((Get-FileHash -LiteralPath $ual).Hash -ine 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7' -or
      (Get-FileHash -LiteralPath $core).Hash -ine '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60') { throw 'Fixture source pins mismatch' }
  foreach ($name in @('bare-no', 'bare-eof', 'bare-invalid', 'unknown-winmm', 'unknown-opti', 'unknown-both', 'directory-winmm', 'directory-opti', 'link-winmm', 'dangling-opti', 'non-winmm', 'non-winmm-ready', 'ready-winmm-no')) {
    $fx = New-X64Fixture $name
    switch ($name) {
      'unknown-winmm' { [IO.File]::WriteAllText((Join-Path $fx.Root 'winmm.dll'), 'unknown') }
      'unknown-opti' { [IO.File]::WriteAllText((Join-Path $fx.Root 'OptiScaler.asi'), 'unknown') }
      'unknown-both' {
        [IO.File]::WriteAllText((Join-Path $fx.Root 'winmm.dll'), 'unknown')
        [IO.File]::WriteAllText((Join-Path $fx.Root 'OptiScaler.asi'), 'unknown')
      }
      'directory-winmm' { New-Item -ItemType Directory -Path (Join-Path $fx.Root 'winmm.dll') | Out-Null }
      'directory-opti' { New-Item -ItemType Directory -Path (Join-Path $fx.Root 'OptiScaler.asi') | Out-Null }
      'link-winmm' {
        # Junctions require no symlink privilege and exercise ReparsePoint.
        $target = Join-Path $scratch 'live-link-destination'
        New-Item -ItemType Directory -Path $target | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $fx.Root 'winmm.dll') -Target $target | Out-Null
      }
      'dangling-opti' {
        $target = Join-Path $scratch 'link-destination'
        New-Item -ItemType Directory -Path $target | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $fx.Root 'OptiScaler.asi') -Target $target | Out-Null
        Remove-Item -LiteralPath $target -Force
      }
      'non-winmm' { Copy-Item -LiteralPath $ual -Destination (Join-Path $fx.Root 'dinput8.dll') }
      'non-winmm-ready' {
        Copy-Item -LiteralPath $ual -Destination (Join-Path $fx.Root 'dinput8.dll')
        Copy-Item -LiteralPath $fx.Exe -Destination (Join-Path $fx.Root 'ReShade.asi')
        [IO.File]::WriteAllText((Join-Path $fx.Root 'dinput8.ini'), "[globalsets]`r`nloadextraplugins=ReShade.asi`r`n")
      }
      'ready-winmm-no' {
        Copy-Item -LiteralPath $ual -Destination (Join-Path $fx.Root 'winmm.dll')
        Copy-Item -LiteralPath $fx.Exe -Destination (Join-Path $fx.Root 'ReShade.asi')
        [IO.File]::WriteAllText((Join-Path $fx.Root 'winmm.ini'), "[globalsets]`r`nloadextraplugins=ReShade.asi`r`n")
      }
    }
    $journal = Join-Path $scratch ($name + '-journals')
    New-Item -ItemType Directory -Path $journal | Out-Null
    $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
    # Advisory choice inserted where the guided selector occurs; bare-eof keeps
    # its stdin CLOSED so the advisory/consent reads exercise real EOF.
    $answers = @('2', $fx.Exe, '1', '1')
    if ($name -eq 'bare-eof') { $answers = @('2', $fx.Exe) }
    if ($name -eq 'bare-invalid') { $answers = @('2', $fx.Exe, '1', 'not-consent') }
    $r = Invoke-GuidedChild -Answers $answers -JournalRoot $journal
    $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
    $status = 'refused'; $reason = 'guided-target-conflict'
    if ($name -like 'bare-*' -or $name -eq 'ready-winmm-no') { $reason = 'consent-required' }
    if ($name -eq 'non-winmm') { $status = 'unsupported'; $reason = 'unsupported-state' }
    if ($name -eq 'non-winmm-ready') { $status = 'ready'; $reason = 'ready' }
    $pass = (Test-FinalStatus $r 1 $status $reason) -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja) -and ((Get-HintMarkers $r) -eq 0)
    Write-GuidedReceipt $name $r $pass @{ before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }
  }
  # Real pinned install/remove; the pseudo executable is never launched.
  $fx = New-X64Fixture 'bare-yes'
  $journal = Join-Path $scratch 'happy-journals'
  New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root
  # i6: the full g4 guided install still passes with the default-Other advisory
  # choice inserted before consent.
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe, '1', '2') -JournalRoot $journal
  $installed = Get-FullMap $fx.Root
  $journals = Get-FullMap $journal
  $phases = @(Get-ChildItem -LiteralPath $journal -File | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).phase })
  $pins = @{}
  foreach ($file in @('winmm.dll', 'OptiScaler.asi')) {
    $path = Join-Path $fx.Root $file
    if (Test-Path -LiteralPath $path -PathType Leaf) { $pins[$file] = (Get-FileHash -LiteralPath $path -ErrorAction Stop).Hash }
  }
  $pass = (Test-FinalStatus $r 0 'installed' 'ok') -and $phases -contains 'applied' -and
    $pins['winmm.dll'] -ieq 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7' -and
    $pins['OptiScaler.asi'] -ieq '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60' -and
    ((Get-HintMarkers $r) -eq 0)
  $journalRecords = @{}
  foreach ($file in @(Get-ChildItem -LiteralPath $journal -File)) { $journalRecords[$file.Name] = [IO.File]::ReadAllText($file.FullName) }
  Write-GuidedReceipt 'bare-yes' $r $pass @{ before = $before; installed = $installed; journals = $journals; journalRecords = $journalRecords; phases = $phases; pins = $pins }
  $remove = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ('remove -Exe "' + $fx.Exe + '" -Consent yes -Lang en')
  $restored = Get-FullMap $fx.Root
  $applied = @(Get-ChildItem -LiteralPath $journal -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.ops })
  $removeReason = 'opcount-' + @($applied[0].ops).Count
  $pass = (Test-FinalStatus $remove 0 'removed' $removeReason) -and (Test-SameSnapshot $before $restored)
  $journalRecords = @{}
  foreach ($file in @(Get-ChildItem -LiteralPath $journal -File)) { $journalRecords[$file.Name] = [IO.File]::ReadAllText($file.FullName) }
  Write-GuidedReceipt 'happy-remove' $remove $pass @{ original = $before; restored = $restored; journals = (Get-FullMap $journal); journalRecords = $journalRecords }

  # Actual function AST, fresh real diagnoses before/after repeated changes.
  $fx = New-X64Fixture 'post-consent'
  $beforeCtx = Get-DiagnosisContext -Exe $fx.Exe -Lang en -M @{}
  $beforeGate = Test-GuidedInstallEligible $beforeCtx
  foreach ($target in @('winmm.dll', 'OptiScaler.asi')) {
    [IO.File]::WriteAllText((Join-Path $fx.Root $target), 'new target after consent')
    $afterCtx = Get-DiagnosisContext -Exe $fx.Exe -Lang en -M @{}
    $afterGate = Test-GuidedInstallEligible $afterCtx
    $r = @{ command = 'AST actual Test-GuidedInstallEligible with real diagnosis'; exit = 0; stdout = ''; stderr = ''; reaped = $true }
    $pass = $beforeGate.eligible -and -not $afterGate.eligible -and $afterGate.conflict
    Write-GuidedReceipt ('post-consent-' + $target) $r $pass @{ beforeGate = $beforeGate; afterGate = $afterGate; beforeReason = $beforeCtx.reason; afterReason = $afterCtx.reason; after = (Get-FullMap $fx.Root) }
    Remove-Item -LiteralPath (Join-Path $fx.Root $target)
    $beforeCtx = Get-DiagnosisContext -Exe $fx.Exe -Lang en -M @{}
    $beforeGate = Test-GuidedInstallEligible $beforeCtx
  }
}

function Invoke-AdvisoryCases {
  # Checkbox 3 - explicit guided GTA5E advisory. Machine assertions only: the
  # exact marker, final status/code, fixture and journal maps. Caution wording is
  # reviewed through the dictionaries, never pinned as prose.
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot 'tools/susemi_installer.ps1'), [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw 'Coordinator parse errors' }

  # Localized keys exist and are nonempty in ko AND en (dictionary review).
  $askKo = Get-MessageValue -Ast $ast -Lang 'ko' -Key 'AdvisoryAsk'
  $askEn = Get-MessageValue -Ast $ast -Lang 'en' -Key 'AdvisoryAsk'
  $cauKo = @(Get-MessageRaw -Ast $ast -Lang 'ko' -Key 'AdvisoryGtavEnhanced')
  $cauEn = @(Get-MessageRaw -Ast $ast -Lang 'en' -Key 'AdvisoryGtavEnhanced')
  $keysOk = (-not [string]::IsNullOrWhiteSpace($askKo)) -and (-not [string]::IsNullOrWhiteSpace($askEn)) -and
    ($cauKo.Count -gt 1) -and ($cauEn.Count -gt 1) -and
    (@($cauKo | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) -and
    (@($cauEn | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0)
  Write-GuidedReceipt 'i-keys-nonempty-ko-en' @{ command = 'AST $Messages AdvisoryAsk/AdvisoryGtavEnhanced'; exit = 0; stdout = ''; stderr = ''; reaped = $true } $keysOk @{ askKo = $askKo; askEn = $askEn; cautionKoLines = $cauKo.Count; cautionEnLines = $cauEn.Count }

  # i1 - explicit [2] GTA V Enhanced: exactly one marker, refusal, zero writes.
  $fx = New-X64Fixture 'advisory-gtav'
  $journal = Join-Path $scratch 'advisory-gtav-journals'; New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe, '2', '1') -JournalRoot $journal
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $markers = Get-HintMarkers $r
  $pass = ($markers -eq 1) -and (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
  Write-GuidedReceipt 'i1-gtav-enhanced-marker' $r $pass @{ markers = $markers; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  # i2 - Other: zero markers, same safe refusal.
  $fx = New-X64Fixture 'advisory-other'
  $journal = Join-Path $scratch 'advisory-other-journals'; New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe, '1', '1') -JournalRoot $journal
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $markers = Get-HintMarkers $r
  $pass = ($markers -eq 0) -and (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
  Write-GuidedReceipt 'i2-other-silent' $r $pass @{ markers = $markers; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  # i3a - EOF at the advisory/consent prompts: default Other, real EOF.
  $fx = New-X64Fixture 'advisory-eof'
  $journal = Join-Path $scratch 'advisory-eof-journals'; New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe) -JournalRoot $journal
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $markers = Get-HintMarkers $r
  $pass = ($markers -eq 0) -and (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
  Write-GuidedReceipt 'i3-eof-default-other' $r $pass @{ markers = $markers; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  # i3b - invalid advisory answer: default Other, zero markers.
  $fx = New-X64Fixture 'advisory-invalid'
  $journal = Join-Path $scratch 'advisory-invalid-journals'; New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe, 'not-a-game', '1') -JournalRoot $journal
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $markers = Get-HintMarkers $r
  $pass = ($markers -eq 0) -and (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
  Write-GuidedReceipt 'i3-invalid-default-other' $r $pass @{ markers = $markers; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  # i4 - file NAMED GTA5_Enhanced.exe + Other: no automatic game claim.
  $fx = New-X64Fixture 'advisory-misleading' 'GTA5_Enhanced.exe'
  $journal = Join-Path $scratch 'advisory-misleading-journals'; New-Item -ItemType Directory -Path $journal | Out-Null
  $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
  $r = Invoke-GuidedChild -Answers @('2', $fx.Exe, '1', '1') -JournalRoot $journal
  $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
  $markers = Get-HintMarkers $r
  $pass = ($markers -eq 0) -and (Test-FinalStatus $r 1 'refused' 'consent-required') -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
  Write-GuidedReceipt 'i4-misleading-filename-other' $r $pass @{ markers = $markers; exeName = (Split-Path -Leaf $fx.Exe); before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }

  # i5 - argument modes: silent, zero markers, no extra input, no mutation.
  foreach ($spec in @(
      @{ name = 'i5-arg-diagnose'; args = 'diagnose -Exe "{0}" -Lang en'; status = 'missing-input'; reason = 'no-loader-or-optiscaler'; code = 1 },
      @{ name = 'i5-arg-install-no'; args = 'install -Exe "{0}" -Consent no -Lang en'; status = 'refused'; reason = 'consent-required'; code = 1 },
      @{ name = 'i5-arg-remove-no'; args = 'remove -Exe "{0}" -Consent no -Lang en'; status = 'refused'; reason = 'consent-required'; code = 1 }
    )) {
    $fx = New-X64Fixture $spec.name
    $journal = Join-Path $scratch ($spec.name + '-journals'); New-Item -ItemType Directory -Path $journal | Out-Null
    $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal
    $r = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ($spec.args -f $fx.Exe)
    $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal
    $markers = Get-HintMarkers $r
    $pass = ($markers -eq 0) -and (Test-FinalStatus $r $spec.code $spec.status $spec.reason) -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja)
    Write-GuidedReceipt $spec.name $r $pass @{ markers = $markers; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja }
  }

  # i6 is the modified g4 case (bare-yes + happy-remove): the full guided
  # install/remove still passes with the default-Other advisory choice inserted
  # before consent.
}

function Invoke-PortableSourceCases {
  $sourceRoot = $PackageRoot
  $corePin = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
  $ualPin = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
  $ualRel = 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
  $archive = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
  if ((Get-FileHash -LiteralPath $archive).Hash -ine '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a') { throw 'Explicit ZIP prerequisite pin mismatch' }
  foreach ($name in @('p1-unset', 'p1-empty', 'p2-missing-core', 'p2-missing-ual', 'p3-corrupt-core', 'p3-corrupt-ual', 'p3-unreadable-core', 'p3-unreadable-ual', 'p4-absent-zip', 'p4-corrupt-zip', 'p4-directory-zip', 'p5-pinned-zip')) {
    $PackageRoot = Join-Path $scratch ($name + '-package')
    New-Item -ItemType Directory -Path $PackageRoot | Out-Null
    foreach ($rel in @('Install_OptiScaler_windows.bat', 'setup_windows.bat', 'tools/susemi_installer.ps1', 'tools/susemi_transaction.ps1', 'tools/susemi_stage_helpers.ps1', 'OptiScaler.dll', $ualRel)) {
      $dest = Join-Path $PackageRoot $rel
      New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
      Copy-Item -LiteralPath (Join-Path $sourceRoot $rel) -Destination $dest
    }
    $InstallerPath = Join-Path $PackageRoot 'Install_OptiScaler_windows.bat'
    $script:PortableOverride = $null
    if ($name -eq 'p1-empty') { $script:PortableOverride = '' }
    $member = Join-Path $PackageRoot 'OptiScaler.dll'
    if ($name -like '*-ual') { $member = Join-Path $PackageRoot $ualRel }
    if ($name -like 'p2-*') { Remove-Item -LiteralPath $member }
    if ($name -like 'p3-corrupt-*') { [IO.File]::WriteAllText($member, 'corrupt') }
    if ($name -eq 'p4-absent-zip') {
      $script:PortableOverride = Join-Path $PackageRoot 'absent.zip'
      if (Test-Path -LiteralPath $script:PortableOverride) { throw 'Absent override is not absent' }
    }
    if ($name -eq 'p4-corrupt-zip') {
      $script:PortableOverride = Join-Path $PackageRoot 'corrupt.zip'
      [IO.File]::WriteAllText($script:PortableOverride, 'corrupt')
    }
    if ($name -eq 'p4-directory-zip') { $script:PortableOverride = $PackageRoot }
    if ($name -eq 'p5-pinned-zip') { $script:PortableOverride = $archive }
    $fx = New-X64Fixture $name
    $journal = Join-Path $scratch ($name + '-journals')
    New-Item -ItemType Directory -Path $journal | Out-Null
    $before = Get-FullMap $fx.Root; $jb = Get-FullMap $journal; $pb = Get-FullMap $PackageRoot
    $lock = $null
    try {
      if ($name -like 'p3-unreadable-*') { $lock = [IO.File]::Open($member, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
      $language = '2'; if ($name -eq 'p1-empty' -or $name -eq 'p2-missing-ual' -or $name -eq 'p3-corrupt-ual') { $language = '1' }
      $r = Invoke-GuidedChild -Answers @($language, $fx.Exe, '1', '2') -JournalRoot $journal
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
    $after = Get-FullMap $fx.Root; $ja = Get-FullMap $journal; $pa = Get-FullMap $PackageRoot
    $mode = 'directory'; if ($name -like 'p4-*' -or $name -like 'p5-*') { $mode = 'zip' }
    $sourceProof = $r.stdout.Contains('trace| source=directory root=' + $PackageRoot)
    if ($mode -eq 'zip') { $sourceProof = $r.stdout.Contains('trace| source=zip path=' + $script:PortableOverride) -and -not $r.stdout.Contains('trace| source=directory') }
    $positive = $name -like 'p1-*' -or $name -like 'p5-*'
    if (-not $positive) {
      $reason = 'package-payload-sha-mismatch'
      if ($name -like 'p2-*') { $reason = 'package-payload-missing' }
      if ($name -eq 'p4-absent-zip' -or $name -eq 'p4-directory-zip') { $reason = 'rc2-zip-absent' }
      if ($name -eq 'p4-corrupt-zip') { $reason = 'rc2-zip-sha-mismatch' }
      $pass = (Test-FinalStatus $r 1 'refused' $reason) -and $sourceProof -and (Test-SameSnapshot $before $after) -and (Test-SameSnapshot $jb $ja) -and (Test-SameSnapshot $pb $pa)
      Write-GuidedReceipt $name $r $pass @{ sourceMode = $mode; override = $script:PortableOverride; before = $before; after = $after; journalsBefore = $jb; journalsAfter = $ja; packageBefore = $pb; packageAfter = $pa }
    } else {
      $files = @(Get-ChildItem -LiteralPath $journal -File -Filter '*.json')
      if ($files.Count -ne 1) { throw 'Expected exactly one private transaction journal' }
      $raw = [IO.File]::ReadAllText($files[0].FullName); $applied = $raw | ConvertFrom-Json
      $stagePins = @{}
      foreach ($op in $applied.ops) { $stagePins[$op.target] = $op.sourceSha }
      $pass = (Test-FinalStatus $r 0 'installed' 'ok') -and $sourceProof -and ($applied.phase -eq 'applied') -and (@($applied.ops).Count -eq 2) -and
        (@($applied.ops | Where-Object { $_.beforeExists -or $_.sourceSha -notin @($corePin, $ualPin) }).Count -eq 0) -and
        ((Get-FileHash -LiteralPath (Join-Path $fx.Root 'OptiScaler.asi')).Hash -ieq $corePin) -and ((Get-FileHash -LiteralPath (Join-Path $fx.Root 'winmm.dll')).Hash -ieq $ualPin) -and
        $r.stdout.Contains('trace| staged-core-sha=' + $corePin + ' staged-ual-sha=' + $ualPin) -and (Test-SameSnapshot $pb $pa)
      Write-GuidedReceipt $name $r $pass @{ sourceMode = $mode; override = $script:PortableOverride; before = $before; installed = $after; journals = $ja; journalRaw = $raw; stagePins = $stagePins; packageBefore = $pb; packageAfter = $pa }
      $remove = Invoke-GuidedChild -Answers @() -JournalRoot $journal -Arguments ('remove -Exe "' + $fx.Exe + '" -Consent yes -Lang en')
      $recoveredRaw = [IO.File]::ReadAllText($files[0].FullName); $recovered = $recoveredRaw | ConvertFrom-Json
      $restored = Get-FullMap $fx.Root
      $pass = (Test-FinalStatus $remove 0 'removed' 'opcount-2') -and ($recovered.phase -eq 'recovered') -and ($recovered.txid -eq $applied.txid) -and (Test-SameSnapshot $before $restored)
      Write-GuidedReceipt ($name + '-remove') $remove $pass @{ original = $before; restored = $restored; journalRaw = $recoveredRaw; journals = (Get-FullMap $journal); stagedDir = $applied.staged_dir; stageAbsent = -not (Test-Path -LiteralPath $applied.staged_dir) }
    }
  }
  $script:PortableOverride = $null
}

# All case execution and reporting run inside try/finally so this invocation's
# generated run-GUID scratch is removed on every exit path: normal result,
# assertion failure, bounded child failure (timeout-kill), or unexpected
# exception. Teardown runs only after every spawned child has exited or been
# killed, and it removes ONLY this invocation's directory (see finally below).
try {

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

if ($launcherExists) { Invoke-GuidedSafetyCases }
if ($launcherExists) { Invoke-AdvisoryCases }
if ($launcherExists) { Invoke-HoldEpilogueCases }
if ($launcherExists) { Invoke-PortableSourceCases }

$passed = $script:caseCount - $script:failCount
Write-Output ("SUMMARY pass={0}/{1} launcherExists={2} scratch={3}" -f $passed, $script:caseCount, $launcherExists, $scratch)
if (-not $launcherExists) { $script:exitCode = 3 }
elseif ($script:failCount -gt 0) { $script:exitCode = 1 }
else { $script:exitCode = 0 }
} finally {
  # Teardown runs only after every invocation-owned child is reaped. If any
  # owned child is still unreaped the scratch is intentionally left intact and a
  # nonzero error receipt is emitted instead of claiming a clean removal.
  $teardown = Remove-OwnedScratch -ScratchPath $scratch -ExpectedLeaf "run-$runId" -Children @($script:liveChildren)
  if ($teardown.Withheld) {
    $script:exitCode = 4
    [Console]::Error.WriteLine(("CLEANUP-WITHHELD reason={0} scratch={1} liveChildren={2}" -f $teardown.Reason, $scratch, @($script:liveChildren).Count))
  }
}
exit $script:exitCode
