<#
    xefg-native-unlock-port TODO 9: re-pin of the RTX 20/30 INTENDED-DELTA verification INI receipt
    to exactly the measured +3 keys of the native XeFG unlock port. This revision REPLACES the
    prior expected-additions pin (nr-xefg-088-release todo 12, six keys, valid against the
    r1-frozen baseline) with exactly the three measured keys below. Every other pin and every
    check is untouched.

    Current-era comparison story (slim release pair): after the owner-ordered slim repackage
    (nr-xefg-followups 09/11, release zips now carry 52/56 members), the release pair is verified
    against the PRIOR slim pair as the baseline by passing -BaselineZip/-BaselineSha256/
    -BaselineMemberCount explicitly (invocation + current-pair fixtures: xefg-native-unlock-port
    09 receipt). The pinned expected INI additions are therefore the relative additions vs that
    baseline: exactly the three measured [XeFG] keys (xefg-native-unlock-port todo 4 ini template /
    todo 9 ini-key-delta), shipped as "auto". The six nr-xefg-088-release keys already live in
    the slim baseline, so they are covered by the no-lost/no-changed checks below, not by the
    additions pin.

    The frozen r1/A/B comparison story of the nr-xefg-088-release todo-12 revision is preserved
    in .omo/evidence/nr-xefg-088-release/12/Verify-Rtx2030Delta.ps1.todo12; running this tool
    against the r1 baseline on the slim pair exits 1 by design (followups 11 supplemental runs).

    Classifies EVERY member of the verified artifact against the selected baseline into three
    explicit lists:

      ADD       - allowed only for the pinned payload members (the module under the
                  vendor/dlssg_sm86/PIN.json bundled_name, OptiScaler/dlssg_sm86/dlssg_sm86.ini,
                  OptiScaler/dlssg_sm86/THIRD_PARTY_NOTICES.txt and its Licenses/ copy) and the
                  intentionally added doc members docs/RELEASE-v0.8.8.md and docs/RELEASE-NOTES-r3-KO.md
                  (followups T8 bundling). Anything else added
                  FAILS, named. (A carries only the docs; B carries the docs plus the payload.)
      MODIFY    - allowed only for OptiScaler.dll, OptiScaler.ini, README.md, INSTALL-DLSSNR.md,
                  INSTALL-KO.md, docs/NR-DLSS-ENLARGEMENT.md, SHA256SUMS.txt. Anything else
                  modified FAILS, named.
      IDENTICAL - every other common member must hash equal to the baseline; a baseline member
                  missing from the new zip FAILS, named.

    Plus:
      - the embedded SHA256SUMS.txt must self-verify over every member (the sums file covers all
        members except itself),
      - an OptiScaler.ini key-by-key preservation receipt: exactly the three measured keys are
        added ([XeFG] UnlockMFG=auto, MaxInterpolatedFrames=auto, ExtraPacing=auto; the measured
        values from xefg-native-unlock-port todo 9's ini-key-delta) and every pre-existing
        key/value pair still exists unchanged (duplicate keys are compared as multisets so
        repeated keys are handled).

    Note for the A/B pair: their shared members are byte-identical except OptiScaler.dll, which
    differs by design of the build order (incremental-LTCG relink asymmetry between the two
    packaging builds of the same tree - receipt 13 section 7); each artifact is verified
    independently against the selected baseline and that inter-artifact difference is not a
    deviation. Plan row 18 (the
    non-discriminating flavour probe in package_release.ps1) remains separate work, untouched.

    T13 extension (xefg-native-unlock-port todo 13): the MODIFY allowlist gains exactly the
    measured port-file set - Config.md and docs/RELEASE-NOTES-r3-KO.md - the two packaged
    members the port wave changed vs the v11 pair (raw as-is runs naming them: 13/A-pre +
    13/B-pre; final PASS runs: 13/A + 13/B). No check, pin, expected-key or exit-code logic
    changed; the T9 identity stamps above stay, this paragraph is the extension record.

    Exit codes: 0 = PASS (no unexpected entries, INI receipt exact, sums self-check clean),
                1 = FAIL (every offender named on stdout).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NewZip,
    [Parameter(Mandatory = $true)][string]$BaselineZip,
    [Parameter(Mandatory = $true)][string]$EvidenceDir,
    [string]$RepoRoot = 'C:\omo-research\susemi-next-ui-lang',
    [string]$BaselineSha256 = '36bf8dcbd9cac4836d6ecb0a661413a92b3726efc47565149ced4617e807758e',
    [int]$BaselineMemberCount = 66,
    [string]$RecordedBaselineList = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:checks = New-Object System.Collections.ArrayList
$script:failures = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("{0} {1,-32} {2}" -f $status, $Name, $Detail)
    [void]$script:checks.Add([pscustomobject]@{ name = $Name; status = $status; detail = $Detail })
    if (-not $Ok) { [void]$script:failures.Add(("{0}: {1}" -f $Name, $Detail)) }
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Sort-Ordinal {
    param([string[]]$Names)
    $copy = @($Names)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return , $copy
}

function Get-ZipMemberTable {
    param([string]$ZipPath)
    $table = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.Name -eq '') { continue }   # directory entry; this packaging never writes one
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            $table[$entry.FullName] = [pscustomobject]@{ sha256 = $hash; bytes = $entry.Length }
        }
    } finally { $archive.Dispose() }
    return $table
}

