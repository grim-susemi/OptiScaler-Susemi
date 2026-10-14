#requires -Version 7.0
param([string]$CandidateRoot, [string]$HostRoot, [Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [string]$SourceManifest, [string]$SourceManifestSha256,
      [string]$RuntimeRoot, [string]$RuntimeSha256,
      [string]$GpuAdmissionReceipt, [string]$GpuAdmissionSha256,
      [string]$BudgetReceipt, [string]$BudgetSha256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/Task23All.ps1"
. "$PSScriptRoot/Task23TypedCalls.ps1"
$plan = Get-Task23AllPlan @PSBoundParameters
# Reuse the actual accepted reader bodies and limits, including opened-length,
# repeated-identity, duplicate-key, path, depth, array and budget guards.
$analyzer = Join-Path $PSScriptRoot 'Analyze.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($analyzer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'T23_ANALYZER_SOURCE_PARSE' }
$nodes = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$limits'}, $true))
if ($nodes.Count -ne 1) { throw 'T23_ANALYZER_LIMITS_DRIFT' }
Invoke-Expression $nodes[0].Extent.Text
$functions = @{}
foreach ($node in $ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
    $functions[$node.Name] = $node.Extent.Text
}
foreach ($name in @('Fail','Hash','CheckPath','ReadArtifact','ValidateJsonNode','ReadJson','Integer','Boolean','Required','SameHash','ValidateNativeTerminal')) {
    if (!$functions.ContainsKey($name)) { throw 'T23_ANALYZER_READER_DRIFT' }
    Invoke-Expression $functions[$name]
}
$bindings = [Collections.Generic.List[object]]::new()
$seen = @{}
$jsonBytes = 0L
$totalBytes = [long]$plan.budget.retainedBeforeBytes
$caseData = [Collections.Generic.List[object]]::new()
$unavailable = [Collections.Generic.List[string]]::new()
$findings = [Collections.Generic.List[string]]::new()

function OwnedPath([string]$Path, [string]$Root) {
    if (!$Path -or ![IO.Path]::IsPathRooted($Path)) { throw 'T23_OUTPUT_PATH_REQUIRED' }
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'T23_OUTPUT_OUTSIDE_OWNED_ROOT' }
    CheckPath $resolved
    return $resolved
}
function Assert-Task23SummaryPaths($Summary, $Result, [string]$Fixture) {
    foreach ($field in @('captureManifest','actualCalls')) {
        $summaryPath = OwnedPath $Summary[$field] $Fixture
        $resultPath = OwnedPath $Result[$field] $Fixture
        if ($summaryPath -ine $resultPath) { throw 'T23_CASE_SUMMARY_MISMATCH' }
    }
}
function Need([bool]$Condition, [string]$Finding) {
    if (!$Condition) { $findings.Add($Finding) }
}
function ReadCalls([string]$Path) {
    $artifact = ReadArtifact $Path $limits.jsonFile 'actual-provider-call-stream'
    if (!$artifact) { throw 'T23_ACTUAL_CALLS_UNAVAILABLE' }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in [Text.UTF8Encoding]::new($false,$true).GetString($artifact.data).Split("`n")) {
        if (!$line.Trim()) { continue }
        $options = [Text.Json.JsonDocumentOptions]::new(); $options.MaxDepth = 16
        $document = [Text.Json.JsonDocument]::Parse($line,$options)
        try { ValidateJsonNode $document.RootElement } finally { $document.Dispose() }
        $rows.Add(($line | ConvertFrom-Json -AsHashtable -Depth 16))
        if ($rows.Count -gt 512) { throw 'T23_CALL_ARRAY_LIMIT' }
    }
    return ,$rows.ToArray()
}
function PixelValues($Image, [byte[]]$Data) {
    $components = switch ([int]$Image.format) { 28 {4}; 10 {4}; 41 {1}; 16 {2}; default {throw 'T23_PIXEL_FORMAT_UNAVAILABLE'} }
    $componentBytes = switch ([int]$Image.format) { 28 {1}; 10 {2}; default {4} }
    $values = [Collections.Generic.List[double]]::new()
    for ($y=0; $y -lt $Image.height; ++$y) {
        for ($x=0; $x -lt $Image.width*$components; ++$x) {
            $offset = [int]($y*$Image.rowPitch + $x*$componentBytes)
            $value = switch ([int]$Image.format) {
                28 { [double]$Data[$offset]/255 }
                10 { [double][BitConverter]::UInt16BitsToHalf([BitConverter]::ToUInt16($Data,$offset)) }
                default { [double][BitConverter]::ToSingle($Data,$offset) }
            }
            if (![double]::IsFinite($value)) { throw 'T23_NONFINITE_PIXEL' }
            $values.Add($value)
        }
    }
    return ,$values.ToArray()
}

