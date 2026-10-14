#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$evidence=[IO.Path]::GetFullPath($EvidenceRoot)
$work=Join-Path $evidence 'task22-reader-recovery-r1'
$oldWork=Join-Path $evidence 'task-22-analysis-r1'
function Require([bool]$condition,[string]$name) {if (!$condition) {throw "T22_RECOVERY_$name"}}
function Json([string]$path) {return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)}
function Hash([byte[]]$bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [Convert]::ToHexString($algorithm.ComputeHash($bytes))} finally {$algorithm.Dispose()}
}
function TextHash([string]$text) {return Hash ([Text.Encoding]::UTF8.GetBytes($text))}
function Identity([string]$path,[string]$kind='audit') {
    $file=Get-Item -LiteralPath $path
    return @{path=$file.FullName;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash;kind=$kind}
}
function Match($record,[string]$path=$record.path) {
    $actual=Identity $path
    Require ($actual.bytes -eq $record.bytes -and $actual.sha256 -ieq $record.sha256) "BINDING_DRIFT:$path"
}
function WriteJson([string]$path,$value) {
    Require (![IO.File]::Exists($path)) "OUTPUT_ALREADY_EXISTS:$path"
    $value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
}
function Parse([string]$text) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Require ($errors.Count -eq 0) 'SOURCE_PARSE'
    return $ast
}
function Body([string]$text,[string]$name) {
    $nodes=@((Parse $text).FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    Require ($nodes.Count -eq 1) "BODY_COUNT:$name"
    return $nodes[0].Extent.Text
}
function OutsideReader([string]$text) {
    $body=Body $text 'ReadArtifact'
    Require (($text.Split(@($body),[StringSplitOptions]::None).Count-1) -eq 1) 'READER_EXTENT_UNIQUE'
    return $text.Replace($body,'<exact ReadArtifact extent excluded>')
}
function ReplaceOne([string]$text,[string]$anchor,[string]$replacement) {
    Require (($text.Split(@($anchor),[StringSplitOptions]::None).Count-1) -eq 1) 'TRANSFORM_ANCHOR'
    return $text.Replace($anchor,$replacement)
}
function Limits([string]$text) {
    $nodes=@((Parse $text).FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$limits'},$true))
    Require ($nodes.Count -eq 1) 'LIMIT_EXTENT'
    return $nodes[0].Extent.Text
}
function Archive([string]$path) {
    $record=Json $path
    $bytes=[Convert]::FromBase64String($record.base64)
    Require ($bytes.Length -eq $record.bytes -and (Hash $bytes) -ceq $record.sha256) 'LOSSLESS_ARCHIVE'
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function Inventory($seal) {
    $inputMemory=[IO.MemoryStream]::new([Convert]::FromBase64String($seal.inventoryGzipBase64))
    $gzip=[IO.Compression.GZipStream]::new($inputMemory,[IO.Compression.CompressionMode]::Decompress)
    $outputMemory=[IO.MemoryStream]::new()
    try {$gzip.CopyTo($outputMemory);$bytes=$outputMemory.ToArray()} finally {$gzip.Dispose();$inputMemory.Dispose();$outputMemory.Dispose()}
    Require ($bytes.Length -eq $seal.inventoryBytes -and (Hash $bytes) -ceq $seal.inventorySha256) 'INVENTORY_IDENTITY'
    return ,([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable)
}
$analyzer=Join-Path $PSScriptRoot 'Analyze.ps1'
$archivePath=Join-Path $work 'analyzer-preimage.json'
$archiveRecord=Json $archivePath
Require ($archiveRecord.bytes -eq 25755 -and $archiveRecord.sha256 -ceq 'EFDC5B6A29B65F5215FE3044EF69D4528B2CAD691F6E1752979F5C5364FB0717' -and $archiveRecord.path -ieq $analyzer) 'PREIMAGE_AUTHORITY'
$before=Archive $archivePath
$current=[IO.File]::ReadAllText($analyzer)
$oldReader=Body $before 'ReadArtifact'
$newReader=Body $current 'ReadArtifact'
Require ((OutsideReader $before) -ceq (OutsideReader $current)) 'ENTIRE_ANALYZER_OUTSIDE_READER_CHANGED'
Require ((Limits $before) -ceq (Limits $current)) 'LIMITS_CHANGED'
$expected=ReplaceOne $oldReader "    if (`$script:totalBytes + `$file.Length -gt `$limits.retained) { Fail 'TOTAL_READ_LIMIT' }" "    if (!`$seen.ContainsKey(`$path) -and `$script:totalBytes + `$file.Length -gt `$limits.retained) { Fail 'TOTAL_READ_LIMIT' }"
$expected=ReplaceOne $expected "        if (`$stream.Length -gt `$maximum) { Fail 'FILE_SIZE_LIMIT' }`n        `$data = [byte[]]::new([int]`$stream.Length)" "        `$openedLength = `$stream.Length`n        if (`$openedLength -gt `$maximum) { Fail 'FILE_SIZE_LIMIT' }`n        if (!`$seen.ContainsKey(`$path) -and `$openedLength -gt `$limits.retained - `$script:totalBytes) { Fail 'TOTAL_READ_LIMIT' }`n        `$data = [byte[]]::new([int]`$openedLength)"
$expected=ReplaceOne $expected "        if (`$stream.ReadByte() -ne -1) { Fail 'ARTIFACT_CHANGED_DURING_READ' }" "        if (`$stream.ReadByte() -ne -1) { Fail 'ARTIFACT_CHANGED_DURING_READ' }`n        if (`$stream.Length -ne `$data.Length) { Fail 'ARTIFACT_CHANGED_DURING_READ' }"
$expected=ReplaceOne $expected "    if (!`$seen.ContainsKey(`$path)) {`n        `$seen[`$path] = `$true" "    if (`$seen.ContainsKey(`$path)) {`n        if (`$data.Length -ne `$seen[`$path].bytes -or `$sha -cne `$seen[`$path].sha256) { Fail 'ARTIFACT_CHANGED_BETWEEN_READS' }`n    } else {`n        `$seen[`$path] = @{bytes=`$data.Length; sha256=`$sha}"
Require ($expected -ceq $newReader) 'SOLE_READER_TRANSFORM'
$prefixPath=Join-Path $work 'prefix-043f61b5/result.json'
$repairPath=Join-Path $work 'repair-2f387811/result.json'
$prefix=Json $prefixPath;$repair=Json $repairPath
Require ($prefix.passed -and !$prefix.behaviorAccepted -and $prefix.rows.Count -eq 2 -and $repair.passed -and $repair.behaviorAccepted -and $repair.rows.Count -eq 6) 'TARGETED_COVERAGE'
$fixture=Join-Path $PSScriptRoot 'ReaderFixture.ps1'
$proof=Join-Path $PSScriptRoot 'ReaderProof.ps1'
foreach ($receipt in @($prefix,$repair)) {
    foreach ($bound in $receipt.sources) {
        if ($bound.path -ieq $analyzer -and $receipt.phase -ceq 'PreFix') {Require ($bound.bytes -eq $archiveRecord.bytes -and $bound.sha256 -ceq $archiveRecord.sha256) 'PREFIX_ANALYZER_ARCHIVE'} else {Match $bound}
    }
    Require ($receipt.resourceClosure.allChildNativeExitsObserved -and $receipt.resourceClosure.allProcessObjectsDisposed -and
        @($receipt.children | Where-Object {$null -eq $_.exit -or $_.timeout -or !$_.ownedOnly -or !$_.processObjectDisposed}).Count -eq 0) 'OWNED_CHILD_CLOSURE'
    Require ($receipt.gpuCommands -eq 0 -and $receipt.compilerCommands -eq 0 -and $receipt.processCensusCommands -eq 0 -and $receipt.foreignActions -eq 0) 'FORBIDDEN_ACTION'
}
$totalGuard="        if (!`$seen.ContainsKey(`$path) -and `$openedLength -gt `$limits.retained - `$script:totalBytes) { Fail 'TOTAL_READ_LIMIT' }"
$repeatGuard="        if (`$data.Length -ne `$seen[`$path].bytes -or `$sha -cne `$seen[`$path].sha256) { Fail 'ARTIFACT_CHANGED_BETWEEN_READS' }"
$generatedProof=@()
foreach ($pair in @(@{receipt=$prefix;text=$before;reader=$oldReader},@{receipt=$repair;text=$current;reader=$newReader})) {
    $initialization=(Limits $pair.text)+"`n"+'$bindings = [Collections.Generic.List[object]]::new()'+"`n"+'$seen = @{}'+"`n"+'$totalBytes = 0L'+"`n"
    $helpers=@((Body $pair.text 'Fail'),(Body $pair.text 'Hash'),(Body $pair.text 'CheckPath')) -join "`n"
    foreach ($generated in $pair.receipt.generatedBodies) {
        Require ((Get-FileHash -LiteralPath $generated.path).Hash -ceq $generated.sha256) 'GENERATED_FILE_SHA'
        $expectedBody=$pair.reader
        switch ([IO.Path]::GetFileName($generated.path)) {
            'mutant-opened-total-stage.ps1' {$expectedBody=ReplaceOne $expectedBody $totalGuard ''}
            'mutant-repeat-identity.ps1' {$expectedBody=ReplaceOne $expectedBody $repeatGuard ''}
        }
        Require ((TextHash $expectedBody) -ceq $generated.extractedReaderBodySha256) 'EXTRACTED_BODY_IDENTITY'
        if ($generated.singleStatOpenCallback) {
            $open='    $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)'
            $expectedBody=ReplaceOne $expectedBody $open ('    Invoke-ReaderStatOpenTransition $path $file.Length'+"`n"+$open)
        }
        Require ([IO.File]::ReadAllText($generated.path) -ceq ($initialization+$helpers+"`n"+$expectedBody+"`n")) 'ENTIRE_GENERATED_HELPER_DELTA'
        Require ((TextHash $expectedBody) -ceq $generated.emittedReaderBodySha256 -and (TextHash $helpers) -ceq $generated.helpersSha256 -and (TextHash (Limits $pair.text)) -ceq $generated.actualProductionLimitsSha256) 'DERIVED_BODY_METADATA'
        $generatedProof+=@{artifact=(Identity $generated.path 'exact-derived-reader');fullSourceExact=$true;
            expectedReaderBodySha256=(TextHash $expectedBody);productionLimitsByteExact=$true;
            soleStageCallback=$generated.singleStatOpenCallback;onlyRemovedGuard=if ($generated.path -like '*mutant-opened*') {'opened actual total admission'} elseif ($generated.path -like '*mutant-repeat*') {'repeat length/SHA identity'} else {$null}}
    }
}
$observables=@()
foreach ($row in @($prefix.rows)+@($repair.rows)) {
    $result=Json $row.fixtureReceipt
    $log=[IO.File]::ReadAllText($row.log)
    Require ($row.passed -and $row.exit -eq $row.expectedExit -and $row.helperFixture -and !$row.fullAnalyzerCli -and $result.helperFixture -and !$result.fullAnalyzerCli -and $result.realOwnedFilesAndFileStreams -and !$result.fakeHashes -and $result.configuredRetainedLimit -eq 268435456) 'SCENARIO_SCOPE'
    Match $result.readerSource
    foreach ($version in $result.actualObservations | Where-Object {$_.ContainsKey('versionSnapshot')}) {Match $version $version.versionSnapshot}
    if ($row.exit -eq 1) {
        Require (!$result.passed -and $log.Contains($row.expectedOracle)) 'CAUSAL_NATIVE_FAILURE'
        $accepted=@($result.actualObservations | Where-Object {$_.ContainsKey('unexpectedAcceptedBytes')})
        Require ($accepted.Count -eq 1) 'ACTUAL_UNEXPECTED_READ'
        $lastVersion=@($result.actualObservations | Where-Object {$_.ContainsKey('versionSnapshot')})[-1]
        $returned=[byte[]]$accepted[0].actualReturnedBytes
        Require ($returned.Length -eq $lastVersion.bytes -and (Hash $returned) -ceq $lastVersion.sha256 -and $accepted[0].unexpectedAcceptedSha256 -ceq $lastVersion.sha256) 'ACTUAL_RETURNED_BYTES_NOT_FAKE_HASH'
        if ($row.scenario -ceq 'stat-open-growth') {Require ($result.retainedCounter -eq 268435584 -and $result.firstBindingSnapshots.Count -eq 1) 'B1_ACTUAL_OVERSHOOT'}
        else {Require ($result.retainedCounter -eq 32 -and $result.firstBindingSnapshots.Count -eq 1 -and $result.firstBindingSnapshots[0].sha256 -cne $lastVersion.sha256) 'B2_ACTUAL_UNBOUND_NEW_BYTES'}
    } else {
        Require ($result.passed -and $log.Contains("T22_READER_SCENARIO=$($row.scenario) PASS")) 'POSITIVE_NATIVE_OBSERVABLE'
        switch ($row.scenario) {
            'stable-first-repeat' {
                $actual=$result.actualObservations[-1]
                Require ($result.retainedCounter -eq 268435456 -and $result.firstBindingSnapshots.Count -eq 1 -and $actual.firstActualBytes -eq 32 -and $actual.repeatedActualBytes -eq 32 -and $actual.firstActualSha256 -ceq $actual.repeatedActualSha256 -and $actual.firstActualSha256 -ceq $result.actualObservations[0].sha256) 'UNCHANGED_REPEAT_AT_EXACT_BUDGET'
            }
            'stat-open-growth' {Require ($result.observedError -ceq 'T22_TOTAL_READ_LIMIT' -and $result.retainedCounter -eq 268435328 -and $result.firstBindingSnapshots.Count -eq 0) 'OPENED_GROWTH_REFUSAL'}
            default {
                $versions=@($result.actualObservations | Where-Object {$_.ContainsKey('versionSnapshot')})
                Require ($result.observedError -ceq 'T22_ARTIFACT_CHANGED_BETWEEN_READS' -and $result.retainedCounter -eq 32 -and $result.firstBindingSnapshots.Count -eq 1 -and $result.firstBindingSnapshots[0].sha256 -ceq $versions[0].sha256 -and $versions[0].sha256 -cne $versions[1].sha256) 'CHANGED_REPEAT_REFUSAL'
                Require (($row.scenario -ceq 'equal-length-change' -and $versions[0].bytes -eq $versions[1].bytes) -or ($row.scenario -ceq 'length-change' -and $versions[0].bytes -ne $versions[1].bytes)) 'REAL_LENGTH_TRANSITION'
            }
        }
    }
    if ($row.scenario -ceq 'stat-open-growth') {
        $transition=@($result.actualObservations | Where-Object {$_.ContainsKey('transition')})
        Require ($result.statOpenStageCallbacks -eq 1 -and $transition.Count -eq 1 -and $transition[0].cachedStatLength -eq 0 -and $transition[0].actualFileLength -eq 256 -and $transition[0].remainingBytes -eq 128 -and $transition[0].configuredRetainedLimit -eq 268435456 -and $transition[0].perFileMaximum -eq 1024) 'DETERMINISTIC_STAT_OPEN_TRANSITION'
    }
    $observables+=@{case=$row.case;scenario=$row.scenario;nativeExit=$row.exit;command=$row.command;expectedOracle=$row.expectedOracle;
        receipt=(Identity $row.fixtureReceipt 'actual-reader-scenario');log=(Identity $row.log 'native-output');actualError=$result.observedError;
        actualRetainedCounter=$result.retainedCounter;actualObservations=$result.actualObservations;originalBindings=$result.firstBindingSnapshots;
        helperFixture=$true;fullAnalyzerCli=$false;oracleVerified=$true}
}
$oldPacketPath=Join-Path $evidence 'task-22-classification.json'
$oldDonePath=Join-Path $evidence 'task-22-DoneClaim.md'
$oldFreezePath=Join-Path $oldWork 'producer-freeze.json'
$pinned=@(@{path=$oldPacketPath;bytes=67832;sha256='579DFB503EC01BE7CCBB0B09B28BDD0C4C0A7172E7AFB8B764CB0D6E6B60B7EA'},
    @{path=$oldDonePath;bytes=3008;sha256='8E9DFCE1B27AE11699B3349CF43021BB0143F69A8FBF7FDAE6D3C09A5FC34765'},
    @{path=$oldFreezePath;bytes=43005;sha256='72171615ABEE29B434EABFD4D30545ACAEF907739508C70E2F2934AF18462E65'})
foreach ($bound in $pinned) {Match $bound}
$oldPacket=Json $oldPacketPath
$oldSeal=Json $oldFreezePath
$oldInventory=Inventory $oldSeal
Require ($oldInventory -is [array] -and $oldInventory.Count -eq 1860 -and $oldSeal.entryCount -eq 1860) 'R0_INVENTORY_SHAPE'
$unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$delta=0;$unchanged=0
foreach ($bound in $oldInventory) {
    Require ($bound -is [Collections.IDictionary] -and $bound.path -is [string] -and $bound.path -match '^[A-Za-z]:[\\/]' -and $unique.Add($bound.path) -and $bound.bytes -isnot [string] -and $bound.bytes -isnot [bool] -and [string]$bound.bytes -match '^[0-9]+$' -and $bound.sha256 -cmatch '^[A-Fa-f0-9]{64}$') 'R0_INVENTORY_ROW'
    if ($bound.path -ieq $analyzer) {Require ($bound.bytes -eq $archiveRecord.bytes -and $bound.sha256 -ceq $archiveRecord.sha256) 'R0_ANALYZER_PREIMAGE_BINDING';$delta++} else {Match $bound;$unchanged++}
}
Require ($delta -eq 1 -and $unchanged -eq 1859) 'ONLY_AUTHORIZED_R0_DELTA'
$reusedInputs=@();$stableConditions=@()
Require ($oldPacket.qa.Count -eq 42) 'R0_COVERAGE_COUNT'
foreach ($row in $oldPacket.qa) {
    Require ($row.passed -and (Get-Item -LiteralPath $row.log).Length -gt 0) 'R0_RECEIPT'
    if ($row.ContainsKey('output') -and $row.output) {
        $report=Json $row.output
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total=0L
        foreach ($bound in $report.inputBindings) {
            Match $bound
            Require ($paths.Add($bound.path)) 'R0_DUPLICATE_BINDING'
            $maximum=switch ($bound.kind) {'structured-json' {65536} 'raw-roi' {1048576} 'historical-native-fact-log' {65536} default {throw 'T22_RECOVERY_UNKNOWN_INPUT_KIND'}}
            Require ($bound.bytes -le $maximum) 'R0_RETAINED_INPUT_PER_FILE'
            $total+=[long]$bound.bytes
            $reusedInputs+=@{scenario=$row.scenario;bound=$bound;maximum=$maximum;actualSizeHashStillExact=$true}
        }
        Require ($total -le 268435456 -and $paths.Count -le 580) 'R0_STABLE_READER_PRECONDITIONS'
        $stableConditions+=@{scenario=$row.scenario;inputBindingCount=$paths.Count;uniqueRetainedBytes=$total;retainedLimit=268435456;
            actualCurrentBytesMatchEveryHistoricalBinding=$true;unchangedSizeHashRepeatedReadAccepted=$true;
            newActualOpenedTotalGuardInactive=$true;newRepeatIdentityGuardInactiveForTheseImmutableBoundInputs=$true;
            report=(Identity $row.output 'historical-classification-report');nativeExit=$row.exit;newNativeReplay=$false}
    }
}
Require ($reusedInputs.Count -eq 174) 'R0_INPUT_BINDING_COUNT'
$reusePath=Join-Path $oldWork 'composed-proof-reuse.json'
$oldReuse=Json $reusePath
$runner=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Analysis.ps1'))
$fixtureBodies=@()
foreach ($entry in $oldReuse.exactPreservedFunctionBodies) {
    Require ((TextHash (Body $runner $entry.function)) -ceq $entry.sha256 -and $entry.byteExact) 'R0_FIXTURE_ORACLE_BODY_IDENTITY'
    $fixtureBodies+=$entry
}
Require ($fixtureBodies.Count -eq 9) 'R0_FIXTURE_ORACLE_COUNT'
$mutations=@(
    @{name='wrong-defect-class';anchor="$"+"report.outcome='OptiScalerDefect'";replacement="$"+"report.outcome='NotReproduced'"},
    @{name='ignored-artifact-mismatch';anchor='if (!$complete -or $mismatches.Count -gt 0)';replacement='if (!$complete)'},
    @{name='relaxed-frame-bound';anchor='frames=64;';replacement='frames=65;'},
    @{name='ignored-pixel-origin';anchor="if (`$image.pixelOrigin -cne 'owned_nr_surface' -or !`$image.rawResource)";replacement='if (!$image.rawResource)'},
    @{name='counter-as-defect';anchor="`$values.applied -eq '1' -and";replacement="`$values.applied -in @('0','1') -and"},
    @{name='neutral-as-defect';anchor=' $values.scratch -cne $values.original -and $values.application -cne $contract.expectedApplicationPixel';replacement=' $true'}
)
$causalBranches=@()
foreach ($mutation in $mutations) {
    $row=@($oldPacket.qa | Where-Object scenario -CEQ ('mutation-'+$mutation.name))
    Require ($row.Count -eq 1 -and $row[0].exit -eq 1) 'R0_MUTANT_ROW'
    $oldMutant=[IO.File]::ReadAllText($row[0].mutationSource)
    Require ($oldMutant -ceq (ReplaceOne $before $mutation.anchor $mutation.replacement)) 'R0_EXACT_MUTANT_SOURCE'
    $projected=ReplaceOne $current $mutation.anchor $mutation.replacement
    Require ((OutsideReader $oldMutant) -ceq (OutsideReader $projected) -and (Body $oldMutant 'ReadArtifact') -ceq $oldReader) 'R0_MUTANT_CAUSAL_BRANCH_PRESERVATION'
    $causalBranches+=@{scenario=$row[0].scenario;historicalMutant=(Identity $row[0].mutationSource 'historical-causative-mutant');
        exactOriginalMutation=$true;anchor=$mutation.anchor;replacement=$mutation.replacement;
        entireSourceOutsideReaderStillExact=$true;projectedCurrentMutantSha256=(TextHash $projected);
        historicalNativeExit=1;historicalLog=(Identity $row[0].log 'original-causative-oracle');newNativeReplay=$false}
}
$gateRoot='C:/Users/USER/orca/projects/기타 작업/.omo/ulw-execute/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task-22/codex-independent-r1'
$gate=@(@{path="$gateRoot/AdversarialVerify.json";bytes=9790;sha256='EE54ABA1AA789668EDE73373456FB6083B92DD8A0CC3FF3826D46957E65F8761'},
    @{path="$gateRoot/review.md";bytes=14248;sha256='0B4CC78F7FA2B90FDF05411997D603D0C516E1EDE065B828064C5869BA38760C'})
foreach ($bound in $gate) {Match $bound}
$oldReceipts=@(Get-ChildItem -LiteralPath $oldWork -File -Filter result.json -Recurse | ForEach-Object {Json $_.FullName})
foreach ($receipt in $oldReceipts) {
    Require ($receipt.ownedResourceClosure.allChildProcessesTerminal -and $receipt.ownedResourceClosure.nativeProcessObjectsDisposed -and
        @($receipt.children | Where-Object {$null -eq $_.exit -or $_.timeout -or !$_.processObjectDisposed}).Count -eq 0) 'R0_NATIVE_CLOSURE'
}
$closure=@{schema=1;newOwnedNativeChildren=@($prefix.children)+@($repair.children);newChildCount=8;
    allNewChildNativeExitsObserved=$true;allProcessObjectsDisposed=$true;retainedR0ReceiptCount=$oldReceipts.Count;
    retainedR0ChildCount=@($oldReceipts | ForEach-Object {$_.children}).Count;
    producerNativeOperationsInFlight=0;ownedWatchers=0;createdWindows=0;temporaryMappings=0;gpuResources=0;
    gpuCommands=0;compilerCommands=0;processCensusCommands=0;foreignProcessActions=0;
    closureMethod='Directly owned Process handles: native exits observed, streams read, handles disposed; no global census.'}
WriteJson "$work/owned-resource-closure.json" $closure
$reuse=@{schema='task22-reader-recovery-reuse-v1';oldFreeze=(Identity $oldFreezePath 'immutable-R0-seal');
    R0InventoryCount=1860;unchangedCurrentPaths=1859;soleAuthorizedLiveDelta=@{historicalAnalyzer=$archiveRecord;losslessArchive=(Identity $archivePath 'lossless-R0-analyzer');currentAnalyzer=(Identity $analyzer 'current-reader-repair')};
    entireAnalyzerOutsideReadArtifactByteExact=$true;outsideReaderSha256=(TextHash (OutsideReader $current));
    oldReaderBodySha256=(TextHash $oldReader);currentReaderBodySha256=(TextHash $newReader);soleTransformVerified=$true;
    originalLimitsByteExact=$true;limitsSha256=(TextHash (Limits $current));retainedLimit=268435456;
    original42Receipts=$oldPacket.qa;originalReceiptComposition=$oldPacket.proofComposition;
    reusedInputBindings=$reusedInputs;reusedBindingCount=174;stableReaderPreconditions=$stableConditions;
    unchangedFixtureOracleBodies=$fixtureBodies;originalSixCausalBranches=$causalBranches;
    originalFailureAndIneffectiveControlPreserved=$true;R0DoneClaimAndPacketAndSealUntouched=$true;
    noOldNativeClassificationOrGpuReplay=$true;qualification='Historical 36+5+1 CLI evidence is retained with exact files, inputs, oracle bodies and unchanged policy branches. New 2 red + 4 positive + 2 guard controls exercise only the actual shared reader seam. No claim of a new full Analysis invocation.'}
WriteJson "$work/composed-proof-reuse.json" $reuse
$sources=@(Identity $analyzer 'current-offline-analyzer';Identity $fixture 'new-real-reader-fixture';Identity $proof 'new-targeted-proof-runner';Identity $PSCommandPath 'successor-finalization-audit';Identity "$PSScriptRoot/RunReaderFinalization.ps1" 'owned-native-finalization-wrapper')
foreach ($source in $oldPacket.currentSources | Where-Object {$_.path -ine $analyzer}) {$sources+=Identity $source.path $source.kind}
$packet=@{schema='task22-reader-recovery-proof-v1';task=22;producerComplete=$true;independentAcceptance=$false;
    repairedBlockingFindings=@('B1 actual opened size admitted against remaining retained budget before allocation/read','B2 same path changed length or actual SHA rejected against first actual byte identity');
    priorWholeGate=$gate;oldPacket=(Identity $oldPacketPath 'immutable-R0-packet');oldDoneClaim=(Identity $oldDonePath 'immutable-R0-DoneClaim');
    exactOutcomeClasses=$oldPacket.exactOutcomeClasses;original42Qa=$oldPacket.qa;newReaderQa=$observables;
    originalActualTask21=$oldPacket.actualCurrentTask21;originalActualTask21Artifact=(Identity $oldPacket.actualCurrentTask21Artifact 'retained-current-Task21-InsufficientData-report');
    currentSources=$sources;losslessAnalyzerPreimage=$archivePath;reuseProof="$work/composed-proof-reuse.json";
    resourceClosure="$work/owned-resource-closure.json";prefixProof=(Identity $prefixPath 'actual-pre-fix-red-proof');repairProof=(Identity $repairPath 'new-targeted-reader-proof');
    proofComposition='REUSED immutable historical 36+5+1 CLI receipts + NEW exact-reader 2 pre-fix native1 failures + 4 native0 positive/refusal cases + 2 native1 causal guard controls; no new full Analysis run.';
    unchangedClassificationAndCandidatePolicy=$true;unchangedLimits=$true;noGameReproduction=$true;noFoliageCure=$true;noProprietaryCauseInference=$true;
    noProductOrCaptureSchemaChanges=$true;noDispatcherOrAnalysisRunnerOrDocumentationChanges=$true;noWCTransfer=$true;
    cpuOnly=$true;originalTasksAccepted=17;task22Accepted=$false;gate='One fresh whole Task22 independent R2 gate after this producer is terminal.'}
WriteJson "$work/task-22-classification.json" $packet
$done=@'
# Task22 reader recovery producer DoneClaim

The sole product-facing delta is ReadArtifact in tests/nr_mfg_diagnostics/Analyze.ps1. B1 now admits the actual opened stream length against the unchanged 256MiB retained budget before allocation/read. Existing per-file, FileShare.Read, truncation/ReadByte guards remain and final opened size is checked. B2 retains the first actual byte length/SHA identity and rejects a changed repeated path with T22_ARTIFACT_CHANGED_BETWEEN_READS. An unchanged repeated read retains one binding and one budget charge, including at the exact retained limit. No classifier, phase, timing, candidate, schema, dispatcher, Analysis runner or documentation policy changed.

NEW CPU helper evidence: ReaderProof -Phase PreFix produced two native1 named oracle failures using the original exact reader; ReaderProof -Phase Repair produced four native0 scenarios and two native1 causal guard-removal controls. Real owned files/streams supply the observed bytes and independent snapshot hashes. The largest actual file is 256 bytes; a typed counter uses the actual unchanged 268435456-byte production threshold. A deterministic derived helper adds only one verified stat/open stage callback; it changes a closed owned file before the real File.Open. Production has no test conditional and no mocked reads or fake success. All eight exact invocations, native exits, logs, receipts, data snapshots and full derived body/limits identities are bound in task-22-classification.json and composed-proof-reuse.json. The original same oracles catch omission of each new guard. These are targeted shared-reader fixtures, not a new full analyzer CLI or classification invocation.

Historical original evidence is honestly REUSED: 36 original classification/rejection/current-Task21 cases + five original decisive controls + the corrected causative neutral control. All 174 reported input bindings still match their actual bytes and bounded sizes, all nine original fixture/oracle function bodies match, and all six original mutant sources and causal branches outside ReadArtifact are exact. Old failure/ineffective-control/finalization receipts are preserved. The R0 seal still binds 1860 historical paths: 1859 current paths are exact and its one old live analyzer record resolves to the new lossless preimage archive; the current analyzer is separately bound. R0 packet/DoneClaim/seal and all old files remain untouched. No old 42-classification, Capture/Contracts/DLL/GPU/Task11/Task12/PQ test was replayed.

Actual Task21 input remains the retained InsufficientData result with unchanged bound inputs: real raw images alone do not supply unavailable observer/exposure/phase/timing metadata. Complete non-InsufficientData examples remain explicitly SYNTHETIC. Historical Task5 final-copy facts do not prove a current product/game defect. Counters/raw indexes/provider activity do not become phase, timing, optical-flow causation or generated-pixel proof. No foliage fix, Crimson reproduction, proprietary cause, product source repair or Task13/14/23 completion is claimed.

All eight new directly owned child native exits were observed and Process handles disposed. All original direct-child closure evidence remains exact. No GPU/compiler/census/game/foreign-process action, windows, watchers, mappings or runtime install was used. Current source/support and all successor evidence are frozen only after final packet/DoneClaim/closure wording. Finalizer stdout/transcript is not a mutable file inside the inventory.

Producer implementation is terminal; Task22 acceptance remains pending a fresh WHOLE independent R2 gate. Accepted original tasks remain 17/29. No WC transfer is performed by this worker.
'@
Require (![IO.File]::Exists("$work/DoneClaim.md")) 'DONECLAIM_ALREADY_EXISTS'
[IO.File]::WriteAllText("$work/DoneClaim.md",$done,[Text.UTF8Encoding]::new($false))
$freezeRows=[Collections.Generic.List[object]]::new()
$freezePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Freeze([string]$path,[string]$kind) {if ($freezePaths.Add([IO.Path]::GetFullPath($path))) {$freezeRows.Add((Identity $path $kind))}}
foreach ($bound in $oldInventory) {if ($bound.path -ine $analyzer) {Freeze $bound.path ('retained-R0/'+$bound.kind)}}
foreach ($bound in $pinned+$gate) {Freeze $bound.path 'immutable-authority-or-prior-gate'}
foreach ($source in $sources) {Freeze $source.path $source.kind}
foreach ($file in Get-ChildItem -LiteralPath $work -File -Recurse) {Freeze $file.FullName 'successor-all-retained-evidence-including-red-failures'}
foreach ($assembly in @([Text.Json.JsonDocument].Assembly,[Management.Automation.PSObject].Assembly,[Diagnostics.Process].Assembly,[Security.Cryptography.SHA256].Assembly)) {if ($assembly.Location) {Freeze $assembly.Location 'actual-loaded-pwsh-dotnet-support'}}
foreach ($bound in $freezeRows) {Match $bound}
$bytes=[Text.Encoding]::UTF8.GetBytes(($freezeRows.ToArray() | ConvertTo-Json -Depth 8 -Compress))
$outputMemory=[IO.MemoryStream]::new()
$gzip=[IO.Compression.GZipStream]::new($outputMemory,[IO.Compression.CompressionLevel]::Optimal,$true)
try {$gzip.Write($bytes,0,$bytes.Length)} finally {$gzip.Dispose()}
try {$compressed=$outputMemory.ToArray()} finally {$outputMemory.Dispose()}
WriteJson "$work/producer-freeze.json" @{schema=1;task=22;producerTerminal=$true;sourceWritesClosed=$true;nativeOperationsInFlight=0;independentAcceptance=$false;
    entryCount=$freezeRows.Count;inventoryEncoding='gzip-base64 UTF8 JSON array';inventoryBytes=$bytes.Length;inventorySha256=(Hash $bytes);inventoryGzipBase64=[Convert]::ToBase64String($compressed);
    currentSources=$sources;composition=$packet.proofComposition;originalR0InventoryQualification=@{originalCount=1860;unchanged=1859;soleAuthorizedAnalyzerDelta=1;preimage=$archivePath};
    ownedResourceClosure="$work/owned-resource-closure.json";excludedFromSelfInventory=@('producer-freeze.json','active native-finalization-*/native.log and receipt.json created only after finalizer exit; separately additive terminal proof');noOpenMutableTranscriptInInventory=$true}
Write-Host "T22_READER_RECOVERY_FINALIZED entries=$($freezeRows.Count) oldUnchanged=1859 analyzerDelta=1 reusedBindings=174 newChildren=8"
