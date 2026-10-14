param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/Task23TypedCalls.ps1"
$observations = [Collections.Generic.List[object]]::new()
function Assert([bool]$Condition, [string]$Case) {
    if (!$Condition) { throw "T23_TYPED_CPU_ORACLE_$Case" }
}
function Refusal([string]$Case, [scriptblock]$Operation, [string]$Expected) {
    try { & $Operation | Out-Null } catch {
        if ($_.Exception.Message -cne $Expected) { throw }
        $observations.Add(@{case=$Case; refusal=$Expected; passed=$true})
        return
    }
    throw "T23_TYPED_CPU_ORACLE_$Case"
}
function Fixture([long]$Offset=0) {
    $rows = [Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($stage in @('create','evaluate')) {
        $operation = $(if ($stage -ceq 'create') {100L} else {200L}) + $Offset
        $application = if ($stage -ceq 'create') {1} else {3}
        $entry = @{schema=1; sequence=++$sequence; fixtureApplication=$application; operation=$operation
            event=($stage+'Entry'); lane=0; commands=(12288L+$Offset); parameters=(16384L+$Offset)}
        if ($stage -ceq 'create') { $entry.feature=18; $entry.outHandleStorage=20480L+$Offset }
        else { $entry.handle=24576L+$Offset; $entry.progressCallback=0L }
        $rows.Add($entry)
        $keys = if ($stage -ceq 'create') {
            @('DLSSNR.UI','DLSSNR.UIAlpha','DLSSNR.ControlMask','DLSSNR.Backbuffer',
              'DLSSNR.UICorrection','DLSSNR.Width','DLSSNR.Height')
        } else { @('DLSSNR.Color','DLSSNR.Depth','DLSSNR.MVec','DLSSNR.Output','DLSSNR.Width','DLSSNR.Height') }
        $resourceIndex = 0
        foreach ($key in $keys) {
            $unsigned = $key -cin @('DLSSNR.UICorrection','DLSSNR.Width','DLSSNR.Height')
            $value = if ($unsigned) {if ($key -ceq 'DLSSNR.UICorrection') {1L} else {64L}}
                elseif ($stage -ceq 'create') {0L} else {28672L + (++$resourceIndex)*4096L + $Offset}
            $read = @{schema=1; sequence=++$sequence; fixtureApplication=$application; operation=$operation
                event='parameterRead'; key=$key; type=$(if ($unsigned) {'unsigned'} else {'ID3D12Resource*'})
                attempted=$true; result=1; success=$true; rawValue=$value; valueKnown=$true}
            if ($unsigned) { $read.expected=$value }
            $rows.Add($read)
        }
        $result = @{schema=1; sequence=++$sequence; fixtureApplication=$application; operation=$operation
            event=$stage; lane=0; commands=$entry.commands; parameters=$entry.parameters
            handle=(24576L+$Offset); result=1; forwardedExactlyOnce=$true; argumentsModified=$false}
        if ($stage -ceq 'create') { $result.feature=18 }
        $rows.Add($result)
    }
    return ,$rows.ToArray()
}
function Row($Rows, [string]$Event, [string]$Key='') {
    return @($Rows | Where-Object {$_.event -ceq $Event -and (!$Key -or $_.key -ceq $Key)})[0]
}
$paths = @("$PSScriptRoot/Task23TypedCalls.ps1", "$PSScriptRoot/Task23Pair.ps1", $PSCommandPath)
foreach ($path in $paths) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'changed-source-parse'
    $observations.Add(@{case='changed-source-parse'; path=$path; errors=@($errors); passed=$true})
}
$left = Fixture
$right = Fixture 100000
$normalizedLeft = ConvertTo-Task23TypedOperations $left
$normalizedRight = ConvertTo-Task23TypedOperations $right
Assert (($normalizedLeft.operations | ConvertTo-Json -Depth 10 -Compress) -ceq
        ($normalizedRight.operations | ConvertTo-Json -Depth 10 -Compress)) 'cross-process-role-normalization'
Assert ((Row $left 'create').handle -ne (Row $right 'create').handle -and
        (Row $left 'evaluateEntry').parameters -ne (Row $right 'evaluateEntry').parameters) 'different-absolute-pointers'
Assert ($normalizedLeft.createCount -eq 1 -and $normalizedLeft.evaluateCount -eq 1 -and
        $normalizedLeft.successfullyCreatedFeatures -eq 1 -and
        $normalizedLeft.operations[0].fixtureApplication -eq 1 -and
        $normalizedLeft.operations[1].fixtureApplication -eq 3 -and
        $normalizedLeft.operations[1].featureOrdinal -eq $normalizedLeft.operations[0].featureOrdinal) 'same-case-feature-not-same-ordinal'
Assert (!$normalizedLeft.proxyToScenePixelLineageKnown -and !$normalizedLeft.physicalFgObserved -and
        @($normalizedLeft.operations[1].reads | Where-Object role -EQ 'model-input-proxy').Count -eq 1) 'no-fabricated-scene-lineage'
$observations.Add(@{case='different-pointers-and-operation-ids-normalize-by-role-and-same-case-ownership'
    createApplication=1; evaluateApplication=3; proxySceneLineageKnown=$false; passed=$true})
