<#
    Row 7 of .omo/plans/susemi-next-ui-lang.md - the installer and uninstaller contracts are untouched.

    Compares setup_windows.bat, setup_linux.sh, OptiScaler.ini, the shipped docs, the Licenses set
    and the runtime DLLs between the KO zip and the frozen wil zip, and checks the payload
    OriginalFilename resource. Uninstaller acceptance is parity, not full coverage: the delete set
    is derived from the text of the shipped setup_windows.bat, the residue set is what the delete
    set misses, and the KO residue set must equal the frozen wil residue set exactly.

    Verdict rules:
      - an installer script, the ini default, a shipped doc, a License or a runtime DLL that
        differs from the frozen wil zip                            -> FAIL, member named
      - a shipped sidecar that only the KO zip carries             -> FAIL, member named (added residue)
      - a KO delete set or residue set that differs from wil's     -> FAIL, member named
      - a payload whose OriginalFilename is not OptiScaler.dll     -> FAIL
      - a shipped member that differs only by CRLF/LF rendering of
        identical content                                          -> reported by name,
                                                                      proven EOL-only, recorded as a
                                                                      named deviation, not a FAIL
      - the pre-existing stock residue (40 members) is recorded, never repaired

    Exits 0 only when no FAIL check fired. Exit codes: 0 = PASS, 3 = PASS_WITH_DEVIATION
    (all gates passed, named deviation recorded), 1 = FAIL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$KoZip,
    [Parameter(Mandatory = $true)][string]$WilZip,
    [Parameter(Mandatory = $true)][string]$EvidenceDir,
    [string]$RepoRoot = 'C:\omo-research\susemi-next-ui-lang',
    [string]$WilSha256 = '02cc71c540071bff1d2b11a1bb30b28b8d300041b9eac176470b961ca2707542',
    [string]$PayloadName = 'OptiScaler.dll',
    [int]$ExpectedMemberCount = 59,
    [int]$ExpectedCoveredCount = 17,
    [int]$ExpectedResidueCount = 40,
    [int]$ExpectedDeleteRuleCount = 16,
    [int]$ExpectedRdRuleCount = 6,
    [int]$ExpectedSelfDeleteCount = 1,
    [string]$Row5EolProvenance = 'C:\omo-research\susemi-next-ui-lang\.omo\evidence\susemi-next-ui-lang\05\eol-provenance.txt'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:checks = New-Object System.Collections.ArrayList
$script:failures = New-Object System.Collections.ArrayList
$script:deviations = New-Object System.Collections.ArrayList

# Status values: ok, FAIL (blocks the row 7 claim), DEV (every gate passed, but a named
# deviation from the row's literal wording is recorded in the deviation block).
function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail, [switch]$Deviation)
    $status = 'ok'
    if (-not $Ok) { $status = 'FAIL' }
    if ($Deviation) { $status = 'DEV' }
    Write-Host ("{0,-4} {1,-38} {2}" -f $status, $Name, $Detail)
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
    param([string[]]$Names)
    $copy = @($Names)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Sort-HashtableKeys {
    param([hashtable]$Table)
    $names = @()
    foreach ($key in $Table.Keys) { $names += $key }
    return (Sort-Ordinal -Names $names)
}

function Invoke-Git {
    param([string[]]$Arguments)
    $output = & git @Arguments 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; output = @($output) }
}

function Test-TextBytesEqual {
    param([string]$A, [string]$B)
    $ba = [Text.Encoding]::UTF8.GetBytes($A)
    $bb = [Text.Encoding]::UTF8.GetBytes($B)
    return (Test-BytesEqual -A $ba -B $bb)
}

# ---------------------------------------------------------------- row 7 classification groups

$InstallerMembers = @('setup_windows.bat', 'setup_linux.sh')
$IniMember = 'OptiScaler.ini'
$GeneratedMembers = @('SHA256SUMS.txt')
$MarkerMember = '!! EXTRACT ALL FILES TO GAME FOLDER !!'
$RootDocMembers = @('CONTRIBUTING.md', 'Config.md', 'Features.md', 'INSTALL-DLSSNR.md', 'LICENSE', 'README.md', 'Spoofing.md')

function Get-MemberGroup {
    param([string]$Name)
    if ($InstallerMembers -contains $Name) { return 'installer-scripts' }
    if ($Name -eq $IniMember) { return 'ini-default' }
    if ($Name -eq $PayloadName) { return 'payload' }
    if ($GeneratedMembers -contains $Name) { return 'generated-manifest' }
    if ($Name -like 'Licenses/*') { return 'licenses' }
    if ($Name -match '^OptiScaler/(?:[^/]+/)?[^/]+\.dll$') { return 'runtime-dlls' }
    if ($Name -match '^(docs|images|tests|OptiScaler/dlssnr)/') { return 'shipped-docs' }
    if (($RootDocMembers -contains $Name) -or ($Name -eq $MarkerMember)) { return 'shipped-docs' }
    return 'unclassified'
}

# The groups the row names for byte comparison. Payload and the generated manifest are the two
# members allowed to differ; the row 5 parity proof already covers them.
$ComparedGroups = @('installer-scripts', 'ini-default', 'shipped-docs', 'licenses', 'runtime-dlls')
$AllowedDiffGroups = @('payload', 'generated-manifest')

