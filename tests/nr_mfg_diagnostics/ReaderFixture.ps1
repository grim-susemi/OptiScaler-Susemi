#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$ReaderSource,
      [Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [Parameter(Mandatory=$true)][ValidateSet('stable-first-repeat','equal-length-change','length-change','stat-open-growth')][string]$Scenario)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath($EvidenceRoot)
[IO.Directory]::CreateDirectory($root) | Out-Null
. $ReaderSource
$sourceIdentity=@{path=$ReaderSource;bytes=(Get-Item -LiteralPath $ReaderSource).Length;sha256=(Get-FileHash -LiteralPath $ReaderSource).Hash}
$observations=[Collections.Generic.List[object]]::new()
$accepted=$false
$observedError=$null
$stageCount=0
$fixturePath=Join-Path $root 'owned-input.bin'
$first=[byte[]](0..31)
function ExpectedHash([byte[]]$data) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [Convert]::ToHexString($algorithm.ComputeHash($data))} finally {$algorithm.Dispose()}
}
function Snapshot([string]$path,[string]$label) {
    $data=[IO.File]::ReadAllBytes($path)
    $snapshot=Join-Path $root ($label+'.bin')
    [IO.File]::WriteAllBytes($snapshot,$data)
    $version=@{path=$path;versionSnapshot=$snapshot;bytes=$data.Length;sha256=(ExpectedHash $data)}
    $observations.Add($version)
    return $version
}
function Assert([bool]$condition,[string]$name) {if (!$condition) {throw "T22_READER_ORACLE_$name"}}
function RequireRefusal([scriptblock]$operation,[string]$expected,[string]$oracle) {
    try {$returned=& $operation}
    catch {
        if ($_.Exception.Message -cne $expected) {throw}
        $script:observedError=$_.Exception.Message
        Write-Host "T22_READER_REFUSAL=$script:observedError"
        return
    }
    $observations.Add(@{unexpectedAcceptedBytes=$returned.bytes;unexpectedAcceptedSha256=$returned.sha256;
        actualReturnedBytes=@($returned.data);totalBytesAfterUnexpectedRead=$script:totalBytes;bindingCount=$bindings.Count})
    throw "T22_READER_ORACLE_$oracle"
}
function Invoke-ReaderStatOpenTransition([string]$path,[long]$cachedStatLength) {
    Assert ($Scenario -eq 'stat-open-growth' -and $script:stageCount -eq 0 -and $cachedStatLength -eq 0) 'GROWTH_STAGE_IDENTITY'
    $script:stageCount++
    $growth=[byte[]]::new(256)
    [Array]::Fill[byte]($growth,170)
    [IO.File]::WriteAllBytes($path,$growth)
    $version=Snapshot $path 'after-stat-before-open'
    $observations.Add(@{transition='owned file write closed after cached stat and before real File.Open';
        cachedStatLength=$cachedStatLength;actualFileLength=$version.bytes;actualFileSha256=$version.sha256;
        totalBytesBeforeOpen=$script:totalBytes;remainingBytes=$limits.retained-$script:totalBytes;
        configuredRetainedLimit=$limits.retained;perFileMaximum=1024})
}
try {
    Assert ($limits.retained -eq 268435456 -and $limits.rawFile -eq 1048576 -and $script:totalBytes -is [long]) 'PRODUCTION_LIMITS_AND_TYPED_COUNTER'
    if ($Scenario -eq 'stat-open-growth') {
        [IO.File]::WriteAllBytes($fixturePath,[byte[]]::new(0))
        [void](Snapshot $fixturePath 'before-stat')
        $script:totalBytes=[long]$limits.retained-128L
        $before=$script:totalBytes
        RequireRefusal {ReadArtifact $fixturePath 1024 'owned-growth-test'} 'T22_TOTAL_READ_LIMIT' 'B1_TOTAL_GROWTH_REFUSAL_REQUIRED'
        Assert ($stageCount -eq 1 -and $script:totalBytes -eq $before -and $bindings.Count -eq 0 -and $seen.Count -eq 0) 'B1_REFUSAL_BEFORE_ACCEPTANCE'
    } else {
        [IO.File]::WriteAllBytes($fixturePath,$first)
        $version=Snapshot $fixturePath 'first-read-version'
        if ($Scenario -eq 'stable-first-repeat') {$script:totalBytes=[long]$limits.retained-$first.Length}
        $baseline=$script:totalBytes
        $initial=ReadArtifact $fixturePath 1024 'owned-first-read'
        Assert ($initial.bytes -eq 32 -and $initial.sha256 -ceq $version.sha256 -and
            [Convert]::ToHexString($initial.data) -ceq [Convert]::ToHexString($first)) 'STABLE_FIRST_CONTENT'
        Assert ($bindings.Count -eq 1 -and $seen.Count -eq 1 -and $script:totalBytes -eq $baseline+32) 'STABLE_FIRST_BINDING_AND_TOTAL'
        if ($Scenario -eq 'stable-first-repeat') {
            $again=ReadArtifact $fixturePath 1024 'owned-repeated-read'
            Assert ($again.bytes -eq $initial.bytes -and $again.sha256 -ceq $initial.sha256 -and
                [Convert]::ToHexString($again.data) -ceq [Convert]::ToHexString($first)) 'STABLE_REPEAT_CONTENT'
            Assert ($bindings.Count -eq 1 -and $seen.Count -eq 1 -and $script:totalBytes -eq $limits.retained -and
                $bindings[0].sha256 -ceq $version.sha256) 'STABLE_REPEAT_SINGLE_BINDING_AT_LIMIT'
            $observations.Add(@{firstActualBytes=$initial.bytes;firstActualSha256=$initial.sha256;
                repeatedActualBytes=$again.bytes;repeatedActualSha256=$again.sha256;bindings=$bindings.Count;
                totalBytes=$script:totalBytes;limit=$limits.retained;actualFileBytes=32})
        } else {
            $changed=[byte[]]::new($(if ($Scenario -eq 'equal-length-change') {32} else {64}))
            [Array]::Fill[byte]($changed,170)
            [IO.File]::WriteAllBytes($fixturePath,$changed)
            $newVersion=Snapshot $fixturePath 'changed-before-second-read'
            Assert ($newVersion.sha256 -cne $version.sha256 -and
                (($Scenario -eq 'equal-length-change' -and $newVersion.bytes -eq $version.bytes) -or
                 ($Scenario -eq 'length-change' -and $newVersion.bytes -ne $version.bytes))) 'ACTUAL_FILE_CHANGED'
            $oracle=if ($Scenario -eq 'equal-length-change') {'B2_EQUAL_LENGTH_REFUSAL_REQUIRED'} else {'B2_CHANGED_LENGTH_REFUSAL_REQUIRED'}
            RequireRefusal {ReadArtifact $fixturePath 1024 'owned-repeated-changed-read'} 'T22_ARTIFACT_CHANGED_BETWEEN_READS' $oracle
            Assert ($bindings.Count -eq 1 -and $seen.Count -eq 1 -and $script:totalBytes -eq $baseline+32 -and
                $bindings[0].bytes -eq 32 -and $bindings[0].sha256 -ceq $version.sha256) 'B2_ORIGINAL_IDENTITY_RETAINED'
        }
    }
    $accepted=$true
    Write-Host "T22_READER_SCENARIO=$Scenario PASS helperFixture=true fullCli=false"
} finally {
    $receipt=@{schema='task22-real-reader-fixture-v1';scenario=$Scenario;passed=$accepted;observedError=$observedError;
        actualObservations=$observations.ToArray();readerSource=$sourceIdentity;firstBindingSnapshots=$bindings.ToArray();
        retainedCounter=$script:totalBytes;configuredRetainedLimit=$limits.retained;statOpenStageCallbacks=$stageCount;
        helperFixture=$true;fullAnalyzerCli=$false;realOwnedFilesAndFileStreams=$true;fakeHashes=$false;
        fixtureMaximumActualFileBytes=256;fileStreamsDisposedByReaderFinally=$true;ownedWindows=0;gpuCommands=0;
        compilerCommands=0;processCensusCommands=0;foreignActions=0}
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$root/fixture-result.json" -Encoding utf8
}