$changed = Fixture 100000
(Row $changed 'parameterRead' 'DLSSNR.Width').rawValue=65L
Refusal 'typed-value-not-counter-proof' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_UNSIGNED_VALUE_MISMATCH'
$changed = Fixture
(Row $changed 'createEntry').fixtureApplication=0
Refusal 'no-guessed-create-application-zero' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_ORDER_OR_APPLICATION_INVALID'
$changed = Fixture
(Row $changed 'evaluateEntry').handle=123456L
Refusal 'feature-must-be-created-in-same-case' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_FEATURE_NOT_CREATED_IN_CASE'
$changed = Fixture
(Row $changed 'create').result=3134193664L
Refusal 'failed-create-cannot-grant-ownership' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_FEATURE_NOT_CREATED_IN_CASE'
$changed = Fixture
(Row $changed 'create').handle=(Row $changed 'createEntry').outHandleStorage
Refusal 'output-slot-is-not-created-feature' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_FEATURE_NOT_CREATED_IN_CASE'
$changed = Fixture
(Row $changed 'create').parameters++
Refusal 'actual-result-parameter-scope' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_RESULT_SCOPE_MISMATCH'
$changed = Fixture
(Row $changed 'evaluate').commands++
Refusal 'actual-result-command-scope' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_RESULT_SCOPE_MISMATCH'
$changed = Fixture
(Row $changed 'evaluate').handle++
Refusal 'actual-evaluate-result-handle-scope' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_EVALUATE_HANDLE_MISMATCH'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').operation=100L
Refusal 'read-operation-join' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_OPERATION_JOIN_MISMATCH'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').fixtureApplication=2
Refusal 'read-actual-application-join' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_OPERATION_JOIN_MISMATCH'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').parameters=9999L
Refusal 'read-parameter-identity-when-observed' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_PARAMETERS_JOIN_MISMATCH'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.UI').rawValue=123L
Refusal 'create-resource-typed-null' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_CREATE_NULL_REQUIRED'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').rawValue=0L
Refusal 'evaluate-model-surface-required' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_EVALUATE_RESOURCE_REQUIRED'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').key='Color'
Refusal 'no-guessed-key-alias' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_KEY_SET_MISMATCH'
$changed = Fixture
(Row $changed 'parameterRead' 'DLSSNR.Color').type='unsigned'
Refusal 'actual-typed-getter-required' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_READ_TYPE_MISMATCH'
$changed = Fixture
(Row $changed 'evaluate').forwardedExactlyOnce=$false
Refusal 'forwarded-exactly-once-preserved' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_FORWARDING_CHANGED'
$changed = Fixture
(Row $changed 'evaluate').argumentsModified=$true
Refusal 'forwarded-arguments-unchanged' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_FORWARDING_CHANGED'
$changed = Fixture
(Row $changed 'evaluate').sequence=1
Refusal 'actual-order-not-counter' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_ORDER_OR_APPLICATION_INVALID'
$changed = Fixture
$changed = @($changed | Where-Object event -CNE 'evaluate')
Refusal 'missing-result-not-success' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_OPERATION_UNCLOSED'
$changed = Fixture
$changed[1] = (Row $changed 'evaluateEntry').Clone()
Refusal 'provider-nested-calls-not-flattened-as-root' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_NESTED_ROOT_OPERATION'
$changed = Fixture
(Row $changed 'evaluateEntry').operation=100L
Refusal 'distinct-root-operations-not-reused' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_OPERATION_REUSED'
$changed = Fixture
(Row $changed 'create').feature=19
Refusal 'actual-created-feature-matches-entry' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_CREATE_FEATURE_MISMATCH'
$changed = Fixture
$changed[2].key=$changed[1].key
Refusal 'duplicate-key-not-complete-typed-observation' {ConvertTo-Task23TypedOperations $changed} 'T23_TYPED_KEY_SET_MISMATCH'
$changed = Fixture
$read = Row $changed 'parameterRead' 'DLSSNR.Color'
$read.success=$false; $read.valueKnown=$false; $read.result=3134193664L; $read.rawValue=12345L
$unknown = ConvertTo-Task23TypedOperations $changed
Assert ($unknown.unavailable -contains 'typed-value-unavailable:DLSSNR.Color' -and
        $null -eq @($unknown.operations[1].reads | Where-Object key -CEQ 'DLSSNR.Color')[0].value -and
        $read.rawValue -eq 12345L -and $read.result -eq 3134193664L) 'unknown-raw-storage-preserved'
$observations.Add(@{case='failed-typed-read-remains-unavailable-and-raw-storage-preserved'; passed=$true})
$identities = foreach ($path in $paths) {
    @{path=$path; bytes=(Get-Item -LiteralPath $path).Length; sha256=(Get-FileHash -LiteralPath $path).Hash}
}
$result = @{schema=1; kind='task23-typed-association-delta-CPU'; passed=$true
    observations=$observations.ToArray(); sources=@($identities); prior19CPUChecksReplayed=$false
    syntheticCPUFixture=$true; actualProviderPassClaimed=$false; siblingCodeExecuted=$false
    gpuOrRuntimeLoads=0; generatedQaFiles=0; generatedImages=0; childLaunches=0; ownedAssets=0; pending=0}
Write-Output ('T23_TYPED_CPU_RESULT=' + ($result | ConvertTo-Json -Depth 12 -Compress))
Write-Output 'T23_TYPED_CPU_NATIVE_EXIT=0'
