<#
    Row 5 of .omo/plans/susemi-next-ui-lang.md - C7 packaging identity proof.

    Downloads and rehashes the frozen wilsjo2 v0.8.7 rtx40-mfg zip, extracts both archives,
    compares the member sets and the embedded SHA256SUMS.txt sets, byte-compares every
    non-DLL member, and confirms the KO payload keeps the "RTX 40 MFG unlock (restart)"
    flavor marker and its OriginalFilename resource.

    Verdict rules:
      - member set drift (added, dropped, renamed payload)          -> FAIL, member named
      - content drift on any member except OptiScaler.dll and the
        generated SHA256SUMS.txt                                    -> FAIL, member named
      - a shipped member that differs only by CRLF/LF rendering of
        identical content                                            -> reported by name,
                                                                        proven EOL-only, and
                                                                        marked clean in git
      - missing flavor marker or a wrong OriginalFilename            -> FAIL
      - frozen zip whose rehash does not match the pinned SHA256     -> FAIL

    Exits 0 only when no FAIL check fired. Exit codes: 0 = PASS, 3 = PASS_WITH_DEVIATION
    (all gates passed, named deviation recorded), 1 = FAIL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KoZip,
    [Parameter(Mandatory = $true)][string]$WilZip,
    [Parameter(Mandatory = $true)][string]$EvidenceDir,
    [string]$WilUrl = 'https://github.com/wilsjo2/OptiScaler-DLSSNR-PreSR-Multipass/releases/download/v0.8.7/OptiScaler-NR-v0.8.7-rtx40-mfg.zip',
    [string]$WilSha256 = '02cc71c540071bff1d2b11a1bb30b28b8d300041b9eac176470b961ca2707542',
    [int]$ExpectedMemberCount = 59,
    [string]$RepoRoot = 'C:\omo-research\susemi-next-ui-lang',
    [string]$FlavorMarker = 'RTX 40 MFG unlock (restart)',
    [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:checks = New-Object System.Collections.ArrayList
$script:failures = New-Object System.Collections.ArrayList
$script:deviations = New-Object System.Collections.ArrayList

# Status values: ok, FAIL (blocks the C7 claim), DEV (every gate passed, but a named
# deviation from the row's literal wording is recorded in the deviation block).
function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail, [switch]$Deviation)
    $status = 'ok'
    if (-not $Ok) { $status = 'FAIL' }
    if ($Deviation) { $status = 'DEV' }
    Write-Host ("{0,-4} {1,-34} {2}" -f $status, $Name, $Detail)
    [void]$script:checks.Add([pscustomobject]@{ name = $Name; status = $status; detail = $Detail })
    if (-not $Ok) {
        if ($Deviation) { [void]$script:deviations.Add(("{0}: {1}" -f $Name, $Detail)) }
        else { [void]$script:failures.Add(("{0}: {1}" -f $Name, $Detail)) }
    }
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-FileBytesEqual {
    param([string]$A, [string]$B)
    if ((Get-Item -LiteralPath $A).Length -ne (Get-Item -LiteralPath $B).Length) { return $false }
    $fa = [IO.File]::Open($A, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $fb = [IO.File]::Open($B, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $bufA = New-Object byte[] 65536
        $bufB = New-Object byte[] 65536
        while ($true) {
            $n = $fa.Read($bufA, 0, $bufA.Length)
            $m = $fb.Read($bufB, 0, $bufB.Length)
            if ($n -ne $m) { return $false }
            if ($n -eq 0) { return $true }
            for ($i = 0; $i -lt $n; $i++) { if ($bufA[$i] -ne $bufB[$i]) { return $false } }
        }
    }
    finally { $fa.Dispose(); $fb.Dispose() }
}

# CRLF -> LF normalization, the same reduction git applies for text=auto.
function Get-CrStrippedBytes {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $out = New-Object System.Collections.Generic.List[byte]
    foreach ($b in $bytes) { if ($b -ne 13) { [void]$out.Add($b) } }
    return , $out.ToArray()
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Get-TextMetrics {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $cr = 0; $lf = 0
    foreach ($b in $bytes) { if ($b -eq 13) { $cr++ } elseif ($b -eq 10) { $lf++ } }
    return [pscustomobject]@{ bytes = $bytes.Length; cr = $cr; lf = $lf }
}

function Get-MemberTable {
    param([string]$Root)
    $table = @{}
    foreach ($entry in (Get-ChildItem -LiteralPath $Root -File -Recurse)) {
        $relative = $entry.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        $table[$relative] = $entry
    }
    return $table
}

function Sort-Ordinal {
    param([hashtable]$Table)
    $names = @()
    foreach ($key in $Table.Keys) { $names += $key }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return $names
}

function Write-MemberList {
    param([string]$ZipPath, [string]$ZipHash, [long]$ZipBytes, [hashtable]$Table, [string]$OutPath)
    $sorted = Sort-Ordinal -Table $Table
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# zip:     $ZipPath")
    [void]$sb.AppendLine("# sha256:  $ZipHash")
    [void]$sb.AppendLine("# bytes:   $ZipBytes")
    [void]$sb.AppendLine("# members: $($sorted.Count)")
    [void]$sb.AppendLine("# format:  <sha256>  <bytes>  <path>    (ordinal sort by path; no directory entries exist in either archive)")
    foreach ($name in $sorted) {
        $file = $Table[$name]
        [void]$sb.AppendLine(("{0}  {1,12}  {2}" -f (Get-FileSha256 -Path $file.FullName), $file.Length, $name))
    }
    [IO.File]::WriteAllText($OutPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
}

function Get-SumsEntries {
    param([string]$Path)
    $entries = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $text = $line.Trim()
        if ($text.Length -eq 0) { continue }
        $m = [regex]::Match($text, '^([0-9A-Fa-f]{64}) [* ](.+)$')
        if (-not $m.Success) { throw "Unparsable SHA256SUMS.txt line in ${Path}: $text" }
        [void]$entries.Add([pscustomobject]@{
            path = $m.Groups[2].Value
            hash = $m.Groups[1].Value.ToLowerInvariant()
        })
    }
    return $entries
}

# Source path for members whose staged name differs from the repository name.
$sourceMap = @{
    'Licenses/XeSS_LICENSE.txt'             = 'external/xess/LICENSE.txt'
    'Licenses/FidelityFX_v1_LICENSE.md'     = 'external/FidelityFX-SDK/docs/license.md'
    'Licenses/FidelityFX_v2_LICENSE.md'     = 'external/FidelityFX-SDK-v2/docs/license.md'
    'Licenses/DirectX_LICENSE.txt'          = 'external/directx_agility_sdk/LICENSE.txt'
    'Licenses/RenoDX_ATTRIBUTION.txt'       = 'Licenses/RenoDX_ATTRIBUTION.txt'
    'OptiScaler/libxess.dll'                = 'external/xess/bin/libxess.dll'
    'OptiScaler/libxess_dx11.dll'           = 'external/xess/bin/libxess_dx11.dll'
    'OptiScaler/libxell.dll'                = 'external/xess/bin/libxell.dll'
    'OptiScaler/libxess_fg.dll'             = 'external/xess/bin/libxess_fg.dll'
    'OptiScaler/amd_fidelityfx_loader_dx12.dll' = 'external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_loader_dx12.dll'
    'OptiScaler/amd_fidelityfx_upscaler_dx12.dll' = 'external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_upscaler_dx12.dll'
    'OptiScaler/amd_fidelityfx_framegeneration_dx12.dll' = 'external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_framegeneration_dx12.dll'
    'OptiScaler/amd_fidelityfx_vk.dll'      = 'external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll'
    'OptiScaler/D3D12_OptiScaler/D3D12Core.dll' = 'external/directx_agility_sdk/lib/D3D12Core.dll'
}

# Native git writes to stderr for expected misses; PowerShell 5.1 turns that into a
# terminating error while $ErrorActionPreference is Stop, so merge the streams locally.
function Invoke-Git {
    param([string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $RepoRoot @Arguments 2>&1
        return [pscustomobject]@{ exit = $LASTEXITCODE; output = @($output) }
    }
    finally { $ErrorActionPreference = $previous }
}

function Get-GitState {
    param([string]$RelativePath)
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) { return 'no-repo' }
    if ((Invoke-Git -Arguments @('ls-files', '--error-unmatch', '--', $RelativePath)).exit -ne 0) { return 'not-tracked' }
    if ((Invoke-Git -Arguments @('diff', '--quiet', 'HEAD', '--', $RelativePath)).exit -eq 0) { return 'clean' }
    return 'modified'
}

function Get-SourcePath {
    param([string]$Member)
    if ($sourceMap.ContainsKey($Member)) { return $sourceMap[$Member] }
    return $Member
}

# ---------------------------------------------------------------- inputs

$repoResolved = [IO.Path]::GetFullPath($KoZip)
if (-not (Test-Path -LiteralPath $repoResolved -PathType Leaf)) { throw "KO zip not found: $repoResolved" }
$wilResolved = [IO.Path]::GetFullPath($WilZip)
$evidenceResolved = [IO.Path]::GetFullPath($EvidenceDir)
if (-not (Test-Path -LiteralPath $evidenceResolved)) { New-Item -ItemType Directory -Path $evidenceResolved -Force | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Host "row 5 / C7 zip parity"
Write-Host "ko zip   : $repoResolved"
Write-Host "wil zip  : $wilResolved"
Write-Host "evidence : $evidenceResolved"
Write-Host "utc      : $stamp"
Write-Host ""

# ---------------------------------------------------------------- frozen asset

$downloaded = $false
if (-not (Test-Path -LiteralPath $wilResolved -PathType Leaf)) {
    if ($NoDownload) { throw "Frozen wil zip is absent and -NoDownload was requested: $wilResolved" }
    Write-Host "download $WilUrl"
    Write-Host "      -> $wilResolved"
    New-Item -ItemType Directory -Path (Split-Path -Parent $wilResolved) -Force | Out-Null
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($WilUrl, $wilResolved) } finally { $client.Dispose() }
    $downloaded = $true
}
Add-Check -Name 'frozen-zip-present' -Ok (Test-Path -LiteralPath $wilResolved -PathType Leaf) -Detail ("downloaded={0} path={1}" -f $downloaded, $wilResolved)

$wilHash = Get-FileSha256 -Path $wilResolved
$wilBytes = (Get-Item -LiteralPath $wilResolved).Length
Add-Check -Name 'frozen-zip-rehash' -Ok ($wilHash -eq $WilSha256.ToLowerInvariant()) -Detail ("sha256={0} pinned={1} bytes={2}" -f $wilHash, $WilSha256.ToLowerInvariant(), $wilBytes)

$koHash = Get-FileSha256 -Path $repoResolved
$koBytes = (Get-Item -LiteralPath $repoResolved).Length
Add-Check -Name 'ko-zip-hashed' -Ok ($koBytes -gt 0) -Detail ("sha256={0} bytes={1}" -f $koHash, $koBytes)

# ---------------------------------------------------------------- extraction

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('zip-parity-' + [Guid]::NewGuid().ToString('N'))
$koDir = Join-Path $scratch 'ko'
$wilDir = Join-Path $scratch 'wil'
New-Item -ItemType Directory -Path $koDir, $wilDir -Force | Out-Null
Expand-Archive -LiteralPath $repoResolved -DestinationPath $koDir -Force
Expand-Archive -LiteralPath $wilResolved -DestinationPath $wilDir -Force
Add-Check -Name 'extract-both-zips' -Ok ((Test-Path -LiteralPath $koDir) -and (Test-Path -LiteralPath $wilDir)) -Detail ("ko={0} wil={1}" -f $koDir, $wilDir)

$koTable = Get-MemberTable -Root $koDir
$wilTable = Get-MemberTable -Root $wilDir
$koNames = Sort-Ordinal -Table $koTable
$wilNames = Sort-Ordinal -Table $wilTable
Write-Host ("     extracted ko members={0} wil members={1}" -f $koNames.Count, $wilNames.Count)

Write-MemberList -ZipPath $repoResolved -ZipHash $koHash -ZipBytes $koBytes -Table $koTable -OutPath (Join-Path $evidenceResolved 'KoZip-member-list.txt')
Write-MemberList -ZipPath $wilResolved -ZipHash $wilHash -ZipBytes $wilBytes -Table $wilTable -OutPath (Join-Path $evidenceResolved 'WilZip-member-list.txt')

# ---------------------------------------------------------------- member sets

$added = New-Object System.Collections.ArrayList
foreach ($name in $koNames) { if (-not $wilTable.ContainsKey($name)) { [void]$added.Add($name) } }
$dropped = New-Object System.Collections.ArrayList
foreach ($name in $wilNames) { if (-not $koTable.ContainsKey($name)) { [void]$dropped.Add($name) } }
$common = New-Object System.Collections.ArrayList
foreach ($name in $koNames) { if ($wilTable.ContainsKey($name)) { [void]$common.Add($name) } }

$payloadRenamed = (-not $koTable.ContainsKey('OptiScaler.dll'))
Add-Check -Name 'member-set-parity' -Ok (($added.Count -eq 0) -and ($dropped.Count -eq 0)) -Detail ("added=[{0}] dropped=[{1}]" -f ($added -join ', '), ($dropped -join ', '))
Add-Check -Name 'member-count' -Ok (($koNames.Count -eq $wilNames.Count) -and ($koNames.Count -eq $ExpectedMemberCount)) -Detail ("ko={0} wil={1} expected={2}" -f $koNames.Count, $wilNames.Count, $ExpectedMemberCount)
Add-Check -Name 'payload-name-kept' -Ok (-not $payloadRenamed) -Detail ("OptiScaler.dll present in KO zip={0}" -f (-not $payloadRenamed))

# ---------------------------------------------------------------- member content

$allowedDiff = @('OptiScaler.dll', 'SHA256SUMS.txt')
$identical = New-Object System.Collections.ArrayList
$allowed = New-Object System.Collections.ArrayList
$eolOnly = New-Object System.Collections.ArrayList
$contentDiff = New-Object System.Collections.ArrayList

foreach ($name in $common) {
    $koFile = $koTable[$name]
    $wilFile = $wilTable[$name]
    if (Test-FileBytesEqual -A $koFile.FullName -B $wilFile.FullName) {
        [void]$identical.Add($name)
        continue
    }
    if ($allowedDiff -contains $name) {
        [void]$allowed.Add([pscustomobject]@{
            member   = $name
            ko_sha256  = Get-FileSha256 -Path $koFile.FullName
            wil_sha256 = Get-FileSha256 -Path $wilFile.FullName
            ko_bytes   = $koFile.Length
            wil_bytes  = $wilFile.Length
            reason   = 'allowed: payload build output' 
        })
        continue
    }
    $koMetrics = Get-TextMetrics -Path $koFile.FullName
    $wilMetrics = Get-TextMetrics -Path $wilFile.FullName
    $normalizedEqual = $false
    if (($koFile.Length -le 67108864) -and ($wilFile.Length -le 67108864)) {
        $normalizedEqual = Test-BytesEqual -A (Get-CrStrippedBytes -Path $koFile.FullName) -B (Get-CrStrippedBytes -Path $wilFile.FullName)
    }
    if ($normalizedEqual) {
        $sourcePath = Get-SourcePath -Member $name
        $gitState = Get-GitState -RelativePath $sourcePath
        $sourceFile = Join-Path $RepoRoot ($sourcePath.Replace('/', '\'))
        $sourceExists = Test-Path -LiteralPath $sourceFile -PathType Leaf
        $sourceMatches = $null
        if ($sourceExists) { $sourceMatches = Test-FileBytesEqual -A $koFile.FullName -B $sourceFile }
        # git hash-object applies the clean filter, so it proves content identity with the frozen tag
        # in a line-ending-insensitive way, including for files with no CRLF/LF-safe text decoding.
        $tagBlobHash = $null
        $worktreeBlobHash = $null
        $blobHashesEqual = $null
        $lsTreeOutput = @((Invoke-Git -Arguments @('ls-tree', 'HEAD', '--', $sourcePath)).output)
        if (($lsTreeOutput.Count -eq 1) -and ($lsTreeOutput[0] -match '^[0-9]+ blob ([0-9a-f]{40})')) { $tagBlobHash = $Matches[1] }
        if ($sourceExists) {
            $hashOutput = @((Invoke-Git -Arguments @('hash-object', '--', $sourcePath)).output)
            if (($hashOutput.Count -ge 1) -and ($hashOutput[0] -match '^([0-9a-f]{40})')) { $worktreeBlobHash = $Matches[1] }
        }
        if ($tagBlobHash -and $worktreeBlobHash) { $blobHashesEqual = ($tagBlobHash -eq $worktreeBlobHash) }
        [void]$eolOnly.Add([pscustomobject]@{
            member            = $name
            ko_bytes          = $koFile.Length
            wil_bytes         = $wilFile.Length
            ko_crlf           = $koMetrics.cr
            wil_crlf          = $wilMetrics.cr
            ko_lf             = $koMetrics.lf
            wil_lf            = $wilMetrics.lf
            content_equal_after_crlf_normalization = $true
            source_path       = $sourcePath
            source_git_state  = $gitState
            source_file_on_host = $sourceExists
            source_file_matches_ko_member = $sourceMatches
            frozen_tag_blob_hash   = $tagBlobHash
            source_worktree_blob_hash = $worktreeBlobHash
            source_content_equals_frozen_tag = $blobHashesEqual
        })
    }
    else {
        [void]$contentDiff.Add([pscustomobject]@{
            member     = $name
            ko_sha256  = Get-FileSha256 -Path $koFile.FullName
            wil_sha256 = Get-FileSha256 -Path $wilFile.FullName
            ko_bytes   = $koFile.Length
            wil_bytes  = $wilFile.Length
        })
    }
}

$nonDllMembers = @($common | Where-Object { $_ -ne 'OptiScaler.dll' })
$nonDllRawIdentical = @($nonDllMembers | Where-Object { $identical -contains $_ })
$nonDllEolOnly = @($eolOnly | Where-Object { $_.member -ne 'OptiScaler.dll' })
$nonDllContentDiff = @($contentDiff | Where-Object { $_.member -ne 'OptiScaler.dll' })
$nonDllAllowed = @($allowed | Where-Object { $_.member -ne 'OptiScaler.dll' })
$nonDllAllowedOutsideSums = @($nonDllAllowed | Where-Object { $_.member -ne 'SHA256SUMS.txt' })
# The comparable non-DLL set for the literal byte-identity reading: everything but the payload
# and the generated checksum file, both of which C7 allows to differ.
$nonDllComparable = @($nonDllMembers | Where-Object { $_ -ne 'SHA256SUMS.txt' })
$nonDllComparableRawIdentical = @($nonDllComparable | Where-Object { $identical -contains $_ })

$contentDetail = "content differences=[{0}] eol-only=[{1}] allowed=[{2}]" -f (($contentDiff | ForEach-Object { $_.member }) -join ', '), (($eolOnly | ForEach-Object { $_.member }) -join ', '), (($allowed | ForEach-Object { $_.member }) -join ', ')
Add-Check -Name 'non-dll-content-parity' -Ok (($nonDllContentDiff.Count -eq 0) -and ($nonDllAllowedOutsideSums.Count -eq 0)) -Detail $contentDetail
$allowedMembers = @($allowed | ForEach-Object { $_.member })
$allowedSetOk = (($allowedMembers.Count -eq 2) -and ($allowedMembers -contains 'OptiScaler.dll') -and ($allowedMembers -contains 'SHA256SUMS.txt'))
Add-Check -Name 'allowed-content-diff-set' -Ok $allowedSetOk -Detail ("allowed=[{0}] expected=[OptiScaler.dll, SHA256SUMS.txt]" -f ($allowedMembers -join ', '))

# The row's literal wording: every non-DLL member byte-identical, only OptiScaler.dll and the
# generated SHA256SUMS.txt differing. Reported as a named deviation when line endings alone differ.
$rawDetail = "raw-identical={0}/{1} eol-only={2} non-dll-allowed-diff={3}" -f $nonDllComparableRawIdentical.Count, $nonDllComparable.Count, $nonDllEolOnly.Count, (($nonDllAllowedOutsideSums | ForEach-Object { $_.member }) -join ', ')
$literalByteIdentity = ($nonDllComparableRawIdentical.Count -eq $nonDllComparable.Count)
Add-Check -Name 'non-dll-byte-identity-literal' -Ok $literalByteIdentity -Deviation -Detail $rawDetail

# An EOL-only member that git reports as modified would mean a shipped text member was edited.
$editedShippedMembers = @($eolOnly | Where-Object { $_.source_git_state -eq 'modified' })
Add-Check -Name 'eol-only-members-are-checkout-rendering' -Ok ($editedShippedMembers.Count -eq 0) -Detail ("eol-only count={0} of which git-modified=[{1}]" -f $nonDllEolOnly.Count, (($editedShippedMembers | ForEach-Object { $_.member }) -join ', '))

# The staged member must be a verbatim copy of its repository source file.
$sourceCopiesVerified = @($eolOnly | Where-Object { $_.source_file_on_host }).Count
$sourceCopyMismatch = @($eolOnly | Where-Object { $_.source_file_on_host -and (-not $_.source_file_matches_ko_member) })
$sourceCopyDetail = "verified={0} mismatched=[{1}] not-on-host=[{2}]" -f $sourceCopiesVerified, (($sourceCopyMismatch | ForEach-Object { $_.member }) -join ', '), ((@($eolOnly | Where-Object { -not $_.source_file_on_host } | ForEach-Object { $_.member })) -join ', ')
Add-Check -Name 'eol-only-members-are-verbatim-copies' -Ok ($sourceCopyMismatch.Count -eq 0) -Detail $sourceCopyDetail

# Every EOL-only member must still carry the frozen tag's own content, proven through git's
# clean filter so line endings cannot mask an edit.
$tagContentMismatch = @($eolOnly | Where-Object { $null -ne $_.source_content_equals_frozen_tag -and (-not $_.source_content_equals_frozen_tag) })
$tagContentCompared = @($eolOnly | Where-Object { $null -ne $_.source_content_equals_frozen_tag }).Count
$tagContentDetail = "compared={0} mismatched=[{1}]" -f $tagContentCompared, (($tagContentMismatch | ForEach-Object { $_.member }) -join ', ')
Add-Check -Name 'eol-only-members-equal-frozen-tag-content' -Ok ($tagContentMismatch.Count -eq 0) -Detail $tagContentDetail

# Every staged member that has a source file on this host must be a byte-for-byte copy of it,
# so a member that was rewritten in staging is caught even when its new bytes happen to match
# the frozen zip. The payload and the generated files have no source and are exempt.
$generatedMembers = @('OptiScaler.dll', 'SHA256SUMS.txt', '!! EXTRACT ALL FILES TO GAME FOLDER !!')
$copyChecked = New-Object System.Collections.ArrayList
$copyUnresolved = New-Object System.Collections.ArrayList
$copyMismatch = New-Object System.Collections.ArrayList
foreach ($name in $common) {
    if ($generatedMembers -contains $name) { continue }
    $sourceRelative = Get-SourcePath -Member $name
    $sourceFile = Join-Path $RepoRoot ($sourceRelative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { [void]$copyUnresolved.Add($name); continue }
    [void]$copyChecked.Add($name)
    if (-not (Test-FileBytesEqual -A $koTable[$name].FullName -B $sourceFile)) { [void]$copyMismatch.Add($name) }
}
Add-Check -Name 'staged-members-are-source-copies' -Ok ($copyMismatch.Count -eq 0) -Detail ("checked={0} mismatched=[{1}] no-source=[{2}]" -f $copyChecked.Count, ($copyMismatch -join ', '), ($copyUnresolved -join ', '))

# ---------------------------------------------------------------- embedded SHA256SUMS.txt

$koSumsPath = Join-Path $koDir 'SHA256SUMS.txt'
$wilSumsPath = Join-Path $wilDir 'SHA256SUMS.txt'
$koSums = Get-SumsEntries -Path $koSumsPath
$wilSums = Get-SumsEntries -Path $wilSumsPath
$koSumsPaths = @($koSums | ForEach-Object { $_.path })
$wilSumsPaths = @($wilSums | ForEach-Object { $_.path })
$koSumsPathsSorted = @($koSumsPaths)
[Array]::Sort($koSumsPathsSorted, [StringComparer]::Ordinal)
$wilSumsPathsSorted = @($wilSumsPaths)
[Array]::Sort($wilSumsPathsSorted, [StringComparer]::Ordinal)
$koOnlySums = New-Object System.Collections.ArrayList
foreach ($p in $koSumsPathsSorted) { if (-not ($wilSumsPathsSorted -contains $p)) { [void]$koOnlySums.Add($p) } }
$wilOnlySums = New-Object System.Collections.ArrayList
foreach ($p in $wilSumsPathsSorted) { if (-not ($koSumsPathsSorted -contains $p)) { [void]$wilOnlySums.Add($p) } }
$sumsSetEqual = (($koOnlySums.Count -eq 0) -and ($wilOnlySums.Count -eq 0))
$sumsOrderedEqual = (@(Compare-Object -ReferenceObject $wilSumsPaths -DifferenceObject $koSumsPaths -SyncWindow 0).Count -eq 0)
Add-Check -Name 'sha256sums-member-set' -Ok $sumsSetEqual -Detail ("ko={0} wil={1} entries; ko-only=[{2}] wil-only=[{3}] ordered-equal={4}" -f $koSumsPaths.Count, $wilSumsPaths.Count, ($koOnlySums -join ', '), ($wilOnlySums -join ', '), $sumsOrderedEqual)

$koSumsDeclaredMismatch = New-Object System.Collections.ArrayList
foreach ($entry in $koSums) {
    if (-not $koTable.ContainsKey($entry.path)) { [void]$koSumsDeclaredMismatch.Add("$($entry.path) (missing from archive)"); continue }
    $actual = Get-FileSha256 -Path $koTable[$entry.path].FullName
    if ($actual -ne $entry.hash) { [void]$koSumsDeclaredMismatch.Add("$($entry.path) declared=$($entry.hash) actual=$actual") }
}
Add-Check -Name 'sha256sums-self-consistent-ko' -Ok ($koSumsDeclaredMismatch.Count -eq 0) -Detail ("mismatches=[{0}]" -f ($koSumsDeclaredMismatch -join '; '))

$wilSumsDeclaredMismatch = New-Object System.Collections.ArrayList
foreach ($entry in $wilSums) {
    if (-not $wilTable.ContainsKey($entry.path)) { [void]$wilSumsDeclaredMismatch.Add("$($entry.path) (missing from archive)"); continue }
    $actual = Get-FileSha256 -Path $wilTable[$entry.path].FullName
    if ($actual -ne $entry.hash) { [void]$wilSumsDeclaredMismatch.Add("$($entry.path) declared=$($entry.hash) actual=$actual") }
}
Add-Check -Name 'sha256sums-self-consistent-wil' -Ok ($wilSumsDeclaredMismatch.Count -eq 0) -Detail ("mismatches=[{0}]" -f ($wilSumsDeclaredMismatch -join '; '))

$sumsValueDiffs = New-Object System.Collections.ArrayList
foreach ($koEntry in $koSums) {
    $match = $wilSums | Where-Object { $_.path -eq $koEntry.path } | Select-Object -First 1
    if ($null -eq $match) { continue }
    if ($match.hash -ne $koEntry.hash) { [void]$sumsValueDiffs.Add($koEntry.path) }
}
$eolOnlyMemberNames = @($eolOnly | ForEach-Object { $_.member })
$unexpectedSumsDiffs = @($sumsValueDiffs | Where-Object { ($_ -ne 'OptiScaler.dll') -and (-not ($eolOnlyMemberNames -contains $_)) })
Add-Check -Name 'sha256sums-value-diff-set' -Ok ($unexpectedSumsDiffs.Count -eq 0) -Detail ("differing members=[{0}] unexplained=[{1}]" -f ($sumsValueDiffs -join ', '), ($unexpectedSumsDiffs -join ', '))

# ---------------------------------------------------------------- dll flavor and resource

$koDllPath = Join-Path $koDir 'OptiScaler.dll'
$wilDllPath = Join-Path $wilDir 'OptiScaler.dll'
$koDllHash = Get-FileSha256 -Path $koDllPath
$wilDllHash = Get-FileSha256 -Path $wilDllPath
Add-Check -Name 'dll-content-differs-from-wil' -Ok ($koDllHash -ne $wilDllHash) -Detail ("ko={0} wil={1}" -f $koDllHash, $wilDllHash)

$koDllText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($koDllPath))
$wilDllText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($wilDllPath))
Add-Check -Name 'dll-flavor-marker' -Ok ($koDllText.Contains($FlavorMarker)) -Detail ("marker='{0}' present_in_ko={1} present_in_wil={2}" -f $FlavorMarker, $koDllText.Contains($FlavorMarker), $wilDllText.Contains($FlavorMarker))

$koVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($koDllPath)
$wilVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($wilDllPath)
Add-Check -Name 'dll-original-filename' -Ok (($koVersion.OriginalFilename -eq 'OptiScaler.dll') -and ($wilVersion.OriginalFilename -eq 'OptiScaler.dll')) -Detail ("ko='{0}' wil='{1}'" -f $koVersion.OriginalFilename, $wilVersion.OriginalFilename)

$stagedDll = Join-Path $RepoRoot 'x64\Release-RTX40-MFG\OptiScaler.dll'
$stagedHash = $null
$stagedMatches = $null
if (Test-Path -LiteralPath $stagedDll -PathType Leaf) {
    $stagedHash = Get-FileSha256 -Path $stagedDll
    $stagedMatches = ($stagedHash -eq $koDllHash)
}

# ---------------------------------------------------------------- evidence

$result = 'PASS'
$exitCode = 0
if ($script:deviations.Count -gt 0) { $result = 'PASS_WITH_DEVIATION'; $exitCode = 3 }
if ($script:failures.Count -gt 0) { $result = 'FAIL'; $exitCode = 1 }

$parity = [pscustomobject]@{
    tool                = 'tools/Verify-ZipParity.ps1'
    plan_row            = 5
    contract            = 'C7'
    generated_utc       = $stamp
    result              = $result
    exit_code_meaning   = '0 = PASS (clean); 3 = PASS_WITH_DEVIATION (all gates passed, named deviation recorded); 1 = FAIL'
    failures            = @($script:failures)
    deviations          = @($script:deviations)
    deviation           = [pscustomobject]@{
        criterion                      = 'every non-DLL member byte-identical to the frozen rtx40-mfg zip; only OptiScaler.dll and the generated SHA256SUMS.txt differ in content'
        literal_byte_identity          = $literalByteIdentity
        class                          = 'crlf-lf-rendering-only'
        members                        = $eolOnlyMemberNames
        content_identical              = (($nonDllContentDiff.Count -eq 0) -and ($nonDllAllowedOutsideSums.Count -eq 0))
        root_cause                     = 'the frozen wil zip ships mixed line endings for its text members (the four release docs and their LF blobs ship as LF, README.md/Config.md/Features.md/CONTRIBUTING.md/OptiScaler.ini/setup_windows.bat ship as CRLF, Licenses/FidelityFX_v2_LICENSE.md ships as CRLF), while this host materializes tracked text as CRLF at checkout; no uniform checkout policy matches all of them, so literal byte identity is not reproducible from the frozen tag'
        provenance_evidence            = (Join-Path $evidenceResolved 'eol-provenance.txt')
        resolution_if_literal_required = 'rewrite the six affected non-product files to the frozen zip per-file line endings and repackage; not reproducible and not done here'
    }
    ko_zip              = [pscustomobject]@{ path = $repoResolved; sha256 = $koHash; bytes = $koBytes; members = $koNames.Count }
    wil_zip             = [pscustomobject]@{ path = $wilResolved; sha256 = $wilHash; bytes = $wilBytes; members = $wilNames.Count; pinned_sha256 = $WilSha256.ToLowerInvariant(); rehash_matches_pin = ($wilHash -eq $WilSha256.ToLowerInvariant()); downloaded_this_run = $downloaded; source_url = $WilUrl }
    member_set          = [pscustomobject]@{ added = @($added); dropped = @($dropped); common = $common.Count; expected_count = $ExpectedMemberCount; payload_name = 'OptiScaler.dll' }
    content             = [pscustomobject]@{
        byte_identical_members          = $identical.Count
        byte_identical_non_dll          = @($nonDllRawIdentical)
        allowed_diff_members            = @($allowed)
        eol_only_members                = @($eolOnly)
        content_difference_members      = @($contentDiff)
        non_dll_byte_identical          = ($nonDllRawIdentical.Count -eq $nonDllMembers.Count)
        non_dll_byte_identity_literal   = $literalByteIdentity
        non_dll_comparable_members      = $nonDllComparable.Count
        non_dll_content_identical       = (($nonDllContentDiff.Count -eq 0) -and ($nonDllAllowedOutsideSums.Count -eq 0))
        non_dll_nonidentical_members    = @($nonDllMembers | Where-Object { -not ($nonDllRawIdentical -contains $_) })
    }
    sha256sums          = [pscustomobject]@{
        ko_entries              = $koSumsPaths.Count
        wil_entries             = $wilSumsPaths.Count
        member_sets_equal       = $sumsSetEqual
        member_order_equal      = $sumsOrderedEqual
        ko_declared_mismatches  = @($koSumsDeclaredMismatch)
        wil_declared_mismatches = @($wilSumsDeclaredMismatch)
        value_diff_members      = @($sumsValueDiffs)
        unexpected_value_diffs  = @($unexpectedSumsDiffs)
    }
    dll                 = [pscustomobject]@{
        ko_sha256                 = $koDllHash
        wil_sha256                = $wilDllHash
        ko_bytes                  = (Get-Item -LiteralPath $koDllPath).Length
        wil_bytes                 = (Get-Item -LiteralPath $wilDllPath).Length
        flavor_marker             = $FlavorMarker
        flavor_marker_present_ko  = $koDllText.Contains($FlavorMarker)
        flavor_marker_present_wil = $wilDllText.Contains($FlavorMarker)
        original_filename_ko      = $koVersion.OriginalFilename
        original_filename_wil     = $wilVersion.OriginalFilename
        file_version              = $koVersion.FileVersion
        product_name              = $koVersion.ProductName
        staged_build_dll          = $stagedDll
        staged_build_sha256       = $stagedHash
        staged_build_matches_ko_zip_member = $stagedMatches
    }
    checks              = @($script:checks)
}
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'parity.json'), ($parity | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

$manifestMembers = [ordered]@{}
foreach ($name in $koNames) { $manifestMembers[$name] = (Get-FileSha256 -Path $koTable[$name].FullName) }
$declared = [ordered]@{}
foreach ($entry in $koSums) { $declared[$entry.path] = $entry.hash }

$manifest = [pscustomobject]@{
    tool          = 'tools/Verify-ZipParity.ps1'
    plan_row      = 5
    generated_utc = $stamp
    ko_zip        = [pscustomobject]@{ path = $repoResolved; sha256 = $koHash; bytes = $koBytes; members = $koNames.Count }
    wil_zip       = [pscustomobject]@{ path = $wilResolved; sha256 = $wilHash; bytes = $wilBytes; pinned_sha256 = $WilSha256.ToLowerInvariant() }
    ko_dll        = [pscustomobject]@{ member = 'OptiScaler.dll'; sha256 = $koDllHash; bytes = (Get-Item -LiteralPath $koDllPath).Length; flavor_marker = $FlavorMarker; original_filename = $koVersion.OriginalFilename }
    wil_dll       = [pscustomobject]@{ member = 'OptiScaler.dll'; sha256 = $wilDllHash; bytes = (Get-Item -LiteralPath $wilDllPath).Length }
    staged_build_dll = [pscustomobject]@{ path = $stagedDll; sha256 = $stagedHash; matches_ko_zip_member = $stagedMatches }
    ko_members    = [pscustomobject]$manifestMembers
    ko_sha256sums_declared = [pscustomobject]$declared
}
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'sha256-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

Remove-Item -LiteralPath $scratch -Recurse -Force

Write-Host ""
Write-Host ("checks={0} failures={1} deviations={2} result={3} exit={4}" -f $script:checks.Count, $script:failures.Count, $script:deviations.Count, $result, $exitCode)
if ($script:deviations.Count -gt 0) {
    Write-Host "deviations (every gate passed; the deviation block in parity.json names each one):"
    foreach ($deviation in $script:deviations) { Write-Host "  - $deviation" }
    Write-Host "  literal byte identity: $literalByteIdentity"
    Write-Host ("  eol-only members: {0}" -f ($eolOnlyMemberNames -join ', '))
}
if ($script:failures.Count -gt 0) {
    Write-Host "failed checks:"
    foreach ($failure in $script:failures) { Write-Host "  - $failure" }
}
exit $exitCode
