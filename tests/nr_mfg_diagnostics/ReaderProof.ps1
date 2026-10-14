#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [Parameter(Mandatory=$true)][ValidateSet('PreFix','Repair')][string]$Phase)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out=Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ($Phase.ToLowerInvariant()+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[IO.Directory]::CreateDirectory($out) | Out-Null
$native=(Get-Command pwsh.exe).Source
$analyzer=Join-Path $PSScriptRoot 'Analyze.ps1'
$source=[IO.File]::ReadAllText($analyzer)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw 'T22_READER_SOURCE_PARSE_ERROR'}
$functions=@{}
foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {$functions[$function.Name]=$function.Extent.Text}
$limits=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$limits'},$true))
if ($limits.Count -ne 1) {throw 'T22_READER_LIMITS_EXTRACTION_DRIFT'}
$initialization=$limits[0].Extent.Text+"`n"+'$bindings = [Collections.Generic.List[object]]::new()'+"`n"+'$seen = @{}'+"`n"+'$totalBytes = 0L'+"`n"
$helpers=@($functions.Fail,$functions.Hash,$functions.CheckPath) -join "`n"
$reader=$functions.ReadArtifact
function Hash([string]$text) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [Convert]::ToHexString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))} finally {$algorithm.Dispose()}
}
function Identity([string]$path) {return @{path=$path;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash}}
function ReplaceOne([string]$text,[string]$anchor,[string]$replacement) {
    if (($text.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) {throw 'T22_READER_MUTATION_OR_INJECTION_ANCHOR_DRIFT'}
    return $text.Replace($anchor,$replacement)
}
function Emit([string]$name,[string]$body,[bool]$stage=$false) {
    $exactBody=$body
    if ($stage) {
        $anchor='    $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)'
        $body=ReplaceOne $body $anchor ('    Invoke-ReaderStatOpenTransition $path $file.Length'+"`n"+$anchor)
    }
    $path=Join-Path $out ($name+'.ps1')
    $emitted=$initialization+$helpers+"`n"+$body+"`n"
    [IO.File]::WriteAllText($path,$emitted,[Text.UTF8Encoding]::new($false))
    $script:generated.Add(@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;
        extractedReaderBodySha256=(Hash $exactBody);emittedReaderBodySha256=(Hash $body);helpersSha256=(Hash $helpers);
        actualProductionLimitsSha256=(Hash $limits[0].Extent.Text);singleStatOpenCallback=$stage;
        soleInjection='Invoke-ReaderStatOpenTransition $path $file.Length before actual File.Open; no production hook or mocked read';
        currentSourceBodyExact=($exactBody -ceq $reader)})
    return $path
}
$rows=[Collections.Generic.List[object]]::new()
$children=[Collections.Generic.List[object]]::new()
$generated=[Collections.Generic.List[object]]::new()
$passed=$false
function Run([string]$name,[string]$scenario,[string]$readerPath,[int]$expectedExit,[string]$oracle='') {
    $caseRoot=Join-Path $out $name
    $arguments=@('-NoProfile','-File',"$PSScriptRoot/ReaderFixture.ps1",'-ReaderSource',$readerPath,'-EvidenceRoot',$caseRoot,'-Scenario',$scenario)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$native;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$out
    foreach ($argument in $arguments) {$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $id=$null;$code=$null;$timedOut=$false
    try {
        if (!$process.Start()) {throw 'T22_READER_NATIVE_START_FAILED'}
        $id=$process.Id
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) {$timedOut=$true;$process.Kill($true);$process.WaitForExit()}
        $code=$process.ExitCode
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        $log=Join-Path $out ($name+'.log')
        [IO.File]::WriteAllText($log,$text,[Text.UTF8Encoding]::new($false))
    } finally {$process.Dispose();$children.Add(@{pid=$id;exit=$code;timeout=$timedOut;ownedOnly=$true;processObjectDisposed=$true})}
    $row=@{scenario=$scenario;case=$name;command=@($native)+$arguments;exit=$code;expectedExit=$expectedExit;log=$log;
        expectedOracle=$oracle;fixtureReceipt="$caseRoot/fixture-result.json";reader=$readerPath;passed=$false;
        helperFixture=$true;fullAnalyzerCli=$false}
    $rows.Add($row)
    if ($timedOut -or $code -ne $expectedExit -or ($oracle -and $text -notmatch [regex]::Escape($oracle))) {throw "T22_READER_PROOF_FAILED_$name"}
    if ($code -eq 0 -and !(Get-Content -LiteralPath $row.fixtureReceipt -Raw | ConvertFrom-Json).passed) {throw 'T22_READER_ZERO_EXIT_WITHOUT_OBSERVABLE'}
    $row.passed=$true
    Write-Host "T22_READER_CASE=$name native=$code PASS"
}
try {
    if ($Phase -eq 'PreFix') {
        if ((Get-FileHash -LiteralPath $analyzer).Hash -cne 'EFDC5B6A29B65F5215FE3044EF69D4528B2CAD691F6E1752979F5C5364FB0717') {throw 'T22_PREFIX_NOT_ORIGINAL_ANALYZER'}
        Run 'old-stat-open-growth' 'stat-open-growth' (Emit 'old-reader-stage' $reader $true) 1 'T22_READER_ORACLE_B1_TOTAL_GROWTH_REFUSAL_REQUIRED'
        Run 'old-equal-length-change' 'equal-length-change' (Emit 'old-reader' $reader) 1 'T22_READER_ORACLE_B2_EQUAL_LENGTH_REFUSAL_REQUIRED'
    } else {
        $plain=Emit 'current-reader' $reader
        Run 'stable-first-repeat' 'stable-first-repeat' $plain 0
        Run 'equal-length-change' 'equal-length-change' $plain 0
        Run 'length-change' 'length-change' $plain 0
        Run 'stat-open-growth' 'stat-open-growth' (Emit 'current-reader-stage' $reader $true) 0
        $totalAnchor="        if (!`$seen.ContainsKey(`$path) -and `$openedLength -gt `$limits.retained - `$script:totalBytes) { Fail 'TOTAL_READ_LIMIT' }"
        $badTotal=ReplaceOne $reader $totalAnchor ''
        Run 'negative-missing-opened-total-guard' 'stat-open-growth' (Emit 'mutant-opened-total-stage' $badTotal $true) 1 'T22_READER_ORACLE_B1_TOTAL_GROWTH_REFUSAL_REQUIRED'
        $repeatAnchor="        if (`$data.Length -ne `$seen[`$path].bytes -or `$sha -cne `$seen[`$path].sha256) { Fail 'ARTIFACT_CHANGED_BETWEEN_READS' }"
        $badRepeat=ReplaceOne $reader $repeatAnchor ''
        Run 'negative-missing-repeat-identity-guard' 'equal-length-change' (Emit 'mutant-repeat-identity' $badRepeat) 1 'T22_READER_ORACLE_B2_EQUAL_LENGTH_REFUSAL_REQUIRED'
    }
    $passed=$true
} finally {
    @{schema='task22-reader-proof-v1';phase=$Phase;passed=$passed;behaviorAccepted=($passed -and $Phase -eq 'Repair');
        output=$out;rows=$rows.ToArray();sources=@((Identity $analyzer),(Identity $PSCommandPath),(Identity "$PSScriptRoot/ReaderFixture.ps1"),(Identity $native));
        generatedBodies=$generated.ToArray();readerBodySha256=(Hash $reader);children=$children.ToArray();
        gpuCommands=0;compilerCommands=0;processCensusCommands=0;foreignActions=0;
        resourceClosure=@{allChildNativeExitsObserved=(@($children | Where-Object {$null -eq $_.exit}).Count -eq 0);
            allProcessObjectsDisposed=$true;createdWindows=0;watchers=0;temporaryMappings=0;gpuResources=0};
        qualification='Real shared reader and helpers extracted byte-exactly; stage-derived growth fixture adds exactly one verified stat/open callback. Not a new full analyzer CLI/classification run.'} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$out/result.json" -Encoding utf8
    Write-Host "T22_READER_PROOF=$out/result.json passed=$passed"
}
