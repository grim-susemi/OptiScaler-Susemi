param(
    [Parameter(Mandatory)][ValidateSet('Cpu','Warp','Runtime')][string]$Phase,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$RuntimeSha256,
    [Parameter(Mandatory)][string]$SourceManifest,
    [string]$GpuAdmissionReceipt,
    [string]$GpuAdmissionSha256,
    [switch]$Task15Candidate,
    [ValidateSet('B00','R01','U02','P03','R04','R05','U06','P07','H08','H09','H10','H11')][string]$RuntimeCase = 'B00',
    [string]$FinalCandidate,
    [string]$BudgetReceipt,
    [string]$BudgetSha256,
    [ValidateSet('off','on')][string]$DiagnosticPair
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$root = [IO.Path]::GetFullPath($EvidenceRoot)
$expectedRoot = Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'
if (!$root.StartsWith($expectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Host artifacts must remain in current task-owned evidence'
}
$exe = Join-Path (Resolve-Path -LiteralPath $CandidateRoot).Path 'NRAddonHost.exe'
$hostHash = (Get-FileHash -LiteralPath $exe).Hash
$manifestPath = (Resolve-Path -LiteralPath $SourceManifest).Path
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($Task15Candidate) {
    if ($Phase -eq 'Warp') { throw 'HOST_CASE_MODE_UNSUPPORTED' }
    $suffix = if ($DiagnosticPair) { "-$DiagnosticPair" } else { '' }
    $resultReceipt = Join-Path $root "task15-result-$Phase-$RuntimeCase$suffix.json"
    if (Test-Path -LiteralPath $resultReceipt) { throw 'HOST_TASK15_RESULT_NOT_FRESH' }
    if ($manifest.schema -ne 1 -or $manifest.kind -cne 'task15AffectedHostManifest' -or
        $manifest.host.sha256 -ne $hostHash -or [IO.Path]::GetFullPath($manifest.host.path) -ine $exe -or
        $manifest.finalCandidate.sha256 -cne '02CB71546ECB2EA1525F4EA07DC65ADBE344B4C0787464F503FD6C00F7B71C84' -or
        $manifest.finalCandidate.bytes -ne 27289088 -or
        $manifest.shaderArraySha256 -cne '8DD859A3EB0447DD85B5AB3021218B4865FC1E3021B94D209F95356EBBD0AE67' -or
        $manifest.processingAssociations.commonSourceCount -ne 51 -or
        !$manifest.qualifiedUnchanged -or !$manifest.affectedUnits -or !$manifest.nativeController.path -or
        !$manifest.linkReceipt -or !$manifest.nativeClosureReceipt) { throw 'HOST_QUALIFIED_INPUTS_SCHEMA' }
    if (!$FinalCandidate -or [IO.Path]::GetFullPath($FinalCandidate) -ine [IO.Path]::GetFullPath($manifest.finalCandidate.path) -or
        (Get-Item -LiteralPath $FinalCandidate).Length -ne $manifest.finalCandidate.bytes -or
        (Get-FileHash -LiteralPath $FinalCandidate).Hash -ne $manifest.finalCandidate.sha256) {
        throw 'HOST_FINAL_CANDIDATE_IDENTITY_MISMATCH'
    }
    $current = @{}
    foreach ($unit in $manifest.affectedUnits) {
        foreach ($binding in @($unit.source)+@($unit.dependencies)+@($unit.object)+@($unit.commandReceipt)) {
            if (!$binding.PSObject.Properties['path'] -or !$binding.PSObject.Properties['sha256'] -or
                !$binding.path -or !$binding.sha256) { throw 'HOST_AFFECTED_INPUTS_INCOMPLETE' }
            if ($current.ContainsKey($binding.path)) {
                if ($current[$binding.path] -ne $binding.sha256) { throw 'HOST_AFFECTED_INPUTS_CONFLICT' }
            } else {
                if ($binding.PSObject.Properties['qualification'] -and
                    $binding.qualification -ceq 'accepted hash reused on exact affected dependency stat') {
                    $file = Get-Item -LiteralPath $binding.path
                    $epoch = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc).Ticks
                    $write = ([decimal]($file.LastWriteTimeUtc.Ticks-$epoch)*100).ToString('0',[Globalization.CultureInfo]::InvariantCulture)
                    if ($file.Length -ne $binding.bytes -or $write -cne $binding.currentLastWriteUnixNs) { throw 'HOST_AFFECTED_INPUTS_STALE' }
                } elseif ((Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256) { throw 'HOST_AFFECTED_INPUTS_STALE' }
                $current[$binding.path] = $binding.sha256
            }
        }
    }
    foreach ($binding in @($manifest.nativeController)+@($manifest.linkReceipt)+@($manifest.nativeClosureReceipt)) {
        if ((Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256) { throw 'HOST_AFFECTED_INPUTS_STALE' }
    }
    foreach ($binding in $manifest.scriptBindings) {
        if ((Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256) { throw 'HOST_AFFECTED_INPUTS_STALE' }
    }
    . "$PSScriptRoot/GpuAdmission.ps1"
    $purpose = if ($DiagnosticPair) { 'task23-diagnostic-pair' } else { 'task15-matrix' }
    $budget = AssertTask15Budget -Receipt $BudgetReceipt -ReceiptSha256 $BudgetSha256 -Purpose $purpose -StructureOnly:($Phase -eq 'Cpu')
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
    $admission = @{
        Receipt=$GpuAdmissionReceipt;ReceiptSha256=$GpuAdmissionSha256;HostSha256=$hostHash;
        ManifestSha256=$manifestHash;FinalCandidateSha256=$manifest.finalCandidate.sha256;
        RuntimeSha256=$RuntimeSha256;BudgetSha256=$BudgetSha256;RuntimeCase=$RuntimeCase;
        Purpose=$purpose;DiagnosticPair=$DiagnosticPair
    }
    if ($Phase -eq 'Runtime') { $null = AssertTask15GpuAdmission @admission }
    $out = Join-Path $root ('task15-' + $Phase.ToLowerInvariant() + '-' + $RuntimeCase + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $out | Out-Null
    $arguments = @($(if ($Phase -eq 'Cpu') {'--host-contracts'} else {'--runtime'}),
        '--headless','--task15-candidate','--runtime-case',$RuntimeCase,'--fixture-root',$out,
        '--candidate',$exe,'--candidate-sha256',$hostHash,
        '--runtime-root',[IO.Path]::GetFullPath($RuntimeRoot),'--runtime-sha256',$RuntimeSha256,
        '--final-candidate',[IO.Path]::GetFullPath($FinalCandidate),'--final-candidate-sha256',$manifest.finalCandidate.sha256,
        '--qualified-inputs',$manifestPath,'--qualified-inputs-sha256',$manifestHash,
        '--retained-bytes',[string]$budget.retainedBeforeBytes,'--reservation-bytes',[string]$budget.reservationBytes)
    if ($DiagnosticPair) { $arguments += @('--diagnostic-pair',$DiagnosticPair) }
    if ($Phase -eq 'Runtime') {
        $release = Get-Content -LiteralPath $GpuAdmissionReceipt -Raw | ConvertFrom-Json
        $driver = $release.rootRelease.driverAssociation
        $arguments += @('--driver',$driver.path,'--driver-sha256',$driver.sha256,
            '--adapter-luid-low',[string]$driver.adapterLuidLow,'--adapter-luid-high',[string]$driver.adapterLuidHigh)
    }
    $quoted = @($arguments | ForEach-Object { '"' + $_.Replace('"','\"').TrimEnd('\') + '"' })
    $command = '"' + $exe + '" ' + ($quoted -join ' ')
    $settingsPath = Join-Path $out 'native-settings.json'
    $settings = [ordered]@{
        mode='task15-candidate';evidenceRoot=$out;image=$exe;command=$command;cwd=$repo;
        trace="$out/native.trace.jsonl";stdout="$out/native.stdout.log";captureTerminal="$out/native.capture-terminal.json";
        controllerTrace="$out/native.controller-trace.jsonl";controllerTerminal="$out/native.controller-terminal.json";
        helperImage=$manifest.nativeController.path;captureBoundMs=240000;drainBoundMs=30000;controllerBoundMs=300000;
        requiresTechnicalRelease=$false;policy=@{enabled=$false}
    }
    $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    [ordered]@{schema=1;kind='task15PreLaunchRegistration';executable=$exe;argv=$arguments;cwd=$repo;
        command=$command;settings=$settingsPath;gpuRequested=($Phase -eq 'Runtime');purpose=$purpose;
        manifestSha256=$manifestHash;budgetSha256=$BudgetSha256} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$out/registration.json" -Encoding UTF8
    Write-Host "HOST_TASK15_COMMAND=$command"
    if ($Phase -eq 'Runtime') { $null = AssertTask15GpuAdmission @admission }
    & $manifest.nativeController.path --control $settingsPath
    $native = $LASTEXITCODE
    $capture = Get-Content -LiteralPath $settings.captureTerminal -Raw | ConvertFrom-Json
    $controller = Get-Content -LiteralPath $settings.controllerTerminal -Raw | ConvertFrom-Json
    if ($native -ne 0 -or $capture.primaryBuildExit -ne 0 -or !$capture.ownershipReconciled -or
        !$capture.ownedResourceClosure -or $capture.active -ne 0 -or $capture.numberOfProcessIdsInList -ne 0 -or
        $capture.remainingOwnedResources -ne 0 -or !$controller.ownedResourceClosure -or
        $controller.nativeProcessExit -ne 0 -or $controller.remainingOwnedResources -ne 0) { throw 'HOST_TASK15_NATIVE_CLOSURE_FAILED' }
    Get-Content -LiteralPath $settings.stdout | Write-Host
    $caseSummary = $null; $captureManifest = $null
    if ($Phase -eq 'Runtime') {
        $caseSummary = Join-Path $out 'case-summary.json'
        $summary = Get-Content -LiteralPath $caseSummary -Raw | ConvertFrom-Json
        $captureManifest = [IO.Path]::GetFullPath($summary.captureManifest)
        if ($summary.schema -ne 1 -or $summary.runtimeCase -cne $RuntimeCase -or
            $summary.applicationFrames -ne 8 -or $summary.retainedFrames -ne 1 -or $summary.retainedApplication -ne 8 -or
            $summary.ownedResourcesClosed -ne $true -or
            !$captureManifest.StartsWith($out + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
            !(Test-Path -LiteralPath $captureManifest -PathType Leaf)) { throw 'HOST_TASK15_CASE_OUTPUT_INVALID' }
    }
    [ordered]@{schema=1;kind='task15HostCaseResult';task=15;phase=$Phase;runtimeCase=$RuntimeCase;diagnosticPair=$DiagnosticPair;
        hostSha256=$hostHash;finalCandidateSha256=$manifest.finalCandidate.sha256;manifestSha256=$manifestHash;
        fixtureRoot=$out;registration="$out/registration.json";resultReceipt=$resultReceipt;
        caseSummary=$caseSummary;captureManifest=$captureManifest;captureSession=$(if($Phase -eq 'Runtime'){"$out/case-io/capture-session.json"}else{$null});
        actualCalls=$(if($Phase -eq 'Runtime'){"$out/actual-calls.jsonl"}else{$null});
        diagnosticObserver=$(if($DiagnosticPair -and $Phase -eq 'Runtime'){"$out/diagnostic-observer.json"}else{$null});
        command=$command;argv=$arguments;nativeExit=$native;captureTerminal=$settings.captureTerminal;
        controllerTerminal=$settings.controllerTerminal;gpuExecuted=($Phase -eq 'Runtime');task23Executed=$false} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultReceipt -Encoding UTF8
    Write-Host "HOST_TASK15_PASS=$Phase case=$RuntimeCase root=$out"
    return
}
if ($manifest.kind -ne 'candidateSourceManifest' -or $manifest.hostSha256 -ne $hostHash -or
    $manifest.candidateDllSha256 -ne $null -or $manifest.candidateDllState -ne 'unbuiltPendingTask14') {
    throw 'Current host/source boundary mismatch'
}
$currentBindings = @{}
function AssertCurrentBinding([string]$Path,[string]$Sha256) {
    if ($currentBindings.ContainsKey($Path)) {
        if ($currentBindings[$Path] -ne $Sha256) { throw "Conflicting current input binding: $Path" }
        return
    }
    if ((Get-FileHash -LiteralPath $Path).Hash -ne $Sha256) { throw "Current input changed: $Path" }
    $currentBindings[$Path] = $Sha256
}
foreach ($unit in $manifest.units) {
    foreach ($file in $unit.dependencies) {
        AssertCurrentBinding $file.path $file.sha256
    }
    AssertCurrentBinding $unit.object $unit.objectSha256
    AssertCurrentBinding $unit.dependencyReceipt $unit.dependencySha256
}
foreach ($library in $manifest.linkLibraries) { AssertCurrentBinding $library.path $library.sha256 }
AssertCurrentBinding $manifest.project $manifest.projectSha256
AssertCurrentBinding $manifest.actualPerObjectCommandCache $manifest.actualPerObjectCommandCacheSha256
AssertCurrentBinding $manifest.nativeDiagnosticLog $manifest.nativeDiagnosticLogSha256
AssertCurrentBinding $manifest.nativeBinlog $manifest.nativeBinlogSha256
foreach ($path in $currentBindings.Keys) {
    if ((Get-FileHash -LiteralPath $path).Hash -ne $currentBindings[$path]) { throw "Current input drift during validation: $path" }
}
if ($Phase -ne 'Cpu') {
    . "$PSScriptRoot/GpuAdmission.ps1"
    $admitted = AssertTask13GpuAdmission -Receipt $GpuAdmissionReceipt -ReceiptSha256 $GpuAdmissionSha256 -Phase $Phase `
        -HostSha256 $hostHash -ManifestSha256 (Get-FileHash -LiteralPath $manifestPath).Hash -RuntimeSha256 $RuntimeSha256
}
$out = Join-Path $root ('host-' + $Phase.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $out | Out-Null
$commands = @()
function InvokeCase([string]$Name, [string[]]$Arguments, [string]$ExpectedError) {
    $stdout = Join-Path $out ($Name + '.stdout.log')
    $stderr = Join-Path $out ($Name + '.stderr.log')
    $quoted = @($Arguments | ForEach-Object { '"' + $_.Replace('"','\"').TrimEnd('\') + '"' })
    Write-Host ('HOST_COMMAND=' + $exe + ' ' + ($quoted -join ' '))
    if ($Phase -ne 'Cpu') {
        $admitted = AssertTask13GpuAdmission -Receipt $GpuAdmissionReceipt -ReceiptSha256 $GpuAdmissionSha256 -Phase $Phase `
            -HostSha256 $hostHash -ManifestSha256 (Get-FileHash -LiteralPath $manifestPath).Hash -RuntimeSha256 $RuntimeSha256
    }
    $process = Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory $out -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $null = $process.Handle
    [ordered]@{case=$Name;nativePid=$process.Id;exe=$exe;arguments=$Arguments;startedUtc=[DateTimeOffset]::UtcNow.ToString('o');terminal=$false} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/$Name.started.json" -Encoding UTF8
    $process.WaitForExit()
    $exit = $process.ExitCode
    if ($null -eq $exit -or !$process.HasExited) { throw 'Native process terminal state is unavailable' }
    $output = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    $script:commands += [ordered]@{case=$Name;exe=$exe;arguments=$Arguments;nativePid=$process.Id;
        nativeExit=$exit;nativeTerminal=$process.HasExited;stdout=$stdout;stderr=$stderr;expectedError=$ExpectedError}
    Write-Host "HOST_NATIVE_EXIT=$exit case=$Name pid=$($process.Id) terminal=$($process.HasExited)"
    $process.Dispose()
    Write-Host $output
    if ($ExpectedError) {
        if (!$exit -or $output -notmatch ('HOST_ERROR=' + [regex]::Escape($ExpectedError) + '(\r?\n|$)')) {
            throw "Contract did not reject with exact named error: $Name"
        }
    } elseif ($exit) { throw "Native host failed: $Name" }
}
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
try {
    Write-Host "HOST_RUN_ROOT=$out"
    $base = @('--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash,
        '--runtime-root',[IO.Path]::GetFullPath($RuntimeRoot),'--runtime-sha256',$RuntimeSha256)
    if ($Phase -eq 'Cpu') {
        $tinyRoot = Join-Path $out 'malformed-runtime'
        New-Item -ItemType Directory -Path $tinyRoot | Out-Null
        $tiny = Join-Path $tinyRoot 'nvngx_dlssnr.dll'
        [IO.File]::WriteAllBytes($tiny,[byte[]]@(0,1,2,3))
        $tinyHash = (Get-FileHash -LiteralPath $tiny).Hash
        $exportRoot = Join-Path $out 'missing-export-runtime'
        New-Item -ItemType Directory -Path $exportRoot | Out-Null
        $exportFile = Join-Path $exportRoot 'nvngx_dlssnr.dll'
        $pe = New-Object byte[] 512
        $pe[0]=0x4D; $pe[1]=0x5A; $pe[0x3C]=0x80; $pe[0x80]=0x50; $pe[0x81]=0x45
        $pe[0x84]=0x64; $pe[0x85]=0x86; $pe[0x94]=0xF0; $pe[0x98]=0x0B; $pe[0x99]=0x02; $pe[0x104]=16
        [IO.File]::WriteAllBytes($exportFile,$pe)
        $exportHash = (Get-FileHash -LiteralPath $exportFile).Hash
        $zeroHash = '0' * 64
        InvokeCase 'absent-runtime' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash) 'HOST_RUNTIME_MISSING'
        InvokeCase 'wrong-candidate-identity' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$zeroHash) 'HOST_CANDIDATE_IDENTITY_MISMATCH'
        InvokeCase 'wrong-candidate-path' @('--host-contracts','--fixture-root',$out,'--candidate',$tiny,'--candidate-sha256',$tinyHash) 'HOST_CANDIDATE_PATH_MISMATCH'
        InvokeCase 'wrong-runtime-path' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash,'--runtime-root','relative-path','--runtime-sha256',$RuntimeSha256) 'HOST_RUNTIME_PATH_INVALID'
        InvokeCase 'wrong-runtime-identity' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash,'--runtime-root',$RuntimeRoot,'--runtime-sha256',$zeroHash) 'HOST_RUNTIME_IDENTITY_MISMATCH'
        InvokeCase 'malformed-abi' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash,'--runtime-root',$tinyRoot,'--runtime-sha256',$tinyHash) 'HOST_ABI_INVALID'
        InvokeCase 'missing-export-abi' @('--host-contracts','--fixture-root',$out,'--candidate',$exe,'--candidate-sha256',$hostHash,'--runtime-root',$exportRoot,'--runtime-sha256',$exportHash) 'HOST_ABI_EXPORT_MISSING'
        InvokeCase 'admitted-runtime-cpu' (@('--host-contracts') + $base) ''
    } elseif ($Phase -eq 'Warp') {
        InvokeCase 'missing-guide' (@('--warp-handoff','--guide-contract','missing') + $base) 'HOST_GUIDE_MISSING'
        InvokeCase 'foreign-device' (@('--warp-handoff','--guide-contract','foreign-device') + $base) 'HOST_FOREIGN_DEVICE'
        InvokeCase 'adapter-mismatch' (@('--warp-handoff','--guide-contract','adapter-mismatch') + $base) 'HOST_ADAPTER_MISMATCH'
        InvokeCase 'owned-warp-handoff' (@('--warp-handoff') + $base) ''
    } else {
        InvokeCase 'real-provider-baseline' (@('--runtime','--headless') + $base) ''
    }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $RuntimeRoot 'nvngx_dlssnr.dll')
    [ordered]@{schema=1;task=13;phase=$Phase;hostSha256=$hostHash;candidateSourceManifestSha256=(Get-FileHash -LiteralPath $manifestPath).Hash;
        candidateDllSha256=$null;candidateDllState='unbuiltPendingTask14';runtimeSha256=$RuntimeSha256;
        runtimeSignatureStatus=$signature.Status.ToString();signatureAloneRejected=$false;
        admissionReceipt=$GpuAdmissionReceipt;admissionSha256=$(if($GpuAdmissionReceipt){(Get-FileHash -LiteralPath $GpuAdmissionReceipt).Hash}else{$null});
        commands=$commands;producerTerminal=$true} | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Write-Host "HOST_PHASE_PASS=$Phase root=$out"
} catch {
    [ordered]@{schema=1;task=13;phase=$Phase;failure=$_.Exception.Message;hostSha256=$hostHash;
        sourceManifest=$manifestPath;commands=$commands;gpuAdmissionReceipt=$GpuAdmissionReceipt} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$out/failure.json" -Encoding UTF8
    throw
} finally { Stop-Transcript | Out-Null }