function Get-Task23RetainedDebit($Summary, [long]$RawBytes, [long]$SharedReservation) {
    $declared = Integer $Summary.retainedReservationBytes $limits.retained 'sharedReservation'
    $raw = Integer $Summary.retainedRawBytes $limits.retained 'retainedRawBytes'
    $metadata = Integer $Summary.metadataReservationBytes $limits.retained 'metadataReservationBytes'
    if ($declared -ne $SharedReservation) { throw 'T23_SHARED_RESERVATION_MISMATCH' }
    if ($raw -ne $RawBytes) { throw 'T23_ACTUAL_RETAINED_DEBIT_MISMATCH' }
    return [long]($raw + $metadata)
}
function Measure-Task23RetainedTree([string]$Root) {
    $directories = [Collections.Generic.Queue[string]]::new()
    $directories.Enqueue($Root)
    $bytes = 0L; $files = 0
    while ($directories.Count) {
        $directory = $directories.Dequeue()
        CheckPath $directory
        foreach ($entry in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()) {
            CheckPath $entry.FullName
            if ($entry -is [IO.DirectoryInfo]) { $directories.Enqueue($entry.FullName); continue }
            if (++$files -gt $limits.fileCount) { Fail 'FILE_COUNT_LIMIT' }
            if ($entry.Length -gt $limits.retained - $bytes) { Fail 'TOTAL_READ_LIMIT' }
            $bytes += $entry.Length
        }
    }
    return $bytes
}
function Assert-Task23RetainedDebits($Budget, [long[]]$Debits, [long]$PhysicalBytes) {
    $retained = 0L
    foreach ($debit in $Debits) {
        if ($debit -lt 0 -or $debit -gt $Budget.reservationBytes - $retained) {
            throw 'T23_ACTUAL_RETAINED_BUDGET_REFUSED'
        }
        $retained += $debit
    }
    # Physical files already contain the raw data: do not add them a second time
    # to the raw + metadata debit. Both independent bounds must fit one cap.
    $accounted = [Math]::Max($retained,$PhysicalBytes)
    if ($PhysicalBytes -lt 0 -or $accounted -gt $Budget.reservationBytes -or
        $accounted -gt $Budget.ceilingBytes - $Budget.retainedBeforeBytes) {
        throw 'T23_ACTUAL_RETAINED_BUDGET_REFUSED'
    }
    return $retained
}
Invoke-Task23CanonicalPair $plan
$pairInputRoot = Split-Path $plan.cases[0].parameters.EvidenceRoot -Parent
foreach ($case in $plan.cases) {
    $resultPath = Join-Path $case.parameters.EvidenceRoot ("task15-result-Runtime-B00-" + $case.pair + '.json')
    $result = ReadJson (OwnedPath $resultPath $pairInputRoot)
    if (!$result) { throw 'T23_HOST_RESULT_UNAVAILABLE' }
    Required $result @('schema','kind','task','phase','runtimeCase','diagnosticPair','hostSha256',
        'finalCandidateSha256','manifestSha256','fixtureRoot','registration','nativeExit','captureTerminal',
        'controllerTerminal','gpuExecuted','caseSummary','captureManifest','actualCalls','diagnosticObserver')
    if ($result.schema -ne 1 -or $result.kind -cne 'task15HostCaseResult' -or $result.task -ne 15 -or
        $result.phase -cne 'Runtime' -or $result.runtimeCase -cne 'B00' -or $result.diagnosticPair -cne $case.pair -or
        $result.nativeExit -ne 0 -or $result.gpuExecuted -isnot [bool] -or !$result.gpuExecuted -or
        $result.hostSha256 -ine $plan.hostSha256 -or $result.manifestSha256 -ine $plan.manifestSha256 -or
        $result.finalCandidateSha256 -ine $plan.finalCandidateSha256) { throw 'T23_HOST_RESULT_BINDING_MISMATCH' }
    $fixture = OwnedPath $result.fixtureRoot $case.parameters.EvidenceRoot
    foreach ($name in @('captureTerminal','controllerTerminal')) {
        $terminal = ReadJson (OwnedPath $result[$name] $fixture) -NativeTerminal:($name -ceq 'captureTerminal')
        if (!$terminal -or !$terminal.ownedResourceClosure -or $terminal.remainingOwnedResources -ne 0 -or $terminal.failure) {
            throw 'T23_NATIVE_RESOURCE_CLOSURE_REQUIRED'
        }
    }
    $registration = ReadJson (OwnedPath $result.registration $fixture)
    if (!$registration -or $registration.kind -cne 'task15PreLaunchRegistration' -or
        $registration.purpose -cne 'task23-diagnostic-pair' -or
        $registration.manifestSha256 -ine $plan.manifestSha256 -or
        $registration.budgetSha256 -ine $BudgetSha256) { throw 'T23_PRELAUNCH_REGISTRATION_MISMATCH' }
    $summary = ReadJson (OwnedPath $result.caseSummary $fixture)
    Required $summary @('schema','runtimeCase','applicationFrames','retainedFrames','retainedApplication',
        'captureManifest','actualCalls','diagnosticObserver','finalNativeFence','requested','effective',
        'actualNrCreateCalls','actualNrEvaluateCalls','nativePresentCalls','applications','retainedRawBytes',
        'metadataReservationBytes','retainedReservationBytes','ownedResourcesClosed','nativeSubmissionCount',
        'nativeFenceCompletedCount','phaseKnown','displayTimingAvailable','productMfgEvaluateCount',
        'productMfgPresentCount','physicalFgProviderExercised','compositionApplications','copyBackApplications',
        'productionSubmittedApplications','distinctCreatedHandles','distinctEvaluatedHandles')
    if ($summary.schema -ne 1 -or $summary.runtimeCase -cne 'B00' -or $summary.applicationFrames -ne 8 -or
        $summary.retainedFrames -ne 1 -or $summary.retainedApplication -ne 8 -or
        $summary.applications -isnot [array] -or $summary.applications.Count -ne 8 -or
        !$summary.ownedResourcesClosed) { throw 'T23_CASE_SUMMARY_MISMATCH' }
    Assert-Task23SummaryPaths $summary $result $fixture
    Need ($summary.diagnosticObserver -eq $(if ($case.pair -ceq 'on') {1} else {0})) 'observer-switch'
    Need ($summary.nativePresentCalls -eq 8 -and
        $summary.nativeSubmissionCount -eq $summary.nativeFenceCompletedCount -and $summary.finalNativeFence -gt 0) 'native-count-fence'
    if ($null -ne $summary.productMfgEvaluateCount -or $null -ne $summary.productMfgPresentCount -or
        $summary.physicalFgProviderExercised -cne $false -or $summary.phaseKnown -cne $false -or
        $summary.displayTimingAvailable -cne $false) { throw 'T23_UNKNOWN_BOUNDARY_CHANGED' }
    $calls = ReadCalls (OwnedPath $result.actualCalls $fixture)
    $typed = ConvertTo-Task23TypedOperations $calls
    foreach ($field in $typed.unavailable) { $unavailable.Add($field) }
    Need ($typed.createCount -eq $summary.actualNrCreateCalls -and
          $typed.evaluateCount -eq $summary.actualNrEvaluateCalls -and
          $typed.successfullyCreatedFeatures -eq $summary.distinctCreatedHandles) 'actual-stream-counts'
    # Failed create attempts remain in the typed stream and pair comparison.
    # The existing typed contract grants ownership only to successful creates;
    # every evaluation of those owned features must still succeed.
    foreach ($operation in $typed.operations) {
        if ($operation.stage -ceq 'evaluate') { Need ($operation.result -eq 1) 'actual-provider-result' }
    }
    $observer = ReadJson (OwnedPath $result.diagnosticObserver $fixture)
    Required $observer @('schema','observer','session','owner','applicationSeams','eventCount','contentionDrops','active','capped','events')
    if ($observer.schema -ne 1 -or $observer.events -isnot [array] -or
        $observer.events.Count -ne $observer.eventCount -or $observer.events.Count -gt 512) { throw 'T23_OBSERVER_SCHEMA_INVALID' }
    foreach ($event in $observer.events) {
        Required $event @('phaseKnown','pixelOriginKnown','displayTimingAvailable','rawIndex','indexReadResult',
            'indexSource','indexReadResultKnown','indexReadAttempted','indexReadSuccess','identity','resources')
        if ($event.phaseKnown -ne 0 -or $event.pixelOriginKnown -ne 0 -or $event.displayTimingAvailable -ne 0) {
            throw 'T23_OBSERVER_UNKNOWN_BOUNDARY_CHANGED'
        }
    }
    $capturePath = OwnedPath $result.captureManifest $fixture
    $capture = ReadJson $capturePath
    Required $capture @('schema','applicationKnown','owner','consumer','generation','application','workerThread',
        'exposureProvenanceKnown','preExposureRawBits','preExposureReadAttempted','preExposureReadSucceeded',
        'preExposureReadResult','resolvedPreExposureBits','exposureReadSucceeded','exposureReadResult',
        'exposureStateRaw','resolvedExposureMode','observerReference','phaseKnown','displayTimingAvailable','images')
    if ($capture.schema -ne 1 -or $capture.images -isnot [array] -or $capture.images.Count -ne 4 -or
        $capture.phaseKnown -cne $false -or $capture.displayTimingAvailable -cne $false) { throw 'T23_CAPTURE_SCHEMA_INVALID' }
    $representative = $summary.applications[7]
    Need ($capture.applicationKnown -ceq $true -and $capture.owner -eq $representative.owner -and
        $capture.consumer -eq $representative.consumer -and $capture.generation -eq $representative.generation -and
        $capture.application -eq $representative.statusApplication) 'actual-capture-identity'
    $images = @{}
    $captureDir = [IO.Path]::GetDirectoryName($capturePath)
    $roleFields = @{application_input='input';depth='depth';motion='motion';final_output='output'}
    $rawBytes = 0UL
    foreach ($image in $capture.images) {
        Required $image @('role','imageAvailable','sourceState','rawResource','pixelOrigin')
        if (!$roleFields.ContainsKey($image.role) -or $images.ContainsKey($image.role)) { throw 'T23_CAPTURE_ROLE_INVALID' }
        if ($image.imageAvailable -cne $true) {
            Required $image @('unavailableReason')
            if ($image.pixelOrigin -cne 'unknown') { throw 'T23_UNAVAILABLE_ORIGIN_INVALID' }
            $unavailable.Add('retired-io-unavailable')
            $images[$image.role] = @{available=$false; metadata=$image}
            continue
        }
        Required $image @('evidence','width','height','format','rowPitch','bytes')
        $width = Integer $image.width 256 'width' 1
        $height = Integer $image.height 256 'height' 1
        $pitch = Integer $image.rowPitch 4096 'rowPitch' 1
        $bytes = Integer $image.bytes 1048576 'rawBytes' 1
        $bpp = switch ([int]$image.format) {28 {4};10 {8};41 {4};16 {8};default {throw 'T23_PIXEL_FORMAT_UNAVAILABLE'}}
        if ($pitch % 256 -ne 0 -or $pitch -lt $width*$bpp -or $bytes -ne $pitch*$height -or
            $image.evidence -cne ($image.role+'.raw') -or $image.pixelOrigin -cne 'owned_nr_surface') {
            throw 'T23_CAPTURE_LAYOUT_OR_ORIGIN_INVALID'
        }
        Need ($image.rawResource -eq $representative[$roleFields[$image.role]]) 'retired-role-resource-identity'
        $raw = ReadArtifact (OwnedPath (Join-Path $captureDir $image.evidence) $captureDir) $limits.rawFile 'retired-raw-roi'
        if (!$raw -or $raw.bytes -ne $bytes) { throw 'T23_RETIRED_IMAGE_LENGTH_MISMATCH' }
        $rawBytes += $bytes
        $images[$image.role] = @{available=$true; metadata=$image; sha256=$raw.sha256; values=(PixelValues $image $raw.data)}
    }
    $retainedDebit = Get-Task23RetainedDebit $summary $rawBytes $plan.budget.reservationBytes
    $pixels = ReadJson (OwnedPath (Join-Path $captureDir 'pixel-assertions.json') $captureDir)
    Required $pixels @('schema','application','completion','classification','images')
    Need ($pixels.schema -eq 1 -and $pixels.application -eq 8 -and
        $pixels.completion -ceq 'native_fence_retired' -and $pixels.classification -cin @('neutral','changed')) 'retired-pixel-proof'
    foreach ($pixel in $pixels.images) {
        Required $pixel @('role','bytes','finiteComponents','rawSha256')
        Need ($images.ContainsKey($pixel.role) -and $images[$pixel.role].available -and
            $pixel.rawSha256 -ieq $images[$pixel.role].sha256 -and
            $pixel.bytes -eq $images[$pixel.role].metadata.bytes) 'retired-pixel-hash'
    }
    # This is the new actual case-io session, not a synthetic/control-suite replay.
    # Keep missing ../mfg-preflight.json missing. The accepted CLI reports the
    # actual observed/unavailable fields without rewriting either capture.
    $analysisPath = Join-Path $EvidenceRoot ('analysis-' + $case.pair + '.json')
    $analysisRuntime = (Get-Command pwsh.exe -ErrorAction Stop).Source
    & $analysisRuntime -NoProfile -File $analyzer -InputRoot ([IO.Path]::GetDirectoryName($captureDir)) -OutputPath $analysisPath
    if ($LASTEXITCODE -ne 0) { throw 'T23_ACTUAL_CAPTURE_ANALYSIS_FAILED' }
    $analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json -AsHashtable
    if ($analysis.synthetic -or $analysis.gameReproduced -or $analysis.qualityFixProven -or
        $analysis.outcome -cne 'InsufficientData') { throw 'T23_ANALYSIS_UNKNOWN_BOUNDARY_CHANGED' }
    $caseData.Add(@{pair=$case.pair; result=$result; summary=$summary; calls=$calls;
        observer=$observer; capture=$capture; images=$images; pixelAssertions=$pixels; analysis=$analysis; typed=$typed;
        retainedDebitBytes=$retainedDebit})
}

