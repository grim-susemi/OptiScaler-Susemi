#Requires -Version 5.1
<#
.SYNOPSIS
  susemi_transaction.ps1 — file-transaction engine for OptiScaler installs.

  ACTIONS:
    plan      [-GameDir <dir>] [-StagedDir <dir>] [-Route asi|proxy] [-ProxyName <dll>]
              [-IncludeUal] [-StagedUalPath <path>] [-JournalRoot <dir>]
              [-ExtraJson <path>]

  -ExtraJson appends caller-supplied ops (JSON array of {"target","source"}) to the
  plan, after the route/UAL ops, so they are journaled LAST. An extra op's target
  must be inside GameDir and unique; op type (create/replace) is derived from the
  live target exactly like the built-in ops, and prepare/apply/recover/rollback
  treat them identically (byte-exact preimage backup, restore or delete).
    prepare   -Journal <path>
    apply     -Journal <path> [-RaceProbe <path>]
    recover   -Journal <path>
    rollback  -Journal <path>

  EXIT CODES: 0 = success, 1 = refused/failed, 2 = invalid-invocation.
#>

$ErrorActionPreference = 'Stop'

# ── Helpers ────────────────────────────────────────────────────────────────

function Get-SHA256 {
  param([string]$FilePath)
  if (-not (Test-Path -Path $FilePath)) { return '' }
  try {
    $item = Get-Item -Path $FilePath
    if ($item.PSIsContainer) { return '' }
    return (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
  } catch {
    return ''
  }
}

function Write-StatusLine {
  param(
    [string]$Status,
    [string]$Reason,
    [string]$Human
  )
  Write-Output ('status={0} reason={1}' -f $Status, $Reason)
  if (-not [string]::IsNullOrEmpty($Human)) {
    Write-Output $Human
  }
}

function New-TxId {
  return ([System.Guid]::NewGuid().ToString('N'))
}

function Atomic-JournalWrite {
  # Writes journal data to targetPath via temp+rename. Returns bool.
  param(
    [string]$TargetPath,
    [object]$JournalData
  )
  try {
    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -Path $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    $tmpPath = $TargetPath + '.susemi-tmp-journal'
    $json = $JournalData | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpPath -Destination $TargetPath -Force -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Load-Journal {
  param([string]$Path)
  if (-not (Test-Path -Path $Path)) { return $null }
  try {
    $raw = [System.IO.File]::ReadAllText($Path)
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-BelongsToBase {
  param(
    [string]$Candidate,
    [string]$Base
  )
  $absBase = [System.IO.Path]::GetFullPath($Base).TrimEnd('\').TrimEnd('/')
  $absCand = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\').TrimEnd('/')
  if ($absCand.Contains('..') -or $absBase.Contains('..')) { return $false }
  # Invariant: candidate must be INSIDE base, so a sibling directory whose name
  # merely starts with the base name (e.g. 'game-evil' vs 'game') must be rejected.
  # Enforce a separator boundary before the prefix comparison.
  $baseWithSep = $absBase + '\'
  if (-not $absCand.StartsWith($baseWithSep, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  return $true
}

function Test-NotReparseDir {
  param([string]$DirPath)
  if (-not (Test-Path -Path $DirPath -PathType Container)) { return $true }
  try {
    $item = Get-Item -Path $DirPath
    # Check if it's a directory with reparse/symlink flags
    # On modern Windows, DirectoryInfo with SpecialAttributes can detect reparse points
    if ($item.GetType().FullName -eq 'System.IO.DirectoryInfo') {
      $attr = $item.Attributes
      # Reparse point detection via special attribute check
      try {
        $isReparse = ($attr -band 0x400) -ne 0
        if ($isReparse) { return $false }
      } catch {}
    }
    return $true
  } catch {
    return $true
  }
}

# ── ACTION: plan ───────────────────────────────────────────────────────────

function Invoke-Plan {
  param(
    [string]$GameDir,
    [string]$StagedDir,
    [string]$Route,
    [string]$ProxyName,
    [switch]$IncludeUal,
    [string]$StagedUalPath,
    [string]$JournalRoot,
    [string]$ExtraJson
  )

  # Defaults
  if ([string]::IsNullOrEmpty($JournalRoot)) {
    $JournalRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer\journal'
  }
  if ([string]::IsNullOrEmpty($ProxyName)) {
    $ProxyName = 'dxgi.dll'
  }

  # Resolve paths
  try {
    $GameDir = [System.IO.Path]::GetFullPath($GameDir).TrimEnd('\').TrimEnd('/')
    $StagedDir = [System.IO.Path]::GetFullPath($StagedDir).TrimEnd('\').TrimEnd('/')
  } catch {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'cannot-resolve-paths' -Human 'Could not resolve GameDir/StagedDir.'
    return 2
  }

  # Validate GameDir exists
  if (-not (Test-Path -Path $GameDir -PathType Container)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'game-dir-missing' -Human "GameDir does not exist or is not a directory: $($GameDir)"
    return 2
  }
  if (-not (Test-NotReparseDir $GameDir)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'game-dir-reparse' -Human "GameDir is a reparse/symlink point."
    return 2
  }

  if (-not $Route) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-route' -Human 'Route must be asi or proxy.'
    return 2
  }
  if ($Route -notin @('asi', 'proxy')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-route' -Human "Route must be asi or proxy, got '$($Route)'."
    return 2
  }

  if (-not (Test-Path -Path $StagedDir)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'staged-dir-missing' -Human "StagedDir is not valid: $($StagedDir)"
    return 2
  }
  if (-not (Test-NotReparseDir $StagedDir)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'staged-dir-reparse' -Human "StagedDir is a reparse/symlink point."
    return 2
  }

  # Build ops list
  $ops = @()
  if ($Route -eq 'asi') {
    $sourceAsi = Join-Path $StagedDir 'OptiScaler.asi'
    if (-not (Test-Path -Path $sourceAsi)) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'stage-file-missing' -Human "Staged source missing: $($sourceAsi)"
      return 2
    }
    $targetAsi = Join-Path $GameDir 'OptiScaler.asi'
    $backupAsi = Join-Path $GameDir ".susemi-backup\OptiScaler.asi.susemi-bak"
    $ops += (BuildOp -Target $targetAsi -Source $sourceAsi -Backup $backupAsi)
  } elseif ($Route -eq 'proxy') {
    $sourceDll = Join-Path $StagedDir $ProxyName
    if (-not (Test-Path -Path $sourceDll)) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'stage-file-missing' -Human "Staged source missing: $($sourceDll)"
      return 2
    }
    $targetProxy = Join-Path $GameDir $ProxyName
    $backupProxy = Join-Path $GameDir ".susemi-backup\$($ProxyName).susemi-bak"
    $ops += (BuildOp -Target $targetProxy -Source $sourceDll -Backup $backupProxy)
  }

  # IncludeUAL op
  if ($IncludeUal) {
    $ualSrc = ''
    if (-not [string]::IsNullOrEmpty($StagedUalPath)) {
      $ualSrc = $StagedUalPath
    } else {
      $ualSrc = Join-Path $StagedDir 'winmm.dll'
    }
    if (-not (Test-Path -Path $ualSrc)) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'ual-source-missing' -Human "UAL source missing: $($ualSrc)"
      return 2
    }
    $ualTarget = Join-Path $GameDir 'winmm.dll'
    $ualBackup = Join-Path $GameDir ".susemi-backup\winmm.dll.susemi-bak"
    $ops += (BuildOp -Target $ualTarget -Source $ualSrc -Backup $ualBackup)
  }

  # Caller-supplied extra ops (e.g. a byte-preserving winmm.ini extension and a
  # verified ReShade.asi conversion copy). Appended LAST so they are journaled as
  # the final operations; the same BuildOp/create-replace/preimage rules apply.
  if (-not [string]::IsNullOrEmpty($ExtraJson)) {
    if (-not (Test-Path -Path $ExtraJson -PathType Leaf)) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-json-missing' -Human "ExtraJson not found: $($ExtraJson)"
      return 2
    }
    $extraSpec = $null
    # NOTE: in PowerShell 5.1 a JSON array returned by ConvertFrom-Json is a nested
    # Object[]; wrapping it in @() keeps it a single element and would make the
    # loop below treat the whole array as one op. Keep it unwrapped; the foreach
    # iterates its elements (and a lone object is yielded once).
    try { $extraSpec = ((Get-Content -LiteralPath $ExtraJson -Raw) | ConvertFrom-Json) } catch { $extraSpec = $null }
    if ($null -eq $extraSpec) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-json-invalid' -Human 'ExtraJson is not a valid JSON array.'
      return 2
    }
    $extraIdx = 0
    foreach ($ex in $extraSpec) {
      $exTarget = [string]$ex.target
      $exSource = [string]$ex.source
      if ([string]::IsNullOrEmpty($exTarget) -or [string]::IsNullOrEmpty($exSource)) {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-json-invalid' -Human ('ExtraJson entry {0} needs target and source.' -f $extraIdx)
        return 2
      }
      if (-not (Test-BelongsToBase $exTarget $GameDir)) {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-target-outside-gamedir' -Human "Extra target outside GameDir: $($exTarget)"
        return 2
      }
      if (-not (Test-Path -Path $exSource -PathType Leaf)) {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-source-missing' -Human "Extra source missing: $($exSource)"
        return 2
      }
      foreach ($prev in $ops) {
        if (([string]$prev.target).Equals($exTarget, [StringComparison]::OrdinalIgnoreCase)) {
          Write-StatusLine -Status 'invalid-invocation' -Reason 'extra-target-duplicate' -Human "Extra target duplicates an earlier op target: $($exTarget)"
          return 2
        }
      }
      $exBackup = Join-Path $GameDir ('.susemi-backup\' + (Split-Path -Leaf $exTarget) + '.susemi-bak')
      $ops += (BuildOp -Target $exTarget -Source $exSource -Backup $exBackup)
      $extraIdx++
    }
  }

  # Validate each target: inside GameDir prefix check; reject dirs/reparse
  foreach ($op in $ops) {
    if (-not (Test-BelongsToBase $op.target $GameDir)) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'target-outside-gamedir' -Human "Target outside GameDir: $($op.target)"
      return 2
    }
    if (Test-Path -Path $op.target) {
      try {
        $tItem = Get-Item -Path $op.target
        if ($tItem.PSIsContainer -eq $true) {
          Write-StatusLine -Status 'invalid-invocation' -Reason 'target-is-directory' -Human "Target is a directory: $($op.target)"
          return 2
        }
        # Check reparse attribute
        try {
          $isReparse = ($tItem.Attributes -band 0x400) -ne 0
          if ($isReparse) {
            Write-StatusLine -Status 'invalid-invocation' -Reason 'target-is-reparse' -Human "Target is a reparse/symlink: $($op.target)"
            return 2
          }
        } catch {}
      } catch {}
    }
  }

  # A present target whose bytes cannot be read (locked/permission) has no valid
  # baseline: beforeExists=true with beforeSha='' is unreadable, not empty
  # (an empty file hashes to e3b0c442...). Refuse rather than journal a bogus preimage.
  $unreadable = @($ops | Where-Object { $_.beforeExists -and [string]::IsNullOrEmpty($_.beforeSha) })
  if ($unreadable.Count -gt 0) {
    Write-StatusLine -Status 'refused' -Reason 'before-sha-read-failure' -Human ("Cannot read the existing target bytes; refusing to plan over an unreadable baseline: {0}" -f $unreadable[0].target)
    return 1
  }

  # Record sha for staged sources
  foreach ($op in $ops) {
    $op.sourceSha = Get-SHA256 $op.source
  }
  $badOps = @($ops | Where-Object { -not $_.sourceSha })
  if ($badOps.Count -gt 0) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'sha-read-failure' -Human 'Could not compute SHA256 for staged files.'
    return 2
  }

  # Journal dir
  try {
    if (-not (Test-Path -Path $JournalRoot)) {
      New-Item -ItemType Directory -Path $JournalRoot -Force | Out-Null
    }
  } catch {}

  $journalId = 'j_' + (Get-Date -Format 'yyyyMMddHHmmss_fff')
  $journalPath = Join-Path $JournalRoot "$($journalId)_plan.json"
  $txId = New-TxId

  $journal = @{
    schema_version = 1
    txid           = $txId
    phase          = 'prepared'
    action         = 'plan'
    route          = $Route
    game_dir       = $GameDir
    staged_dir     = $StagedDir
    include_ual    = $IncludeUal.IsPresent
    created_at     = (Get-Date -Format 'o')
    ops            = $ops
  }

  if (-not (Atomic-JournalWrite -TargetPath $journalPath -JournalData $journal)) {
    Write-StatusLine -Status 'refused' -Reason 'journal-write-failed' -Human 'Failed to write journal file atomically.'
    return 1
  }

  $opCount = $ops.Count
  Write-StatusLine -Status 'planned' -Reason ("opcount-{0}" -f $opCount) -Human ("plan: planned {0} op(s), journal={1}" -f $opCount, $journalPath)
  return 0
}

function BuildOp {
  param(
    [string]$Target,
    [string]$Source,
    [string]$Backup
  )
  $beforeExists = $false
  $beforeSha = ''
  if (Test-Path -Path $Target) {
    $beforeExists = $true
    $beforeSha = Get-SHA256 $Target
  }
  $opType = 'create'
  if ($beforeExists) {
    $opType = 'replace'
  }
  return @{
    op           = $opType
    target       = $Target
    source       = $Source
    backupPath   = $Backup
    sourceSha    = ''
    beforeExists = $beforeExists
    beforeSha    = $beforeSha
    state        = ''
  }
}

# ── ACTION: prepare ────────────────────────────────────────────────────────

function Invoke-Prepare {
  param([string]$JournalPath)

  if ([string]::IsNullOrEmpty($JournalPath)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'prepare requires -Journal <path>.'
    return 2
  }
  $j = Load-Journal -Path $JournalPath
  if (-not $j) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'journal-not-found' -Human "Journal not found: $($JournalPath)"
    return 2
  }

  # For each op where beforeExists is true: copy target->backupPath, verify sha.
  # The backup dir is created lazily per op: an all-create install must leave no
  # trace in the game folder, so rollback is byte-identical to the pre-install map.
  $failed = $false
  $failMsg = ''
  $failReason = ''
  for ($idx = 0; $idx -lt $j.ops.Count; $idx++) {
    $op = $j.ops[$idx]
    if ($op.beforeExists) {
      $bakDir = Split-Path -Parent $op.backupPath
      if (-not (Test-Path -Path $bakDir)) {
        try { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null } catch { }
      }
      try {
        Copy-Item -Path $op.target -Destination $op.backupPath -Force -ErrorAction Stop | Out-Null
      } catch {
        $failed = $true
        $failReason = 'backup-copy-error'
        $failMsg = ('backup-copy-error at index {0}: {1}' -f $idx, $_.Exception.Message)
        break
      }
      $backupSha = Get-SHA256 $op.backupPath
      if ($backupSha -ne $op.beforeSha) {
        $failed = $true
        $failReason = 'backup-sha-mismatch'
        $failMsg = 'backup-sha-mismatch at index {0}' -f $idx
        break
      }
    }
  }

  if ($failed) {
    $j.phase = 'prepared-failed'
    Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
    Write-StatusLine -Status 'prepared-failed' -Reason $failReason -Human ("prepare failed: {0}" -f $failMsg)
    return 1
  }

  # Phase -> armed (atomic rewrite)
  $j.phase = 'armed'
  Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
  Write-StatusLine -Status 'prepared' -Reason 'ready' -Human "prepare: all backups OK, phase=armed. Journal=$($JournalPath)"
  return 0
}

# ── ACTION: apply ──────────────────────────────────────────────────────────

function Invoke-Apply {
  param(
    [string]$JournalPath,
    [string]$RaceProbe
  )

  if ([string]::IsNullOrEmpty($JournalPath)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'apply requires -Journal <path>.'
    return 2
  }
  $j = Load-Journal -Path $JournalPath
  if (-not $j) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'journal-not-found' -Human "Journal not found: $($JournalPath)"
    return 2
  }

  # Race probe (TEST ONLY): before first op, create file at given path
  if (-not [string]::IsNullOrEmpty($RaceProbe)) {
    try {
      $probeDir = Split-Path -Parent $RaceProbe
      if (-not (Test-Path -Path $probeDir)) {
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
      }
      $bytes = New-Object byte[] 1024
      $random = New-Object System.Random 42
      $random.NextBytes($bytes)
      [System.IO.File]::WriteAllBytes($RaceProbe, $bytes)
    } catch {}
  }

  $appliedCount = 0
  $GameDir = $j.game_dir

  for ($i = 0; $i -lt $j.ops.Count; $i++) {
    $op = $j.ops[$i]
    $opTarget = $op.target
    $opSource = $op.source
    $opSourceSha = $op.sourceSha

    try {
      if ($op.op -eq 'create') {
        # Re-stat: if target now exists, conflict
        if (Test-Path -Path $opTarget) {
          $j.phase = 'apply-conflict'
          Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
          Write-StatusLine -Status 'conflict' -Reason 'target-appeared' -Human ("apply conflict: target already exists after re-stat: {0}" -f $opTarget)
          return 1
        }
        # Copy source -> target
        Copy-Item -Path $opSource -Destination $opTarget -Force -ErrorAction Stop | Out-Null
        # Verify sha
        $writtenSha = Get-SHA256 $opTarget
        if ($writtenSha -ne $opSourceSha) {
          $j.phase = 'apply-failed'
          Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
          Write-StatusLine -Status 'apply-failed' -Reason 'sha-mismatch-after-copy' -Human ("apply failed: sha mismatch after creating {0}" -f $opTarget)
          return 1
        }
      } elseif ($op.op -eq 'replace') {
        # Copy source -> <target>.susemi-tmp inside GameDir
        $tmpName = $opTarget + '.susemi-tmp'
        Copy-Item -Path $opSource -Destination $tmpName -Force -ErrorAction Stop | Out-Null
        # Verify tmp sha
        $tmpSha = Get-SHA256 $tmpName
        if ($tmpSha -ne $opSourceSha) {
          Remove-Item -Path $tmpName -Force -ErrorAction SilentlyContinue | Out-Null
          $j.phase = 'apply-failed'
          Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
          Write-StatusLine -Status 'apply-failed' -Reason 'sha-mismatch-tmp' -Human ("apply failed: sha mismatch on tmp for {0}" -f $opTarget)
          return 1
        }
        # Move-Item -Force tmp -> target; never leave the staging tmp behind on failure
        try {
          Move-Item -Path $tmpName -Destination $opTarget -Force -ErrorAction Stop | Out-Null
        } catch {
          Remove-Item -Path $tmpName -Force -ErrorAction SilentlyContinue | Out-Null
          throw
        }
        # Verify target sha
        $finalSha = Get-SHA256 $opTarget
        if ($finalSha -ne $opSourceSha) {
          $j.phase = 'apply-failed'
          Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
          Write-StatusLine -Status 'apply-failed' -Reason 'sha-mismatch-final' -Human ("apply failed: sha mismatch on final target {0}" -f $opTarget)
          return 1
        }
      }

      # Success: update journal op state and atomic rewrite
      $j.ops[$i].state = 'applied'
      $appliedCount++
      Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null

    } catch {
      if ($tmpName) { Remove-Item -Path $tmpName -Force -ErrorAction SilentlyContinue | Out-Null }
      $j.phase = 'apply-failed'
      Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
      Write-StatusLine -Status 'apply-failed' -Reason 'copy-error' -Human ("apply failed on op {0}: {1}" -f $i, $_.Exception.Message)
      return 1
    }
  }

  $j.phase = 'applied'
  Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
  Write-StatusLine -Status 'installed' -Reason ("applied-{0}" -f $appliedCount) -Human ("apply: installed {0} op(s). Journal={1}" -f $appliedCount, $JournalPath)
  return 0
}

# ── ACTION: recover ────────────────────────────────────────────────────────

function Invoke-Recover {
  param([string]$JournalPath)

  if ([string]::IsNullOrEmpty($JournalPath)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'recover requires -Journal <path>.'
    return 2
  }
  $j = Load-Journal -Path $JournalPath
  if (-not $j) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'journal-not-found' -Human "Journal not found: $($JournalPath)"
    return 2
  }

  # Idempotent: phase=recovered means nothing to do
  if ($j.phase -eq 'recovered') {
    Write-StatusLine -Status 'already-recovered' -Reason 'nothing-to-do' -Human 'Journal already recovered.'
    return 0
  }

  $needsRecovery = $false

  for ($i = 0; $i -lt $j.ops.Count; $i++) {
    $op = $j.ops[$i]

    # Only recover ops that were applied
    if ($op.state -ne 'applied') { continue }

    if ($op.op -eq 'replace') {
      # Guard: if the backup file is missing, refuse rather than let
      # Get-FileHash throw PathNotFound (B3 regression in F2).
      if (-not (Test-Path -LiteralPath $op.backupPath -PathType Leaf)) {
        $j.phase = 'recovery-required'
        Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
        Write-StatusLine -Status 'recovery-required' -Reason 'backup-missing' -Human ('Missing backup for ' + $op.target)
        return 1
      }
      # Invariant: never touch the live target until the backup preimage is
      # proven to match the journaled before-sha. A tampered backup must NOT
      # reach the live file (F2 blocker B2).
      $backupSha = (Get-FileHash -LiteralPath $op.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($backupSha -ne $op.beforeSha.ToLowerInvariant()) {
        $j.phase = 'recovery-required'
        Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
        Write-StatusLine -Status 'recovery-required' -Reason 'backup-tampered' -Human ('Backup preimage mismatch for ' + $op.target)
        return 1
      }
      # Post-copy verification: we now validate backup SHA before copy; this keeps
      # the invariant that the final target == original preimage, just rephrased.
      try {
        Copy-Item -Path $op.backupPath -Destination $op.target -Force -ErrorAction Stop | Out-Null
      } catch {
        $needsRecovery = $true
        break
      }
      $verifySha = Get-SHA256 $op.target
      if ($verifySha -ne $op.beforeSha) {
        $needsRecovery = $true
        break
      }
    } elseif ($op.op -eq 'create') {
      # If current target sha == sourceSha, delete it (proven installer-created)
      if (Test-Path -Path $op.target) {
        $currentSha = Get-SHA256 $op.target
        if ($currentSha -eq $op.sourceSha) {
          try {
            Remove-Item -Path $op.target -Force -ErrorAction Stop | Out-Null
          } catch {
            $needsRecovery = $true
            break
          }
        } else {
          # sha mismatch => not ours, leave but mark recovery-required
          $needsRecovery = $true
          break
        }
      }
      # else: target doesn't exist, nothing to do for create
    }
  }

  if ($needsRecovery) {
    $j.phase = 'recovery-required'
    Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
    Write-StatusLine -Status 'recovery-required' -Reason 'recovery-incomplete' -Human 'Recovery incomplete - manual intervention required.'
    return 1
  }

  $j.phase = 'recovered'
  Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
  Write-StatusLine -Status 'recovered' -Reason 'ok' -Human ("Recover: all applied ops restored. Journal={0}" -f $JournalPath)
  return 0
}

# ── ACTION: rollback ───────────────────────────────────────────────────────

function Invoke-Rollback {
  param([string]$JournalPath)

  if ([string]::IsNullOrEmpty($JournalPath)) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'rollback requires -Journal <path>.'
    return 2
  }
  $j = Load-Journal -Path $JournalPath
  if (-not $j) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'journal-not-found' -Human "Journal not found: $($JournalPath)"
    return 2
  }

  # Refuse rollback on phase=prepared-failed
  if ($j.phase -eq 'prepared-failed') {
    Write-StatusLine -Status 'refused' -Reason 'nothing-to-undo' -Human 'Nothing to undo: journal is in prepared-failed phase.'
    return 1
  }

  $hasMismatch = $false

  for ($i = 0; $i -lt $j.ops.Count; $i++) {
    $op = $j.ops[$i]
    if ($op.state -ne 'applied') { continue }

    if ($op.op -eq 'replace') {
      # Refuse when any backup sha mismatch
      if ($op.beforeExists -and $op.beforeSha -ne '') {
        if (Test-Path -Path $op.backupPath) {
          $bSha = Get-SHA256 $op.backupPath
          if ($bSha -ne $op.beforeSha) {
            $hasMismatch = $true
            break
          }
        }
      }
    }
  }

  if ($hasMismatch) {
    $j.phase = 'recovery-required'
    Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
    Write-StatusLine -Status 'recovery-required' -Reason 'backup-sha-mismatch' -Human 'Rollback refused: backup sha mismatch detected.'
    return 1
  }

  # Perform restore (same as recover semantics)
  for ($i = 0; $i -lt $j.ops.Count; $i++) {
    $op = $j.ops[$i]
    if ($op.state -ne 'applied') { continue }

    if ($op.op -eq 'replace') {
      try {
        if (Test-Path -Path $op.backupPath) {
          Copy-Item -Path $op.backupPath -Destination $op.target -Force -ErrorAction Stop | Out-Null
          $verifySha = Get-SHA256 $op.target
          if ($verifySha -ne $op.beforeSha) {
            $j.phase = 'recovery-required'
            Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
            Write-StatusLine -Status 'recovery-required' -Reason 'restore-verify-failed' -Human ("Rollback verification failed for {0}" -f $op.target)
            return 1
          }
        }
      } catch {
        $j.phase = 'recovery-required'
        Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
        Write-StatusLine -Status 'recovery-required' -Reason 'restore-error' -Human ("Rollback error: {0}" -f $_.Exception.Message)
        return 1
      }
    } elseif ($op.op -eq 'create') {
      # Delete target if current sha == sourceSha (proven installer-created)
      if (Test-Path -Path $op.target) {
        $currentSha = Get-SHA256 $op.target
        if ($currentSha -eq $op.sourceSha) {
          try {
            Remove-Item -Path $op.target -Force -ErrorAction Stop | Out-Null
          } catch {
            $j.phase = 'recovery-required'
            Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
            Write-StatusLine -Status 'recovery-required' -Reason 'delete-error' -Human ("Rollback delete failed: {0}" -f $_.Exception.Message)
            return 1
          }
        }
      }
    }
  }

  $j.phase = 'recovered'
  Atomic-JournalWrite -TargetPath $JournalPath -JournalData $j | Out-Null
  Write-StatusLine -Status 'recovered' -Reason 'ok' -Human ("Rollback: all applied ops reverted. Journal={0}" -f $JournalPath)
  return 0
}

