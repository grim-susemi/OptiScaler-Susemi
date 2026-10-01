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
  if (-not (Test-Path -LiteralPath $FilePath)) { return '' }
  try {
    $item = Get-Item -LiteralPath $FilePath
    if ($item.PSIsContainer) { return '' }
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
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
  # Exclusive temporary journal, durable flush, atomic replacement, readback.
  param(
    [string]$TargetPath,
    [object]$JournalData
  )
  try {
    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-OrdinaryPath $targetDir -Directory)) { return $false }
    $exists = Test-OrdinaryPath $TargetPath
    $tmpPath = Join-Path $targetDir ('.susemi-journal-' + (New-TxId) + '.tmp')
    if (Test-OrdinaryPath $tmpPath) { return $false }
    $json = $JournalData | ConvertTo-Json -Depth 14 -Compress
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($tmpPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    $null = Test-OrdinaryPath $TargetPath
    if ($exists) { [IO.File]::Replace($tmpPath, $TargetPath, [NullString]::Value) }
    else { [IO.File]::Move($tmpPath, $TargetPath) }
    if ([IO.File]::ReadAllText($TargetPath) -ne $json) { return $false }
    return $true
  } catch {
    Write-Host ('journal! ' + $_.Exception.Message)
    return $false
  }
}

function Load-Journal {
  param([string]$Path)
  try {
    if (-not (Test-OrdinaryPath $Path)) { return $null }
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
  try { $null = Test-OrdinaryPath $DirPath -Directory; return $true } catch { return $false }
}

function Get-CanonicalPath([string]$Path) {
  if (-not [IO.Path]::IsPathRooted($Path)) { throw 'path-not-absolute' }
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  if ($full.Substring($root.Length).Contains(':')) { throw 'path-not-ordinary' }
  if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
  return $full
}

function Test-OrdinaryPath {
  param([string]$Path, [switch]$Directory)
  $cursor = Get-CanonicalPath $Path
  $leaf = $true; $exists = $false
  while ($cursor) {
    # Ordinary PS5.1/native paths include the terminating NUL in MAX_PATH.
    # CreateDirectoryW also reserves 12 characters for an appended 8.3 name.
    # Plan probes every target, generated file, journal and their ancestors
    # here before creating anything; never defer this refusal to prepare/apply.
    $limit = 260
    if (-not $leaf -or $Directory) { $limit = 248 }
    if ($cursor.Length -ge $limit) { throw 'path-limit' }
    $attributes = $null
    try { $attributes = [IO.File]::GetAttributes($cursor) }
    catch {
      $errorObject = $_.Exception
      while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
      if (-not ($errorObject -is [IO.FileNotFoundException] -or $errorObject -is [IO.DirectoryNotFoundException])) { throw 'path-unreadable' }
    }
    if ($null -ne $attributes) {
      if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'path-reparse' }
      $isDir = [bool]($attributes -band [IO.FileAttributes]::Directory)
      if ((-not $leaf -or $Directory) -and -not $isDir) { throw 'parent-not-directory' }
      if ($leaf -and -not $Directory -and $isDir) { throw 'target-is-directory' }
      if ($isDir) {
        try { $null = [IO.Directory]::GetFileSystemEntries($cursor) }
        catch { throw 'path-unreadable' }
      }
      if ($leaf) { $exists = $true }
    }
    $cursor = [IO.Path]::GetDirectoryName($cursor); $leaf = $false
  }
  return $exists
}

function Save-Tx([string]$Path, $Journal) {
  if (-not (Atomic-JournalWrite $Path $Journal)) { throw 'journal-write-failed' }
}

