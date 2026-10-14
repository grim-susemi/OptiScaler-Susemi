#requires -Version 7.0
param([string]$InputRoot,
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$limits = @{frames=64; imagesPerFrame=8; roi=256; jsonFile=65536; jsonTotal=5MB;
    fileCount=580; retained=256MB; rawFile=1MB; events=512}
$bindings = [Collections.Generic.List[object]]::new()
$seen = @{}
$jsonBytes = 0L
$totalBytes = 0L
$mismatches = [Collections.Generic.List[string]]::new()
$unavailable = [Collections.Generic.List[string]]::new()
function Fail([string]$name) { throw "T22_$name" }
function Hash([byte[]]$data) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($algorithm.ComputeHash($data)) }
    finally { $algorithm.Dispose() }
}
function CheckPath([string]$path) {
    $cursor = [IO.Path]::GetFullPath($path)
    while ($cursor) {
        if (([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) -and
            (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Fail 'UNSAFE_REPARSE_PATH'
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\','/'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Reference([string]$base, [string]$relative) {
    if (!$relative -or $relative.Length -gt 160 -or $relative -match '[:\x00-\x1f]' -or
        [IO.Path]::IsPathRooted($relative)) { Fail 'UNSAFE_REFERENCE' }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($base,$relative))
    if (!$path.StartsWith($script:rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { Fail 'UNSAFE_REFERENCE' }
    CheckPath $path
    return $path
}
function ReadArtifact([string]$path, [long]$maximum, [string]$kind) {
    CheckPath $path
    $file = [IO.FileInfo]::new($path)
    if (!$file.Exists) { return $null }
    if ($file.Length -gt $maximum) { Fail 'FILE_SIZE_LIMIT' }
    if (!$seen.ContainsKey($path) -and $script:totalBytes + $file.Length -gt $limits.retained) { Fail 'TOTAL_READ_LIMIT' }
    $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $openedLength = $stream.Length
        if ($openedLength -gt $maximum) { Fail 'FILE_SIZE_LIMIT' }
        if (!$seen.ContainsKey($path) -and $openedLength -gt $limits.retained - $script:totalBytes) { Fail 'TOTAL_READ_LIMIT' }
        $data = [byte[]]::new([int]$openedLength)
        $offset = 0
        while ($offset -lt $data.Length) {
            $count = $stream.Read($data,$offset,$data.Length-$offset)
            if (!$count) { Fail 'ARTIFACT_CHANGED_DURING_READ' }
            $offset += $count
        }
        if ($stream.ReadByte() -ne -1) { Fail 'ARTIFACT_CHANGED_DURING_READ' }
        if ($stream.Length -ne $data.Length) { Fail 'ARTIFACT_CHANGED_DURING_READ' }
    } finally { $stream.Dispose() }
    $sha = Hash $data
    if ($seen.ContainsKey($path)) {
        if ($data.Length -ne $seen[$path].bytes -or $sha -cne $seen[$path].sha256) { Fail 'ARTIFACT_CHANGED_BETWEEN_READS' }
    } else {
        $seen[$path] = @{bytes=$data.Length; sha256=$sha}
        $script:totalBytes += $data.Length
        $bindings.Add([ordered]@{path=$path; kind=$kind; bytes=$data.Length; sha256=$sha})
        if ($bindings.Count -gt $limits.fileCount) { Fail 'FILE_COUNT_LIMIT' }
    }
    return @{data=$data; bytes=$data.Length; sha256=$sha}
}
function ValidateJsonNode($node) {
    switch ($node.ValueKind.ToString()) {
        'Object' {
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $node.EnumerateObject()) {
                if (!$keys.Add($property.Name)) { Fail 'DUPLICATE_JSON_KEY' }
                if ($keys.Count -gt 128 -or $property.Name.Length -gt 80) { Fail 'JSON_SHAPE_LIMIT' }
                ValidateJsonNode $property.Value
            }
        }
        'Array' {
            if ($node.GetArrayLength() -gt $limits.events) { Fail 'JSON_ARRAY_LIMIT' }
            foreach ($element in $node.EnumerateArray()) { ValidateJsonNode $element }
        }
        'String' { if ($node.GetString().Length -gt 2048) { Fail 'JSON_STRING_LIMIT' } }
    }
}
function ReadJson([string]$path, [switch]$NativeTerminal) {
    # A complete ownership terminal can use no more than the unchanged batch
    # JSON budget. Small capture metadata keeps its independent 64 KiB bound.
    $maximum = if ($NativeTerminal) { $limits.jsonTotal } else { $limits.jsonFile }
    $kind = if ($NativeTerminal) { 'native-ownership-terminal' } else { 'structured-json' }
    $artifact = ReadArtifact $path $maximum $kind
    if (!$artifact) { return $null }
    $script:jsonBytes += $artifact.bytes
    if ($script:jsonBytes -gt $limits.jsonTotal) { Fail 'JSON_TOTAL_LIMIT' }
    try {
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($artifact.data).TrimStart([char]0xfeff)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 16
        $document = [Text.Json.JsonDocument]::Parse($text,$options)
        try { ValidateJsonNode $document.RootElement }
        finally { $document.Dispose() }
        $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 16
    } catch {
        if ($_.Exception.Message -match 'T22_') { throw }
        Fail 'MALFORMED_JSON'
    }
    if ($value -isnot [Collections.IDictionary]) { Fail 'JSON_OBJECT_REQUIRED' }
    if ($NativeTerminal) { ValidateNativeTerminal $value }
    return $value
}
function Integer($value, [ulong]$maximum, [string]$field, [ulong]$minimum=0) {
    $number = 0UL
    if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or
        ![ulong]::TryParse([string]$value,[ref]$number) -or $number -lt $minimum -or $number -gt $maximum) {
        Fail "INVALID_NUMBER_$field"
    }
    return $number
}
function Boolean($value, [string]$field) {
    if ($value -isnot [bool]) { Fail "INVALID_BOOLEAN_$field" }
    return $value
}
function Required($record, [string[]]$fields) {
    foreach ($field in $fields) { if (!$record.Contains($field)) { Fail "MISSING_FIELD_$field" } }
}
function SameHash($value) { return ($value -is [string] -and $value -cmatch '^[A-Fa-f0-9]{64}$') }
function ValidateNativeTerminal($terminal) {
    Required $terminal @('mode','result','failure','primaryBuildExit','total','active','uniqueBirth',
        'actualNativeExits','acquiredJobHandles','debugDuplicateHandles','actualDisposals',
        'actualWaitUnregistrations','debugStarts','debugExits','pendingDebugEvent','activePids',
        'numberOfAssignedProcesses','numberOfProcessIdsInList','unresolvedAcquisitions',
        'workerErrors','cleanupErrors','population','ownershipReconciled','ownedResourceClosure',
        'remainingOwnedResources','success','rootPid')
    $count = Integer $terminal.uniqueBirth $limits.events 'nativePopulation' 1
    if ($terminal.mode -cne 'task15-candidate' -or $terminal.failure -ne $null -or
        $terminal.result -ne 0 -or $terminal.primaryBuildExit -ne 0 -or $terminal.total -ne $count -or
        $terminal.active -ne 0 -or $terminal.numberOfAssignedProcesses -ne 0 -or
        $terminal.numberOfProcessIdsInList -ne 0 -or $terminal.remainingOwnedResources -ne 0 -or
        $terminal.population -isnot [array] -or $terminal.population.Count -ne $count) { Fail 'NATIVE_TERMINAL_SCHEMA' }
    foreach ($field in @('success','ownershipReconciled','ownedResourceClosure')) {
        if (!(Boolean $terminal[$field] $field)) { Fail 'NATIVE_TERMINAL_CLOSURE' }
    }
    foreach ($field in @('result','primaryBuildExit','active','numberOfAssignedProcesses','numberOfProcessIdsInList','remainingOwnedResources')) {
        if ((Integer $terminal[$field] $limits.events $field) -ne 0) { Fail 'NATIVE_TERMINAL_SCHEMA' }
    }
    if ((Integer $terminal.total $limits.events 'nativeTotal') -ne $count) { Fail 'NATIVE_TERMINAL_CARDINALITY' }
    [void](Integer $terminal.rootPid ([uint]::MaxValue) 'nativeRootPid' 1)
    if (Boolean $terminal.pendingDebugEvent 'pendingDebugEvent') { Fail 'NATIVE_TERMINAL_CLOSURE' }
    foreach ($field in @('activePids','unresolvedAcquisitions','workerErrors','cleanupErrors')) {
        if ($terminal[$field] -isnot [array] -or $terminal[$field].Count) { Fail 'NATIVE_TERMINAL_CLOSURE' }
    }
    foreach ($field in @('actualNativeExits','acquiredJobHandles','debugDuplicateHandles','debugStarts','debugExits')) {
        if ((Integer $terminal[$field] $limits.events $field) -ne $count) { Fail 'NATIVE_TERMINAL_CARDINALITY' }
    }
    foreach ($field in @('actualDisposals','actualWaitUnregistrations')) {
        if ((Integer $terminal[$field] (2*$limits.events) $field) -ne 2*$count) { Fail 'NATIVE_TERMINAL_CARDINALITY' }
    }
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $handles = [Collections.Generic.HashSet[ulong]]::new()
    $rootFound = $false
    foreach ($row in $terminal.population) {
        Required $row @('identity','metadataAvailable','debugStart','exitCode','exitFileTime','handles')
        $identity = $row.identity
        Required $identity @('pid','creationFileTime','identity','image','commandLine')
        $pidValue = Integer $identity.pid ([uint]::MaxValue) 'nativePid' 1
        $birth = 0UL; $exitTime = 0UL
        if ($identity.creationFileTime -isnot [string] -or
            ![ulong]::TryParse($identity.creationFileTime,[ref]$birth) -or !$birth -or
            $identity.identity -cne "$pidValue@$birth" -or !$identities.Add($identity.identity) -or
            $identity.image -isnot [string] -or ![IO.Path]::IsPathRooted($identity.image) -or
            $identity.commandLine -isnot [string] -or !$identity.commandLine -or
            $row.exitFileTime -isnot [string] -or ![ulong]::TryParse($row.exitFileTime,[ref]$exitTime) -or
            $exitTime -lt $birth -or (Integer $row.exitCode ([uint]::MaxValue) 'nativeExit') -ne 0 -or
            !(Boolean $row.metadataAvailable 'metadataAvailable') -or !(Boolean $row.debugStart 'debugStart') -or
            $row.handles -isnot [array] -or $row.handles.Count -ne 2) { Fail 'NATIVE_TERMINAL_IDENTITY' }
        if ($pidValue -eq $terminal.rootPid) { $rootFound = $true }
        $provenances = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($handle in $row.handles) {
            Required $handle @('id','provenance','registered','unregistered','signaled','disposed','metadataObservation')
            $id = Integer $handle.id (2*$limits.events) 'nativeHandle' 1
            if (!$handles.Add($id) -or $handle.provenance -cnotin @('Job-member acquired','debug CREATE original duplicate') -or
                !$provenances.Add($handle.provenance)) { Fail 'NATIVE_TERMINAL_HANDLE' }
            foreach ($field in @('registered','unregistered','signaled','disposed')) {
                if (!(Boolean $handle[$field] $field)) { Fail 'NATIVE_TERMINAL_HANDLE' }
            }
            $observation = $handle.metadataObservation
            Required $observation @('ownerId','provenance','handle','nativePid','nativeBirth','inOriginalJob',
                'metadataAvailable','metadata','metadataFailure','observedAtAcquisitionNotImmutableCreationMetadata')
            Required $observation.metadata @('identity','pid','creationFileTime','image','commandLine')
            $nativeHandle = 0UL
            if ($observation.ownerId -ne $id -or $observation.provenance -cne $handle.provenance -or
                $observation.handle -isnot [string] -or ![ulong]::TryParse($observation.handle,[ref]$nativeHandle) -or !$nativeHandle -or
                $observation.nativePid -ne $pidValue -or $observation.nativeBirth -cne $identity.creationFileTime -or
                $observation.metadata.identity -cne $identity.identity -or $observation.metadata.pid -ne $pidValue -or
                $observation.metadata.creationFileTime -cne $identity.creationFileTime -or
                $observation.metadataFailure -ne $null -or
                !(Boolean $observation.inOriginalJob 'inOriginalJob') -or
                !(Boolean $observation.metadataAvailable 'metadataAvailable') -or
                !(Boolean $observation.observedAtAcquisitionNotImmutableCreationMetadata 'acquisitionObservation')) {
                Fail 'NATIVE_TERMINAL_HANDLE_IDENTITY'
            }
        }
    }
    if (!$rootFound -or $handles.Count -ne 2*$count) { Fail 'NATIVE_TERMINAL_CARDINALITY' }
}
function Analyze {
    $report = [ordered]@{schema='nr-mfg-analysis-v1'; outcome='InsufficientData'; synthetic=$false;
        evidenceScope='offline-capture-observation'; gameReproduced=$false; qualityFixProven=$false;
        observed=[ordered]@{frames=@(); rawFrameContentChange=$null; nrOutputContentChange=$null;
            nrExposureVariation=@(); declaredPhase=@(); observedSampleBehavior=@(); availableTiming=@();
            providerMetadata=@(); phaseContentAnomalies=@()};
        unavailable=$unavailable; artifactMismatches=$mismatches; reproducedContractFailures=@();
        candidates=@(); inputBindings=$bindings; limits=$limits;
        limitsOfInference=@('No proprietary optical-flow or occlusion cause is inferred.',
            'Raw MultiFrameIndex, tokens, counters and worker spacing do not prove phase or display timing.',
            'Current-file module hashes do not identify the mapped image.',
            'SYNTHETIC metadata and historical host failures do not reproduce a current game defect.')}
    if (!$InputRoot -or ![IO.Directory]::Exists($InputRoot)) { $unavailable.Add('captures-absent'); return $report }
    if ($InputRoot -notmatch '^[A-Za-z]:[\\/]') { Fail 'LOCAL_ABSOLUTE_INPUT_REQUIRED' }
    $script:root = [IO.Path]::GetFullPath($InputRoot).TrimEnd('\','/')
    $script:rootPrefix = $script:root + [IO.Path]::DirectorySeparatorChar
    CheckPath $script:root
    $directories = [Collections.Generic.List[string]]::new()
    $files = 0
    foreach ($entry in [IO.DirectoryInfo]::new($script:root).EnumerateFileSystemInfos()) {
        CheckPath $entry.FullName
        if ($entry -is [IO.DirectoryInfo]) {
            if ($entry.Name -cnotmatch '^frame-[0-9]{1,2}$') { Fail 'INVALID_FRAME_DIRECTORY' }
            $directories.Add($entry.FullName)
            if ($directories.Count -gt $limits.frames) { Fail 'FRAME_LIMIT' }
            foreach ($child in $entry.EnumerateFileSystemInfos()) {
                CheckPath $child.FullName
                if ($child -is [IO.DirectoryInfo]) { Fail 'INPUT_DEPTH_LIMIT' }
                ++$files
                if ($files -gt $limits.fileCount) { Fail 'FILE_COUNT_LIMIT' }
            }
        } else { ++$files; if ($files -gt $limits.fileCount) { Fail 'FILE_COUNT_LIMIT' } }
    }
    $session = ReadJson (Reference $script:root 'capture-session.json')
    if ($session) {
        Required $session @('schema','frames','writes','peakReadbackBytes','retainedReservationBytes','inFlightReadbackBytes')
        if ($session.schema -ne 1) { Fail 'UNSUPPORTED_SESSION_SCHEMA' }
        [void](Integer $session.frames 64 'sessionFrames')
        [void](Integer $session.writes 64 'sessionWrites')
        [void](Integer $session.peakReadbackBytes 32MB 'peakReadbackBytes')
        [void](Integer $session.retainedReservationBytes 256MB 'retainedReservationBytes')
        [void](Integer $session.inFlightReadbackBytes 32MB 'inFlightReadbackBytes')
        if ($session.writes -ne $directories.Count -or $session.frames -lt $directories.Count) { $mismatches.Add('session-frame-count') }
    } else { $unavailable.Add('capture-session-metadata') }
    $context = ReadJson (Reference $script:root 'analysis-synthetic.json')
    $contextFrames = @{}
    if ($context) {
        Required $context @('schema','synthetic','provenance','frames')
        if ($context.schema -cne 'nr-mfg-analysis-synthetic-v1' -or $context.synthetic -isnot [bool] -or
            !$context.synthetic -or $context.provenance -cne 'SYNTHETIC') { Fail 'SYNTHETIC_PROVENANCE_REQUIRED' }
        if ($context.frames -isnot [array] -or $context.frames.Count -gt 64) { Fail 'CONTEXT_FRAME_LIMIT' }
        $report.synthetic = $true
        $report.evidenceScope = 'SYNTHETIC-complete-metadata-fixture-only'
        foreach ($entry in $context.frames) {
            Required $entry @('application','captureSha256','images')
            $key = [string](Integer $entry.application ([ulong]::MaxValue) 'contextApplication' 1)
            if ($contextFrames.ContainsKey($key)) { Fail 'DUPLICATE_CONTEXT_IDENTITY' }
            if (!(SameHash $entry.captureSha256)) { Fail 'INVALID_CAPTURE_HASH' }
            if ($entry.images -isnot [array] -or $entry.images.Count -gt 8) { Fail 'IMAGE_LIMIT' }
            foreach ($expectedImage in $entry.images) {
                Required $expectedImage @('role','sha256')
                if ($expectedImage.role -isnot [string] -or $expectedImage.role -cnotmatch '^[a-z][a-z0-9_]{0,39}$' -or !(SameHash $expectedImage.sha256)) { Fail 'INVALID_CONTEXT_IMAGE' }
            }
            $contextFrames[$key] = $entry
        }
    }
    $identities = @{}
    $complete = $true
    $failures = [Collections.Generic.List[object]]::new()
    $formats = @{2=16; 10=8; 41=4; 54=2; 34=4; 16=8; 26=4; 28=4; 87=4; 24=4}
    foreach ($directory in ($directories | Sort-Object { [int]([IO.Path]::GetFileName($_).Substring(6)) })) {
        $capturePath = Reference $directory 'capture.json'
        $capture = ReadJson $capturePath
        if (!$capture) { $unavailable.Add('frame-capture-missing'); $complete=$false; continue }
        Required $capture @('schema','applicationKnown','owner','consumer','generation','application','workerThread',
            'exposureProvenanceKnown','preExposureRawBits','preExposureReadAttempted','preExposureReadSucceeded',
            'preExposureReadResult','resolvedPreExposureBits','exposureReadSucceeded','exposureReadResult',
            'exposureStateRaw','resolvedExposureMode','observerReference','phaseKnown','displayTimingAvailable','images')
        if ($capture.schema -ne 1) { Fail 'UNSUPPORTED_CAPTURE_SCHEMA' }
        foreach ($field in @('applicationKnown','exposureProvenanceKnown','preExposureReadAttempted','preExposureReadSucceeded',
            'exposureReadSucceeded','phaseKnown','displayTimingAvailable')) { [void](Boolean $capture[$field] $field) }
        foreach ($field in @('owner','consumer','generation','application','workerThread')) {
            [void](Integer $capture[$field] ([ulong]::MaxValue) $field)
        }
        foreach ($field in @('preExposureRawBits','preExposureReadResult','resolvedPreExposureBits','exposureReadResult',
            'exposureStateRaw','resolvedExposureMode')) { [void](Integer $capture[$field] ([uint]::MaxValue) $field) }
        if (!$capture.applicationKnown -or !$capture.owner -or !$capture.consumer -or !$capture.generation -or !$capture.application) {
            $unavailable.Add('application-identity-unknown'); $complete=$false
        }
        $identity = "$($capture.owner)/$($capture.consumer)/$($capture.generation)/$($capture.application)"
        if ($identities.ContainsKey($identity)) { $mismatches.Add('duplicate-application-identity') }
        $identities[$identity]=$true
        $observerPath = Reference $directory $capture.observerReference
        $observer = ReadJson $observerPath
        if ($observer) {
            Required $observer @('schema','observationScope','hashScope','telemetryAtomicity','displayTimingAvailable')
            if ($observer.schema -cne 'nr-mfg-preflight-v1' -or $observer.observationScope -cne 'worker-time-metadata-not-frame-phase' -or
                $observer.hashScope -cne 'current-file-not-mapped-image' -or $observer.telemetryAtomicity -cne 'independent-last-values') {
                Fail 'UNSUPPORTED_OBSERVER_SCHEMA'
            }
            $report.observed.providerMetadata += $observer
        } else { $unavailable.Add('observer-reference-unavailable'); $complete=$false }
        if ($capture.images -isnot [array] -or $capture.images.Count -gt $limits.imagesPerFrame) { Fail 'IMAGE_LIMIT' }
        $frame = [ordered]@{identity=$identity; application=$capture.application; capture=$capturePath;
            exposureRawBits=$capture.preExposureRawBits; exposureGetAttempted=$capture.preExposureReadAttempted;
            exposureGetSucceeded=$capture.preExposureReadSucceeded; exposureGetResult=$capture.preExposureReadResult;
            resolvedExposureBits=$capture.resolvedPreExposureBits; exposureMode=$capture.resolvedExposureMode;
            exposureProvenanceKnown=$capture.exposureProvenanceKnown; images=@(); nr=$null}
        $sample = if ($contextFrames.ContainsKey([string]$capture.application)) { $contextFrames[[string]$capture.application] } else { $null }
        if ($sample -and $sample.captureSha256 -ine @($bindings | Where-Object path -EQ $capturePath)[0].sha256) { $mismatches.Add('capture-hash') }
        $roles = @{}
        foreach ($image in $capture.images) {
            Required $image @('role','imageAvailable','sourceState','rawResource','pixelOrigin')
            if ($image.role -isnot [string] -or $image.role -cnotmatch '^[a-z][a-z0-9_]{0,39}$' -or $roles.ContainsKey($image.role)) { Fail 'INVALID_IMAGE_ROLE' }
            $roles[$image.role]=$true
            [void](Boolean $image.imageAvailable 'imageAvailable')
            [void](Integer $image.sourceState ([uint]::MaxValue) 'sourceState')
            [void](Integer $image.rawResource ([ulong]::MaxValue) 'rawResource')
            if (!$image.imageAvailable) {
                Required $image @('unavailableReason')
                if ($image.pixelOrigin -cne 'unknown' -or !$image.unavailableReason) { Fail 'INVALID_UNAVAILABLE_PROVENANCE' }
                $frame.images += [ordered]@{role=$image.role; available=$false; reason=$image.unavailableReason; pixelOrigin='unknown'}
                continue
            }
            Required $image @('evidence','width','height','format','rowPitch','bytes')
            if ($image.pixelOrigin -cne 'owned_nr_surface' -or !$image.rawResource) { Fail 'UNPROVEN_PIXEL_ORIGIN' }
            $width = Integer $image.width $limits.roi 'width' 1
            $height = Integer $image.height $limits.roi 'height' 1
            $format = [int](Integer $image.format 200 'format')
            if (!$formats.ContainsKey($format)) { Fail 'UNSUPPORTED_PIXEL_FORMAT' }
            $pitch = Integer $image.rowPitch 4096 'rowPitch' 1
            $bytes = Integer $image.bytes $limits.rawFile 'bytes' 1
            if ($pitch % 256 -ne 0 -or $pitch -lt $width*$formats[$format] -or $bytes -ne $pitch*$height) { Fail 'INVALID_ROI_LAYOUT' }
            if ($image.evidence -cne ($image.role+'.raw')) { Fail 'INVALID_IMAGE_REFERENCE' }
            $rawPath = Reference $directory $image.evidence
            $raw = ReadArtifact $rawPath $limits.rawFile 'raw-roi'
            if (!$raw) { $mismatches.Add('image-missing'); $complete=$false; continue }
            if ($raw.bytes -ne $bytes) { $mismatches.Add('image-length'); $complete=$false; continue }
            $active = [byte[]]::new([int]($width*$height*$formats[$format]))
            for ($row=0; $row -lt $height; ++$row) {
                [Array]::Copy($raw.data,[int]($row*$pitch),$active,[int]($row*$width*$formats[$format]),[int]($width*$formats[$format]))
            }
            $frame.images += [ordered]@{role=$image.role; available=$true; pixelOrigin=$image.pixelOrigin;
                width=$width; height=$height; format=$format; evidence=$rawPath; artifactSha256=$raw.sha256; activeContentSha256=(Hash $active)}
            if ($sample) {
                $expected = @($sample.images | Where-Object { $_.role -ceq $image.role })
                if ($expected.Count -ne 1 -or !(SameHash $expected[0].sha256) -or $expected[0].sha256 -ine $raw.sha256) { $mismatches.Add('image-hash') }
            }
        }
        if (@($frame.images | Where-Object { $_.available -and $_.role -ceq 'nr_input' }).Count -ne 1 -or
            @($frame.images | Where-Object { $_.available -and $_.role -ceq 'nr_output' }).Count -ne 1) {
            $unavailable.Add('nr-input-or-output-unavailable'); $complete=$false
        }
        if ($sample -and $sample.Contains('declaredPhase') -and $sample.declaredPhase -cin @('real','generated') -and
            $sample.Contains('displayTimeMs') -and $sample.displayTimeMs -is [ValueType] -and $sample.displayTimeMs -isnot [bool] -and
            [double]::IsFinite([double]$sample.displayTimeMs) -and [double]$sample.displayTimeMs -ge 0 -and $sample.Contains('nr')) {
            Required $sample.nr @('enabled','signature')
            [void](Boolean $sample.nr.enabled 'nrEnabled')
            if ($sample.nr.signature -isnot [string] -or !$sample.nr.signature -or $sample.nr.signature.Length -gt 120) { Fail 'INVALID_NR_SIGNATURE' }
            $frame.nr = $sample.nr
            $report.observed.declaredPhase += @{application=$capture.application; declared=$sample.declaredPhase; source='SYNTHETIC-declaration-not-pixel-origin'}
            $report.observed.availableTiming += @{application=$capture.application; milliseconds=$sample.displayTimeMs; source='SYNTHETIC-display-time-declaration'}
        } else { $unavailable.Add('declared-phase-or-display-timing-or-nr-settings-unavailable'); $complete=$false }
        if (!$capture.exposureProvenanceKnown -or !$capture.preExposureReadAttempted -or !$capture.preExposureReadSucceeded) {
            $unavailable.Add('raw-exposure-provenance-unavailable'); $complete=$false
        }
        if ($sample -and $sample.Contains('finalCopyContract')) {
            $contract = $sample.finalCopyContract
            Required $contract @('kind','log','sha256','expectedApplicationPixel','historicalTask','provenance')
            if ($contract.kind -cne 'applied-final-copy' -or $contract.historicalTask -ne 5 -or
                $contract.provenance -cne 'SYNTHETIC-reconstruction-of-retained-Task5-native-facts' -or
                $contract.expectedApplicationPixel -cnotmatch '^[A-F0-9]{8}$' -or !(SameHash $contract.sha256)) { Fail 'INVALID_FINAL_COPY_CONTRACT' }
            $logPath = Reference $script:root $contract.log
            $log = ReadArtifact $logPath 65536 'historical-native-fact-log'
            if (!$log -or $log.sha256 -ine $contract.sha256) { $mismatches.Add('host-log-hash') }
            else {
                $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($log.data),$true)
                try { $logText=$reader.ReadToEnd() } finally { $reader.Dispose() }
                $facts = [regex]::Matches($logText,'(?m)^R1_FACTS (?<facts>[^\r\n]+)')
                if ($facts.Count -ne 1) { Fail 'HOST_FACTS_REQUIRED' }
                $values=@{}
                foreach ($token in $facts[0].Groups['facts'].Value.Split(' ')) {
                    if ($token -match '^([A-Za-z]+)=([A-Za-z0-9-]+)$') { $values[$matches[1]]=$matches[2] }
                }
                Required $values @('original','application','scratch','applied','composed','copyBack','executed','submitted')
                foreach ($field in @('original','application','scratch')) { if ($values[$field] -cnotmatch '^[A-F0-9]{8}$') { Fail 'HOST_PIXEL_FACT_REQUIRED' } }
                foreach ($field in @('applied','composed','copyBack','executed','submitted')) { if ($values[$field] -notin @('0','1')) { Fail 'HOST_BOOLEAN_FACT_REQUIRED' } }
                if ($contract.expectedApplicationPixel -cne $values.scratch) { $mismatches.Add('host-expected-copy-not-bound-to-scratch') }
                elseif ($values.applied -eq '1' -and $values.composed -eq '1' -and $values.copyBack -eq '1' -and
                    $values.executed -eq '1' -and $values.submitted -eq '1' -and
                    $values.scratch -cne $values.original -and $values.application -cne $contract.expectedApplicationPixel) {
                    $failures.Add(@{contract='applied-final-copy'; application=$capture.application; actualPixel=$values.application;
                        expectedPixel=$contract.expectedApplicationPixel; nativeFacts=$logPath; historicalTask=5;
                        provenance=$contract.provenance; currentRegressionProven=$false})
                }
            }
        }
        $report.observed.frames += $frame
    }
    if ($contextFrames.Count -ne $directories.Count -and $context) { $mismatches.Add('context-frame-count') }
    if ($report.observed.frames.Count -lt 2) { $unavailable.Add('multiple-comparable-frames-unavailable'); $complete=$false }
    $rawChanges=0; $outputChanges=0
    for ($i=1; $i -lt $report.observed.frames.Count; ++$i) {
        $before=$report.observed.frames[$i-1]; $after=$report.observed.frames[$i]
        $sampleChanges=@{}
        foreach ($role in @('nr_input','nr_output')) {
            $left=@($before.images | Where-Object { $_.available -and $_.role -ceq $role })
            $right=@($after.images | Where-Object { $_.available -and $_.role -ceq $role })
            $changed=$null
            if ($left.Count -eq 1 -and $right.Count -eq 1 -and $left[0].width -eq $right[0].width -and
                $left[0].height -eq $right[0].height -and $left[0].format -eq $right[0].format) {
                $changed=$left[0].activeContentSha256 -cne $right[0].activeContentSha256
            } else { $unavailable.Add('comparable-role-layout-unavailable'); $complete=$false }
            $sampleChanges[$role]=$changed
        }
        if ($sampleChanges.nr_input) { ++$rawChanges }
        if ($sampleChanges.nr_output) { ++$outputChanges }
        $exposureChanged=$before.exposureRawBits -ne $after.exposureRawBits -or $before.resolvedExposureBits -ne $after.resolvedExposureBits -or $before.exposureMode -ne $after.exposureMode
        $nrChanged=($null -ne $before.nr -and $null -ne $after.nr -and ($before.nr.enabled -ne $after.nr.enabled -or $before.nr.signature -cne $after.nr.signature))
        $report.observed.nrExposureVariation += @{from=$before.application; to=$after.application; rawExposureChanged=($before.exposureRawBits -ne $after.exposureRawBits);
            resolvedExposureChanged=($before.resolvedExposureBits -ne $after.resolvedExposureBits); modeChanged=($before.exposureMode -ne $after.exposureMode); nrSettingsChanged=$nrChanged}
        $report.observed.observedSampleBehavior += @{from=$before.application; to=$after.application; rawInputChanged=$sampleChanges.nr_input; nrOutputChanged=$sampleChanges.nr_output}
        if ($sampleChanges.nr_output -and !$sampleChanges.nr_input -and !$exposureChanged -and !$nrChanged) {
            $report.observed.phaseContentAnomalies += @{from=$before.application; to=$after.application; observation='NR sample changed with stable sampled input and declared NR/exposure settings'; causalConclusion=$null}
        }
    }
    if ($report.observed.frames.Count -ge 2) { $report.observed.rawFrameContentChange=($rawChanges -gt 0); $report.observed.nrOutputContentChange=($outputChanges -gt 0) }
    $report.unavailable=@($unavailable | Select-Object -Unique)
    $report.artifactMismatches=@($mismatches | Select-Object -Unique)
    if (!$complete -or $mismatches.Count -gt 0) { return $report }
    $report.reproducedContractFailures=$failures.ToArray()
    if ($failures.Count -gt 0) {
        $report.outcome='OptiScalerDefect'
        $report.candidates=@(@{sourcePath='OptiScaler/shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp'; routeToExistingTask=5;
            action='Retained historical failure regression route; current repaired product is not reopened without current failure proof.';
            currentRepairRequested=$false; evidence=@($failures | ForEach-Object nativeFacts)})
    } elseif ($report.observed.phaseContentAnomalies.Count -gt 0) { $report.outcome='ProviderHypothesisOnly' }
    else { $report.outcome='NotReproduced' }
    return $report
}
try {
    if ($OutputPath -notmatch '^[A-Za-z]:[\\/]' -or [IO.File]::Exists($OutputPath)) { Fail 'NEW_LOCAL_OUTPUT_REQUIRED' }
    $resolvedOutput=[IO.Path]::GetFullPath($OutputPath)
    CheckPath $resolvedOutput
    if ($InputRoot -and $resolvedOutput.StartsWith([IO.Path]::GetFullPath($InputRoot).TrimEnd('\','/')+'\',[StringComparison]::OrdinalIgnoreCase)) { Fail 'OUTPUT_INSIDE_INPUT' }
    $result=Analyze
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
    $result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    Write-Host "T22_OUTCOME=$($result.outcome) SYNTHETIC=$($result.synthetic) inputFiles=$($bindings.Count) readBytes=$totalBytes"
    exit 0
} catch {
    $message=$_.Exception.Message
    if ($message -notmatch 'T22_') { $message='T22_INTERNAL_ERROR: '+$message }
    [Console]::Error.WriteLine($message)
    exit 2
}
