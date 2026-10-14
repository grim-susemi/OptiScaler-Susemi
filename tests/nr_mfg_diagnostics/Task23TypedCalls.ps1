# Authoritative role/operation contract: Task15 INTERFACE.md, first section.
# These functions only analyze supplied observations; they never call a provider.
function Read-Task23TypedUInt($Value, [UInt64]$Maximum, [string]$Field) {
    $number = [UInt64]0
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        ![UInt64]::TryParse([string]$Value, [ref]$number) -or $number -gt $Maximum) {
        throw "T23_TYPED_NUMBER_$Field"
    }
    return $number
}
function Require-Task23TypedFields($Row, [string[]]$Fields) {
    foreach ($field in $Fields) {
        if (!$Row.Contains($field)) { throw "T23_TYPED_MISSING_$field" }
    }
}
function ConvertTo-Task23TypedOperations([object[]]$Calls) {
    if (!$Calls -or $Calls.Count -gt 512) { throw 'T23_TYPED_CALL_LIMIT' }
    $createKeys = @('DLSSNR.UI','DLSSNR.UIAlpha','DLSSNR.ControlMask','DLSSNR.Backbuffer',
        'DLSSNR.UICorrection','DLSSNR.Width','DLSSNR.Height')
    $evaluateKeys = @('DLSSNR.Color','DLSSNR.Depth','DLSSNR.MVec','DLSSNR.Output','DLSSNR.Width','DLSSNR.Height')
    $roles = @{
        'DLSSNR.UI'='null-ui'; 'DLSSNR.UIAlpha'='null-ui-alpha'
        'DLSSNR.ControlMask'='null-control-mask'; 'DLSSNR.Backbuffer'='null-backbuffer'
        'DLSSNR.Color'='model-input-proxy'; 'DLSSNR.Depth'='model-depth-guide'
        'DLSSNR.MVec'='model-motion-guide'; 'DLSSNR.Output'='model-answer-surface'
    }
    $parameters = @{}; $commands = @{}; $created = @{}; $seenOperations = @{}
    $normalized = [Collections.Generic.List[object]]::new()
    $unavailable = [Collections.Generic.List[string]]::new()
    $open = $null; $lastSequence = [UInt64]0; $createCount = 0; $evaluateCount = 0
    foreach ($row in $Calls) {
        Require-Task23TypedFields $row @('schema','sequence','fixtureApplication','operation','event')
        $sequence = Read-Task23TypedUInt $row.sequence ([UInt64]::MaxValue) 'sequence'
        $application = Read-Task23TypedUInt $row.fixtureApplication 8 'fixtureApplication'
        $operation = [string](Read-Task23TypedUInt $row.operation ([UInt64]::MaxValue) 'operation')
        if ($row.schema -ne 1 -or !$application -or $operation -ceq '0' -or $sequence -le $lastSequence) {
            throw 'T23_TYPED_ORDER_OR_APPLICATION_INVALID'
        }
        $lastSequence = $sequence
        if ($row.event -cin @('createEntry','evaluateEntry')) {
            if ($open) { throw 'T23_TYPED_NESTED_ROOT_OPERATION' }
            if ($seenOperations.ContainsKey($operation)) { throw 'T23_TYPED_OPERATION_REUSED' }
            Require-Task23TypedFields $row @('lane','commands','parameters')
            [void](Read-Task23TypedUInt $row.lane 1 'lane')
            [void](Read-Task23TypedUInt $row.commands ([UInt64]::MaxValue) 'commands')
            $parameter = [string](Read-Task23TypedUInt $row.parameters ([UInt64]::MaxValue) 'parameters')
            if ($parameter -ceq '0') { throw 'T23_TYPED_PARAMETERS_REQUIRED' }
            if (!$parameters.ContainsKey($parameter)) { $parameters[$parameter] = $parameters.Count + 1 }
            $command = [string]$row.commands
            if (!$commands.ContainsKey($command)) { $commands[$command] = $commands.Count + 1 }
            $stage = if ($row.event -ceq 'createEntry') {'create'} else {'evaluate'}
            $featureOrdinal = $null
            if ($stage -ceq 'create') {
                Require-Task23TypedFields $row @('feature','outHandleStorage')
                [void](Read-Task23TypedUInt $row.feature ([UInt32]::MaxValue) 'feature')
                if ($row.feature -ne 18 -or !(Read-Task23TypedUInt $row.outHandleStorage ([UInt64]::MaxValue) 'outHandleStorage')) {
                    throw 'T23_TYPED_CREATE_ARGUMENT_INVALID'
                }
            } else {
                Require-Task23TypedFields $row @('handle','progressCallback')
                [void](Read-Task23TypedUInt $row.progressCallback ([UInt64]::MaxValue) 'progressCallback')
                $handle = [string](Read-Task23TypedUInt $row.handle ([UInt64]::MaxValue) 'handle')
                if (!$created.ContainsKey($handle) -or $created[$handle].lane -ne $row.lane) {
                    throw 'T23_TYPED_FEATURE_NOT_CREATED_IN_CASE'
                }
                $featureOrdinal = $created[$handle].ordinal
            }
            $seenOperations[$operation] = $true
            $open = @{operation=$operation; stage=$stage; entry=$row; reads=@{}
                featureOrdinal=$featureOrdinal; parametersOrdinal=$parameters[$parameter]; commandsOrdinal=$commands[$command]}
            continue
        }
        if (!$open -or $operation -cne $open.operation -or $application -ne $open.entry.fixtureApplication) {
            throw 'T23_TYPED_OPERATION_JOIN_MISMATCH'
        }
        if ($row.event -ceq 'parameterRead') {
            Require-Task23TypedFields $row @('key','type','attempted','result','success','rawValue','valueKnown')
            $keys = if ($open.stage -ceq 'create') {$createKeys} else {$evaluateKeys}
            if ($row.key -cnotin $keys -or $open.reads.ContainsKey($row.key)) { throw 'T23_TYPED_KEY_SET_MISMATCH' }
            if ($row.attempted -isnot [bool] -or !$row.attempted -or
                $row.success -isnot [bool] -or $row.valueKnown -isnot [bool]) { throw 'T23_TYPED_READ_FLAGS_INVALID' }
            [void](Read-Task23TypedUInt $row.result ([UInt32]::MaxValue) 'readResult')
            [void](Read-Task23TypedUInt $row.rawValue ([UInt64]::MaxValue) 'rawValue')
            if ($row.Contains('parameters') -and $row.parameters -ne $open.entry.parameters) {
                throw 'T23_TYPED_PARAMETERS_JOIN_MISMATCH'
            }
            $resource = $roles.ContainsKey($row.key)
            $expectedType = if ($resource) {'ID3D12Resource*'} else {'unsigned'}
            if ($row.type -cne $expectedType) { throw 'T23_TYPED_READ_TYPE_MISMATCH' }
            if (!$resource) {
                Require-Task23TypedFields $row @('expected')
                [void](Read-Task23TypedUInt $row.expected ([UInt32]::MaxValue) 'expected')
            }
            $known = $row.success -and $row.valueKnown
            if (!$known) { $unavailable.Add('typed-value-unavailable:' + $row.key) }
            elseif ($resource -and $open.stage -ceq 'create' -and $row.rawValue -ne 0) {
                throw 'T23_TYPED_CREATE_NULL_REQUIRED'
            } elseif ($resource -and $open.stage -ceq 'evaluate' -and $row.rawValue -eq 0) {
                throw 'T23_TYPED_EVALUATE_RESOURCE_REQUIRED'
            } elseif (!$resource -and $row.rawValue -ne $row.expected) { throw 'T23_TYPED_UNSIGNED_VALUE_MISMATCH' }
            $open.reads[$row.key] = $row
            continue
        }
        if ($row.event -cne $open.stage) { throw 'T23_TYPED_RESULT_EVENT_MISMATCH' }
        Require-Task23TypedFields $row @('lane','commands','parameters','handle','result','forwardedExactlyOnce','argumentsModified')
        [void](Read-Task23TypedUInt $row.lane 1 'lane')
        [void](Read-Task23TypedUInt $row.commands ([UInt64]::MaxValue) 'commands')
        [void](Read-Task23TypedUInt $row.parameters ([UInt64]::MaxValue) 'parameters')
        if ($row.lane -ne $open.entry.lane -or $row.commands -ne $open.entry.commands -or
            $row.parameters -ne $open.entry.parameters) { throw 'T23_TYPED_RESULT_SCOPE_MISMATCH' }
        if ($row.forwardedExactlyOnce -isnot [bool] -or !$row.forwardedExactlyOnce -or
            $row.argumentsModified -isnot [bool] -or $row.argumentsModified) { throw 'T23_TYPED_FORWARDING_CHANGED' }
        $result = Read-Task23TypedUInt $row.result ([UInt32]::MaxValue) 'result'
        $handle = [string](Read-Task23TypedUInt $row.handle ([UInt64]::MaxValue) 'handle')
        $keys = if ($open.stage -ceq 'create') {$createKeys} else {$evaluateKeys}
        if ($open.reads.Count -ne $keys.Count) { throw 'T23_TYPED_KEY_SET_MISMATCH' }
        if ($open.stage -ceq 'create') {
            Require-Task23TypedFields $row @('feature')
            [void](Read-Task23TypedUInt $row.feature ([UInt32]::MaxValue) 'feature')
            if ($row.feature -ne $open.entry.feature) { throw 'T23_TYPED_CREATE_FEATURE_MISMATCH' }
            # nvsdk_ngx_defs.h: NVSDK_NGX_Result_Success=0x1. Failed creates
            # never grant feature ownership, even if raw storage is nonzero.
            if ($result -eq 1) {
                if ($handle -ceq '0' -or $created.ContainsKey($handle)) { throw 'T23_TYPED_CREATE_HANDLE_INVALID' }
                $created[$handle] = @{ordinal=$created.Count + 1; lane=$row.lane}
                $open.featureOrdinal = $created[$handle].ordinal
            }
            ++$createCount
        } else {
            if ($handle -cne [string]$open.entry.handle) { throw 'T23_TYPED_EVALUATE_HANDLE_MISMATCH' }
            ++$evaluateCount
        }
        $reads = foreach ($key in $keys) {
            $read = $open.reads[$key]; $known = $read.success -and $read.valueKnown
            [ordered]@{key=$key; type=$read.type; role=$(if ($roles.ContainsKey($key)) {$roles[$key]} else {'unsigned-setting'})
                attempted=$read.attempted; result=$read.result; success=$read.success; valueKnown=$read.valueKnown
                value=$(if (!$known) {$null} elseif ($roles.ContainsKey($key)) {
                    if ($read.rawValue -eq 0) {'typed-null'} else {'typed-bound-surface'}
                } else {$read.rawValue})}
        }
        $normalized.Add([ordered]@{operationOrdinal=$normalized.Count + 1; stage=$open.stage
            fixtureApplication=$application; lane=$row.lane; feature=18; featureOrdinal=$open.featureOrdinal
            parametersOrdinal=$open.parametersOrdinal; commandsOrdinal=$open.commandsOrdinal
            commandsPresent=($row.commands -ne 0)
            progressCallbackPresent=$(if ($open.stage -ceq 'evaluate') {$open.entry.progressCallback -ne 0} else {$null})
            result=$result; forwardedExactlyOnce=$row.forwardedExactlyOnce; argumentsModified=$row.argumentsModified
            reads=@($reads)})
        $open = $null
    }
    if ($open) { throw 'T23_TYPED_OPERATION_UNCLOSED' }
    return [pscustomobject]@{operations=$normalized.ToArray(); createCount=$createCount; evaluateCount=$evaluateCount
        successfullyCreatedFeatures=$created.Count; unavailable=$unavailable.ToArray()
        proxyToScenePixelLineageKnown=$false; physicalFgObserved=$false}
}