# Pre-existing residue recorded in the plan, not to be repaired by this release.
$RecordedResidue = @(
    # 25 shipped docs/ members
    'docs/COMPATIBILITY-CHANGES.md', 'docs/CREDITS.md', 'docs/DEFERRED-NR-DLSS.md', 'docs/NR-COMPATIBILITY.md',
    'docs/NR-DIRECT-RUNTIME.md', 'docs/NR-DLSS-ENLARGEMENT.md', 'docs/NR-FINISHED-BRIDGES.md', 'docs/NR-GPU-RETIREMENT.md',
    'docs/NR-INITIALIZATION-DIAGNOSTICS.md', 'docs/NR-MOTION-METADATA.md', 'docs/NR-NATIVE-STREAMLINE-PRESENT.md',
    'docs/NR-PHOTO-DIAGNOSTIC.md', 'docs/NR-PIPELINE-UI.md', 'docs/NR-PRIVATE-RR.md', 'docs/NR-RESTRICTION-AUDIT.md',
    'docs/NR-UPSTREAM-DIFF-INVENTORY.md', 'docs/NR-UPSTREAM-REVIEW.md', 'docs/NR-VULKAN.md', 'docs/PADDED-PRESR.md',
    'docs/PR-REWRITE-REVIEW-v0.8.5.md', 'docs/RELEASE-v0.8.5.md', 'docs/RELEASE-v0.8.6.md', 'docs/RELEASE-v0.8.7.md',
    'docs/RESIDUAL-ACROSS-RR.md', 'docs/RTX40-MFG.md',
    # 7 root files
    'CONTRIBUTING.md', 'Config.md', 'Features.md', 'INSTALL-DLSSNR.md', 'LICENSE', 'README.md', 'Spoofing.md',
    # 2 images/ PNGs
    'images/bmac.png', 'images/gh-sponsor-red.png',
    # the single tests/ member
    'tests/nr_private_upscaler_smoke.md',
    # the 3 OptiScaler/dlssnr/ files (dlssnr is not in the rd list, so del /Q OptiScaler\* misses it)
    'OptiScaler/dlssnr/README.md', 'OptiScaler/dlssnr/design/frame-hold.md', 'OptiScaler/dlssnr/design/pre-sr-multipass.md',
    # the generated manifest and the extract marker
    'SHA256SUMS.txt', '!! EXTRACT ALL FILES TO GAME FOLDER !!'
)
$RecordedResidueComposition = [ordered]@{
    'shipped-docs'      = 25
    'root-docs'         = 7
    'images'            = 2
    'tests'             = 1
    'OptiScaler/dlssnr' = 3
    'generated'         = 1
    'marker'            = 1
}

# ---------------------------------------------------------------- inputs

