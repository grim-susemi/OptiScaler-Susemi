#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$evidence=[IO.Path]::GetFullPath($EvidenceRoot)
$work=Join-Path $evidence 'task-22-analysis-r1'
$initial=Join-Path $work 'task-22-analysis-6eb38d7b/result.json'
$last=Join-Path $work 'task-22-analysis-01174e22/result.json'
function ReadJson([string]$path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) }
function Hash([byte[]]$bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [Convert]::ToHexString($algorithm.ComputeHash($bytes))} finally {$algorithm.Dispose()}
}
function Identity([string]$path,[string]$kind) {
    $file=Get-Item -LiteralPath $path
    return @{path=$file.FullName;kind=$kind;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
}
function Match($record,[string]$path=$record.path) {
    $actual=Identity $path 'audit'
    if ($actual.bytes -ne $record.bytes -or $actual.sha256 -ine $record.sha256) {throw "T22_BINDING_DRIFT: $path"}
}
function WriteJson([string]$path,$value) {
    if ([IO.File]::Exists($path)) {throw "T22_FINALIZATION_PATH_ALREADY_EXISTS: $path"}
    $value | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $path -Encoding utf8
}
function ReplaceOne([string]$text,[string]$anchor,[string]$replacement) {
    if (($text.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) {throw 'T22_REUSE_TRANSFORM_ANCHOR_DRIFT'}
    return $text.Replace($anchor,$replacement)
}
function ArchiveText([string]$path) {
    $record=ReadJson $path
    $bytes=[Convert]::FromBase64String($record.base64)
    if ($bytes.Length -ne $record.bytes -or (Hash $bytes) -ine $record.sha256) {throw 'T22_LOSSLESS_PREIMAGE_INVALID'}
    return [Text.Encoding]::UTF8.GetString($bytes)
}
function FunctionBodies([string]$text) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {throw 'T22_PARSER_ERROR'}
    $bodies=@{}
    foreach ($node in $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        if ($bodies.ContainsKey($node.Name)) {throw 'T22_DUPLICATE_FUNCTION'}
        $bodies[$node.Name]=$node.Extent.Text
    }
    return $bodies
}
function Canonical($value) {
    if ($null -eq $value) {return 'null'}
    if ($value -is [Collections.IDictionary]) {
        return '{'+(@($value.Keys | Sort-Object | ForEach-Object {($_ | ConvertTo-Json -Compress)+':'+(Canonical $value[$_])}) -join ',')+'}'
    }
    if ($value -is [array]) {return '['+(@($value | ForEach-Object {Canonical $_}) -join ',')+']'}
    return ($value | ConvertTo-Json -Compress)
}
$beforeRunner=ArchiveText "$work/fixture-runner-before-neutral-control.json"
$runner=[IO.File]::ReadAllText("$PSScriptRoot/Analysis.ps1")
$expected=ReplaceOne $beforeRunner "      [string]`$OnlyCase,`n" "      [string]`$OnlyCase,`n      [string]`$OnlyMutation,`n"
$expected=ReplaceOne $expected "`$passed=`$false`n" "`$passed=`$false`nif (`$OnlyMutation) { `$OnlyCase='__changed_mutation_only__' }`n"
$expected=ReplaceOne $expected 'if (!$SkipMutations -and !$OnlyCase)' 'if (!$SkipMutations -and (!$OnlyCase -or $OnlyMutation))'
$expected=ReplaceOne $expected "anchor=' `$values.scratch -cne `$values.original -and';replacement=' `$true -and'" "anchor=' `$values.scratch -cne `$values.original -and `$values.application -cne `$contract.expectedApplicationPixel';replacement=' `$true'"
$expected=ReplaceOne $expected "        foreach (`$mutation in `$mutations) {`n" "        foreach (`$mutation in `$mutations) {`n            if (`$OnlyMutation -and `$OnlyMutation -cne `$mutation.name) { continue }`n"
if ($expected -cne $runner) {throw 'T22_RUNNER_DELTA_NOT_EXACT'}
$oldBodies=FunctionBodies $beforeRunner
$newBodies=FunctionBodies $runner
$bodyProof=@()
foreach ($name in $oldBodies.Keys) {
    if ($oldBodies[$name] -cne $newBodies[$name]) {throw "T22_REUSED_ORACLE_OR_FIXTURE_BODY_CHANGED: $name"}
    $bodyProof+=@{function=$name;sha256=(Hash ([Text.Encoding]::UTF8.GetBytes($newBodies[$name])));byteExact=$true}
}
$oldDispatcher=ArchiveText "$work/dispatcher-preimage.json"
$dispatcher=[IO.File]::ReadAllText("$repo/tests/run_nr_mfg_diagnostics.ps1")
$oldCapture=$oldDispatcher.Substring($oldDispatcher.IndexOf("if (`$Tier -eq 'Capture')"))
$newCapture=$dispatcher.Substring($dispatcher.IndexOf("if (`$Tier -eq 'Capture')"))
if ($oldCapture -cne $newCapture) {throw 'T22_CONTRACTS_CAPTURE_TAIL_CHANGED'}
$dispatchBefore=ReadJson "$work/dispatcher-preimage.json"
if ($dispatchBefore.bytes -ne 28856 -or $dispatchBefore.sha256 -cne '9223FF53B6F521FA7A5658B1B0E360D8032151B9EFF0665285B4F450539D2EFD') {throw 'T22_DISPATCHER_AUTHORITY_DRIFT'}
$dispatchAst=FunctionBodies $dispatcher
$a=ReadJson $initial;$b=ReadJson $last
$positive=@($a.rows | Where-Object {$_.scenario -notlike 'mutation-*'})
$negative=@($a.rows | Where-Object {$_.scenario -like 'mutation-*' -and $_.passed})+@($b.rows)
if ($a.passed -or $positive.Count -ne 36 -or $negative.Count -ne 6 -or !$b.passed -or
    @($positive+$negative | Where-Object {!$_.passed}).Count) {throw 'T22_COMPOSED_COVERAGE_INCOMPLETE'}
$sourcePreimage=ReadJson "$work/fixture-runner-before-neutral-control.json"
foreach ($bound in $a.inputSources) {
    if ($bound.kind -eq 'current-analysis-fixture-runner') {
        if ($bound.bytes -ne $sourcePreimage.bytes -or $bound.sha256 -ine $sourcePreimage.sha256) {throw 'T22_OLD_RUNNER_NOT_ARCHIVED'}
    } else {Match $bound}
}
foreach ($bound in $b.inputSources) {Match $bound}
foreach ($row in $positive+$negative) {
    if (![IO.File]::Exists($row.log) -or (Get-Item -LiteralPath $row.log).Length -eq 0) {throw 'T22_EMPTY_QA_ARTIFACT'}
    if ($row.ContainsKey('output') -and $row.output) {
        $report=ReadJson $row.output
        foreach ($bound in $report.inputBindings) {Match $bound}
    }
}
$oldNeutral=Join-Path (Split-Path $initial -Parent) 'input-known-host-neutral'
$childResult=@(Get-ChildItem -LiteralPath (Split-Path $last -Parent) -Filter result.json -Recurse | Where-Object {$_.FullName -ne $last})
if ($childResult.Count -ne 1) {throw 'T22_NEUTRAL_CHILD_RECEIPT_COUNT'}
$child=ReadJson $childResult[0].FullName
if ($child.passed -or $child.rows.Count -ne 1 -or $child.rows[0].scenario -cne 'known-host-neutral' -or $child.rows[0].exit -ne 0) {throw 'T22_CAUSATIVE_NEUTRAL_CONTROL_NOT_NATIVE_CLASSIFICATION'}
$newNeutral=Join-Path $child.output 'input-known-host-neutral'
$neutralData=@()
$derivedCaptureBindings=@()
foreach ($relative in @('capture-session.json','mfg-preflight.json','analysis-synthetic.json','frame-0/capture.json','frame-1/capture.json',
    'frame-0/nr_input.raw','frame-0/nr_output.raw','frame-1/nr_input.raw','frame-1/nr_output.raw','host-facts.log')) {
    $left=Join-Path $oldNeutral $relative;$right=Join-Path $newNeutral $relative
    if ($relative.EndsWith('.json')) {
        $leftValue=ReadJson $left;$rightValue=ReadJson $right
        if ($relative -eq 'analysis-synthetic.json') {
            foreach ($pair in @(@{value=$leftValue;root=$oldNeutral},@{value=$rightValue;root=$newNeutral})) {
                foreach ($frame in $pair.value.frames) {
                    $capture=Join-Path $pair.root ('frame-'+([int]$frame.application-1)+'/capture.json')
                    if ($frame.captureSha256 -cne (Get-FileHash -LiteralPath $capture).Hash) {throw 'T22_NEUTRAL_CAPTURE_HASH_NOT_BOUND'}
                    $derivedCaptureBindings+=@{application=$frame.application;declaredSha256=$frame.captureSha256;
                        capture=(Identity $capture 'respective-exact-capture-bytes');byteBindingExact=$true}
                    $frame.Remove('captureSha256') | Out-Null
                }
            }
        }
        if ((Canonical $leftValue) -cne (Canonical $rightValue)) {throw "T22_NEUTRAL_JSON_DATA_CHANGED: $relative"}
        $equality='identical typed values and structure; JSON property order is nonsemantic'
        if ($relative -eq 'analysis-synthetic.json') {$equality='all non-derived typed fields and array order identical; distinct derived capture hashes separately preserved and verified against respective exact capture bytes'}
    } else {
        if ((Get-FileHash -LiteralPath $left).Hash -cne (Get-FileHash -LiteralPath $right).Hash) {throw "T22_NEUTRAL_BINARY_CHANGED: $relative"}
        $equality='byte-exact'
    }
    $neutralData+=@{relative=$relative;before=(Identity $left 'original-neutral-fixture');after=(Identity $right 'new-neutral-fixture');equality=$equality}
}
$task21FreezePath=Join-Path $evidence 'task21-runner-recovery-r1/producer-freeze.json'
$task21Freeze=ReadJson $task21FreezePath
if ((Get-FileHash -LiteralPath $task21FreezePath).Hash -cne '6A52D761A8188291B1DCCA13D95A8A8D5DE3586658BBC02CCD831F477B30B61C') {throw 'T22_TASK21_FREEZE_CHANGED'}
$compressed=[Convert]::FromBase64String($task21Freeze.inventoryGzipBase64)
$memory=[IO.MemoryStream]::new($compressed)
$gzip=[IO.Compression.GZipStream]::new($memory,[IO.Compression.CompressionMode]::Decompress)
$decoded=[IO.MemoryStream]::new()
try {$gzip.CopyTo($decoded);$inventoryBytes=$decoded.ToArray()} finally {$gzip.Dispose();$memory.Dispose();$decoded.Dispose()}
if ($inventoryBytes.Length -ne $task21Freeze.inventoryBytes -or (Hash $inventoryBytes) -ine $task21Freeze.inventorySha256) {throw 'T22_TASK21_INVENTORY_INTEGRITY'}
$inventory=[Text.Encoding]::UTF8.GetString($inventoryBytes) | ConvertFrom-Json -AsHashtable
if ($inventory.schema -ne 1 -or $inventory.entries -isnot [array] -or $inventory.entries.Count -ne 203) {throw 'T22_TASK21_INVENTORY_COUNT'}
$uniqueTask21=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($bound in $inventory.entries) {
    if ($bound -isnot [Collections.IDictionary] -or !$bound.ContainsKey('path') -or !$bound.ContainsKey('bytes') -or !$bound.ContainsKey('sha256') -or
        $bound.path -isnot [string] -or $bound.path -notmatch '^[A-Za-z]:[\\/]' -or !$uniqueTask21.Add($bound.path) -or
        $bound.bytes -is [bool] -or $bound.bytes -is [string] -or [string]$bound.bytes -notmatch '^[0-9]+$' -or
        $bound.sha256 -isnot [string] -or $bound.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') {throw 'T22_TASK21_INVENTORY_ROW_INVALID'}
    if ($bound.path -ieq $dispatchBefore.path) {
        if ($bound.bytes -ne $dispatchBefore.bytes -or $bound.sha256 -ine $dispatchBefore.sha256) {throw 'T22_TASK21_DISPATCHER_PREIMAGE_NOT_BOUND'}
    } else {Match $bound}
}
$allReceipts=@(Get-ChildItem -LiteralPath $work -File -Filter result.json -Recurse | ForEach-Object {ReadJson $_.FullName})
foreach ($receipt in $allReceipts) {
    if (!$receipt.ownedResourceClosure.allChildProcessesTerminal -or !$receipt.ownedResourceClosure.nativeProcessObjectsDisposed -or
        $receipt.gpuCommands -ne 0 -or $receipt.compilerCommands -ne 0 -or $receipt.processCensusCommands -ne 0 -or
        @($receipt.children | Where-Object {$null -eq $_.exit -or $_.timeout -or !$_.processObjectDisposed}).Count) {throw 'T22_NATIVE_RESOURCE_NOT_CLOSED'}
}
$reuse=@{schema=1;producerScope='36 original positive/rejection/actual21 cases + 5 original controls + 1 changed causative neutral control';
    originalInvocationReceipt=$initial;originalPassedFalsePreserved=$true;newLastControlReceipt=$last;
    exactRunnerTransformOnly=$true;exactPreservedFunctionBodies=$bodyProof;neutralData=$neutralData;derivedCaptureBindings=$derivedCaptureBindings;
    oldRunnerLosslessPreimage="$work/fixture-runner-before-neutral-control.json";
    dispatcherPreimage="$work/dispatcher-preimage.json";contractsCaptureTailByteExact=$true;
    contractsCaptureTailSha256=(Hash ([Text.Encoding]::UTF8.GetBytes($newCapture)));
    task21Current203=@{unchanged=202;authorizedDispatcherDelta=1;originalFreezeUntouched=$true;originalFreeze=$task21FreezePath;
        oldDispatcher=$dispatchBefore.sha256;currentDispatcher=(Identity "$repo/tests/run_nr_mfg_diagnostics.ps1" 'authorized-analysis-entry-delta')};
    oldControlsNotReplayed=$true;currentAnalyzerUnchangedAcrossAllProofs=$true}
WriteJson "$work/composed-proof-reuse.json" $reuse
$closure=@{schema=1;ownedDirectChildren=@($allReceipts | ForEach-Object {$_.children});receiptCount=$allReceipts.Count;
    allDirectChildNativeExitsObserved=$true;allProcessObjectsDisposed=$true;ownedWatchers=0;createdWindows=0;temporaryMappings=0;
    gpuResources=0;compilerCommands=0;gpuCommands=0;processCensusCommands=0;foreignProcessActions=0;
    closureMethod='owned System.Diagnostics.Process handles: WaitForExit and Dispose; no foreign/global census';
    producerNativeOperationsInFlight=0;capturedUtc=[DateTime]::UtcNow.ToString('o')}
WriteJson "$work/owned-resource-closure.json" $closure
$actualRow=@($positive | Where-Object scenario -EQ 'actual-current-task21')[0]
$packet=@{schema='task22-classification-proof-v1';task=22;producerComplete=$true;independentAcceptance=$false;
    proofComposition='COMPOSED 36 original cases + 5 original decisive controls + 1 changed causative neutral control; not one current invocation';
    exactOutcomeClasses=@('NotReproduced','OptiScalerDefect','ProviderHypothesisOnly','InsufficientData');
    qa=$positive+$negative;actualCurrentTask21=ReadJson $actualRow.output;actualCurrentTask21Artifact=$actualRow.output;
    historicalTask5Boundary='Only SYNTHETIC complete metadata reconstructs retained native old failure facts. Current repaired product/game regression is not proved.';
    sourceCandidateBoundary='Only independently declared nonneutral final-copy contradiction produces source path/task5 route. No candidate from counters/neutral/provider hypothesis.';
    currentSources=@(Identity "$PSScriptRoot/Analyze.ps1" 'offline-analyzer';Identity "$PSScriptRoot/Analysis.ps1" 'fixture-runner';
        Identity "$repo/tests/run_nr_mfg_diagnostics.ps1" 'dispatcher';Identity "$PSScriptRoot/Analysis.md" 'schema-and-usage';Identity $PSCommandPath 'finalization-audit');
    reuseProof="$work/composed-proof-reuse.json";resourceClosure="$work/owned-resource-closure.json";
    originalFailureReceipt=$initial;missingSurfaceRedReceipt="$work/task-22-analysis-61e24a23/red-receipt.json";
    noGameReproduction=$true;noFoliageCure=$true;noProprietaryCauseInference=$true;noProductSourceEdits=$true;
    cpuOnly=$true;notCompletedTasks=@(13,14,23);gate='Fresh whole Task22 independent verification required after producer terminal.'}
WriteJson "$evidence/task-22-classification.json" $packet
$done=@'
# Task22 producer DoneClaim

Task22 delivers a bounded offline reader for actual Task21 capture schema 1 and nr-mfg-preflight-v1, plus a separate explicitly SYNTHETIC complete-metadata fixture companion. The dispatcher exposes -Tier Analysis and optional -AnalysisInputRoot. The original Contracts/Capture tail is byte-exact, and the old dispatcher is losslessly archived.

CPU-only evidence is honestly COMPOSED: 36 native original classification/rejection/current-Task21 scenarios, five original decisive bad-classifier/bounds/provenance controls, and one newly causative neutral control. The first overall passed=false receipt and ineffective neutral mutant are preserved. Only the neutral-control generation and optional targeted entry changed afterward; every original fixture/oracle/native-runner function body is byte-exact, and neutral raw/native-log bytes and typed JSON facts match. Capture JSON property ordering changes exact byte SHA values; both companion-derived capture hashes are preserved and independently verified against their respective exact artifacts. No array reordering, scalar coercion, missing/null equivalence or semantic fact normalization is used. The first literal-SHA comparison failure is preserved. No passed original scenario/control, Capture/Contracts/DLL/GPU/Task11/Task12 test was replayed.

The actual current Task21 input returns InsufficientData: real images exist, but exposure provenance, phase/timing and the referenced observer are unavailable. Worker counters/raw indexes never become phase, display timing, generated pixel origin or proprietary cause. The two OptiScalerDefect fixtures are SYNTHETIC reconstructions of retained historical Task5 native facts, route to already existing Task5 and request no current repair. applied=0 and neutral expected-copy controls do not produce a defect or candidate. Game reproduction and quality-fix claims remain false.

Evidence: task-22-classification.json; task-22-analysis-r1/composed-proof-reuse.json; all exact commands/native exits/logs/reports in its qa table; task-22-analysis-r1/owned-resource-closure.json; task-22-analysis-r1/producer-freeze.json. New malformed/unsafe/provenance/unbounded cases exit 2 with named T22 errors, normal classes exit 0, and each causative bad classifier is caught by an unchanged native oracle exit 1.

Current source/support/evidence identities are frozen. Task21's original 203-entry inventory remains immutable: 202 live paths match and its one dispatcher entry resolves to the exact lossless preimage; current changed dispatcher is separately bound. All directly owned child native exits were observed and Process handles disposed, with no GPU/compiler/census/watchers/mappings/windows/foreign actions. Inputs were read without modification.

Producer implementation is terminal. Independent acceptance is pending one fresh whole-scope Task22 gate. This does not complete Task13, Task14, Task23 or the 29-task candidate, and provides no provider/game/NVIDIA image acceptance.
'@
if ([IO.File]::Exists("$evidence/task-22-DoneClaim.md")) {throw 'T22_DONECLAIM_ALREADY_EXISTS'}
[IO.File]::WriteAllText("$evidence/task-22-DoneClaim.md",$done,[Text.UTF8Encoding]::new($false))
$freezeRows=[Collections.Generic.List[object]]::new()
$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Freeze([string]$path,[string]$kind) {if ($paths.Add($path)) {$freezeRows.Add((Identity $path $kind))}}
foreach ($file in Get-ChildItem -LiteralPath $work -File -Recurse) {Freeze $file.FullName 'task22-all-retained-evidence-including-failures'}
foreach ($source in $packet.currentSources) {Freeze $source.path $source.kind}
Freeze "$evidence/task-22-classification.json" 'task22-producer-packet'
Freeze "$evidence/task-22-DoneClaim.md" 'task22-doneclaim'
foreach ($reportRow in $positive | Where-Object {$_.output}) {
    foreach ($bound in (ReadJson $reportRow.output).inputBindings) {Freeze $bound.path $bound.kind}
}
foreach ($support in @("$repo/OptiScaler/dlssnr/DlssNr_PipelineCapture.h","$repo/OptiScaler/dlssnr/DlssNr_MfgDiagnostics.h",
    "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp","$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp",$task21FreezePath)) {Freeze $support 'current-read-only-schema-source-support'}
foreach ($bound in $a.inputSources | Where-Object {$_.kind -ne 'current-analysis-fixture-runner'}) {Freeze $bound.path $bound.kind}
foreach ($assembly in @([Text.Json.JsonDocument].Assembly,[Management.Automation.PSObject].Assembly,[Diagnostics.Process].Assembly,[Security.Cryptography.SHA256].Assembly)) {
    if ($assembly.Location) {Freeze $assembly.Location 'actual-loaded-pwsh-dotnet-support'}
}
foreach ($bound in $freezeRows) {Match $bound}
$encoded=[Text.Encoding]::UTF8.GetBytes(($freezeRows.ToArray() | ConvertTo-Json -Depth 6 -Compress))
$outputMemory=[IO.MemoryStream]::new()
$compressor=[IO.Compression.GZipStream]::new($outputMemory,[IO.Compression.CompressionLevel]::Optimal,$true)
try {$compressor.Write($encoded,0,$encoded.Length)} finally {$compressor.Dispose()}
try {$zip=$outputMemory.ToArray()} finally {$outputMemory.Dispose()}
WriteJson "$work/producer-freeze.json" @{schema=1;task=22;producerTerminal=$true;sourceWritesClosed=$true;nativeOperationsInFlight=0;
    independentAcceptance=$false;entryCount=$freezeRows.Count;inventoryBytes=$encoded.Length;inventorySha256=(Hash $encoded);
    inventoryEncoding='gzip-base64 UTF8 JSON';inventoryGzipBase64=[Convert]::ToBase64String($zip);
    composition=$packet.proofComposition;currentSources=$packet.currentSources;originalTask21DispatcherQualification=$reuse.task21Current203;
    excludedFromSelfInventory=@('producer-freeze.json');ownedResourceClosure="$work/owned-resource-closure.json"}
Write-Host "T22_FINALIZED entries=$($freezeRows.Count) positives=36 controls=6 task21Unchanged=202 dispatcherDelta=1"
