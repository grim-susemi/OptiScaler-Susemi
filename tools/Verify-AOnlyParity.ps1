<#
    Repair-r2 (B3) A-only parity: compare a new A ZIP against a prior A baseline
    ZIP under a named expected-delta contract, without weakening the comparison
    on any non-exempt member.

    - Added/removed members must EXACTLY equal -ExpectedAdded/-ExpectedRemoved.
    - Changed members (same name, different SHA-256) must each be named either
      in -ExpectedChangedContent (reviewed content change) or in
      -ExpectedChangedEol (byte difference must prove CR-stripped equal,
      otherwise FAIL).
    - Every other common member must be hash-identical; any unnamed difference
      FAILs with the member named.
    - SHA256SUMS.txt is auto-exempt (per-archive generated manifest); its two
      digests are reported, not compared.

    Exit 0 = contract holds; exit 1 = any unnamed delta. No downloads, no
    archive writes; temp use is limited to the evidence text file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NewZip,
    [Parameter(Mandatory = $true)][string]$BaselineZip,
    [string[]]$ExpectedAdded = @(),
    [string[]]$ExpectedRemoved = @(),
    [string[]]$ExpectedChangedContent = @(),
    [string[]]$ExpectedChangedEol = @(),
    [string]$EvidenceDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipBytes {
    param([string]$ZipPath)
    $table = @{}
    $z = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $z.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }
            $s = $e.Open(); $m = New-Object IO.MemoryStream
            try { $s.CopyTo($m); $table[$e.FullName] = $m.ToArray() }
            finally { $s.Dispose(); $m.Dispose() }
        }
    } finally { $z.Dispose() }
    return $table
}

function Get-Sha256([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $h.Dispose() }
}

if (-not (Test-Path -LiteralPath $NewZip -PathType Leaf)) { throw "New ZIP not found: $NewZip" }
if (-not (Test-Path -LiteralPath $BaselineZip -PathType Leaf)) { throw "Baseline ZIP not found: $BaselineZip" }
$new = Get-ZipBytes $NewZip
$base = Get-ZipBytes $BaselineZip

$lines = New-Object System.Collections.ArrayList
function Report([string]$Line) { Write-Output $Line; [void]$lines.Add($Line) }

$failures = New-Object System.Collections.ArrayList
$added = @($new.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
$removed = @($base.Keys | Where-Object { -not $new.ContainsKey($_) } | Sort-Object)
$changed = @($new.Keys | Where-Object { $base.ContainsKey($_) -and (Get-Sha256 $new[$_]) -ne (Get-Sha256 $base[$_]) } | Sort-Object)
$same = @($new.Keys | Where-Object { $base.ContainsKey($_) -and (Get-Sha256 $new[$_] ) -eq (Get-Sha256 $base[$_]) } | Sort-Object)

Report ("new={0} members={1} baseline={2} members={3}" -f $NewZip, $new.Count, $BaselineZip, $base.Count)
Report ("added=[{0}] expected-added=[{1}]" -f ($added -join ', '), ($ExpectedAdded -join ', '))
$addOk = ((Compare-Object $added $ExpectedAdded -SyncWindow 0) -eq $null) -and ($added.Count -eq $ExpectedAdded.Count)
if (-not $addOk) { [void]$failures.Add("unnamed-added=[$($added -join ', ')]") }
Report ("removed=[{0}] expected-removed=[{1}]" -f ($removed -join ', '), ($ExpectedRemoved -join ', '))
$remOk = ((Compare-Object $removed $ExpectedRemoved -SyncWindow 0) -eq $null) -and ($removed.Count -eq $ExpectedRemoved.Count)
if (-not $remOk) { [void]$failures.Add("unnamed-removed=[$($removed -join ', ')]") }

Report "changed-member disposition:"
foreach ($m in $changed) {
    if ($m -eq 'SHA256SUMS.txt') { Report "  EXEMPT-GENERATED: $m (per-archive manifest)"; continue }
    if ($ExpectedChangedContent -contains $m) { Report "  NAMED-CONTENT: $m"; continue }
    if ($ExpectedChangedEol -contains $m) {
        $a = [Text.Encoding]::UTF8.GetString($new[$m]) -replace "`r", ''
        $b = [Text.Encoding]::UTF8.GetString($base[$m]) -replace "`r", ''
        if ($a -ceq $b) { Report "  NAMED-EOL-ONLY (cr-stripped equal): $m"; continue }
        [void]$failures.Add("eol-claim-false-content-differs=$m")
        Report "  FAIL-EOL-CLAIM-FALSE: $m"
        continue
    }
    [void]$failures.Add("unnamed-changed=$m")
    Report "  FAIL-UNNAMED-CHANGED: $m"
}
$namedChanged = @($ExpectedChangedContent + $ExpectedChangedEol | Sort-Object -Unique)
foreach ($m in $namedChanged) {
    if (($changed -notcontains $m) -and ($m -ne 'SHA256SUMS.txt')) {
        Report "  NOTE-EXPECTED-BUT-IDENTICAL: $m"
    }
}
Report ("identical-non-exempt-common={0}" -f $same.Count)

if ($EvidenceDir -ne '') {
    if (-not (Test-Path -LiteralPath $EvidenceDir)) { New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null }
    [IO.File]::WriteAllLines((Join-Path $EvidenceDir 'parity-delta-table.txt'), $lines, [Text.UTF8Encoding]::new($false))
}
if ($failures.Count -gt 0) {
    Write-Output ("PARITY-FAIL: {0}" -f ($failures -join '; '))
    exit 1
}
Write-Output "PARITY-PASS: named deltas hold, all other members identical"
exit 0