# ── CLI dispatch ───────────────────────────────────────────────────────────

$argv = @($args)
if ($argv.Count -eq 0) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'no-action' -Human 'No action specified. Actions: plan, prepare, apply, recover, rollback.'
  exit 2
}

$action = ([string]$argv[0]).ToLowerInvariant()

$params = @{
  GameDir       = $null
  StagedDir     = $null
  Route         = $null
  ProxyName     = $null
  IncludeUal    = $false
  StagedUalPath = $null
  JournalRoot   = $null
  Journal       = $null
  RaceProbe     = $null
  ExtraJson     = $null
}

$sawGameDir = $false
$sawStagedDir = $false
$i = 1
while ($i -lt $argv.Count) {
  $key = ([string]$argv[$i]).ToLowerInvariant()
  switch ($key) {
    '-gamedir' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -GameDir.'
        exit 2
      }
      $params['GameDir'] = $argv[++$i]
      $sawGameDir = $true
    }
    '-stageddir' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -StagedDir.'
        exit 2
      }
      $params['StagedDir'] = $argv[++$i]
      $sawStagedDir = $true
    }
    '-route' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -Route.'
        exit 2
      }
      $params['Route'] = $argv[++$i]
    }
    '-proxynames' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -ProxyName.'
        exit 2
      }
      $params['ProxyName'] = $argv[++$i]
    }
    '-ProxyName' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -ProxyName.'
        exit 2
      }
      $params['ProxyName'] = $argv[++$i]
    }
    '-includeual' {
      $params['IncludeUal'] = $true
    }
    '-stagedualpath' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -StagedUalPath.'
        exit 2
      }
      $params['StagedUalPath'] = $argv[++$i]
    }
    '-JournalRoot' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -JournalRoot.'
        exit 2
      }
      $params['JournalRoot'] = $argv[++$i]
    }
    '-ExtraJson' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -ExtraJson.'
        exit 2
      }
      $params['ExtraJson'] = $argv[++$i]
    }
    '-Journal' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -Journal.'
        exit 2
      }
      $params['Journal'] = $argv[++$i]
    }
    '-raceprobe' {
      if (($i + 1) -ge $argv.Count -or $argv[$i + 1] -like '-*') {
        Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' -Human 'Missing value for -RaceProbe.'
        exit 2
      }
      $params['RaceProbe'] = $argv[++$i]
    }
    default {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'unknown-argument' -Human "Unknown argument: $($argv[$i])"
      exit 2
    }
  }
  $i++
}