# Thin Windows filesystem primitives, not a second transaction engine. Directory
# handles deny write/delete while a target is promoted; replacement holds the
# baseline file against external writers and renames it by that same handle.
function Initialize-TxFiles {
  if ('Susemi.TxFiles' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
namespace Susemi {
  public static class TxFiles {
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
      public uint attributes, createdLow, createdHigh, accessedLow, accessedHigh,
        writtenLow, writtenHigh, volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
      IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, IntPtr value, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateDirectoryW(string name, IntPtr security);
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static string FinalPath(SafeFileHandle file) {
      var text = new StringBuilder(32768);
      uint size = GetFinalPathNameByHandleW(file, text, (uint)text.Capacity, 0);
      Check(size != 0);
      if (size >= text.Capacity) throw new IOException("path-unreadable");
      string name = text.ToString();
      if (name.StartsWith(@"\\?\UNC\")) name = @"\\" + name.Substring(8);
      else if (name.StartsWith(@"\\?\")) name = name.Substring(4);
      return name.TrimEnd('\\');
    }
    public sealed class Parents : IDisposable {
      readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
      public Parents(string target) {
        try {
          for (string parent = Path.GetDirectoryName(Path.GetFullPath(target));
               !String.IsNullOrEmpty(parent); parent = Path.GetDirectoryName(parent)) {
            var handle = CreateFileW(parent, 0x80, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
            handles.Add(handle);
            Info info; Check(GetFileInformationByHandle(handle, out info));
            if ((info.attributes & 0x400) != 0 || (info.attributes & 0x10) == 0 ||
                !String.Equals(FinalPath(handle), Path.GetFullPath(parent).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
              throw new IOException("path-reparse");
          }
        } catch { Dispose(); throw; }
      }
      public void Dispose() { foreach (var handle in handles) handle.Dispose(); handles.Clear(); }
    }
    public static Parents LockParents(string target) { return new Parents(target); }
    public static bool CreateDirectoryExclusive(string path) {
      if (CreateDirectoryW(path, IntPtr.Zero)) return true;
      int error = Marshal.GetLastWin32Error();
      if (error == 183) return false;
      throw new Win32Exception(error);
    }
    static void Rename(SafeFileHandle file, string destination) {
      byte[] name = Encoding.Unicode.GetBytes(Path.GetFullPath(destination));
      int rootOffset = IntPtr.Size == 8 ? 8 : 4;
      int lengthOffset = rootOffset + IntPtr.Size, nameOffset = lengthOffset + 4;
      byte[] data = new byte[nameOffset + name.Length + 2];
      BitConverter.GetBytes(name.Length).CopyTo(data, lengthOffset);
      name.CopyTo(data, nameOffset);
      IntPtr memory = Marshal.AllocHGlobal(data.Length);
      try { Marshal.Copy(data, 0, memory, data.Length); Check(SetFileInformationByHandle(file, 3, memory, (uint)data.Length)); }
      finally { Marshal.FreeHGlobal(memory); }
    }
    public static void Promote(string temp, string target, string baseline, string displaced) {
      if (String.IsNullOrEmpty(baseline)) { File.Move(temp, target); return; }
      using (var handle = CreateFileW(target, 0x80010000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        Info info; Check(GetFileInformationByHandle(handle, out info));
        if ((info.attributes & 0x410) != 0) throw new IOException("target-not-ordinary");
        if (!String.Equals(FinalPath(handle), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
          throw new IOException("target-changed");
        string hash;
        using (var borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
        using (var stream = new FileStream(borrowed, FileAccess.Read))
        using (var sha = SHA256.Create()) {
          hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        if (!String.Equals(hash, baseline, StringComparison.OrdinalIgnoreCase)) throw new IOException("target-changed");
        Rename(handle, displaced);
        try { File.Move(temp, target); }
        catch { throw new IOException("promotion-uncertain"); }
      }
    }
    public static void CheckDeleteAccess(string target) {
      using (var handle = CreateFileW(target, 0x80010000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
      }
    }
    public static string DirectoryIdentity(string path) {
      using (var handle = CreateFileW(path, 0x80, 1, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        Info info; Check(GetFileInformationByHandle(handle, out info));
        if ((info.attributes & 0x400) != 0 || (info.attributes & 0x10) == 0) throw new IOException("path-reparse");
        return info.volume.ToString("x8") + ":" + info.indexHigh.ToString("x8") + info.indexLow.ToString("x8");
      }
    }
    public static void DeleteOwned(string target, string expected) {
      using (var handle = CreateFileW(target, 0x80010000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        Info info; Check(GetFileInformationByHandle(handle, out info));
        if ((info.attributes & 0x410) != 0 ||
            !String.Equals(FinalPath(handle), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
          throw new IOException("target-not-ordinary");
        string hash;
        using (var borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
        using (var stream = new FileStream(borrowed, FileAccess.Read))
        using (var sha = SHA256.Create()) {
          hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        if (!String.Equals(hash, expected, StringComparison.OrdinalIgnoreCase)) throw new IOException("target-changed");
        IntPtr value = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(value, 1); Check(SetFileInformationByHandle(handle, 4, value, 4)); }
        finally { Marshal.FreeHGlobal(value); }
      }
    }
  }
}
'@ | Out-Null
}

function Assert-JournalData($Journal) {
  $version = [int]$Journal.schema_version
  if ($version -notin @(1, 2) -or [string]::IsNullOrEmpty([string]$Journal.txid)) { throw 'journal-unknown' }
  $base = Get-CanonicalPath ([string]$Journal.game_dir)
  if ($version -eq 2 -and $base -ne [string]$Journal.game_dir) { throw 'journal-noncanonical' }
  $null = Test-OrdinaryPath $base -Directory
  $seen = @{}
  foreach ($op in @($Journal.ops)) {
    $target = Get-CanonicalPath ([string]$op.target)
    if (-not (Test-BelongsToBase $target $base) -or $seen.ContainsKey($target)) { throw 'path-escape' }
    if ($version -eq 2 -and $target -ne [string]$op.target) { throw 'journal-noncanonical' }
    $seen[$target] = $true
    if ($op.op -notin @('create', 'replace') -or $op.sourceSha -notmatch '^[0-9a-fA-F]{64}$' -or
        $op.state -notin @('', 'applied', 'intent', 'undo-intent', 'reverted')) { throw 'journal-unknown' }
    $null = Test-OrdinaryPath $target
    if ($op.op -eq 'replace') {
      if ($op.beforeSha -notmatch '^[0-9a-fA-F]{64}$' -or [string]::IsNullOrEmpty([string]$op.backupPath)) { throw 'backup-missing' }
      $backup = Get-CanonicalPath ([string]$op.backupPath)
      if (-not (Test-BelongsToBase $backup $base)) { throw 'path-escape' }
      $null = Test-OrdinaryPath $backup
    }
    if ($version -eq 2 -or -not [string]::IsNullOrEmpty([string]$op.tempPath)) {
      foreach ($field in @('tempPath', 'displacedPath')) {
        $path = Get-CanonicalPath ([string]$op.$field)
        if ($path -ne [string]$op.$field -or -not (Test-BelongsToBase $path $base) -or
            (Split-Path -Parent $path) -ne (Split-Path -Parent $target)) { throw 'journal-noncanonical' }
        $null = Test-OrdinaryPath $path
      }
      if ($op.tempState -notin @('none', 'intent', 'partial', 'verified', 'consumed', 'removed', 'foreign') -or
          ($version -eq 2 -and $op.backupState -notin @('none', 'intent', 'partial', 'ready', 'removed', 'foreign')) -or
          $op.displacedState -notin @('none', 'present', 'removed')) { throw 'journal-unknown' }
    }
  }
  if ($version -eq 2) {
    $lastDepth = -1; $dirSeen = @{}
    foreach ($dir in @($Journal.createdDirs)) {
      $path = Get-CanonicalPath ([string]$dir.path)
      $depth = @($path -split '[\\/]').Count
      if ($path -ne [string]$dir.path -or -not (Test-BelongsToBase $path $base) -or
          $dirSeen.ContainsKey($path) -or $depth -lt $lastDepth -or
          $dir.state -notin @('planned', 'intent', 'created', 'preserved', 'removed')) { throw 'journal-unknown' }
      $null = Test-OrdinaryPath $path -Directory
      $dirSeen[$path] = $true; $lastDepth = $depth
    }
    foreach ($reuse in @($Journal.reused)) {
      $path = Get-CanonicalPath ([string]$reuse.target)
      if ($path -ne [string]$reuse.target -or -not (Test-BelongsToBase $path $base) -or
          $seen.ContainsKey($path) -or $reuse.sourceSha -notmatch '^[0-9a-fA-F]{64}$') { throw 'journal-unknown' }
      $seen[$path] = $true; $null = Test-OrdinaryPath $path
      if ((Get-CanonicalPath ([string]$reuse.source)) -ne [string]$reuse.source) { throw 'journal-noncanonical' }
    }
  }
}

function Get-UndoGroup([string]$JournalPath, [switch]$Linked) {
  $path = Get-CanonicalPath $JournalPath
  $root = Split-Path -Parent $path
  $seen = @{}; $game = ''; $expectedId = ''
  while ($path) {
    if ($seen.ContainsKey($path) -or -not (Test-BelongsToBase $path $root)) { throw 'journal-link-invalid' }
    $seen[$path] = $true
    $j = Load-Journal $path
    if (-not $j) { throw 'journal-unknown' }
    Assert-JournalData $j
    if ($expectedId -ne '' -and [string]$j.txid -ne $expectedId) { throw 'journal-link-invalid' }
    if ($game -eq '') { $game = Get-CanonicalPath ([string]$j.game_dir) }
    elseif ((Get-CanonicalPath ([string]$j.game_dir)) -ne $game) { throw 'journal-link-invalid' }
    [pscustomobject]@{ path=$path; data=$j }
    if (-not $Linked -or $null -eq $j.previous_journal) { break }
    $expectedId = [string]$j.previous_journal.txid
    $next = [string]$j.previous_journal.path
    if ($expectedId -eq '' -or (Get-CanonicalPath $next) -ne $next) { throw 'journal-link-invalid' }
    $path = $next
  }
}

function Get-CurrentRecord([string]$GameDir, [string]$JournalRoot) {
  if (-not (Test-OrdinaryPath $JournalRoot -Directory)) { return $null }
  $files = @(Get-ChildItem -LiteralPath $JournalRoot -File -Filter '*.json' -Force | Sort-Object LastWriteTimeUtc, Name -Descending)
  foreach ($file in $files) {
    $null = Test-OrdinaryPath $file.FullName
    $j = Load-Journal $file.FullName
    if (-not $j) { throw 'journal-unknown' }
    if ((Get-CanonicalPath ([string]$j.game_dir)) -eq $GameDir) {
      return [pscustomobject]@{ path=$file.FullName; data=$j }
    }
  }
  return $null
}

function Test-UndoGroup([object[]]$Group, [switch]$Removal) {
  Initialize-TxFiles
  # Simulate newest-first restoration over live hashes before the first write.
  # This also proves overlapping linked preimages connect to older written bytes.
  $virtual = @{}; $directoryOwners = @{}
  foreach ($record in $Group) {
    $j = $record.data
    if ($Removal -and $j.phase -notin @('applied', 'recovered')) { throw 'recovery-required' }
    if ([int]$j.schema_version -eq 2) {
      foreach ($dir in @($j.createdDirs)) {
        if ($dir.state -eq 'intent') { throw 'intent-uncertain' }
        if ($dir.state -in @('created','preserved') -and $dir.identity -ne '' -and (Test-OrdinaryPath $dir.path -Directory)) {
          $identity = [Susemi.TxFiles]::DirectoryIdentity($dir.path)
          if ($identity -eq $dir.identity) { $directoryOwners[[string]$dir.path] = $true }
          elseif (-not $directoryOwners.ContainsKey([string]$dir.path)) {
            $prefix = ([string]$dir.path).TrimEnd('\') + '\'
            foreach ($candidate in @($j.ops)) {
              if ($candidate.state -eq 'applied' -and ([string]$candidate.target).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and
                  (Test-OrdinaryPath $candidate.target)) { throw 'directory-changed' }
            }
          }
        }
      }
      foreach ($reuse in @($j.reused)) {
        if (-not (Test-OrdinaryPath $reuse.target) -or (Get-SHA256 $reuse.target) -ne $reuse.sourceSha) { throw 'target-changed' }
      }
    }
    foreach ($op in @($j.ops)) {
      if ($op.state -in @('intent', 'undo-intent')) { throw 'intent-uncertain' }
      if ([int]$j.schema_version -eq 2 -or -not [string]::IsNullOrEmpty([string]$op.tempPath)) {
        if ($op.tempState -eq 'intent' -or $op.backupState -eq 'intent') { throw 'intent-uncertain' }
        foreach ($check in @(
          @{ path=$op.tempPath; state=$op.tempState; owned=@('partial','verified'); sha=$op.tempSha },
          @{ path=$op.backupPath; state=$op.backupState; owned=@('partial','ready'); sha=$op.backupSha },
          @{ path=$op.displacedPath; state=$op.displacedState; owned=@('present'); sha=$op.displacedSha }
        )) {
          if ($check.state -in $check.owned) {
            if (-not (Test-OrdinaryPath $check.path)) { throw 'backup-missing' }
            if ((Get-SHA256 $check.path) -ne $check.sha) { throw 'backup-tampered' }
          }
        }
      }
      if ($op.op -eq 'replace' -and $op.state -eq 'applied') {
        if (-not (Test-OrdinaryPath $op.backupPath)) { throw 'backup-missing' }
        if ((Get-SHA256 $op.backupPath) -ne $op.beforeSha) { throw 'backup-tampered' }
      }
    }
    if ($j.phase -eq 'recovered') { continue }
    for ($i=@($j.ops).Count-1; $i -ge 0; $i--) {
      $op = $j.ops[$i]
      if ($op.state -notin @('applied','reverted')) { continue }
      $target = [string]$op.target
      if (-not $virtual.ContainsKey($target)) {
        $exists = Test-OrdinaryPath $target
        $hash = ''; if ($exists) { $hash = Get-SHA256 $target }
        if ($exists -and $hash -eq '') { throw 'target-unreadable' }
        $virtual[$target] = @{ exists=$exists; sha=$hash }
      }
      $live = $virtual[$target]
      if ($op.state -eq 'applied' -and (Test-OrdinaryPath $target)) { [Susemi.TxFiles]::CheckDeleteAccess($target) }
      if ($op.state -eq 'reverted') {
        if ($op.op -eq 'create' -and $live.exists) { throw 'target-changed' }
        if ($op.op -eq 'replace' -and (-not $live.exists -or $live.sha -ne $op.beforeSha)) { throw 'target-changed' }
        continue
      }
      if ($op.op -eq 'create') {
        if ($live.exists -and $live.sha -ne $op.sourceSha) { throw 'target-changed' }
        $virtual[$target] = @{ exists=$false; sha='' }
      } else {
        if (-not $live.exists -or ($live.sha -ne $op.sourceSha -and
            -not ([int]$j.schema_version -eq 1 -and -not $op.resource -and
              -not $target.StartsWith(([string]$j.game_dir + '\OptiScaler\'),[StringComparison]::OrdinalIgnoreCase) -and
              $live.sha -eq $op.beforeSha))) { throw 'target-changed' }
        $virtual[$target] = @{ exists=$true; sha=[string]$op.beforeSha }
      }
    }
  }
}

function Get-ActiveGroup([string]$GameDir, [string]$JournalRoot) {
  $record = Get-CurrentRecord $GameDir $JournalRoot
  while ($record -and $record.data.phase -eq 'recovered') {
    if ($null -eq $record.data.previous_journal) { return }
    $previous = $record.data.previous_journal
    $records = @(Get-UndoGroup $record.path -Linked)
    if ($records.Count -lt 2) { throw 'journal-link-invalid' }
    $record = $records[1]
  }
  if (-not $record) { return }
  $group = @(Get-UndoGroup $record.path -Linked)
  Test-UndoGroup $group -Removal
  foreach ($entry in $group) { $entry }
}

function Get-MissingDirectories([object[]]$Ops, [string]$GameDir) {
  $paths = @{}
  foreach ($op in $Ops) {
    $parents = @((Split-Path -Parent $op.target))
    if ($op.op -eq 'replace') { $parents += Split-Path -Parent $op.backupPath }
    foreach ($parent in $parents) {
      $cursor = Get-CanonicalPath $parent
      while ($cursor -ne $GameDir) {
        if (-not (Test-BelongsToBase $cursor $GameDir)) { throw 'path-escape' }
        if (-not (Test-OrdinaryPath $cursor -Directory)) { $paths[$cursor] = $true }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
      }
    }
  }
  foreach ($path in @($paths.Keys | Sort-Object { @($_ -split '[\\/]').Count }, { $_ })) {
    [pscustomobject]@{ path=$path; state='planned'; identity='' }
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
    $GameDir = Get-CanonicalPath $GameDir
    $StagedDir = Get-CanonicalPath $StagedDir
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
      $exTarget = Get-CanonicalPath ([string]$ex.target)
      $exSource = Get-CanonicalPath ([string]$ex.source)
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
      $ops += (BuildOp -Target $exTarget -Source $exSource -Backup $exBackup -Resource:([bool]$ex.resource) -ExpectedSha ([string]$ex.sha256))
      $extraIdx++
    }
  }

  # Validate each target: inside GameDir prefix check; reject dirs/reparse
  foreach ($op in $ops) {
    $null = Test-OrdinaryPath $op.target
    if (-not (Test-OrdinaryPath $op.source)) { throw 'stage-file-missing' }
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
    if ($op.resource -and ($op.expectedSha -notmatch '^[0-9a-f]{64}$' -or $op.sourceSha -ne $op.expectedSha)) { throw 'resource-source-pin-mismatch' }
  }
  $badOps = @($ops | Where-Object { -not $_.sourceSha })
  if ($badOps.Count -gt 0) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'sha-read-failure' -Human 'Could not compute SHA256 for staged files.'
    return 2
  }

  $JournalRoot = Get-CanonicalPath $JournalRoot
  $null = Test-OrdinaryPath $JournalRoot -Directory
  $previous = @(Get-ActiveGroup $GameDir $JournalRoot)
  $txId = New-TxId
  $reused = @(); $changes = @(); $index = 0
  foreach ($op in $ops) {
    if ($op.beforeExists -and $op.beforeSha -eq $op.sourceSha) {
      $reused += @{ target=$op.target; source=$op.source; sourceSha=$op.sourceSha }
      continue
    }
    if ($op.resource -and $op.beforeExists) {
      if ((Get-Item -LiteralPath $op.target).Length -eq 0) { throw 'resource-target-unowned' }
      $owned = $false
      foreach ($record in $previous) {
        foreach ($old in @($record.data.ops)) {
          if ($old.target -eq $op.target -and $old.state -eq 'applied' -and $old.sourceSha -eq $op.beforeSha) { $owned = $true; break }
        }
        if ($owned) { break }
      }
      if (-not $owned) { throw 'resource-target-unowned' }
    }
    $op.backupPath = Join-Path $GameDir ('.susemi-backup\' + $txId + '\' + ('{0:d4}.preimage' -f $index))
    $op.tempPath = Join-Path (Split-Path -Parent $op.target) ('.susemi-' + $txId + '-' + $index + '.tmp')
    $op.displacedPath = Join-Path (Split-Path -Parent $op.target) ('.susemi-' + $txId + '-' + $index + '.old')
    foreach ($path in @($op.backupPath, $op.tempPath, $op.displacedPath)) {
      if (Test-OrdinaryPath $path) { throw 'transaction-path-collision' }
    }
    $changes += $op; $index++
  }
  if ($changes.Count -eq 0) {
    Write-StatusLine 'no-op' 'already-installed' 'Every planned live file equals its verified source; no new ownership or journal.'
    return 0
  }
  $dirs = @(Get-MissingDirectories $changes $GameDir)
  $journalId = 'j_' + (Get-Date -Format 'yyyyMMddHHmmss_fff') + '_' + $txId
  $journalPath = Join-Path $JournalRoot "$($journalId)_plan.json"
  if (Test-OrdinaryPath $journalPath) { throw 'transaction-path-collision' }
  $null = Test-OrdinaryPath (Join-Path $JournalRoot ('.susemi-journal-' + $txId + '.tmp'))
  if (-not (Test-OrdinaryPath $JournalRoot -Directory)) { $null = [IO.Directory]::CreateDirectory($JournalRoot) }

  $journal = @{
    schema_version = 2
    txid           = $txId
    phase          = 'prepared'
    action         = 'plan'
    route          = $Route
    game_dir       = $GameDir
    staged_dir     = $StagedDir
    include_ual    = $IncludeUal.IsPresent
    created_at     = (Get-Date -Format 'o')
    ops            = $changes
    reused         = $reused
    createdDirs    = $dirs
    previous_journal = $null
  }
  if ($previous.Count -gt 0) { $journal.previous_journal = @{ path=$previous[0].path; txid=[string]$previous[0].data.txid } }

  if (-not (Atomic-JournalWrite -TargetPath $journalPath -JournalData $journal)) {
    Write-StatusLine -Status 'refused' -Reason 'journal-write-failed' -Human 'Failed to write journal file atomically.'
    return 1
  }

  $opCount = $changes.Count
  Write-StatusLine -Status 'planned' -Reason ("opcount-{0}" -f $opCount) -Human ("plan: planned {0} op(s), journal={1}" -f $opCount, $journalPath)
  return 0
}

function BuildOp {
  param(
    [string]$Target,
    [string]$Source,
    [string]$Backup,
    [switch]$Resource,
    [string]$ExpectedSha
  )
  $Target = Get-CanonicalPath $Target
  $Source = Get-CanonicalPath $Source
  $beforeExists = $false
  $beforeSha = ''
  if (Test-OrdinaryPath $Target) {
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
    resource     = $Resource.IsPresent
    expectedSha  = $ExpectedSha
    tempPath     = ''
    tempState    = 'none'
    tempSha      = ''
    backupState  = 'none'
    backupSha    = ''
    displacedPath = ''
    displacedState = 'none'
    displacedSha = ''
  }
}

function Read-Tx([string]$Path) {
  $j = Load-Journal $Path
  if (-not $j) { throw 'journal-unknown' }
  Assert-JournalData $j
  return $j
}

function Get-StreamSha([IO.Stream]$Stream) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Open-TxSources($Journal) {
  $streams = @{}
  try {
    foreach ($op in @($Journal.ops) + @($Journal.reused)) {
      if (-not (Test-OrdinaryPath $op.source)) { throw 'stage-file-missing' }
      $stream = [IO.File]::Open($op.source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      $streams[[string]$op.target] = $stream
      if ((Get-StreamSha $stream) -ne $op.sourceSha) { throw 'source-changed' }
      $stream.Position = 0
    }
    return $streams
  } catch {
    foreach ($stream in $streams.Values) { $stream.Dispose() }
    throw
  }
}

function Assert-TxBaselines($Journal) {
  Assert-JournalData $Journal
  foreach ($op in @($Journal.ops)) {
    $exists = Test-OrdinaryPath $op.target
    if ($op.state -eq 'applied') {
      if (-not $exists -or (Get-SHA256 $op.target) -ne $op.sourceSha) { throw 'target-changed' }
    } elseif ($op.state -eq '') {
      if (-not $op.beforeExists -and $exists) { throw 'target-appeared' }
      if ($op.beforeExists -and (-not $exists -or (Get-SHA256 $op.target) -ne $op.beforeSha)) { throw 'target-changed' }
    } else { throw 'intent-uncertain' }
    if ($op.backupState -eq 'ready') {
      if (-not (Test-OrdinaryPath $op.backupPath)) { throw 'backup-missing' }
      if ((Get-SHA256 $op.backupPath) -ne $op.beforeSha) { throw 'backup-tampered' }
    } elseif ($op.backupState -eq 'none' -and (Test-OrdinaryPath $op.backupPath)) { throw 'transaction-path-collision' }
    if ($op.tempState -eq 'none' -and (Test-OrdinaryPath $op.tempPath)) { throw 'transaction-path-collision' }
    if ($op.displacedState -eq 'none' -and (Test-OrdinaryPath $op.displacedPath)) { throw 'transaction-path-collision' }
  }
  foreach ($reuse in @($Journal.reused)) {
    if (-not (Test-OrdinaryPath $reuse.target) -or (Get-SHA256 $reuse.target) -ne $reuse.sourceSha) { throw 'target-changed' }
  }
  foreach ($dir in @($Journal.createdDirs)) {
    $exists = Test-OrdinaryPath $dir.path -Directory
    if ($dir.state -eq 'intent') { throw 'intent-uncertain' }
    if ($dir.state -eq 'created' -and (-not $exists -or [Susemi.TxFiles]::DirectoryIdentity($dir.path) -ne $dir.identity)) { throw 'directory-changed' }
  }
}

function Ensure-TxDirectories([string]$JournalPath, $Journal) {
  Initialize-TxFiles
  foreach ($dir in @($Journal.createdDirs)) {
    if ($dir.state -ne 'planned') { continue }
    $guard = [Susemi.TxFiles]::LockParents($dir.path)
    try {
      if (Test-OrdinaryPath $dir.path -Directory) { $dir.state = 'preserved'; Save-Tx $JournalPath $Journal; continue }
      $dir.state = 'intent'; Save-Tx $JournalPath $Journal
      if ([Susemi.TxFiles]::CreateDirectoryExclusive($dir.path)) {
        $dir.identity = [Susemi.TxFiles]::DirectoryIdentity($dir.path)
        $dir.state = 'created'
      } else {
        if (-not (Test-OrdinaryPath $dir.path -Directory)) { throw 'parent-not-directory' }
        $dir.state = 'preserved'
      }
      Save-Tx $JournalPath $Journal
    } finally { $guard.Dispose() }
  }
}

function Copy-JournalFile {
  param([IO.Stream]$Source, [string]$Path, [string]$ExpectedSha, [string]$Kind,
        $Op, [string]$JournalPath, $Journal)
  $state = $Kind + 'State'; $sha = $Kind + 'Sha'
  if (Test-OrdinaryPath $Path) { throw 'transaction-path-collision' }
  $created = $false; $output = $null
  $Op.$state = 'intent'; Save-Tx $JournalPath $Journal
  try {
    $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $created = $true
    try { $Source.Position = 0; $Source.CopyTo($output); $output.Flush($true) }
    finally { $output.Dispose(); $output = $null }
    if ((Get-SHA256 $Path) -ne $ExpectedSha) { throw 'copy-sha-mismatch' }
  } catch {
    if ($output) { $output.Dispose() }
    if ($created) {
      $actual = Get-SHA256 $Path
      if ($actual -eq '') { throw 'intent-uncertain' }
      $Op.$state = 'partial'; $Op.$sha = $actual
    } elseif (Test-OrdinaryPath $Path) { $Op.$state = 'foreign' }
    else { $Op.$state = 'none' }
    Save-Tx $JournalPath $Journal
    throw
  }
  $Op.$sha = $ExpectedSha
  $Op.$state = if ($Kind -eq 'backup') { 'ready' } else { 'verified' }
  Save-Tx $JournalPath $Journal
}

# ── ACTION: prepare ────────────────────────────────────────────────────────

function Invoke-Prepare {
  param([string]$JournalPath)
  $j = Read-Tx $JournalPath
  if ([int]$j.schema_version -ne 2 -or $j.phase -notin @('prepared','armed')) { throw 'journal-phase-invalid' }
  Initialize-TxFiles
  $streams = Open-TxSources $j
  try {
    Assert-TxBaselines $j
    Ensure-TxDirectories $JournalPath $j
    foreach ($op in @($j.ops)) {
      if ($op.op -ne 'replace' -or $op.backupState -eq 'ready') { continue }
      $guard = [Susemi.TxFiles]::LockParents($op.backupPath)
      $source = $null
      try {
        Assert-TxBaselines $j
        $source = [IO.File]::Open($op.target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ((Get-StreamSha $source) -ne $op.beforeSha) { throw 'target-changed' }
        Copy-JournalFile $source $op.backupPath $op.beforeSha 'backup' $op $JournalPath $j
      } finally { if ($source) { $source.Dispose() }; $guard.Dispose() }
    }
    $j.phase = 'armed'; Save-Tx $JournalPath $j
    Write-StatusLine 'prepared' 'ready' ("prepare: all preimages and owned directory records ready. Journal="+$JournalPath)
    return 0
  } catch {
    $reason = $_.Exception.Message
    $j.phase = 'prepared-failed'; Save-Tx $JournalPath $j
    if ($reason -notmatch '^[a-z][a-z0-9-]+$') { $reason = 'backup-copy-error' }
    Write-StatusLine 'prepared-failed' $reason ("prepare failed without unjournaled target writes. Journal="+$JournalPath)
    return 1
  } finally { foreach ($stream in $streams.Values) { $stream.Dispose() } }
}

# ── ACTION: apply ──────────────────────────────────────────────────────────

function Invoke-Apply {
  param(
    [string]$JournalPath,
    [string]$RaceProbe
  )

  $j = Read-Tx $JournalPath
  if ([int]$j.schema_version -ne 2 -or $j.phase -notin @('prepared','armed')) { throw 'journal-phase-invalid' }
  if ($j.phase -eq 'prepared' -and @($j.ops | Where-Object { $_.op -eq 'replace' }).Count -gt 0) { throw 'backups-not-ready' }
  Initialize-TxFiles
  $streams = Open-TxSources $j
  # Existing explicit test seam represents an external writer. It never
  # overwrites an existing file and never grants ownership of the probe.
  if (-not [string]::IsNullOrEmpty($RaceProbe)) {
    $probe = Get-CanonicalPath $RaceProbe
    if (-not (Test-BelongsToBase $probe $j.game_dir)) { throw 'path-escape' }
    $null = Test-OrdinaryPath $probe
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $probe))
    $bytes = New-Object byte[] 1024
    (New-Object Random 42).NextBytes($bytes)
    $output = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $output.Write($bytes,0,$bytes.Length) } finally { $output.Dispose() }
  }
  $appliedCount = 0
  try {
    Assert-TxBaselines $j
    Ensure-TxDirectories $JournalPath $j
    foreach ($op in @($j.ops)) {
      $guard = [Susemi.TxFiles]::LockParents($op.target)
      try {
        Assert-TxBaselines $j
        if ($op.tempState -eq 'none') {
          Copy-JournalFile $streams[[string]$op.target] $op.tempPath $op.sourceSha 'temp' $op $JournalPath $j
        } elseif ($op.tempState -ne 'verified' -or (Get-SHA256 $op.tempPath) -ne $op.sourceSha) { throw 'intent-uncertain' }
        # Final baseline/ancestor check occurs after the full temporary copy.
        Assert-TxBaselines $j
        $op.state = 'intent'; $j.phase = 'applying'; Save-Tx $JournalPath $j
        $baseline = ''; if ($op.op -eq 'replace') { $baseline = [string]$op.beforeSha }
        try { [Susemi.TxFiles]::Promote($op.tempPath, $op.target, $baseline, $op.displacedPath) }
        catch {
          # A returned failure with the verified temp still present and no
          # displaced file proves promotion did not start. An interrupted
          # intent or a displaced baseline is never inferred from equal bytes.
          if (-not (Test-OrdinaryPath $op.displacedPath) -and
              (Test-OrdinaryPath $op.tempPath) -and (Get-SHA256 $op.tempPath) -eq $op.sourceSha -and
              ($op.op -eq 'create' -or (Get-SHA256 $op.target) -eq $op.beforeSha)) {
            $op.state = ''; Save-Tx $JournalPath $j
          }
          throw
        }
        if ((Get-SHA256 $op.target) -ne $op.sourceSha) { throw 'sha-mismatch-after-promotion' }
        $op.state = 'applied'; $op.tempState = 'consumed'
        if ($op.op -eq 'replace') { $op.displacedState = 'present'; $op.displacedSha = $op.beforeSha }
        Save-Tx $JournalPath $j
        $appliedCount++
        if ($op.displacedState -eq 'present') {
          [Susemi.TxFiles]::DeleteOwned($op.displacedPath, $op.displacedSha)
          $op.displacedState = 'removed'; Save-Tx $JournalPath $j
        }
      } finally { $guard.Dispose() }
    }
    Assert-TxBaselines $j
    $j.phase = 'applied'; Save-Tx $JournalPath $j
    Write-StatusLine 'installed' ("applied-"+$appliedCount) ("apply: verified all written and reused live bytes. Journal="+$JournalPath)
    return 0
  } catch {
    $errorObject = $_.Exception
    while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
    $reason = $errorObject.Message
    if ($reason -notmatch '^[a-z][a-z0-9-]+$') { $reason = 'copy-error' }
    $uncertain = @($j.ops | Where-Object { $_.state -eq 'intent' -or $_.tempState -eq 'intent' -or $_.backupState -eq 'intent' }).Count -gt 0 -or
      @($j.createdDirs | Where-Object { $_.state -eq 'intent' }).Count -gt 0
    $status = 'apply-failed'; $j.phase = 'apply-failed'
    if ($uncertain) { $status = 'recovery-required'; $j.phase = 'recovery-required' }
    elseif ($reason -eq 'target-appeared') { $status = 'conflict'; $j.phase = 'apply-conflict' }
    Save-Tx $JournalPath $j
    Write-StatusLine $status $reason ("apply stopped; recovery must validate the entire current undo set. Journal="+$JournalPath)
    return 1
  } finally {
    foreach ($stream in $streams.Values) { $stream.Dispose() }
  }
}

function Clear-TxPrivateFiles([string]$JournalPath, $Journal) {
  foreach ($op in @($Journal.ops)) {
    $checks = @(
      @{ kind='temp'; path=[string]$op.tempPath; states=@('partial','verified'); sha=[string]$op.tempSha },
      @{ kind='displaced'; path=[string]$op.displacedPath; states=@('present'); sha=[string]$op.displacedSha }
    )
    if ([int]$Journal.schema_version -eq 2) {
      $checks += @{ kind='backup'; path=[string]$op.backupPath; states=@('partial','ready'); sha=[string]$op.backupSha }
    }
    foreach ($check in $checks) {
      $field = $check.kind + 'State'
      if ($op.$field -notin $check.states) { continue }
      $guard = [Susemi.TxFiles]::LockParents($check.path)
      try {
        [Susemi.TxFiles]::DeleteOwned($check.path, $check.sha)
        $op.$field = 'removed'; Save-Tx $JournalPath $Journal
      } finally { $guard.Dispose() }
    }
  }
}

function Remove-TxDirectories([string]$JournalPath, $Journal) {
  # Schema1 never conveys directory ownership, even if somebody added a field.
  if ([int]$Journal.schema_version -ne 2) { return }
  $dirs = @($Journal.createdDirs)
  for ($i=$dirs.Count-1; $i -ge 0; $i--) {
    $dir = $dirs[$i]
    if ($dir.state -ne 'created') { continue }
    $guard = [Susemi.TxFiles]::LockParents($dir.path)
    try {
      if (-not (Test-OrdinaryPath $dir.path -Directory)) { $dir.state = 'removed' }
      elseif ([Susemi.TxFiles]::DirectoryIdentity($dir.path) -ne $dir.identity -or
          [IO.Directory]::GetFileSystemEntries($dir.path).Length -ne 0) { $dir.state = 'preserved' }
      else {
        # Nonrecursive deletion checks emptiness again inside the filesystem.
        try { [IO.Directory]::Delete($dir.path, $false); $dir.state = 'removed' }
        catch {
          if ((Test-OrdinaryPath $dir.path -Directory) -and [IO.Directory]::GetFileSystemEntries($dir.path).Length -gt 0) { $dir.state = 'preserved' }
          else { throw }
        }
      }
      Save-Tx $JournalPath $Journal
    } finally { $guard.Dispose() }
  }
}

function Invoke-Undo {
  param([string]$JournalPath, [switch]$Linked, [switch]$Removal)
  Initialize-TxFiles
  $group = @(Get-UndoGroup $JournalPath -Linked:$Linked)
  # All live targets, all backups, all ancestors, and all linked preimages are
  # validated as one set. Refusal here changes neither targets nor journals.
  try { Test-UndoGroup $group -Removal:$Removal }
  catch {
    $reason = $_.Exception.Message
    if ($reason -notmatch '^[a-z][a-z0-9-]+$') { $reason = 'undo-preflight-failed' }
    $status = if ($Removal) { 'refused' } else { 'recovery-required' }
    Write-StatusLine $status $reason ("Undo refused before any mutation. Journal="+$JournalPath)
    return 1
  }
  $allRecovered = @($group | Where-Object { $_.data.phase -ne 'recovered' }).Count -eq 0
  if ($allRecovered) {
    foreach ($record in $group) {
      foreach ($op in @($record.data.ops)) {
        if ($op.op -eq 'create' -and (Test-OrdinaryPath $op.target)) { throw 'reinstalled-since-removal' }
        if ($op.op -eq 'replace' -and (-not (Test-OrdinaryPath $op.target) -or (Get-SHA256 $op.target) -ne $op.beforeSha)) { throw 'reinstalled-since-removal' }
      }
    }
    if ($Removal) { Write-StatusLine 'no-op' 'already-removed' 'Already removed; foreign files and directories retained.' }
    else { Write-StatusLine 'already-recovered' 'nothing-to-do' 'Journal already recovered.' }
    return 0
  }
  # Historical replacements get exclusively named restore paths before any
  # file mutation; this adds no directory ownership to their schema1 journals.
  foreach ($record in $group) {
    if ([int]$record.data.schema_version -ne 1) { continue }
    foreach ($op in @($record.data.ops)) {
      if ($op.op -ne 'replace' -or $op.state -ne 'applied' -or $op.tempPath) { continue }
      $suffix = '.susemi-restore-' + (New-TxId)
      $fields = @{ tempPath=($op.target+$suffix+'.tmp'); tempState='none'; tempSha='';
                   displacedPath=($op.target+$suffix+'.old'); displacedState='none'; displacedSha='' }
      foreach ($name in $fields.Keys) { $op | Add-Member -NotePropertyName $name -NotePropertyValue $fields[$name] -Force }
      if (Test-OrdinaryPath $op.tempPath) { throw 'transaction-path-collision' }
      if (Test-OrdinaryPath $op.displacedPath) { throw 'transaction-path-collision' }
    }
  }
  $count = 0
  foreach ($record in $group) {
    $j = $record.data
    if ($j.phase -eq 'recovered') { continue }
    try {
      $j.phase = 'recovering'; Save-Tx $record.path $j
      for ($i=@($j.ops).Count-1; $i -ge 0; $i--) {
        $op = $j.ops[$i]
        if ($op.state -ne 'applied') { continue }
        $guard = [Susemi.TxFiles]::LockParents($op.target)
        $backup = $null
        try {
          if ($op.op -eq 'replace') {
            $current = Get-SHA256 $op.target
            if ([int]$j.schema_version -eq 1 -and $current -eq $op.beforeSha) {
              $op.state = 'reverted'; Save-Tx $record.path $j; $count++; continue
            }
            if ($current -ne $op.sourceSha) { throw 'target-changed' }
            $backup = [IO.File]::Open($op.backupPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            if ((Get-StreamSha $backup) -ne $op.beforeSha) { throw 'backup-tampered' }
            if ($op.tempState -eq 'verified' -and (Get-SHA256 $op.tempPath) -eq $op.beforeSha) {
              # Verified pre-intent restore temp from an interrupted attempt.
            } else {
              Copy-JournalFile $backup $op.tempPath $op.beforeSha 'temp' $op $record.path $j
            }
            if ((Get-SHA256 $op.target) -ne $op.sourceSha) { throw 'target-changed' }
            $op.state = 'undo-intent'; Save-Tx $record.path $j
            [Susemi.TxFiles]::Promote($op.tempPath, $op.target, $op.sourceSha, $op.displacedPath)
            if ((Get-SHA256 $op.target) -ne $op.beforeSha) { throw 'restore-verify-failed' }
            $op.tempState = 'consumed'; $op.displacedState = 'present'; $op.displacedSha = $op.sourceSha
          } else {
            $op.state = 'undo-intent'; Save-Tx $record.path $j
            if (Test-OrdinaryPath $op.target) { [Susemi.TxFiles]::DeleteOwned($op.target, $op.sourceSha) }
          }
          $op.state = 'reverted'; Save-Tx $record.path $j; $count++
        } finally { if ($backup) { $backup.Dispose() }; $guard.Dispose() }
      }
      Clear-TxPrivateFiles $record.path $j
      Remove-TxDirectories $record.path $j
      foreach ($op in @($j.ops)) {
        if ($op.state -ne 'reverted') { continue }
        if ($op.op -eq 'create' -and (Test-OrdinaryPath $op.target)) { throw 'restore-verify-failed' }
        if ($op.op -eq 'replace' -and (Get-SHA256 $op.target) -ne $op.beforeSha) { throw 'restore-verify-failed' }
      }
      $j.phase = 'recovered'; Save-Tx $record.path $j
    } catch {
      $errorObject = $_.Exception
      while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
      $reason = $errorObject.Message
      if ($reason -notmatch '^[a-z][a-z0-9-]+$') { $reason = 'recovery-incomplete' }
      $j.phase = 'recovery-required'; Save-Tx $record.path $j
      Write-StatusLine 'recovery-required' $reason ("Undo incomplete; remaining bytes preserved. Journal="+$record.path)
      return 1
    }
  }
  if ($Removal) { Write-StatusLine 'removed' ("opcount-"+$count) ("Removed validated linked group. Journal="+$JournalPath) }
  else { Write-StatusLine 'recovered' 'ok' ("Recovered current transaction only. Journal="+$JournalPath) }
  return 0
}

function Invoke-Recover([string]$JournalPath) { Invoke-Undo $JournalPath }
function Invoke-Rollback([string]$JournalPath) { Invoke-Undo $JournalPath }

function Invoke-Remove([string]$GameDir, [string]$JournalRoot) {
  $GameDir = Get-CanonicalPath $GameDir
  if (-not (Test-OrdinaryPath $GameDir -Directory)) { throw 'game-dir-missing' }
  if ([string]::IsNullOrEmpty($JournalRoot)) { $JournalRoot = Join-Path $env:LOCALAPPDATA 'susemi-installer\journal' }
  $record = Get-CurrentRecord $GameDir (Get-CanonicalPath $JournalRoot)
  if (-not $record) { Write-StatusLine 'missing-input' 'no-install-record' 'No install record for this game directory.'; return 1 }
  Invoke-Undo $record.path -Linked -Removal
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

try {
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
  'remove' {
    if (-not $sawGameDir) {
      Write-StatusLine 'invalid-invocation' 'missing-gamedir' 'remove requires -GameDir.'
      exit 2
    }
    $code = 1
    Invoke-Remove -GameDir $params['GameDir'] -JournalRoot $params['JournalRoot'] | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    exit $code
  }
  default {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unknown-action' -Human "Unknown action: $($action)"
    exit 2
  }
}
} catch {
  $errorObject = $_.Exception
  while ($errorObject.InnerException) { $errorObject = $errorObject.InnerException }
  $reason = $errorObject.Message
  if ($reason -notmatch '^[a-z][a-z0-9-]+$') { $reason = 'transaction-failed' }
  $status = 'refused'
  if ($action -in @('apply','prepare','recover','rollback')) { $status = 'recovery-required' }
  Write-StatusLine $status $reason ('Transaction stopped; ambiguous bytes are preserved. ' + $errorObject.Message)
  exit 1
}