function Read-ZipEntryBytes {
    param([string]$ZipPath, [string]$Name)
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $archive.GetEntry($Name)
        if (-not $entry) { return $null }
        $stream = $entry.Open()
        try {
            $ms = New-Object IO.MemoryStream
            try { $stream.CopyTo($ms); return $ms.ToArray() } finally { $ms.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}

# Parses an INI byte blob into key -> ordered list of values. key = "<section>`n<Key>".
# Comment and blank lines are ignored; repeated keys keep every occurrence (multiset).
function Get-IniKeyMap {
    param([byte[]]$Bytes)
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $text = $text.TrimStart([char]0xFEFF)
    $map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $section = '(root)'
    foreach ($line in ($text -split "`r`n|`n|`r")) {
        $s = $line.Trim()
        if ($s.Length -eq 0) { continue }
        if (($s[0] -eq ';') -or ($s[0] -eq '#')) { continue }
        if (($s[0] -eq '[') -and ($s[$s.Length - 1] -eq ']')) { $section = $s; continue }
        $eq = $s.IndexOf('=')
        if ($eq -lt 0) { continue }
        $key = $s.Substring(0, $eq).Trim()
        $value = $s.Substring($eq + 1).Trim()
        $compound = $section + "`n" + $key
        if (-not $map.ContainsKey($compound)) { $map[$compound] = New-Object System.Collections.Generic.List[string] }
        $map[$compound].Add($value)
    }
    return $map
}

function Format-IniKey {
    param([string]$Compound)
    return ($Compound -replace "`n", ' ')
}

# ---------------------------------------------------------------- inputs

$newResolved = [IO.Path]::GetFullPath($NewZip)
$baselineResolved = [IO.Path]::GetFullPath($BaselineZip)
$evidenceResolved = [IO.Path]::GetFullPath($EvidenceDir)
if (-not (Test-Path -LiteralPath $evidenceResolved)) { New-Item -ItemType Directory -Path $evidenceResolved -Force | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Host "RTX2030 intended-delta verification (xefg-native-unlock-port todo 9)"
Write-Host "new zip      : $newResolved"
Write-Host "baseline zip : $baselineResolved"
Write-Host "evidence     : $evidenceResolved"
Write-Host "utc          : $stamp"
Write-Host ""

$newExists = Test-Path -LiteralPath $newResolved -PathType Leaf
$baselineExists = Test-Path -LiteralPath $baselineResolved -PathType Leaf
Add-Check -Name 'new-zip-present' -Ok $newExists -Detail $newResolved
Add-Check -Name 'baseline-zip-present' -Ok $baselineExists -Detail $baselineResolved
if ((-not $newExists) -or (-not $baselineExists)) {
    Write-Host 'RESULT: FAIL (missing input)'
    exit 1
}

# The baseline is frozen: rehash it and require the pinned identity before using it at all.
$baselineHash = Get-FileSha256 -Path $baselineResolved
$baselineBytes = (Get-Item -LiteralPath $baselineResolved).Length
Add-Check -Name 'baseline-frozen-rehash' -Ok ($baselineHash -eq $BaselineSha256.ToLowerInvariant()) -Detail ("sha256={0} pinned={1} bytes={2}" -f $baselineHash, $BaselineSha256.ToLowerInvariant(), $baselineBytes)

# The bundled module name is read from the pin; never hardcoded here.
$pinPath = Join-Path $RepoRoot 'vendor/dlssg_sm86/PIN.json'
if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { throw "Payload pin is missing: $pinPath" }
$bundledName = (Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json).bundled_name
if (-not $bundledName) { throw "The payload pin has no bundled_name: $pinPath" }

$baselineTable = Get-ZipMemberTable -ZipPath $baselineResolved
$newTable = Get-ZipMemberTable -ZipPath $newResolved
$baselineNames = Sort-Ordinal -Names @($baselineTable.Keys)
$newNames = Sort-Ordinal -Names @($newTable.Keys)
$newHash = Get-FileSha256 -Path $newResolved
$newBytes = (Get-Item -LiteralPath $newResolved).Length

Add-Check -Name 'baseline-member-count' -Ok ($baselineNames.Count -eq $BaselineMemberCount) -Detail ("members={0} expected={1}" -f $baselineNames.Count, $BaselineMemberCount)
Write-Host ("     new zip sha256={0} bytes={1} members={2}" -f $newHash, $newBytes, $newNames.Count)
Write-Host ""

# ---------------------------------------------------------------- optional cross-check against the recorded baseline member list

$recordedResult = 'not-checked'
$recordedMismatches = New-Object System.Collections.ArrayList
if ($RecordedBaselineList) {
    $recordedPath = [IO.Path]::GetFullPath($RecordedBaselineList)
    $recorded = @{}
    foreach ($line in (Get-Content -LiteralPath $recordedPath)) {
        if ($line -match '^\s*$') { continue }
        if ($line -match '^(?i)([0-9a-f]{64})\s+(\d+)\s+(.+)$') {
            $recorded[$Matches[3]] = [pscustomobject]@{ sha256 = $Matches[1].ToLowerInvariant(); bytes = [int64]$Matches[2] }
        }
        else { [void]$recordedMismatches.Add("unparseable line: $line") }
    }
    foreach ($name in $baselineNames) {
        if (-not $recorded.ContainsKey($name)) { [void]$recordedMismatches.Add("recorded list missing $name"); continue }
        if (($recorded[$name].sha256 -cne $baselineTable[$name].sha256) -or ($recorded[$name].bytes -ne $baselineTable[$name].bytes)) {
            [void]$recordedMismatches.Add("recorded list mismatch: $name")
        }
    }
    foreach ($name in $recorded.Keys) {
        if (-not $baselineTable.ContainsKey($name)) { [void]$recordedMismatches.Add("recorded list has extra member $name") }
    }
    $recordedResult = if ($recordedMismatches.Count -eq 0) { 'match' } else { 'mismatch' }
    Add-Check -Name 'recorded-baseline-list-match' -Ok ($recordedMismatches.Count -eq 0) -Detail ("recorded={0} recomputed={1} mismatches=[{2}]" -f $recorded.Count, $baselineNames.Count, ($recordedMismatches -join '; '))
}
else { Write-Host "INFO recorded-baseline-list      not provided" }

# ---------------------------------------------------------------- member classification

$payloadAddAllowlist = @(
    "OptiScaler/dlssg_sm86/$bundledName",
    'OptiScaler/dlssg_sm86/dlssg_sm86.ini',
    'OptiScaler/dlssg_sm86/THIRD_PARTY_NOTICES.txt',
    'Licenses/DLSSG_SM86_THIRD_PARTY_NOTICES.txt'
)
$docAddAllowlist = @('docs/RELEASE-v0.8.8.md', 'docs/RELEASE-NOTES-r3-KO.md')
# T13 (measured set): the port wave's two packaged doc members join the modify allowlist -
# Config.md and docs/RELEASE-NOTES-r3-KO.md were the exact unexpected names of the raw
# as-is delta runs (13/A-pre, 13/B-pre) against the v11 pair; nothing else widened.
$modifyAllowlist = @('OptiScaler.dll', 'OptiScaler.ini', 'README.md', 'INSTALL-DLSSNR.md', 'INSTALL-KO.md', 'docs/NR-DLSS-ENLARGEMENT.md', 'SHA256SUMS.txt', 'Config.md', 'docs/RELEASE-NOTES-r3-KO.md')

$addedAllowed = New-Object System.Collections.ArrayList
$addedUnexpected = New-Object System.Collections.ArrayList
$modifiedAllowed = New-Object System.Collections.ArrayList
$modifiedUnexpected = New-Object System.Collections.ArrayList
$identicalList = New-Object System.Collections.ArrayList
$droppedList = New-Object System.Collections.ArrayList

foreach ($name in $newNames) {
    if (-not $baselineTable.ContainsKey($name)) {
        $kind = $null
        if ($payloadAddAllowlist -ccontains $name) { $kind = 'payload' }
        elseif ($docAddAllowlist -ccontains $name) { $kind = 'doc' }
        if ($kind) {
            [void]$addedAllowed.Add([pscustomobject]@{ name = $name; kind = $kind; sha256 = $newTable[$name].sha256; bytes = $newTable[$name].bytes })
        }
        else {
            [void]$addedUnexpected.Add([pscustomobject]@{ name = $name; sha256 = $newTable[$name].sha256; bytes = $newTable[$name].bytes })
        }
        continue
    }
    if ($newTable[$name].sha256 -cne $baselineTable[$name].sha256) {
        if ($modifyAllowlist -ccontains $name) {
            [void]$modifiedAllowed.Add([pscustomobject]@{ name = $name; baseline_sha256 = $baselineTable[$name].sha256; new_sha256 = $newTable[$name].sha256; baseline_bytes = $baselineTable[$name].bytes; new_bytes = $newTable[$name].bytes })
        }
        else {
            [void]$modifiedUnexpected.Add([pscustomobject]@{ name = $name; baseline_sha256 = $baselineTable[$name].sha256; new_sha256 = $newTable[$name].sha256 })
        }
        continue
    }
    [void]$identicalList.Add([pscustomobject]@{ name = $name; sha256 = $newTable[$name].sha256; bytes = $newTable[$name].bytes })
}
foreach ($name in $baselineNames) {
    if (-not $newTable.ContainsKey($name)) { [void]$droppedList.Add($name) }
}

Add-Check -Name 'add-allowlist' -Ok ($addedUnexpected.Count -eq 0) -Detail ("allowed={0} unexpected={1} unexpected-names=[{2}]" -f $addedAllowed.Count, $addedUnexpected.Count, (($addedUnexpected | ForEach-Object { $_.name }) -join ', '))
Add-Check -Name 'modify-allowlist' -Ok ($modifiedUnexpected.Count -eq 0) -Detail ("allowed={0} unexpected={1} unexpected-names=[{2}]" -f $modifiedAllowed.Count, $modifiedUnexpected.Count, (($modifiedUnexpected | ForEach-Object { $_.name }) -join ', '))
Add-Check -Name 'dropped-members' -Ok ($droppedList.Count -eq 0) -Detail ("dropped={0} names=[{1}]" -f $droppedList.Count, ($droppedList -join ', '))
Add-Check -Name 'identical-bytes' -Ok ($identicalList.Count -eq ($baselineNames.Count - $modifiedAllowed.Count)) -Detail ("identical={0} baseline={1} modified-allowed={2}" -f $identicalList.Count, $baselineNames.Count, $modifiedAllowed.Count)

Write-Host ""
Write-Host ("ADD - {0} allowed, {1} unexpected" -f $addedAllowed.Count, $addedUnexpected.Count)
foreach ($m in $addedAllowed) { Write-Host ("  [{0}] {1} ({2} B, {3})" -f $m.kind, $m.name, $m.bytes, $m.sha256) }
foreach ($m in $addedUnexpected) { Write-Host ("  [UNEXPECTED] {0} ({1} B, {2})" -f $m.name, $m.bytes, $m.sha256) }
Write-Host ("MODIFY - {0} allowed, {1} unexpected" -f $modifiedAllowed.Count, $modifiedUnexpected.Count)
foreach ($m in $modifiedAllowed) { Write-Host ("  {0}`n    baseline {1}`n    new      {2}" -f $m.name, $m.baseline_sha256, $m.new_sha256) }
foreach ($m in $modifiedUnexpected) { Write-Host ("  [UNEXPECTED] {0}`n    baseline {1}`n    new      {2}" -f $m.name, $m.baseline_sha256, $m.new_sha256) }
Write-Host ("IDENTICAL - {0} members, every byte equal to the baseline" -f $identicalList.Count)
foreach ($m in $identicalList) { Write-Host ("  {0}" -f $m.name) }
Write-Host ("DROPPED - {0}" -f $droppedList.Count)
foreach ($m in $droppedList) { Write-Host ("  [MISSING] {0}" -f $m) }
Write-Host ""

# ---------------------------------------------------------------- SHA256SUMS self-check

$sumsResult = 'FAIL'
$sumsLines = 0; $sumsCoveredCount = 0
$sumsMismatches = New-Object System.Collections.ArrayList
$sumsMissing = New-Object System.Collections.ArrayList
$sumsDuplicates = New-Object System.Collections.ArrayList
$sumsUnparseable = New-Object System.Collections.ArrayList
$sumsBytes = Read-ZipEntryBytes -ZipPath $newResolved -Name 'SHA256SUMS.txt'
if ($null -eq $sumsBytes) {
    Add-Check -Name 'sums-present' -Ok $false -Detail 'SHA256SUMS.txt is missing from the new zip'
}
else {
    Add-Check -Name 'sums-present' -Ok $true -Detail ("{0} bytes" -f $sumsBytes.Length)
    $sumsText = [Text.Encoding]::UTF8.GetString($sumsBytes)
    $sumsText = $sumsText.TrimStart([char]0xFEFF)
    $seen = @{}
    foreach ($line in ($sumsText -split "`r`n|`n|`r")) {
        if ($line -match '^\s*$') { continue }
        $sumsLines++
        if ($line -match '^(?i)([0-9a-f]{64}) \*(.+)$') {
            $hash = $Matches[1].ToLowerInvariant()
            $name = $Matches[2]
            if ($seen.ContainsKey($name)) { [void]$sumsDuplicates.Add($name); continue }
            $seen[$name] = $hash
            if (-not $newTable.ContainsKey($name)) { [void]$sumsMismatches.Add("$name (no such member)"); continue }
            if ($newTable[$name].sha256 -cne $hash) { [void]$sumsMismatches.Add($name); continue }
            $sumsCoveredCount++
        }
        else { [void]$sumsUnparseable.Add($line) }
    }
    $expectedCovered = @($newNames | Where-Object { $_ -cne 'SHA256SUMS.txt' })
    foreach ($name in $expectedCovered) { if (-not $seen.ContainsKey($name)) { [void]$sumsMissing.Add($name) } }
    $sumsOk = ($sumsMismatches.Count -eq 0) -and ($sumsMissing.Count -eq 0) -and ($sumsDuplicates.Count -eq 0) -and ($sumsUnparseable.Count -eq 0) -and ($sumsCoveredCount -eq $expectedCovered.Count)
    if ($sumsOk) { $sumsResult = 'PASS' }
    Add-Check -Name 'sums-self-check' -Ok $sumsOk -Detail ("members={0} lines={1} covered={2} expected-covered={3} mismatches=[{4}] missing=[{5}] duplicates=[{6}] unparseable=[{7}]" -f $newNames.Count, $sumsLines, $sumsCoveredCount, $expectedCovered.Count, ($sumsMismatches -join ', '), ($sumsMissing -join ', '), ($sumsDuplicates -join ', '), ($sumsUnparseable -join ' | '))
}

$sumsReport = @(
    'SHA256SUMS.txt self-check (new zip)',
    ('new zip: ' + $newResolved),
    ('members: {0}  (the sums file covers every member except itself: {1} entries expected)' -f $newNames.Count, ($newNames.Count - 1)),
    ('lines: {0}  covered: {1}  mismatches: [{2}]  missing: [{3}]  duplicates: [{4}]  unparseable: [{5}]' -f $sumsLines, $sumsCoveredCount, ($sumsMismatches -join ', '), ($sumsMissing -join ', '), ($sumsDuplicates -join ', '), ($sumsUnparseable -join ' | ')),
    ('RESULT: ' + $sumsResult),
    ''
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'sums-self-check.txt'), $sumsReport, [Text.UTF8Encoding]::new($false))
Write-Host "sums self-check: $sumsResult"
Write-Host ""

# ---------------------------------------------------------------- INI preservation receipt

$iniResult = 'FAIL'
$iniAddedReport = New-Object System.Collections.ArrayList
$iniLost = New-Object System.Collections.ArrayList
$iniChanged = New-Object System.Collections.ArrayList
$iniProblems = New-Object System.Collections.ArrayList
$baselineKeyCount = 0; $newKeyCount = 0
$baselineIniBytes = Read-ZipEntryBytes -ZipPath $baselineResolved -Name 'OptiScaler.ini'
$newIniBytes = Read-ZipEntryBytes -ZipPath $newResolved -Name 'OptiScaler.ini'
if (($null -eq $baselineIniBytes) -or ($null -eq $newIniBytes)) {
    Add-Check -Name 'ini-presence' -Ok $false -Detail 'OptiScaler.ini missing from one of the zips'
}
else {
    Add-Check -Name 'ini-presence' -Ok $true -Detail 'OptiScaler.ini present in both zips'
    $baselineMap = Get-IniKeyMap -Bytes $baselineIniBytes
    $newMap = Get-IniKeyMap -Bytes $newIniBytes
    $baselineKeyCount = @($baselineMap.Keys).Count
    $newKeyCount = @($newMap.Keys).Count

    # Exactly these three keys may be added (measured list: xefg-native-unlock-port todo 9's
    # ini-key-delta - the +3 shipped by todo 4's ini template), with exactly these shipped default
    # values. These are the relative additions vs the slim-era baseline pair; the six
    # nr-xefg-088-release todo-12 keys already live in that baseline and are covered by the
    # no-lost/no-changed checks below.
    $expectedIniAdditions = New-Object System.Collections.Specialized.OrderedDictionary
    $expectedIniAdditions[('[XeFG]' + "`n" + 'UnlockMFG')] = 'auto'
    $expectedIniAdditions[('[XeFG]' + "`n" + 'MaxInterpolatedFrames')] = 'auto'
    $expectedIniAdditions[('[XeFG]' + "`n" + 'ExtraPacing')] = 'auto'
    $expectedKeys = @($expectedIniAdditions.Keys)

    $addedKeys = @($newMap.Keys | Where-Object { -not $baselineMap.ContainsKey($_) })
    $lostKeys = @($baselineMap.Keys | Where-Object { -not $newMap.ContainsKey($_) })
    $changedKeys = @()
    foreach ($k in $baselineMap.Keys) {
        if ($newMap.ContainsKey($k)) {
            $a = @($baselineMap[$k] | Sort-Object) -join "`n"
            $b = @($newMap[$k] | Sort-Object) -join "`n"
            if ($a -cne $b) { $changedKeys += $k }
        }
    }

    $extraAdded = @($addedKeys | Where-Object { $expectedKeys -cnotcontains $_ })
    $missingAdded = @($expectedKeys | Where-Object { $addedKeys -cnotcontains $_ })
    foreach ($k in $extraAdded) { [void]$iniProblems.Add("unexpected added key: $(Format-IniKey $k)") }
    foreach ($k in $missingAdded) { [void]$iniProblems.Add("expected added key missing: $(Format-IniKey $k)") }
    foreach ($k in $expectedKeys) {
        if ($newMap.ContainsKey($k)) {
            $vals = @($newMap[$k])
            $want = $expectedIniAdditions[$k]
            if (-not (($vals.Count -eq 1) -and ($vals[0] -ceq $want))) {
                [void]$iniProblems.Add("wrong added-key value: $(Format-IniKey $k) = '$($vals -join '; ')' (expected '$want')")
            }
        }
    }
    foreach ($k in $lostKeys) { [void]$iniLost.Add((Format-IniKey $k)); [void]$iniProblems.Add("pre-existing key missing: $(Format-IniKey $k)") }
    foreach ($k in $changedKeys) {
        $a = (@($baselineMap[$k] | Sort-Object) -join '; '); $b = (@($newMap[$k] | Sort-Object) -join '; ')
        [void]$iniChanged.Add((Format-IniKey $k)); [void]$iniProblems.Add("pre-existing key changed: $(Format-IniKey $k) baseline='$a' new='$b'")
    }

    $dupHint = ''
    $dupBase = @($baselineMap.Keys | Where-Object { @($baselineMap[$_]).Count -gt 1 })
    if ($dupBase.Count -gt 0) { $dupHint = " (duplicate keys compared as multisets: $($dupBase.Count) repeated key(s), e.g. $(Format-IniKey $dupBase[0]))" }

    if ($iniProblems.Count -eq 0) { $iniResult = 'PASS' }
    Add-Check -Name 'ini-preservation' -Ok ($iniProblems.Count -eq 0) -Detail ("baseline-keys={0} new-keys={1} added={2} lost={3} changed={4} problems=[{5}]" -f $baselineKeyCount, $newKeyCount, $addedKeys.Count, $lostKeys.Count, $changedKeys.Count, ($iniProblems -join '; '))

    Add-Check -Name 'ini-added-set-exact' -Ok (($extraAdded.Count -eq 0) -and ($missingAdded.Count -eq 0)) -Detail ("added=[{0}] expected=[{1}]" -f (($addedKeys | ForEach-Object { Format-IniKey $_ }) -join ', '), (($expectedKeys | ForEach-Object { Format-IniKey $_ }) -join ', '))
    Add-Check -Name 'ini-no-lost-keys' -Ok ($lostKeys.Count -eq 0) -Detail ("lost=[{0}]" -f (($lostKeys | ForEach-Object { Format-IniKey $_ }) -join ', '))
    Add-Check -Name 'ini-no-changed-values' -Ok ($changedKeys.Count -eq 0) -Detail ("changed=[{0}]" -f (($changedKeys | ForEach-Object { Format-IniKey $_ }) -join ', '))

    $addedLines = @()
    foreach ($k in $expectedKeys) {
        if ($newMap.ContainsKey($k)) { $addedLines += ('  {0}={1}' -f (Format-IniKey $k), (@($newMap[$k]) -join '; ')) }
        else { $addedLines += ('  {0} <MISSING>' -f (Format-IniKey $k)) }
    }
    $receipt = @(
        'OptiScaler.ini preservation receipt (baseline vs new release zip)',
        ('baseline: ' + $baselineResolved + '  keys: ' + $baselineKeyCount),
        ('new     : ' + $newResolved + '  keys: ' + $newKeyCount + $dupHint),
        ('added keys - expected exactly {0}:' -f $expectedKeys.Count)
    ) + $addedLines + @(
        ('lost keys - expected 0: ' + $(if ($iniLost.Count -eq 0) { 'none' } else { $iniLost -join ', ' })),
        ('changed values - expected 0: ' + $(if ($iniChanged.Count -eq 0) { 'none' } else { $iniChanged -join ', ' })),
        ('unexpected added keys: ' + $(if ($extraAdded.Count -eq 0) { 'none' } else { ($extraAdded | ForEach-Object { Format-IniKey $_ }) -join ', ' })),
        ('RESULT: ' + $iniResult),
        ''
    )
    [IO.File]::WriteAllText((Join-Path $evidenceResolved 'ini-preservation-receipt.txt'), ($receipt -join "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Host "INI preservation receipt: $iniResult"
}
Write-Host ""

# ---------------------------------------------------------------- member list files + delta report

$baselineListLines = @($baselineNames | ForEach-Object { '{0}  {1}  {2}' -f $baselineTable[$_].sha256, $baselineTable[$_].bytes, $_ })
$newListLines = @($newNames | ForEach-Object { '{0}  {1}  {2}' -f $newTable[$_].sha256, $newTable[$_].bytes, $_ })
[IO.File]::WriteAllLines((Join-Path $evidenceResolved 'baseline-member-list.txt'), $baselineListLines, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines((Join-Path $evidenceResolved 'new-member-list.txt'), $newListLines, [Text.UTF8Encoding]::new($false))

$result = if ($script:failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$reportLines = @(
    'RTX2030 intended-delta verification (xefg-native-unlock-port todo 9)',
    ('utc: ' + $stamp),
    ('new zip      : ' + $newResolved + '  sha256=' + $newHash + '  bytes=' + $newBytes + '  members=' + $newNames.Count),
    ('baseline zip : ' + $baselineResolved + '  sha256=' + $baselineHash + '  bytes=' + $baselineBytes + '  members=' + $baselineNames.Count + ' (pinned)'),
    ('payload name : OptiScaler/dlssg_sm86/' + $bundledName + ' (vendor/dlssg_sm86/PIN.json bundled_name)'),
    ''
) + @(
    ('ADD - {0} allowed, {1} unexpected:' -f $addedAllowed.Count, $addedUnexpected.Count)
) + @($addedAllowed | ForEach-Object { '  [{0}] {1} ({2} B, {3})' -f $_.kind, $_.name, $_.bytes, $_.sha256 }) + @($addedUnexpected | ForEach-Object { '  [UNEXPECTED] {0} ({1} B, {2})' -f $_.name, $_.bytes, $_.sha256 }) + @(
    ('MODIFY - {0} allowed, {1} unexpected:' -f $modifiedAllowed.Count, $modifiedUnexpected.Count)
) + @($modifiedAllowed | ForEach-Object { '  {0}  baseline={1}  new={2}' -f $_.name, $_.baseline_sha256, $_.new_sha256 }) + @($modifiedUnexpected | ForEach-Object { '  [UNEXPECTED] {0}  baseline={1}  new={2}' -f $_.name, $_.baseline_sha256, $_.new_sha256 }) + @(
    ('IDENTICAL - {0} members:' -f $identicalList.Count)
) + @($identicalList | ForEach-Object { '  {0}' -f $_.name }) + @(
    ('DROPPED - {0}:' -f $droppedList.Count)
) + @($droppedList | ForEach-Object { '  [MISSING] {0}' -f $_ }) + @(
    '',
    ('sums self-check: ' + $sumsResult + ' (sums-self-check.txt)'),
    ('INI preservation: ' + $iniResult + ' (ini-preservation-receipt.txt)'),
    ('recorded-baseline-list: ' + $recordedResult),
    ('RESULT: ' + $result)
)
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'delta-report.txt'), ($reportLines -join "`r`n"), [Text.UTF8Encoding]::new($false))

$json = [ordered]@{
    tool     = 'tools/Verify-Rtx2030Delta.ps1'
    todo     = 'xefg-native-unlock-port#9'
    utc      = $stamp
    new_zip  = [ordered]@{ path = $newResolved; sha256 = $newHash; bytes = $newBytes; members = $newNames.Count }
    baseline = [ordered]@{ path = $baselineResolved; sha256 = $baselineHash; bytes = $baselineBytes; members = $baselineNames.Count; expected_sha256 = $BaselineSha256.ToLowerInvariant(); expected_members = $BaselineMemberCount }
    add      = [ordered]@{ allowed = @($addedAllowed); unexpected = @($addedUnexpected) }
    modify   = [ordered]@{ allowed = @($modifiedAllowed); unexpected = @($modifiedUnexpected) }
    identical = @($identicalList)
    dropped   = @($droppedList)
    sums     = [ordered]@{ result = $sumsResult; lines = $sumsLines; covered = $sumsCoveredCount; mismatches = @($sumsMismatches); missing = @($sumsMissing); duplicates = @($sumsDuplicates) }
    ini      = [ordered]@{ result = $iniResult; baseline_keys = $baselineKeyCount; new_keys = $newKeyCount; added = @($addedKeys | ForEach-Object { Format-IniKey $_ }); lost = @($iniLost); changed = @($iniChanged) }
    recorded_baseline_list = [ordered]@{ path = $RecordedBaselineList; result = $recordedResult; mismatches = @($recordedMismatches) }
    checks   = @($script:checks)
    result   = $result
}
[IO.File]::WriteAllText((Join-Path $evidenceResolved 'delta-report.json'), ($json | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

Write-Host "member lists: baseline-member-list.txt, new-member-list.txt"
Write-Host "report      : delta-report.txt, delta-report.json"
if ($script:failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'FAILURES:'
    foreach ($f in $script:failures) { Write-Host ("  - " + $f) }
    Write-Host 'RESULT: FAIL'
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