switch ($action) {
  'plan' {
    if (-not $sawGameDir -or -not $sawStagedDir) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-gamedir-or-stageddir' -Human 'plan requires -GameDir and -StagedDir.'
      exit 2
    }
    # Splat ONLY the keys Invoke-Plan declares: $params is a shared bag for all
    # actions, and splatting its foreign keys (Journal/RaceProbe) makes PS 5.1
    # throw a misleading "parameter 'JournalRoot' is specified more than once".
    $planParams = @{
      GameDir       = $params['GameDir']
      StagedDir     = $params['StagedDir']
      Route         = $params['Route']
      ProxyName     = $params['ProxyName']
      StagedUalPath = $params['StagedUalPath']
      JournalRoot   = $params['JournalRoot']
    }
    if ($params['IncludeUal']) { $planParams['IncludeUal'] = $true }
    if (-not [string]::IsNullOrEmpty($params['ExtraJson'])) { $planParams['ExtraJson'] = $params['ExtraJson'] }
    # Run the action as a STATEMENT and merge its output: assigning the function
    # to a variable would capture (and silently swallow) the machine-readable
    # status= line and turn `exit $array` into a blind exit 0.
    $code = 1
    Invoke-Plan @planParams | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  'prepare' {
    if ([string]::IsNullOrEmpty($params['Journal'])) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'prepare requires -Journal <path>.'
      exit 2
    }
    $code = 1
    Invoke-Prepare -Journal $params['Journal'] | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  'apply' {
    if ([string]::IsNullOrEmpty($params['Journal'])) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'apply requires -Journal <path>.'
      exit 2
    }
    $code = 1
    Invoke-Apply -Journal $params['Journal'] -RaceProbe $params['RaceProbe'] | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  'recover' {
    if ([string]::IsNullOrEmpty($params['Journal'])) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'recover requires -Journal <path>.'
      exit 2
    }
    $code = 1
    Invoke-Recover -Journal $params['Journal'] | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  'rollback' {
    if ([string]::IsNullOrEmpty($params['Journal'])) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-journal' -Human 'rollback requires -Journal <path>.'
      exit 2
    }
    $code = 1
    Invoke-Rollback -Journal $params['Journal'] | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  default {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unknown-action' -Human "Unknown action: $($action)"
    exit 2
  }
}