$off = $caseData[0]; $on = $caseData[1]
foreach ($group in @('requested','effective')) {
    Need (($off.summary[$group] | ConvertTo-Json -Compress) -ceq
          ($on.summary[$group] | ConvertTo-Json -Compress)) "paired-$group-settings"
}
foreach ($field in @('actualNrCreateCalls','actualNrEvaluateCalls','nativePresentCalls','compositionApplications',
                    'copyBackApplications','productionSubmittedApplications','nativeSubmissionCount','nativeFenceCompletedCount',
                    'distinctCreatedHandles','distinctEvaluatedHandles')) {
    Need ($off.summary[$field] -eq $on.summary[$field]) "paired-$field"
}
Need ($off.calls.Count -eq $on.calls.Count) 'paired-typed-call-count'
Need (($off.typed.operations | ConvertTo-Json -Depth 10 -Compress) -ceq
      ($on.typed.operations | ConvertTo-Json -Depth 10 -Compress)) 'paired-semantic-provider-forwarding'
# Raw addresses are process-local. They are preserved, never compared as cross-
# process equality or converted into provider-generated/application phase.
$unavailable.Add('physical-FG-forwarding-unavailable')
$unavailable.Add('declared-phase-or-display-timing-unavailable')
$unavailable.Add('production-preflight-unavailable')
$unavailable.Add('proxy-to-retired-scene-pixel-lineage-unavailable')
foreach ($role in @('application_input','depth','motion','final_output')) {
    $left = $off.images[$role]; $right = $on.images[$role]
    if (!$left.available -or !$right.available) { continue }
    $sameLayout = $left.metadata.width -eq $right.metadata.width -and
        $left.metadata.height -eq $right.metadata.height -and $left.metadata.format -eq $right.metadata.format
    Need $sameLayout "paired-$role-layout"
    if (!$sameLayout) { continue }
    $tolerance = switch ([int]$left.metadata.format) {28 {1.0/255};10 {0.002};default {0.00001}}
    $maxError = 0.0
    for ($index=0; $index -lt $left.values.Count; ++$index) {
        $maxError = [Math]::Max($maxError, [Math]::Abs($left.values[$index]-$right.values[$index]))
    }
    Need ($maxError -le $tolerance) "paired-$role-pixels"
    $left.maxPairedError = $maxError; $left.tolerance = $tolerance
}
foreach ($case in $caseData) {
    foreach ($image in $case.images.Values) { $image.Remove('values') }
}
$physicalRetained = Measure-Task23RetainedTree $pairInputRoot
if ([IO.Path]::GetFullPath($EvidenceRoot) -ine [IO.Path]::GetFullPath($pairInputRoot)) {
    $physicalRetained += Measure-Task23RetainedTree $EvidenceRoot
}
$retained = $off.retainedDebitBytes + $on.retainedDebitBytes
$report = @{schema=1; kind='task23-actual-pair-analysis'; task=23
    contractFindings=$findings.ToArray(); unavailable=@($unavailable | Select-Object -Unique)
    outcome='InsufficientData'; candidateIntegrationComplete=$false; task23Complete=$false
    typedOperationAssociationComplete=($off.typed.unavailable.Count -eq 0 -and $on.typed.unavailable.Count -eq 0)
    gameReproduced=$false; qualityFixProven=$false; blackwellParityProven=$false
    observedCases=$caseData.ToArray(); inputBindings=$bindings.ToArray(); rawObserverMappedToPhase=$false
    synthetic=$false; metadataOrImagesFabricated=$false; retainedPairBytes=$retained
    sharedRetainedReservationBytes=$plan.budget.reservationBytes; physicalRetainedPairBytesBeforeReport=$physicalRetained
    budgetReceipt=$BudgetReceipt; budgetSha256=$BudgetSha256}
$reportJson = $report | ConvertTo-Json -Depth 16
$reportBytes = [Text.UTF8Encoding]::new($false).GetByteCount($reportJson + [Environment]::NewLine)
$null = Assert-Task23RetainedDebits $plan.budget @($caseData | ForEach-Object {$_.retainedDebitBytes}) ($physicalRetained + $reportBytes)
$reportJson | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'task23-pair-analysis.json') -Encoding utf8
if ($findings.Count) { throw 'T23_CURRENT_CANDIDATE_NONINTERFERENCE_FAILED' }
# Missing typed values or retired IO are a nonzero integration refusal.
# Unobserved physical FG/phase/display/proxy-to-scene lineage remains unavailable,
# while actual NR diagnostic noninterference can pass without inventing it.
if (@($unavailable | Where-Object {$_ -like 'typed-value-unavailable:*' -or $_ -ceq 'retired-io-unavailable'}).Count) {
    throw 'T23_INTEGRATION_INSUFFICIENT_DATA'
}
Write-Output 'T23_NR_PAIR_NONINTERFERENCE=PASS physicalFG=unavailable task23Complete=false'
