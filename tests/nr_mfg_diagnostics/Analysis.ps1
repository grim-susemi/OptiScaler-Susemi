#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [string]$AnalysisInputRoot,
      [switch]$ProbeUnavailable,
      [string]$AnalyzerPath,
      [string]$OnlyCase,
      [string]$OnlyMutation,
      [switch]$SkipMutations,
      [switch]$BoundaryOnly,
      [switch]$PathBoundaryOnly,
      [string]$NativeTerminalFixture,
      [string]$HistoricalHostFactsRoot = 'C:/omo-research/optiscaler-nr-present-addon-options-wt/.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task-5-repair-R1-PreFix-90b01c263c054a8887ccf1b92a0bd1ec/pre-fix')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $EvidenceRoot ('task-22-analysis-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[IO.Directory]::CreateDirectory($out) | Out-Null
$native = (Get-Command pwsh.exe -ErrorAction Stop).Source
if ($ProbeUnavailable) {
    $log = Join-Path $out 'missing-analysis.log'
    & $native -NoProfile -File "$repo/tests/run_nr_mfg_diagnostics.ps1" -Tier Analysis -EvidenceRoot $out *> $log
    $code = $LASTEXITCODE
    $receipt = [ordered]@{scenario='Analysis dispatcher absent before implementation';
        command=@($native,'-NoProfile','-File',"$repo/tests/run_nr_mfg_diagnostics.ps1",'-Tier','Analysis','-EvidenceRoot',$out);
        exit=$code; expected='native nonzero ParameterArgumentValidationError on Tier';
        artifact=$log; featureAvailable=$false; capturedUtc=[DateTime]::UtcNow.ToString('o')}
    if ($code -eq 0 -or (Get-Content -LiteralPath $log -Raw) -notmatch 'ValidateSet|validation|Analysis.*Contracts|not belong') {
        throw 'T22_RED_SURFACE_NOT_DEMONSTRATED'
    }
    $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/red-receipt.json" -Encoding utf8
    Write-Host "T22_EXPECTED_RED native=$code artifact=$log"
    exit 0
}
if (!$AnalyzerPath) { $AnalyzerPath=Join-Path $PSScriptRoot 'Analyze.ps1' }
$AnalyzerPath=[IO.Path]::GetFullPath($AnalyzerPath)
$out=[IO.Path]::GetFullPath($out)
$rows=[Collections.Generic.List[object]]::new()
$nativeChildren=[Collections.Generic.List[object]]::new()
$sourceInputs=[Collections.Generic.List[object]]::new()
$passed=$false
if ($OnlyMutation) { $OnlyCase='__changed_mutation_only__' }
function Identity([string]$path, [string]$kind) {
    $item=Get-Item -LiteralPath $path
    return [ordered]@{path=$item.FullName; kind=$kind; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
function SaveJson([string]$path, $value) {
    $value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding utf8
}
function Native([string[]]$arguments, [string]$name) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$native
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.WorkingDirectory=$out
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    $id=$null; $exit=$null; $timeout=$false
    try {
        if (!$process.Start()) { throw 'T22_NATIVE_START_FAILED' }
        $id=$process.Id
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) {
            $timeout=$true
            $process.Kill($true)
            $process.WaitForExit()
        }
        $exit=$process.ExitCode
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        $log=Join-Path $out ($name+'.log')
        [IO.File]::WriteAllText($log,$text,[Text.UTF8Encoding]::new($false))
    } finally {
        $process.Dispose()
        $nativeChildren.Add(@{pid=$id; exit=$exit; timeout=$timeout; processObjectDisposed=$true; ownedOnly=$true})
    }
    if ($timeout) { throw 'T22_OWNED_CHILD_TIMEOUT' }
    return @{exit=$exit; log=$log; text=$text; command=@($native)+$arguments}
}
function Capture([string]$directory, [int]$application, [byte]$inputValue, [byte]$outputValue) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $images=@()
    foreach ($role in @('nr_input','nr_output')) {
        $bytes=[byte[]]::new(256)
        $value=if ($role -eq 'nr_input') { $inputValue } else { $outputValue }
        $bytes[0]=$value; $bytes[1]=$value; $bytes[2]=$value; $bytes[3]=255
        [IO.File]::WriteAllBytes((Join-Path $directory ($role+'.raw')),$bytes)
        $images+=@{role=$role; imageAvailable=$true; sourceState=8; rawResource=1; pixelOrigin='owned_nr_surface';
            evidence=$role+'.raw'; width=1; height=1; format=28; rowPitch=256; bytes=256}
    }
    $capture=[ordered]@{schema=1;applicationKnown=$true;owner=1;consumer=2;generation=3;application=$application;
        workerThread=1;exposureProvenanceKnown=$true;preExposureRawBits=1065353216;exposureResource=0;
        preExposureReadAttempted=$true;preExposureReadSucceeded=$true;preExposureReadResult=1;resolvedPreExposureBits=1065353216;
        exposureReadSucceeded=$false;exposureReadResult=0;exposureStateRaw=0;resolvedExposureMode=0;
        observerReference='../mfg-preflight.json';phaseKnown=$false;displayTimingAvailable=$false;images=$images}
    SaveJson (Join-Path $directory 'capture.json') $capture
}
function BindContext([string]$root) {
    $entries=@()
    foreach ($number in 0..1) {
        $directory=Join-Path $root "frame-$number"
        $entries+=@{application=$number+1;captureSha256=(Get-FileHash -LiteralPath "$directory/capture.json").Hash;
            images=@(@{role='nr_input';sha256=(Get-FileHash -LiteralPath "$directory/nr_input.raw").Hash},
                     @{role='nr_output';sha256=(Get-FileHash -LiteralPath "$directory/nr_output.raw").Hash});
            declaredPhase=if ($number -eq 0) {'real'} else {'generated'};displayTimeMs=16.0*$number;
            nr=@{enabled=$true;signature='SYNTHETIC-NR-fixed-settings'}}
    }
    SaveJson "$root/analysis-synthetic.json" @{schema='nr-mfg-analysis-synthetic-v1';synthetic=$true;provenance='SYNTHETIC';frames=$entries}
}
function Fixture([string]$name, [byte]$nextInput=64, [byte]$nextOutput=64) {
    $root=Join-Path $out ('input-'+$name)
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Capture "$root/frame-0" 1 64 64
    Capture "$root/frame-1" 2 $nextInput $nextOutput
    SaveJson "$root/capture-session.json" @{schema=1;frames=2;writes=2;discarded=0;deviceRemoved=0;ringDrops=0;
        budgetDrops=0;duplicateDrops=0;unknownIdentityDrops=0;peakReadbackBytes=1024;retainedReservationBytes=197632;inFlightReadbackBytes=0}
    SaveJson "$root/mfg-preflight.json" @{schema='nr-mfg-preflight-v1';observationScope='worker-time-metadata-not-frame-phase';
        hashScope='current-file-not-mapped-image';telemetryAtomicity='independent-last-values';qualityFixProven=$false;
        displayTimingAvailable=$false;optionsSeen=$true;stateSeen=$true;active=$true;requested=3;sent=3;optionResultRaw=1;
        presented=999;maxPresented=999;rawMultiFrameIndex=123;streamlineFrameToken=42;label='SYNTHETIC'}
    BindContext $root
    return $root
}
function EditJson([string]$path, [scriptblock]$change) {
    $record=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    & $change $record
    SaveJson $path $record
}
function HostContract([string]$root, [string]$name, [string]$control) {
    $source=Join-Path $HistoricalHostFactsRoot ($name+'.log')
    $expected=if ($name -eq 'private-failure') {'09EF13561554D985F7333C064E33B384DAF6C9C541EAC6A9EE30232E01329387'} else {'BBD633938C1FA19902FB44323EB5750B60E1C52D69754F4D582C97218CFF4C42'}
    if ((Get-FileHash -LiteralPath $source).Hash -cne $expected) { throw 'T22_RETAINED_NATIVE_FACTS_DRIFT' }
    $sourceInputs.Add((Identity $source 'retained-actual-Task5-native-failure-not-replayed'))
    $data=[IO.File]::ReadAllBytes($source)
    $expectedPixel='FF0000FF'
    if ($control) {
        $text=[Text.Encoding]::Unicode.GetString($data).TrimStart([char]0xfeff)
        if ($control -eq 'off') { $text=$text.Replace(' applied=1 ',' applied=0 ') }
        if ($control -eq 'neutral') { $text=$text.Replace('scratch=FF0000FF','scratch=FF000000');$expectedPixel='FF000000' }
        $data=[Text.Encoding]::Unicode.GetPreamble()+[Text.Encoding]::Unicode.GetBytes($text)
    }
    $log="$root/host-facts.log"
    [IO.File]::WriteAllBytes($log,$data)
    EditJson "$root/analysis-synthetic.json" {
        param($record)
        $record.frames[0].finalCopyContract=@{kind='applied-final-copy';log='host-facts.log';sha256=(Get-FileHash -LiteralPath $log).Hash;
            expectedApplicationPixel=$expectedPixel;historicalTask=5;provenance='SYNTHETIC-reconstruction-of-retained-Task5-native-facts'}
    }
}
function Case([string]$name,[string]$root,[string]$expected,[string]$errorName='') {
    if ($OnlyCase -and $OnlyCase -cne $name) { return }
    $output=Join-Path $out ($name+'.json')
    $arguments=@('-NoProfile','-File',$AnalyzerPath,'-OutputPath',$output)
    if ($root) { $arguments+=@('-InputRoot',$root) }
    $child=Native $arguments $name
    $row=[ordered]@{scenario=$name;command=$child.command;exit=$child.exit;log=$child.log;output=$null;
        expected=$expected;errorName=$errorName;passed=$false;synthetic=($name -ne 'actual-current-task21')}
    $rows.Add($row)
    if ($errorName) {
        if ($child.exit -ne 2 -or $child.text -notmatch [regex]::Escape($errorName)) { throw "T22_EXPECTED_REJECTION_$name" }
    } else {
        if ($child.exit -ne 0 -or ![IO.File]::Exists($output)) { throw "T22_CLASSIFIER_NATIVE_FAILED_$name" }
        $result=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
        $row.output=$output
        if ($result.outcome -cne $expected) { throw "T22_WRONG_CLASS_$name expected=$expected actual=$($result.outcome)" }
        if ($result.gameReproduced -or $result.qualityFixProven) { throw 'T22_FALSE_GAME_OR_CURE_CLAIM' }
        if ($expected -ne 'OptiScalerDefect' -and $result.candidates.Count -ne 0) { throw 'T22_UNJUSTIFIED_SOURCE_CANDIDATE' }
        if ($expected -eq 'OptiScalerDefect' -and ($result.candidates.Count -ne 1 -or $result.candidates[0].routeToExistingTask -ne 5 -or
            $result.candidates[0].currentRepairRequested -or !$result.synthetic)) { throw 'T22_HISTORICAL_CONTRACT_ROUTE_FAILED' }
        if ($name -eq 'raw-content-change' -and (!$result.observed.rawFrameContentChange -or !$result.observed.nrOutputContentChange)) { throw 'T22_RAW_CONTENT_NOT_SEPARATE' }
        if ($name -eq 'nr-exposure-variation' -and (!$result.observed.nrExposureVariation[0].rawExposureChanged -or
            !$result.observed.nrExposureVariation[0].nrSettingsChanged)) { throw 'T22_NR_EXPOSURE_NOT_SEPARATE' }
        if ($name -eq 'descriptive-phase-content-anomaly' -and ($result.observed.rawFrameContentChange -or !$result.observed.nrOutputContentChange -or
            $result.observed.declaredPhase[1].declared -cne 'generated' -or $result.observed.frames[1].images[0].pixelOrigin -cne 'owned_nr_surface' -or
            $null -ne $result.observed.phaseContentAnomalies[0].causalConclusion)) { throw 'T22_PHASE_OR_CAUSE_OVERCLAIM' }
        if ($name -eq 'mismatched-artifact' -and 'image-hash' -notin $result.artifactMismatches) { throw 'T22_MISMATCH_NOT_MEASURED' }
        if ($name -eq 'padding-only-change' -and ($result.observed.rawFrameContentChange -or $result.observed.nrOutputContentChange)) { throw 'T22_PADDING_MISLABELED_CONTENT' }
        if ($name -eq 'actual-current-task21' -and ($result.synthetic -or 'declared-phase-or-display-timing-or-nr-settings-unavailable' -notin $result.unavailable)) { throw 'T22_ACTUAL_INPUT_FALSE_METADATA' }
    }
    $row.passed=$true
    Write-Host "T22_CASE=$name exit=$($child.exit) expected=$expected PASS"
}
function BoundaryCase([string]$Name, [scriptblock]$Action, [string]$Expected='') {
    $script:bindings=[Collections.Generic.List[object]]::new()
    $script:seen=@{}; $script:jsonBytes=0L; $script:totalBytes=0L
    $caught=''
    try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
    $ok=if ($Expected) { $caught -match [regex]::Escape($Expected) } else { !$caught }
    $rows.Add(@{scenario=$Name;expectedError=$Expected;actualError=$caught;passed=$ok;
        focusedBoundaryFixture=$true;gpuExecuted=$false})
    if (!$ok) { throw "T22_BOUNDARY_FAILED_$Name expected=$Expected actual=$caught" }
}
function BoundaryFixtures {
    if (!$NativeTerminalFixture) { throw 'T22_NATIVE_TERMINAL_FIXTURE_REQUIRED' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($AnalyzerPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'T22_ANALYZER_PARSE' }
    $assignments=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -ceq '$limits'},$true))
    if ($assignments.Count -ne 1) { throw 'T22_LIMITS_DRIFT' }
    Invoke-Expression $assignments[0].Extent.Text
    $script:limits=$limits
    $readers=@{}
    foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        $readers[$node.Name]=$node.Extent.Text
        Invoke-Expression $node.Extent.Text
    }
    $pairPath=Join-Path $PSScriptRoot 'Task23Pair.ps1'
    $pair=[Management.Automation.Language.Parser]::ParseFile($pairPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'T22_PAIR_PARSE' }
    foreach ($node in $pair.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in @('Get-Task23RetainedDebit','Assert-Task23RetainedDebits','Need','OwnedPath','Assert-Task23SummaryPaths')},$true)) {
        Invoke-Expression $node.Extent.Text
    }
    $sourceInputs.Add((Identity $pairPath 'current-retained-debit-functions'))
    $sourceInputs.Add((Identity $NativeTerminalFixture 'unchanged-real-native-terminal-fixture'))
    if ($PathBoundaryOnly) {
        $path=Join-Path $out 'owned.json'
        [IO.File]::WriteAllText($path,'{"schema":1}')
        $result=@{captureManifest=$path;actualCalls=$path}
        BoundaryCase 'summary-path-separator-case-equivalence' {
            $summary=@{captureManifest=$path.Replace('\','/').ToUpperInvariant();actualCalls=$path.Replace('\','/')}
            Assert-Task23SummaryPaths $summary $result $out
            ReadJson (OwnedPath $summary.captureManifest $out) | Out-Null
            ReadJson (OwnedPath $result.captureManifest $out) | Out-Null
        }
        BoundaryCase 'summary-wrong-owned-file' {
            Assert-Task23SummaryPaths @{captureManifest=(Join-Path $out 'wrong.json');actualCalls=$path} $result $out
        } 'T23_CASE_SUMMARY_MISMATCH'
        BoundaryCase 'summary-outside-owned-root' {
            Assert-Task23SummaryPaths @{captureManifest=(Join-Path (Split-Path $out -Parent) 'outside.json');actualCalls=$path} $result $out
        } 'T23_OUTPUT_OUTSIDE_OWNED_ROOT'
        BoundaryCase 'summary-relative-path' {
            Assert-Task23SummaryPaths @{captureManifest='owned.json';actualCalls=$path} $result $out
        } 'T23_OUTPUT_PATH_REQUIRED'
        $junction=Join-Path ([IO.Path]::GetPathRoot($out)) 'Documents and Settings'
        BoundaryCase 'summary-reparse-path' {
            $reparse=Join-Path $junction 'owned.json'
            Assert-Task23SummaryPaths @{captureManifest=$reparse;actualCalls=$reparse} @{captureManifest=$reparse;actualCalls=$reparse} ([IO.Path]::GetPathRoot($out))
        } 'T22_UNSAFE_REPARSE_PATH'
        BoundaryCase 'equivalent-path-changed-hash' {
            ReadJson (OwnedPath $path $out) | Out-Null
            [IO.File]::WriteAllText($path,'{"schema":2}')
            ReadJson (OwnedPath $path.Replace('\','/').ToUpperInvariant() $out)
        } 'T22_ARTIFACT_CHANGED_BETWEEN_READS'
        [IO.File]::WriteAllText($path,'{"schema":1}')
        BoundaryCase 'equivalent-path-changed-length' {
            ReadJson (OwnedPath $path $out) | Out-Null
            [IO.File]::AppendAllText($path,' ')
            ReadJson (OwnedPath $path.Replace('\','/') $out)
        } 'T22_ARTIFACT_CHANGED_BETWEEN_READS'
        return
    }
    $data=[IO.File]::ReadAllBytes($NativeTerminalFixture)
    if ($data.Length -le $limits.jsonFile) { throw 'T22_TERMINAL_FIXTURE_NOT_OVER_64K' }
    $path=Join-Path $out 'terminal.json'
    [IO.File]::WriteAllBytes($path,$data)
    BoundaryCase 'native-terminal-over-64k' { ReadJson $path -NativeTerminal }
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($data)
    [IO.File]::WriteAllText($path,$text+(' '*($limits.jsonTotal-$data.Length)),[Text.UTF8Encoding]::new($false))
    BoundaryCase 'native-terminal-exact-batch-bound' { ReadJson $path -NativeTerminal }
    [IO.File]::AppendAllText($path,' ',[Text.UTF8Encoding]::new($false))
    BoundaryCase 'native-terminal-just-over-bound' { ReadJson $path -NativeTerminal } 'T22_FILE_SIZE_LIMIT'
    [IO.File]::WriteAllText($path,' '*65537,[Text.UTF8Encoding]::new($false))
    BoundaryCase 'ordinary-json-over-64k' { ReadJson $path } 'T22_FILE_SIZE_LIMIT'
    # Deterministic growth at the stat/open boundary, not a timing race. The
    # actual reader body keeps both guards; only this negative fixture adds a
    # write immediately before Open so the opened-length guard must reject it.
    $anchor='$stream = [IO.File]::Open'
    if ($readers.ReadArtifact.Split(@($anchor),[StringSplitOptions]::None).Count -ne 2) { throw 'T22_OPEN_ANCHOR_DRIFT' }
    $race=$readers.ReadArtifact.Replace('function ReadArtifact(','function ReadArtifactOpenedRace(').
        Replace($anchor,'[IO.File]::WriteAllBytes($path,[byte[]]::new([int]($maximum+1)))'+"`n    "+$anchor)
    Invoke-Expression $race
    [IO.File]::WriteAllText($path,'{}')
    BoundaryCase 'opened-length-over-bound' { ReadArtifactOpenedRace $path 65536 'opened-length-negative-fixture' } 'T22_FILE_SIZE_LIMIT'
    [IO.File]::WriteAllBytes($path,$data)
    BoundaryCase 'repeated-artifact-identity' {
        ReadJson $path -NativeTerminal | Out-Null
        [IO.File]::AppendAllText($path,' ')
        ReadJson $path -NativeTerminal
    } 'T22_ARTIFACT_CHANGED_BETWEEN_READS'
    [IO.File]::WriteAllText($path,'{"mode":"task15-candidate","MODE":"task15-candidate"}')
    BoundaryCase 'terminal-duplicate-key' { ReadJson $path -NativeTerminal } 'T22_DUPLICATE_JSON_KEY'
    [IO.File]::WriteAllText($path,'{"values":['+((@('0')*513)-join ',')+']}')
    BoundaryCase 'terminal-array-bound' { ReadJson $path -NativeTerminal } 'T22_JSON_ARRAY_LIMIT'
    [IO.File]::WriteAllText($path,'{"value":"'+('a'*2049)+'"}')
    BoundaryCase 'terminal-string-bound' { ReadJson $path -NativeTerminal } 'T22_JSON_STRING_LIMIT'
    [IO.File]::WriteAllText($path,('{"nested":'*17)+'0'+('}'*17))
    BoundaryCase 'terminal-depth-bound' { ReadJson $path -NativeTerminal } 'T22_MALFORMED_JSON'
    $script:rootPrefix=$out.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    BoundaryCase 'reference-escape' { Reference $out '../outside.json' } 'T22_UNSAFE_REFERENCE'
    $junction=Join-Path ([IO.Path]::GetPathRoot($out)) 'Documents and Settings'
    BoundaryCase 'reparse-path' { CheckPath (Join-Path $junction 'terminal.json') } 'T22_UNSAFE_REPARSE_PATH'
    $invalid=$text | ConvertFrom-Json -AsHashtable -Depth 16
    $invalid.actualDisposals--
    SaveJson $path $invalid
    BoundaryCase 'native-handle-cardinality' { ReadJson $path -NativeTerminal } 'T22_NATIVE_TERMINAL_CARDINALITY'
    $invalid.actualDisposals++
    $invalid.population[1].identity=$invalid.population[0].identity
    SaveJson $path $invalid
    BoundaryCase 'native-duplicate-identity' { ReadJson $path -NativeTerminal } 'T22_NATIVE_TERMINAL_IDENTITY'
    [IO.File]::WriteAllBytes($path,$data)
    BoundaryCase 'terminal-cumulative-budget' {
        $script:jsonBytes=$limits.jsonTotal-$data.Length+1
        ReadJson $path -NativeTerminal
    } 'T22_JSON_TOTAL_LIMIT'
    $budget=@{reservationBytes=134217728L;retainedBeforeBytes=75497472L;ceilingBytes=268435456L}
    $summary=@{retainedRawBytes=1310720L;metadataReservationBytes=131072L;retainedReservationBytes=134217728L}
    BoundaryCase 'shared-reservation-once' {
        $debit=Get-Task23RetainedDebit $summary 1310720 $budget.reservationBytes
        $actual=Assert-Task23RetainedDebits $budget @($debit,$debit) 12308883
        if ($actual -ne 2883584) { throw 'T22_WRONG_RETAINED_DEBIT' }
    }
    BoundaryCase 'actual-debits-exceed-shared-cap' {
        Assert-Task23RetainedDebits $budget @(67108864L,67108865L) 12308883
    } 'T23_ACTUAL_RETAINED_BUDGET_REFUSED'
    BoundaryCase 'physical-debit-exceeds-shared-cap' {
        Assert-Task23RetainedDebits $budget @(1441792L,1441792L) 134217729
    } 'T23_ACTUAL_RETAINED_BUDGET_REFUSED'
    BoundaryCase 'root-ceiling-exceeded' {
        Assert-Task23RetainedDebits @{reservationBytes=134217728L;retainedBeforeBytes=268435455L;ceilingBytes=268435456L} @(2L) 2
    } 'T23_ACTUAL_RETAINED_BUDGET_REFUSED'
    BoundaryCase 'shared-cap-mismatch' { Get-Task23RetainedDebit $summary 1310720 67108864 } 'T23_SHARED_RESERVATION_MISMATCH'
    . "$PSScriptRoot/Task23TypedCalls.ps1"
    $callsPath=Join-Path (Split-Path $NativeTerminalFixture -Parent) 'actual-calls.jsonl'
    $sourceInputs.Add((Identity $callsPath 'unchanged-real-provider-result-fixture'))
    $calls=@(Get-Content -LiteralPath $callsPath | Where-Object {$_.Trim()} | ConvertFrom-Json -AsHashtable)
    $loops=@($pair.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and
        $n.Variable.Extent.Text -ceq '$operation' -and $n.Condition.Extent.Text -ceq '$typed.operations'},$true))
    if ($loops.Count -ne 1) { throw 'T22_PROVIDER_RESULT_LOOP_DRIFT' }
    BoundaryCase 'real-failed-create-retained' {
        $typed=ConvertTo-Task23TypedOperations $calls
        $script:findings=[Collections.Generic.List[string]]::new()
        Invoke-Expression $loops[0].Extent.Text
        if ($findings.Count -or $typed.createCount -ne 2 -or $typed.successfullyCreatedFeatures -ne 1 -or
            $typed.evaluateCount -ne 7 -or $typed.operations[0].result -ne 3134193675) { throw 'T22_CREATE_RESULT_LOST' }
    }
    BoundaryCase 'failed-evaluation-still-refused' {
        $typed=ConvertTo-Task23TypedOperations $calls
        $typed.operations[-1].result=3134193675
        $script:findings=[Collections.Generic.List[string]]::new()
        Invoke-Expression $loops[0].Extent.Text
        if ($findings.Count -ne 1 -or $findings[0] -cne 'actual-provider-result') { throw 'T22_EVALUATE_RESULT_NOT_REFUSED' }
    }
}
try {
    $sourceInputs.Add((Identity $AnalyzerPath 'current-offline-analyzer'))
    $sourceInputs.Add((Identity $PSCommandPath 'current-analysis-fixture-runner'))
    $sourceInputs.Add((Identity "$repo/tests/run_nr_mfg_diagnostics.ps1" 'current-dispatcher'))
    $sourceInputs.Add((Identity $native 'actual-pwsh-native-runtime'))
    if ($BoundaryOnly -or $PathBoundaryOnly) { BoundaryFixtures; $passed=$true; return }
    Case 'no-input' '' 'InsufficientData'
    Case 'not-reproduced' (Fixture 'not-reproduced') 'NotReproduced'
    Case 'provider-counters-only' (Fixture 'provider-counters-only') 'NotReproduced'
    Case 'raw-content-change' (Fixture 'raw-content-change' 96 96) 'NotReproduced'
    Case 'descriptive-phase-content-anomaly' (Fixture 'descriptive-phase-content-anomaly' 64 96) 'ProviderHypothesisOnly'
    Case 'provider-only-hypothesis' (Fixture 'provider-only-hypothesis' 64 128) 'ProviderHypothesisOnly'
    $root=Fixture 'nr-exposure-variation' 64 96
    EditJson "$root/frame-1/capture.json" {param($record) $record.preExposureRawBits=1073741824;$record.resolvedPreExposureBits=1073741824}
    BindContext $root
    EditJson "$root/analysis-synthetic.json" {param($record) $record.frames[1].nr.signature='SYNTHETIC-NR-changed-settings'}
    Case 'nr-exposure-variation' $root 'NotReproduced'
    foreach ($kind in @('private-failure','composition-failure')) {
        $root=Fixture ('known-host-'+$kind)
        HostContract $root $kind ''
        Case ('known-host-'+$kind) $root 'OptiScalerDefect'
    }
    foreach ($control in @('off','neutral')) {
        $root=Fixture ('known-host-'+$control)
        HostContract $root 'private-failure' $control
        Case ('known-host-'+$control) $root 'NotReproduced'
    }
    $root=Fixture 'mismatched-artifact'
    $data=[IO.File]::ReadAllBytes("$root/frame-1/nr_output.raw");$data[0]=97
    [IO.File]::WriteAllBytes("$root/frame-1/nr_output.raw",$data)
    Case 'mismatched-artifact' $root 'InsufficientData'
    $root=Fixture 'padding-only-change'
    $data=[IO.File]::ReadAllBytes("$root/frame-1/nr_output.raw");$data[255]=97
    [IO.File]::WriteAllBytes("$root/frame-1/nr_output.raw",$data)
    BindContext $root
    Case 'padding-only-change' $root 'NotReproduced'
    foreach ($missing in @('phase','timing','observer','exposure','capture')) {
        $root=Fixture ('missing-'+$missing)
        switch ($missing) {
            'phase' {EditJson "$root/analysis-synthetic.json" {param($record) $record.frames[1].Remove('declaredPhase') | Out-Null}}
            'timing' {EditJson "$root/analysis-synthetic.json" {param($record) $record.frames[1].Remove('displayTimeMs') | Out-Null}}
            'observer' {[IO.File]::Delete("$root/mfg-preflight.json")}
            'exposure' {EditJson "$root/frame-1/capture.json" {param($record) $record.exposureProvenanceKnown=$false};BindContext $root}
            'capture' {[IO.File]::Delete("$root/frame-1/capture.json")}
        }
        Case ('missing-'+$missing) $root 'InsufficientData'
    }
    $root=Fixture 'raw-index-only'
    [IO.File]::Delete("$root/analysis-synthetic.json")
    Case 'raw-index-only' $root 'InsufficientData'
    $root=Fixture 'short-image'
    [IO.File]::WriteAllBytes("$root/frame-1/nr_output.raw",[byte[]]::new(255))
    Case 'short-image' $root 'InsufficientData'
    $root=Fixture 'malformed-json'
    [IO.File]::WriteAllText("$root/frame-0/capture.json",'{bad')
    Case 'malformed-json' $root '' 'T22_MALFORMED_JSON'
    $root=Fixture 'duplicate-key'
    [IO.File]::WriteAllText("$root/capture-session.json",'{"schema":1,"schema":1}')
    Case 'duplicate-key' $root '' 'T22_DUPLICATE_JSON_KEY'
    $root=Fixture 'unsafe-reference'
    EditJson "$root/frame-0/capture.json" {param($record) $record.observerReference='../../outside-sentinel.json'}
    [IO.File]::WriteAllText("$out/outside-sentinel.json",'{"mustNeverBeRead":true}')
    Case 'unsafe-reference' $root '' 'T22_UNSAFE_REFERENCE'
    $root=Fixture 'absolute-reference'
    EditJson "$root/frame-0/capture.json" {param($record) $record.observerReference="$out/outside-sentinel.json"}
    Case 'absolute-reference' $root '' 'T22_UNSAFE_REFERENCE'
    $root=Fixture 'forged-pixel-origin'
    EditJson "$root/frame-0/capture.json" {param($record) $record.images[0].pixelOrigin='provider_generated'}
    Case 'forged-pixel-origin' $root '' 'T22_UNPROVEN_PIXEL_ORIGIN'
    $root=Fixture 'forged-synthetic-origin'
    EditJson "$root/analysis-synthetic.json" {param($record) $record.synthetic=$false;$record.provenance='Crimson Desert'}
    Case 'forged-synthetic-origin' $root '' 'T22_SYNTHETIC_PROVENANCE_REQUIRED'
    $root=Fixture 'roi-over-limit'
    EditJson "$root/frame-0/capture.json" {param($record) $record.images[0].width=257}
    Case 'roi-over-limit' $root '' 'T22_INVALID_NUMBER_width'
    $root=Fixture 'frame-over-limit'
    foreach ($number in 2..64) {[IO.Directory]::CreateDirectory("$root/frame-$number") | Out-Null}
    Case 'frame-over-limit' $root '' 'T22_FRAME_LIMIT'
    $root=Fixture 'image-over-limit'
    EditJson "$root/frame-0/capture.json" {param($record) $record.images=@($record.images[0])*9}
    Case 'image-over-limit' $root '' 'T22_IMAGE_LIMIT'
    $root=Fixture 'json-over-limit'
    [IO.File]::WriteAllText("$root/capture-session.json",' '*65537)
    Case 'json-over-limit' $root '' 'T22_FILE_SIZE_LIMIT'
    $root=Fixture 'event-over-limit'
    EditJson "$root/analysis-synthetic.json" {param($record) $record.events=@(0)*513}
    Case 'event-over-limit' $root '' 'T22_JSON_ARRAY_LIMIT'
    $root=Fixture 'raw-over-limit'
    [IO.File]::WriteAllBytes("$root/frame-0/nr_input.raw",[byte[]]::new(1048577))
    Case 'raw-over-limit' $root '' 'T22_FILE_SIZE_LIMIT'
    $root=Fixture 'session-readback-over-limit'
    EditJson "$root/capture-session.json" {param($record) $record.peakReadbackBytes=33554433}
    Case 'session-readback-over-limit' $root '' 'T22_INVALID_NUMBER_peakReadbackBytes'
    $root=Fixture 'session-retained-over-limit'
    EditJson "$root/capture-session.json" {param($record) $record.retainedReservationBytes=268435457}
    Case 'session-retained-over-limit' $root '' 'T22_INVALID_NUMBER_retainedReservationBytes'
    $root=Fixture 'input-depth-over-limit'
    [IO.Directory]::CreateDirectory("$root/frame-0/nested") | Out-Null
    Case 'input-depth-over-limit' $root '' 'T22_INPUT_DEPTH_LIMIT'
    if ($AnalysisInputRoot) { Case 'actual-current-task21' ([IO.Path]::GetFullPath($AnalysisInputRoot)) 'InsufficientData' }
    if (!$SkipMutations -and (!$OnlyCase -or $OnlyMutation)) {
        $source=[IO.File]::ReadAllText($AnalyzerPath)
        $mutations=@(
            @{name='wrong-defect-class';anchor="$"+"report.outcome='OptiScalerDefect'";replacement="$"+"report.outcome='NotReproduced'";case='known-host-private-failure'},
            @{name='ignored-artifact-mismatch';anchor='if (!$complete -or $mismatches.Count -gt 0)';replacement='if (!$complete)';case='mismatched-artifact'},
            @{name='relaxed-frame-bound';anchor='frames=64;';replacement='frames=65;';case='frame-over-limit'},
            @{name='ignored-pixel-origin';anchor="if (`$image.pixelOrigin -cne 'owned_nr_surface' -or !`$image.rawResource)";replacement='if (!$image.rawResource)';case='forged-pixel-origin'},
            @{name='counter-as-defect';anchor="`$values.applied -eq '1' -and";replacement="`$values.applied -in @('0','1') -and";case='known-host-off'},
            @{name='neutral-as-defect';anchor=' $values.scratch -cne $values.original -and $values.application -cne $contract.expectedApplicationPixel';replacement=' $true';case='known-host-neutral'}
        )
        foreach ($mutation in $mutations) {
            if ($OnlyMutation -and $OnlyMutation -cne $mutation.name) { continue }
            if (($source.Split(@($mutation.anchor),[StringSplitOptions]::None).Count-1) -ne 1) { throw 'T22_MUTATION_ANCHOR_DRIFT' }
            $mutant=Join-Path $out ('mutant-'+$mutation.name+'.ps1')
            [IO.File]::WriteAllText($mutant,$source.Replace($mutation.anchor,$mutation.replacement),[Text.UTF8Encoding]::new($false))
            $child=Native @('-NoProfile','-File',$PSCommandPath,'-EvidenceRoot',$out,'-AnalyzerPath',$mutant,'-OnlyCase',$mutation.case,'-SkipMutations') ('control-'+$mutation.name)
            $rows.Add(@{scenario='mutation-'+$mutation.name;command=$child.command;exit=$child.exit;log=$child.log;
                mutationSource=$mutant;expected='native nonzero named oracle failure';passed=($child.exit -ne 0 -and $child.text -match ('T22_(WRONG_CLASS|EXPECTED_REJECTION)_'+[regex]::Escape($mutation.case)))})
            if (!$rows[$rows.Count-1].passed) { throw "T22_NEGATIVE_SENSITIVITY_NOT_PROVEN_$($mutation.name)" }
            Write-Host "T22_CONTROL=$($mutation.name) native=$($child.exit) PASS"
        }
    }
    $passed=$true
} finally {
    SaveJson "$out/result.json" @{schema='task22-analysis-proof-v1';passed=$passed;rows=$rows.ToArray();inputSources=$sourceInputs.ToArray();
        children=$nativeChildren.ToArray();cpuOnly=$true;gpuCommands=0;compilerCommands=0;processCensusCommands=0;
        retainedHistoricalFailuresNotReplayed=$true;output=$out;actualInput=$AnalysisInputRoot;
        ownedResourceClosure=@{allChildProcessesTerminal=(@($nativeChildren | Where-Object {$null -eq $_.exit}).Count -eq 0);
            nativeProcessObjectsDisposed=$true;createdWindows=0;gpuResources=0;temporaryMappings=0;foreignProcessActions=0}}
    Write-Host "T22_PROOF=$out/result.json passed=$passed"
}
if (!$passed) { exit 1 }