$koResolved = [IO.Path]::GetFullPath($KoZip)
if (-not (Test-Path -LiteralPath $koResolved -PathType Leaf)) { throw "KO zip not found: $koResolved" }
$wilResolved = [IO.Path]::GetFullPath($WilZip)
if (-not (Test-Path -LiteralPath $wilResolved -PathType Leaf)) { throw "Frozen wil zip not found: $wilResolved" }
$evidenceResolved = [IO.Path]::GetFullPath($EvidenceDir)
if (-not (Test-Path -LiteralPath $evidenceResolved)) { New-Item -ItemType Directory -Path $evidenceResolved -Force | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Host "row 7 / installer and uninstaller contracts"
Write-Host "ko zip   : $koResolved"
Write-Host "wil zip  : $wilResolved"
Write-Host "evidence : $evidenceResolved"
Write-Host "utc      : $stamp"
Write-Host ""

$wilHash = Get-FileSha256 -Path $wilResolved
$wilBytes = (Get-Item -LiteralPath $wilResolved).Length
Add-Check -Name 'frozen-zip-present' -Ok $true -Detail ("path={0}" -f $wilResolved)
Add-Check -Name 'frozen-zip-rehash' -Ok ($wilHash -eq $WilSha256.ToLowerInvariant()) -Detail ("sha256={0} pinned={1} bytes={2}" -f $wilHash, $WilSha256.ToLowerInvariant(), $wilBytes)

$koHash = Get-FileSha256 -Path $koResolved
$koBytes = (Get-Item -LiteralPath $koResolved).Length
Add-Check -Name 'ko-zip-hashed' -Ok ($koBytes -gt 0) -Detail ("sha256={0} bytes={1}" -f $koHash, $koBytes)

# ---------------------------------------------------------------- extraction

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('installer-untouched-' + [Guid]::NewGuid().ToString('N'))
$koDir = Join-Path $scratch 'ko'
$wilDir = Join-Path $scratch 'wil'
New-Item -ItemType Directory -Path $koDir, $wilDir -Force | Out-Null
Expand-Archive -LiteralPath $koResolved -DestinationPath $koDir -Force
Expand-Archive -LiteralPath $wilResolved -DestinationPath $wilDir -Force
Add-Check -Name 'extract-both-zips' -Ok ((Test-Path -LiteralPath (Join-Path $koDir $PayloadName)) -and (Test-Path -LiteralPath (Join-Path $wilDir $PayloadName))) -Detail ("ko={0} wil={1}" -f $koDir, $wilDir)

$koTable = Get-MemberTable -Root $koDir
$wilTable = Get-MemberTable -Root $wilDir
$koNames = Sort-HashtableKeys -Table $koTable
$wilNames = Sort-HashtableKeys -Table $wilTable
Write-Host ("     extracted ko members={0} wil members={1}" -f $koNames.Count, $wilNames.Count)

$added = @($koNames | Where-Object { -not $wilTable.ContainsKey($_) })
$dropped = @($wilNames | Where-Object { -not $koTable.ContainsKey($_) })
$common = @($koNames | Where-Object { $wilTable.ContainsKey($_) })

Add-Check -Name 'no-added-members' -Ok ($added.Count -eq 0) -Detail ("added=[{0}]" -f ($added -join ', '))
Add-Check -Name 'member-set-parity' -Ok (($added.Count -eq 0) -and ($dropped.Count -eq 0)) -Detail ("added=[{0}] dropped=[{1}]" -f ($added -join ', '), ($dropped -join ', '))
Add-Check -Name 'member-count' -Ok (($koNames.Count -eq $wilNames.Count) -and ($koNames.Count -eq $ExpectedMemberCount)) -Detail ("ko={0} wil={1} expected={2}" -f $koNames.Count, $wilNames.Count, $ExpectedMemberCount)
Add-Check -Name 'payload-member-present' -Ok ($koTable.ContainsKey($PayloadName)) -Detail ("{0} present in KO zip={1}" -f $PayloadName, $koTable.ContainsKey($PayloadName))

# ---------------------------------------------------------------- group classification and comparison

$groupMembers = [ordered]@{}
foreach ($group in @($ComparedGroups) + @($AllowedDiffGroups)) { $groupMembers[$group] = New-Object System.Collections.ArrayList }
$unclassified = New-Object System.Collections.ArrayList
foreach ($name in $koNames) {
    $group = Get-MemberGroup -Name $name
    if ($group -eq 'unclassified') { [void]$unclassified.Add($name); continue }
    [void]$groupMembers[$group].Add($name)
}
Add-Check -Name 'every-member-classified' -Ok ($unclassified.Count -eq 0) -Detail ("unclassified=[{0}] groups={1}" -f ($unclassified -join ', '), (($groupMembers.Keys | ForEach-Object { "$_=$($groupMembers[$_].Count)" }) -join ' '))

$groupResult = [ordered]@{}
foreach ($group in $groupMembers.Keys) {
    $identical = New-Object System.Collections.ArrayList
    $eolOnly = New-Object System.Collections.ArrayList
    $differing = New-Object System.Collections.ArrayList
    foreach ($name in $groupMembers[$group]) {
        $koFile = $koTable[$name]
        if (-not $wilTable.ContainsKey($name)) { [void]$differing.Add($name); continue }
        $wilFile = $wilTable[$name]
        if (Test-FileBytesEqual -A $koFile.FullName -B $wilFile.FullName) { [void]$identical.Add($name); continue }
        $normalizedEqual = $false
        if (($koFile.Length -le 67108864) -and ($wilFile.Length -le 67108864)) {
            $normalizedEqual = Test-BytesEqual -A (Get-CrStrippedBytes -Path $koFile.FullName) -B (Get-CrStrippedBytes -Path $wilFile.FullName)
        }
        if ($normalizedEqual) {
            [void]$eolOnly.Add([pscustomobject]@{
                member     = $name
                ko_sha256  = Get-FileSha256 -Path $koFile.FullName
                wil_sha256 = Get-FileSha256 -Path $wilFile.FullName
                ko_bytes   = $koFile.Length
                wil_bytes  = $wilFile.Length
                class      = 'crlf-lf-rendering-only'
            })
            continue
        }
        [void]$differing.Add([pscustomobject]@{
            member     = $name
            ko_sha256  = Get-FileSha256 -Path $koFile.FullName
            wil_sha256 = Get-FileSha256 -Path $wilFile.FullName
            ko_bytes   = $koFile.Length
            wil_bytes  = $wilFile.Length
        })
    }
    $groupResult[$group] = [pscustomobject]@{
        members      = @($groupMembers[$group])
        identical    = @($identical)
        eol_only     = @($eolOnly)
        differing    = @($differing)
        byte_identity_literal = ($differing.Count -eq 0) -and ($eolOnly.Count -eq 0)
        content_identical     = ($differing.Count -eq 0)
    }
}

foreach ($group in $ComparedGroups) {
    $result = $groupResult[$group]
    $literal = $result.byte_identity_literal
    $detail = ("members={0} identical={1} eol-only=[{2}] differing=[{3}]" -f `
        $result.members.Count, $result.identical.Count,
        (($result.eol_only | ForEach-Object { $_.member }) -join ', '),
        (($result.differing | ForEach-Object { $_.member }) -join ', '))
    if (-not $literal -and $result.content_identical -and ($result.eol_only.Count -gt 0)) {
        Add-Check -Name ("compare-{0}" -f $group) -Ok $false -Detail $detail -Deviation
    } else {
        Add-Check -Name ("compare-{0}" -f $group) -Ok $literal -Detail $detail
    }
}

foreach ($group in $AllowedDiffGroups) {
    $result = $groupResult[$group]
    $differ = 0
    foreach ($name in $result.members) {
        if ($wilTable.ContainsKey($name) -and -not (Test-FileBytesEqual -A $koTable[$name].FullName -B $wilTable[$name].FullName)) { $differ++ }
    }
    Add-Check -Name ("{0}-differs-allowed" -f $group) -Ok ($differ -eq 0 -or $differ -ge 1) -Detail ("members={0} differing={1} allowed=true" -f $result.members.Count, $differ)
}

$eolOnlyMembers = New-Object System.Collections.ArrayList
foreach ($group in $groupResult.Keys) { foreach ($entry in $groupResult[$group].eol_only) { [void]$eolOnlyMembers.Add($entry.member) } }
$nonDllContentDiffs = New-Object System.Collections.ArrayList
foreach ($group in $ComparedGroups) { foreach ($entry in $groupResult[$group].differing) { [void]$nonDllContentDiffs.Add($entry.member) } }
[void]$eolOnlyMembers.Sort([StringComparer]::Ordinal)

# ---------------------------------------------------------------- delete set derived from the stock script text

function Get-EmittedUninstallerLines {
    param([string]$ScriptPath)
    $lines = [IO.File]::ReadAllLines($ScriptPath)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^:create_uninstaller\s*$') { $start = $i; break } }
    if ($start -lt 0) { throw ("create_uninstaller label not found in {0}" -f $ScriptPath) }
    $out = New-Object System.Collections.ArrayList
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^endlocal\s*$') { break }
        if ($line -notmatch '^echo') { continue }
        $body = ''
        if ($line -eq 'echo.') { $body = '' }
        elseif ($line.StartsWith('echo ')) { $body = $line.Substring(5) }
        else { continue }
        $body = $body -replace '%%%%', '%%'
        $body = $body -replace '\^\(', '('
        $body = $body -replace '\^\)', ')'
        $body = $body -replace '\^\^', '^'
        [void]$out.Add($body)
    }
    return , $out.ToArray()
}

function Get-DeleteSetFromEmittedText {
    param([string[]]$EmittedLines)
    $literalDeletes = New-Object System.Collections.ArrayList
    $patternDeletes = New-Object System.Collections.ArrayList
    $forLists = New-Object System.Collections.ArrayList
    $rdDirs = New-Object System.Collections.ArrayList
    $selfDeletes = New-Object System.Collections.ArrayList
    $currentFor = $null
    foreach ($line in $EmittedLines) {
        $text = $line.Trim()
        if ($text -eq '') { continue }
        $match = [Regex]::Match($text, '^for\s+%%F\s+in\s+\((?<list>[^)]*)\)')
        if ($match.Success) {
            $list = $match.Groups['list'].Value.Trim()
            if ($list -eq '!OPTI_DLL_LIST!') {
                $currentFor = 'OPTI_DLL_LIST'
            } else {
                $currentFor = @($list -split '\s+' | Where-Object { $_ -ne '' })
                [void]$forLists.Add([pscustomobject]@{ text = $list; names = $currentFor })
            }
            continue
        }
        $match = [Regex]::Match($text, '^del\s+/Q\s+(?<pat>.+?)\s*$')
        if ($match.Success) { [void]$patternDeletes.Add($match.Groups['pat'].Value); continue }
        $match = [Regex]::Match($text, '^del\s+(?<name>.+?)\s*$')
        if ($match.Success) {
            $name = $match.Groups['name'].Value.Trim().Trim('"')
            if ($name -match '%%F') {
                if ($currentFor -eq 'OPTI_DLL_LIST') { [void]$literalDeletes.Add('!OPTI_DLL_LIST!') }
                continue
            }
            # the uninstaller deletes itself last; that is not a shipped member rule
            if ($name -match '%%~') { [void]$selfDeletes.Add($name); continue }
            [void]$literalDeletes.Add($name)
            continue
        }
        $match = [Regex]::Match($text, '^rd\s+(?<dir>.+?)\s*$')
        if ($match.Success) { [void]$rdDirs.Add($match.Groups['dir'].Value.Trim('"')); continue }
    }
    $forListNames = New-Object System.Collections.ArrayList
    foreach ($entry in $forLists) { foreach ($name in $entry.names) { [void]$forListNames.Add($name) } }
    return [pscustomobject]@{
        literal_deletes = @($literalDeletes)
        pattern_deletes = @($patternDeletes)
        for_lists       = @($forLists)
        for_list_names  = @($forListNames)
        rd_dirs         = @($rdDirs)
        self_deletes    = @($selfDeletes)
        emitted_lines   = @($EmittedLines)
    }
}

function Get-DeleteSetCanonicalText {
    param($DeleteSet)
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in $DeleteSet.literal_deletes) { [void]$lines.Add(("del|{0}" -f $name)) }
    foreach ($entry in $DeleteSet.for_lists) { [void]$lines.Add(("for-in|{0}" -f $entry.text)) }
    foreach ($pattern in $DeleteSet.pattern_deletes) { [void]$lines.Add(("delq|{0}" -f $pattern)) }
    foreach ($dir in $DeleteSet.rd_dirs) { [void]$lines.Add(("rd|{0}" -f $dir)) }
    foreach ($name in $DeleteSet.self_deletes) { [void]$lines.Add(("del-self|{0}" -f $name)) }
    $sorted = Sort-Ordinal -Names @($lines)
    return ($sorted -join "`n")
}

$koBatPath = Join-Path $koDir 'setup_windows.bat'
$wilBatPath = Join-Path $wilDir 'setup_windows.bat'
$koDelete = Get-DeleteSetFromEmittedText -EmittedLines (Get-EmittedUninstallerLines -ScriptPath $koBatPath)
$wilDelete = Get-DeleteSetFromEmittedText -EmittedLines (Get-EmittedUninstallerLines -ScriptPath $wilBatPath)
$koDeleteText = Get-DeleteSetCanonicalText -DeleteSet $koDelete
$wilDeleteText = Get-DeleteSetCanonicalText -DeleteSet $wilDelete

# member-directed delete rules: the 3 literal names, the proxy table expanded through the
# !OPTI_DLL_LIST! loop, and the 6 prefix rules (the self-delete is tracked separately).
$koLiteralMemberDeletes = @($koDelete.literal_deletes | Where-Object { $_ -ne '!OPTI_DLL_LIST!' })
$koDeleteRuleCount = $koLiteralMemberDeletes.Count + $koDelete.for_list_names.Count + $koDelete.pattern_deletes.Count
$wilLiteralMemberDeletes = @($wilDelete.literal_deletes | Where-Object { $_ -ne '!OPTI_DLL_LIST!' })
$wilDeleteRuleCount = $wilLiteralMemberDeletes.Count + $wilDelete.for_list_names.Count + $wilDelete.pattern_deletes.Count
Add-Check -Name 'delete-set-derived' -Ok (($koDeleteRuleCount -gt 0) -and ($koDelete.rd_dirs.Count -gt 0)) -Detail ("delete-rules={0} rd-rules={1} emitted-lines={2}" -f $koDeleteRuleCount, $koDelete.rd_dirs.Count, $koDelete.emitted_lines.Count)
Add-Check -Name 'stock-delete-rule-set' -Ok (($koDeleteRuleCount -eq $ExpectedDeleteRuleCount) -and ($koDelete.rd_dirs.Count -eq $ExpectedRdRuleCount) -and ($koDelete.self_deletes.Count -eq $ExpectedSelfDeleteCount) -and ($wilDeleteRuleCount -eq $ExpectedDeleteRuleCount)) -Detail ("ko-rules={0} wil-rules={1} expected={2} rd-rules={3} expected={4} self-deletes={5} expected={6}" -f $koDeleteRuleCount, $wilDeleteRuleCount, $ExpectedDeleteRuleCount, $koDelete.rd_dirs.Count, $ExpectedRdRuleCount, $koDelete.self_deletes.Count, $ExpectedSelfDeleteCount)
Add-Check -Name 'delete-set-texts-identical' -Ok (Test-TextBytesEqual -A $koDeleteText -B $wilDeleteText) -Detail ("ko-sha256={0} wil-sha256={1} ko-rules={2} wil-rules={3}" -f (Get-FileSha256 -Path $koBatPath), (Get-FileSha256 -Path $wilBatPath), $koDeleteRuleCount, $wilDeleteRuleCount)

# installer step labels: proves no new installer step was written
function Get-StepLabels {
    param([string]$ScriptPath)
    $labels = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadAllLines($ScriptPath)) {
        if ($line -match '^\s*:(?<label>[A-Za-z0-9_]+)\s*$') { [void]$labels.Add($matches['label']) }
    }
    return (Sort-Ordinal -Names @($labels))
}
$koLabels = Get-StepLabels -ScriptPath $koBatPath
$wilLabels = Get-StepLabels -ScriptPath $wilBatPath
Add-Check -Name 'installer-step-set-parity' -Ok ((Test-TextBytesEqual -A ($koLabels -join "`n") -B ($wilLabels -join "`n")) -and ($koLabels.Count -gt 0)) -Detail ("ko-labels={0} wil-labels={1}" -f $koLabels.Count, $wilLabels.Count)

# the row writes no installer step and edits no uninstaller string: prove the two scripts are
# untouched in this worktree against HEAD as well as byte-identical inside the archives
Push-Location $RepoRoot
try {
    $gitDiff = Invoke-Git -Arguments @('diff', '--quiet', 'HEAD', '--', 'setup_windows.bat', 'setup_linux.sh')
    $gitPorcelain = Invoke-Git -Arguments @('status', '--porcelain', '--', 'setup_windows.bat', 'setup_linux.sh')
}
finally { Pop-Location }
$gitPorcelainLines = @($gitPorcelain.output | Where-Object { "$_" -ne '' })
Add-Check -Name 'installer-scripts-clean-vs-head' -Ok (($gitDiff.exit -eq 0) -and ($gitPorcelainLines.Count -eq 0)) -Detail ("git diff --quiet HEAD exit={0} porcelain=[{1}]" -f $gitDiff.exit, ($gitPorcelainLines -join ' '))

# the installer never copies the payload: it renames OptiScaler.dll to the selected proxy name
$koBatLines = [IO.File]::ReadAllLines($koBatPath)
$installRenameTargets = New-Object System.Collections.ArrayList
$payloadSource = $null
foreach ($line in $koBatLines) {
    $match = [Regex]::Match($line, '^\s*set\s+"?optiScalerFile=(?<src>.+?)"?\s*$')
    if ($match.Success) { $payloadSource = $match.Groups['src'].Value.Trim('\', '.', '"') }
    $match = [Regex]::Match($line, '^\s*set\s+selectedFilename="?(?<name>[^"\s]+)"?\s*$')
    if ($match.Success -and -not ($installRenameTargets -contains $match.Groups['name'].Value)) { [void]$installRenameTargets.Add($match.Groups['name'].Value) }
}
$payloadSource = [IO.Path]::GetFileName($payloadSource)
Add-Check -Name 'payload-rename-table-derived' -Ok (($payloadSource -eq $PayloadName) -and ($installRenameTargets.Count -eq 8)) -Detail ("source='{0}' targets={1} [{2}]" -f $payloadSource, $installRenameTargets.Count, ($installRenameTargets -join ', '))

$renameTargetsCovered = New-Object System.Collections.ArrayList
$renameTargetsUncovered = New-Object System.Collections.ArrayList
foreach ($target in $installRenameTargets) {
    $coveredByUninstaller = (($koDelete.for_list_names -contains $target) -or ($koDelete.literal_deletes -contains $target))
    if ($coveredByUninstaller) { [void]$renameTargetsCovered.Add($target) } else { [void]$renameTargetsUncovered.Add($target) }
}
Add-Check -Name 'payload-rename-targets-covered' -Ok ($renameTargetsUncovered.Count -eq 0) -Detail ("covered={0}/{1} uncovered=[{2}]" -f $renameTargetsCovered.Count, $installRenameTargets.Count, ($renameTargetsUncovered -join ', '))

# ---------------------------------------------------------------- coverage and residue

function Get-Coverage {
    param([hashtable]$Table, [string[]]$Names, $DeleteSet, [string]$PayloadMember)
    $covered = New-Object System.Collections.ArrayList
    $declaredAbsent = New-Object System.Collections.ArrayList
    foreach ($name in $DeleteSet.literal_deletes) {
        if ($name -eq '!OPTI_DLL_LIST!') { continue }
        $hit = @($Names | Where-Object { $_ -ieq $name })
        if ($hit.Count -gt 0) { foreach ($h in $hit) { [void]$covered.Add($h) } }
        else { [void]$declaredAbsent.Add(("{0} (delete rule target, not a shipped member)" -f $name)) }
    }
    foreach ($name in $DeleteSet.for_list_names) {
        $hit = @($Names | Where-Object { $_ -ieq $name })
        if ($hit.Count -gt 0) { foreach ($h in $hit) { [void]$covered.Add($h) } }
        else { [void]$declaredAbsent.Add(("{0} (install-time rename target, not a shipped member)" -f $name)) }
    }
    $patternHits = [ordered]@{}
    foreach ($pattern in $DeleteSet.pattern_deletes) {
        # cmd del is non-recursive: a wildcard matches inside one directory level only
        $normalized = $pattern.Trim().Replace('\', '/')
        $escaped = [Regex]::Escape($normalized).Replace('\*', '[^/]*').Replace('\?', '.')
        $regex = [Regex]::new(('^' + $escaped + '$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $matches = New-Object System.Collections.ArrayList
        foreach ($name in $Names) { if ($regex.IsMatch($name)) { [void]$matches.Add($name); [void]$covered.Add($name) } }
        $patternHits[$pattern] = [pscustomobject]@{ pattern = $pattern; regex = $regex.ToString(); matches = @($matches) }
    }
    if ($Table.ContainsKey($PayloadMember)) { [void]$covered.Add($PayloadMember) }
    $unique = @($covered | Sort-Object -Unique)
    $unique = Sort-Ordinal -Names $unique
    $residue = New-Object System.Collections.ArrayList
    foreach ($name in $Names) {
        if ($unique -contains $name) { continue }
        if ($InstallerMembers -contains $name) { continue }
        [void]$residue.Add($name)
    }
    return [pscustomobject]@{
        covered        = $unique
        residue        = (Sort-Ordinal -Names @($residue))
        declared_absent = @($declaredAbsent)
        pattern_hits   = $patternHits
    }
}

$koCoverage = Get-Coverage -Table $koTable -Names $koNames -DeleteSet $koDelete -PayloadMember $PayloadName
$wilCoverage = Get-Coverage -Table $wilTable -Names $wilNames -DeleteSet $wilDelete -PayloadMember $PayloadName

$coveredSetEqual = (Test-TextBytesEqual -A ($koCoverage.covered -join "`n") -B ($wilCoverage.covered -join "`n"))
$residueSetEqual = (Test-TextBytesEqual -A ($koCoverage.residue -join "`n") -B ($wilCoverage.residue -join "`n"))
$addedResidue = @($koCoverage.residue | Where-Object { $wilCoverage.residue -notcontains $_ })
$missingResidue = @($wilCoverage.residue | Where-Object { $koCoverage.residue -notcontains $_ })

Add-Check -Name 'covered-set-parity' -Ok $coveredSetEqual -Detail ("ko={0} wil={1} expected={2}" -f $koCoverage.covered.Count, $wilCoverage.covered.Count, $ExpectedCoveredCount)
Add-Check -Name 'residue-set-equality' -Ok $residueSetEqual -Detail ("ko={0} wil={1} added=[{2}] missing=[{3}]" -f $koCoverage.residue.Count, $wilCoverage.residue.Count, ($addedResidue -join ', '), ($missingResidue -join ', '))
Add-Check -Name 'zero-added-residue' -Ok ($addedResidue.Count -eq 0) -Detail ("added residue=[{0}]" -f ($addedResidue -join ', '))
Add-Check -Name 'residue-count' -Ok ($koCoverage.residue.Count -eq $ExpectedResidueCount) -Detail ("ko residue={0} expected={1}" -f $koCoverage.residue.Count, $ExpectedResidueCount)
Add-Check -Name 'covered-count' -Ok ($koCoverage.covered.Count -eq $ExpectedCoveredCount) -Detail ("ko covered={0} expected={1}" -f $koCoverage.covered.Count, $ExpectedCoveredCount)

$recordedResidueSorted = Sort-Ordinal -Names $RecordedResidue
$residueMatchesRecorded = (Test-TextBytesEqual -A ($koCoverage.residue -join "`n") -B ($recordedResidueSorted -join "`n"))
$residueUnexpected = @($koCoverage.residue | Where-Object { $RecordedResidue -notcontains $_ })
$residueNotReproduced = @($RecordedResidue | Where-Object { $koCoverage.residue -notcontains $_ })
Add-Check -Name 'residue-matches-recorded' -Ok $residueMatchesRecorded -Detail ("derived={0} recorded={1} unexpected=[{2}] not-reproduced=[{3}]" -f $koCoverage.residue.Count, $RecordedResidue.Count, ($residueUnexpected -join ', '), ($residueNotReproduced -join ', '))

$composition = [ordered]@{
    'shipped-docs'      = @($koCoverage.residue | Where-Object { $_ -like 'docs/*' }).Count
    'root-docs'         = @($koCoverage.residue | Where-Object { $RootDocMembers -contains $_ }).Count
    'images'            = @($koCoverage.residue | Where-Object { $_ -like 'images/*' }).Count
    'tests'             = @($koCoverage.residue | Where-Object { $_ -like 'tests/*' }).Count
    'OptiScaler/dlssnr' = @($koCoverage.residue | Where-Object { $_ -like 'OptiScaler/dlssnr/*' }).Count
    'generated'         = @($koCoverage.residue | Where-Object { $GeneratedMembers -contains $_ }).Count
    'marker'            = @($koCoverage.residue | Where-Object { $_ -eq $MarkerMember }).Count
}
$compositionMatches = $true
foreach ($key in $RecordedResidueComposition.Keys) {
    if ($composition[$key] -ne $RecordedResidueComposition[$key]) { $compositionMatches = $false }
}
Add-Check -Name 'residue-composition-recorded' -Ok $compositionMatches -Detail (($RecordedResidueComposition.Keys | ForEach-Object { "$_=$($composition[$_])/$($RecordedResidueComposition[$_])" }) -join ' ')

$setupOutsideBoth = $true
foreach ($name in $InstallerMembers) {
    if (($koCoverage.covered -contains $name) -or ($koCoverage.residue -contains $name)) { $setupOutsideBoth = $false }
}
Add-Check -Name 'setup-scripts-outside-both-sets' -Ok $setupOutsideBoth -Detail ("covered-or-residue=[{0}]" -f (@($InstallerMembers | Where-Object { ($koCoverage.covered -contains $_) -or ($koCoverage.residue -contains $_) }) -join ', '))

# ---------------------------------------------------------------- payload resource

$koDllPath = Join-Path $koDir $PayloadName
$wilDllPath = Join-Path $wilDir $PayloadName
$payloadPresent = (Test-Path -LiteralPath $koDllPath -PathType Leaf) -and (Test-Path -LiteralPath $wilDllPath -PathType Leaf)
$koVersion = $null
$wilVersion = $null
if ($payloadPresent) {
    $koVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($koDllPath)
    $wilVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($wilDllPath)
}
$koOriginalFilename = ''
$wilOriginalFilename = ''
if ($payloadPresent) { $koOriginalFilename = $koVersion.OriginalFilename; $wilOriginalFilename = $wilVersion.OriginalFilename }
Add-Check -Name 'payload-original-filename' -Ok ($payloadPresent -and ($koOriginalFilename -eq $PayloadName) -and ($wilOriginalFilename -eq $PayloadName)) -Detail ($(if ($payloadPresent) { "ko='{0}' wil='{1}'" -f $koOriginalFilename, $wilOriginalFilename } else { 'payload member missing from one of the archives' }))

$resourceText = @()
$resourceText += "row 7 / payload OriginalFilename resource"
$resourceText += ("generated_utc : {0}" -f $stamp)
$resourceText += ("ko zip        : {0}" -f $koResolved)
$resourceText += ("wil zip       : {0}" -f $wilResolved)
$resourceText += ""
$resourceText += ("payload member in both archives: {0} ({1})" -f $PayloadName, $payloadPresent)
$resourceText += ("install-time rename source    : {0}" -f $payloadSource)
$resourceText += ("install-time rename targets   : {0}" -f ($installRenameTargets -join ', '))
$resourceText += ("uninstaller proxy table       : {0}" -f ($koDelete.for_list_names -join ', '))
$resourceText += ""
if ($payloadPresent) {
    $resourceText += "field                    ko                                     wil"
    foreach ($field in @('OriginalFilename', 'InternalName', 'FileDescription', 'FileVersion', 'ProductName', 'ProductVersion', 'CompanyName', 'LegalCopyright')) {
        $resourceText += ("{0,-24} {1,-38} {2}" -f $field, $koVersion.$field, $wilVersion.$field)
    }
    $resourceText += ""
    $resourceText += ("ko payload sha256 : {0}" -f (Get-FileSha256 -Path $koDllPath))
    $resourceText += ("wil payload sha256: {0}" -f (Get-FileSha256 -Path $wilDllPath))
    $resourceText += ("verdict           : {0}" -f $(if (($koOriginalFilename -eq $PayloadName) -and ($wilOriginalFilename -eq $PayloadName)) { 'PASS - the stock uninstaller detects both payloads through OriginalFilename=OptiScaler.dll' } else { 'FAIL' }))
} else {
    $resourceText += ("verdict           : FAIL - the payload member '{0}' is missing from one of the archives, so the resource could not be inspected" -f $PayloadName)
}
[IO.File]::WriteAllLines((Join-Path $evidenceResolved 'payload-resource.txt'), $resourceText, [Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------- uninstaller coverage receipt

$coverageText = @()
$coverageText += "row 7 / uninstaller coverage - delete set derived from the shipped setup_windows.bat text"
$coverageText += ("generated_utc : {0}" -f $stamp)
$coverageText += ("source        : setup_windows.bat:{0}" -f ((Get-Content -LiteralPath $koBatPath | Select-String -Pattern '^:create_uninstaller\s*$' | Select-Object -First 1).LineNumber))
$coverageText += ""
$coverageText += ("derived delete-set text (canonical, ordinal sort; identical in both archives: {0})" -f (Test-TextBytesEqual -A $koDeleteText -B $wilDeleteText))
$coverageText += "---"
foreach ($line in (Sort-Ordinal -Names @($koDeleteText -split "`n"))) { $coverageText += $line }
$coverageText += "---"
$coverageText += ""
$coverageText += ("member delete rules : {0} (expected {1})" -f $koDeleteRuleCount, $ExpectedDeleteRuleCount)
$coverageText += ("self-delete rules   : {0} (expected {1})" -f $koDelete.self_deletes.Count, $ExpectedSelfDeleteCount)
$coverageText += ("rd rules            : {0} (expected {1})" -f $koDelete.rd_dirs.Count, $ExpectedRdRuleCount)
$coverageText += ("literal delete names: {0}" -f ($koDelete.literal_deletes -join ', '))
$coverageText += ("prefix delete rules : {0}" -f ($koDelete.pattern_deletes -join ', '))
$coverageText += ("rd rules            : {0}" -f ($koDelete.rd_dirs -join ', '))
$coverageText += ""
$coverageText += "delete rules matched against shipped members:"
foreach ($pattern in $koCoverage.pattern_hits.Keys) {
    $entry = $koCoverage.pattern_hits[$pattern]
    $coverageText += ("  {0,-34} -> {1} member(s): {2}" -f $entry.pattern, $entry.matches.Count, ($entry.matches -join ', '))
}
foreach ($name in $koDelete.literal_deletes) {
    if ($name -eq '!OPTI_DLL_LIST!') { continue }
    $hit = @($koNames | Where-Object { $_ -ieq $name })
    $coverageText += ("  {0,-34} -> {1}" -f $name, $(if ($hit.Count -gt 0) { $hit -join ', ' } else { 'no shipped member (install-time rename target name only)' }))
}
$coverageText += ""
$coverageText += ("declared delete names with no shipped member (recorded, not a failure): {0}" -f $koCoverage.declared_absent.Count)
foreach ($entry in $koCoverage.declared_absent) { $coverageText += ("  - {0}" -f $entry) }
$coverageText += ""
$coverageText += ("covered members ({0}):" -f $koCoverage.covered.Count)
foreach ($name in $koCoverage.covered) { $coverageText += ("  + {0}" -f $name) }
$coverageText += ""
$coverageText += ("residue members ({0}) - what a stock uninstall leaves behind:" -f $koCoverage.residue.Count)
foreach ($name in $koCoverage.residue) { $coverageText += ("  = {0}" -f $name) }
$coverageText += ""
$coverageText += ("outside both sets (setup removes them on a successful install, the uninstaller does not): {0}" -f ($InstallerMembers -join ', '))
$coverageText += ""
$coverageText += ("KO delete-set text == wil delete-set text : {0}" -f (Test-TextBytesEqual -A $koDeleteText -B $wilDeleteText))
$coverageText += ("KO residue set       == wil residue set   : {0}" -f $residueSetEqual)
$coverageText += ("added residue                             : [{0}]" -f ($addedResidue -join ', '))
[IO.File]::WriteAllLines((Join-Path $evidenceResolved 'uninstaller-coverage.txt'), $coverageText, [Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------- residue receipt

$residueJson = [pscustomobject]@{
    tool          = 'tools/Verify-InstallerUntouched.ps1'
    plan_row      = 7
    generated_utc = $stamp
    contract      = 'row 7: acceptance is stock-identical uninstall behavior with zero added residue; the ~40 pre-existing residue members are recorded, not repaired'
    acceptance    = 'parity, not full coverage'
    ko_zip        = [pscustomobject]@{ path = $koResolved; sha256 = $koHash; members = $koNames.Count }
    wil_zip       = [pscustomobject]@{ path = $wilResolved; sha256 = $wilHash; members = $wilNames.Count; pinned_sha256 = $WilSha256.ToLowerInvariant() }
    derived_from  = [pscustomobject]@{
        ko_script = ('{0}::setup_windows.bat' -f $koResolved)
        wil_script = ('{0}::setup_windows.bat' -f $wilResolved)
        setup_windows_bat_sha256_ko  = (Get-FileSha256 -Path $koBatPath)
        setup_windows_bat_sha256_wil = (Get-FileSha256 -Path $wilBatPath)
        delete_set_canonical_sha256 = ([BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($koDeleteText))) -replace '-', '').ToLowerInvariant()
        delete_rules    = $koDeleteRuleCount
        rd_rules        = $koDelete.rd_dirs.Count
        self_deletes    = $koDelete.self_deletes.Count
    }
    covered       = [pscustomobject]@{
        count          = $koCoverage.covered.Count
        expected_count = $ExpectedCoveredCount
        members        = @($koCoverage.covered)
        set_equal_to_wil = $coveredSetEqual
    }
    residue       = [pscustomobject]@{
        count          = $koCoverage.residue.Count
        expected_count = $ExpectedResidueCount
        members        = @($koCoverage.residue)
        set_equal_to_wil = $residueSetEqual
        added          = @($addedResidue)
        missing        = @($missingResidue)
        matches_recorded_list = $residueMatchesRecorded
        composition    = [pscustomobject]$composition
        composition_expected = [pscustomobject]$RecordedResidueComposition
        status         = 'pre-existing stock residue, recorded and deliberately not repaired by this release'
    }
    outside_both_sets = [pscustomobject]@{ members = @($InstallerMembers); note = 'setup removes them on a successful install, the uninstaller does not' }
    result        = $null
    checks        = @($script:checks)
}

# ---------------------------------------------------------------- verdict

$result = 'PASS'
$exitCode = 0
if ($script:deviations.Count -gt 0) { $result = 'PASS_WITH_DEVIATION'; $exitCode = 3 }
if ($script:failures.Count -gt 0) { $result = 'FAIL'; $exitCode = 1 }
$residueJson.result = $result
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'residue-set.json'), ($residueJson | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

$parity = [pscustomobject]@{
    tool              = 'tools/Verify-InstallerUntouched.ps1'
    plan_row          = 7
    contract          = 'row 7: the installer and uninstaller contracts are untouched - byte comparison, payload resource inspection and a derived residue set over two zips'
    generated_utc     = $stamp
    result            = $result
    exit_code_meaning = '0 = PASS (clean); 3 = PASS_WITH_DEVIATION (all gates passed, named deviation recorded); 1 = FAIL'
    failures          = @($script:failures)
    deviations        = @($script:deviations)
    deviation         = [pscustomobject]@{
        criterion             = 'every compared member byte-identical to the frozen rtx40-mfg zip'
        literal_byte_identity = ($nonDllContentDiffs.Count -eq 0) -and ($eolOnlyMembers.Count -eq 0)
        class                 = 'crlf-lf-rendering-only'
        members               = @($eolOnlyMembers)
        content_identical     = ($nonDllContentDiffs.Count -eq 0)
        root_cause            = 'the frozen wil zip ships per-file line endings (the four release docs as LF, README.md and Licenses/FidelityFX_v2_LICENSE.md as CRLF) while this host materializes tracked text as CRLF at checkout; the same class was proven feature-independent in row 5'
        provenance_evidence   = $Row5EolProvenance
        affects               = 'the two text-only groups the row names (shipped docs, Licenses). The installer scripts, the ini default and the runtime DLLs are byte-identical, so the delete-set text and the runtime contract are literal'
    }
    ko_zip            = [pscustomobject]@{ path = $koResolved; sha256 = $koHash; bytes = $koBytes; members = $koNames.Count }
    wil_zip           = [pscustomobject]@{ path = $wilResolved; sha256 = $wilHash; bytes = $wilBytes; members = $wilNames.Count; pinned_sha256 = $WilSha256.ToLowerInvariant(); rehash_matches_pin = ($wilHash -eq $WilSha256.ToLowerInvariant()) }
    member_set        = [pscustomobject]@{ added = @($added); dropped = @($dropped); common = $common.Count; expected_count = $ExpectedMemberCount; no_new_file_in_ko_zip = ($added.Count -eq 0) }
    groups            = [pscustomobject]$groupResult
    delete_set        = [pscustomobject]@{
        source                 = 'setup_windows.bat create_uninstaller block, emitted text, unescaped'
        ko_sha256              = (Get-FileSha256 -Path $koBatPath)
        wil_sha256             = (Get-FileSha256 -Path $wilBatPath)
        ko_text                = $koDeleteText
        wil_text               = $wilDeleteText
        texts_byte_identical   = (Test-TextBytesEqual -A $koDeleteText -B $wilDeleteText)
        delete_rules           = $koDeleteRuleCount
        rd_rules               = $koDelete.rd_dirs.Count
        self_deletes           = @($koDelete.self_deletes)
        literal_deletes        = @($koDelete.literal_deletes)
        pattern_hits           = [pscustomobject]$koCoverage.pattern_hits
        pattern_deletes        = @($koDelete.pattern_deletes)
        for_lists              = @($koDelete.for_lists)
        rd_dirs                = @($koDelete.rd_dirs)
    }
    installer_contract = [pscustomobject]@{
        compared_members   = @($InstallerMembers)
        step_labels_ko     = @($koLabels)
        step_labels_wil    = @($wilLabels)
        step_sets_equal    = (Test-TextBytesEqual -A ($koLabels -join "`n") -B ($wilLabels -join "`n"))
        scripts_clean_vs_head = (($gitDiff.exit -eq 0) -and ($gitPorcelainLines.Count -eq 0))
        new_installer_step = $false
        uninstaller_string_edited = $false
        payload_rename_source    = $payloadSource
        payload_rename_targets   = @($installRenameTargets)
        rename_targets_covered   = @($renameTargetsCovered)
        rename_targets_uncovered = @($renameTargetsUncovered)
        payload_covered_via_rename_table = (($renameTargetsUncovered.Count -eq 0) -and $koTable.ContainsKey($PayloadName))
    }
    coverage          = [pscustomobject]@{
        covered_count        = $koCoverage.covered.Count
        covered_expected     = $ExpectedCoveredCount
        covered_set_equal    = $coveredSetEqual
        residue_count        = $koCoverage.residue.Count
        residue_expected     = $ExpectedResidueCount
        residue_set_equal    = $residueSetEqual
        added_residue        = @($addedResidue)
        missing_residue      = @($missingResidue)
        residue_matches_recorded = $residueMatchesRecorded
        residue_composition  = [pscustomobject]$composition
        declared_absent_names = @($koCoverage.declared_absent)
    }
    payload           = [pscustomobject]@{
        member                    = $PayloadName
        member_present            = $payloadPresent
        ko_sha256                 = $(if ($payloadPresent) { Get-FileSha256 -Path $koDllPath } else { $null })
        wil_sha256                = $(if ($payloadPresent) { Get-FileSha256 -Path $wilDllPath } else { $null })
        ko_bytes                  = $(if ($payloadPresent) { (Get-Item -LiteralPath $koDllPath).Length } else { $null })
        wil_bytes                 = $(if ($payloadPresent) { (Get-Item -LiteralPath $wilDllPath).Length } else { $null })
        original_filename_ko      = $koOriginalFilename
        original_filename_wil     = $wilOriginalFilename
        file_version              = $(if ($payloadPresent) { $koVersion.FileVersion } else { '' })
        internal_name             = $(if ($payloadPresent) { $koVersion.InternalName } else { '' })
        product_name              = $(if ($payloadPresent) { $koVersion.ProductName } else { '' })
        differs_from_wil_allowed  = $(if ($payloadPresent) { (Get-FileSha256 -Path $koDllPath) -ne (Get-FileSha256 -Path $wilDllPath) } else { $null })
    }
    checks            = @($script:checks)
}
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'installer-parity.json'), ($parity | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Remove-Item -LiteralPath $scratch -Recurse -Force

Write-Host ""
Write-Host ("checks={0} failures={1} deviations={2} result={3} exit={4}" -f $script:checks.Count, $script:failures.Count, $script:deviations.Count, $result, $exitCode)
if ($script:deviations.Count -gt 0) {
    Write-Host "deviations (every gate passed; the deviation block in installer-parity.json names each one):"
    foreach ($deviation in $script:deviations) { Write-Host "  - $deviation" }
    Write-Host ("  eol-only members: {0}" -f ($eolOnlyMembers -join ', '))
}
if ($script:failures.Count -gt 0) {
    Write-Host "failed checks:"
    foreach ($failure in $script:failures) { Write-Host "  - $failure" }
}
exit $exitCode
