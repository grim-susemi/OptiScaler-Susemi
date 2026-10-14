param([Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [ValidateSet('All','ResidualDelta')][string]$Scope = 'All')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $EvidenceRoot ('task-5-outcomes-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
function Extract([string]$file, [string]$signature) {
    $text = Get-Content -LiteralPath "$repo/$file" -Raw
    $start = $text.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing body: $signature" }
    $first = $text.IndexOf('{', $start)
    $depth = 0
    for ($i = $first; $i -lt $text.Length; ++$i) {
        if ($text[$i] -eq '{') { ++$depth }
        if ($text[$i] -eq '}') { --$depth }
        if (!$depth) { return $text.Substring($start, $i-$start+1) }
    }
    throw "Unterminated body: $signature"
}
function ReplaceOnce([string]$text, [string]$anchor, [string]$replacement) {
    if (($text.Split(@($anchor), [StringSplitOptions]::None).Count-1) -ne 1) { throw "Anchor drift: $anchor" }
    return $text.Replace($anchor, $replacement)
}
try {
    $sourcePaths = @('OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h','OptiScaler/dlssnr/DlssNr_Status.cpp',
        'OptiScaler/dlssnr/DlssNr_Status.h','OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp',
        'OptiScaler/dlssnr/DlssNr_StreamlinePicture.h','OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.h',
        'tests/nr_finished_outcome_smoke.cpp','tests/run_nr_finished_outcome.ps1','tests/run_nr_addon_options.ps1')
    $beforeHashes = @($sourcePaths | ForEach-Object { Get-FileHash -LiteralPath "$repo/$_" })
    $dx = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp'
    $compose = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp'
    $status = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp'
    $context = (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h' '    struct LateContext') + ';'
    $production = @(
        (Extract $dx 'bool DlssNr_Dx12::ApplyFinished'),
        ([regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp" -Raw), '(?m)^#include[^\r\n]*', '')),
        ([regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp" -Raw), '(?m)^#include[^\r\n]*', '')),
        ([regex]::Replace((Get-Content -LiteralPath "$repo/$compose" -Raw), '(?m)^#include[^\r\n]*', '')),
        (Extract $status 'auto DlssNr_Dx12::State::Publish'),
        (Extract $status 'auto DlssNr_Dx12::State::ReportSkipOnce')
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp' 'auto DlssNr_Dx12::State::FinishedPictureSubmitted'),
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp' 'auto DlssNr_Dx12::State::FinishedPictureResetCommandList')
    ) -join "`n"
    $production = ReplaceOnce $production 'FAILED(cmd->Close())' 'FAILED(ComposeClose(cmd))'
    $production = ReplaceOnce $production 'FAILED(queue->Signal(slot.fence.Get(), slot.ready))' `
        'FAILED(ComposeSignal(queue, slot.fence.Get(), slot.ready))'
    $production = ReplaceOnce $production 'FAILED(queue->Signal(slot.fence.Get(), promised))' `
        'FAILED(ProducerSignal(queue, slot.fence.Get(), promised))'
    # Device/queue/Read helpers are inline in the actual public header.
    $streamline = [regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp" -Raw), '(?m)^#include[^\r\n]*', '')
    $statusBody = [regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_Status.cpp" -Raw), '(?m)^#include[^\r\n]*', '')
    $commands = @()
    $tags = if ($Scope -eq 'ResidualDelta') { @('green','seed-residual') }
            else { @('green','seed-pq','seed-hidden','seed-close','seed-signal','seed-history','seed-producer-signal','seed-residual') }
    foreach ($tag in $tags) {
        $dir = Join-Path $out $tag
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = $production
        $case = @()
        if ($Scope -eq 'ResidualDelta' -and $tag -eq 'green') { $case = @('--residual-delta') }
        $assertion = ''
        if ($tag -eq 'seed-pq') {
            $body = ReplaceOnce $body 'const bool ran = finalCopyBack && !outputStatus.hidden &&' `
                'const bool ran = (nr.successfulDispatches > 0) && !outputStatus.hidden &&'
            $body = ReplaceOnce $body 'outputStatus.state != DlssNr::OutputState::Failed;' 'true;'
            $case = @('--case','final-pq-failure'); $assertion = 'T5_FINAL_PQ_FAILURE_NOT_APPLIED'
        }
        if ($tag -eq 'seed-hidden') {
            $body = ReplaceOnce $body 'const bool ran = finalCopyBack && !outputStatus.hidden &&' `
                'const bool ran = outputStatus.composed &&'
            $case = @('--case','hidden'); $assertion = 'T5_HIDDEN_NOT_APPLIED'
        }
        if ($tag -eq 'seed-close') {
            $body = ReplaceOnce $body ('slot.pinned = true;' + "`n" +
                '        outputStatus.state = DlssNr::OutputState::Failed;' + "`n" +
                '        outputStatus.reason = DlssNr::OutputReason::Close;') `
                ('slot.pinned = false;' + "`n" +
                '        outputStatus.state = DlssNr::OutputState::Failed;' + "`n" +
                '        outputStatus.reason = DlssNr::OutputReason::Close;')
            $case = @('--case','close-failure'); $assertion = 'T5_FAILURE_RETAINS_PRODUCER'
        }
        if ($tag -eq 'seed-signal') {
            $body = ReplaceOnce $body ('outputStatus.reason = DlssNr::OutputReason::Signal;' + "`n" +
                '        outputStatus.completionUnknown = true;') ('outputStatus.reason = DlssNr::OutputReason::Signal;' + "`n" +
                '        outputStatus.completionUnknown = false;')
            $case = @('--case','signal-failure'); $assertion = 'T5_SIGNAL_UNKNOWN_COMPLETION'
        }
        if ($tag -eq 'seed-producer-signal') {
            $body = ReplaceOnce $body ('outputStatus.submitted = false;' + "`n" +
                '            outputStatus.completionUnknown = true;') ('outputStatus.submitted = false;' + "`n" +
                '            outputStatus.completionUnknown = false;')
            $case = @('--case','producer-signal-failure'); $assertion = 'T5_PRODUCER_SIGNAL_UNKNOWN_COMPLETION'
        }
        if ($tag -eq 'seed-history') {
            $body = ReplaceOnce $body ('late.reset = outputStatus.state == DlssNr::OutputState::Failed ||' + "`n" +
                '                 (slot.residualOnly ? !appliedResidual : !outputStatus.composed);') 'late.reset = !ran;'
            $case = @('--case','hidden'); $assertion = 'T5_HIDDEN_RETAINS_MODEL_HISTORY'
        }
        if ($tag -eq 'seed-residual') {
            $body = ReplaceOnce $body ('outputStatus.state = DlssNr::OutputState::Failed;' + "`n" +
                '                outputStatus.reason = DlssNr::OutputReason::Composition;') `
                ('outputStatus.state = DlssNr::OutputState::Skipped;' + "`n" +
                '                outputStatus.reason = DlssNr::OutputReason::Composition;')
            $case = @('--case','residual-failure'); $assertion = 'T5_RESIDUAL_FAILURE_NAMED'
        }
        Set-Content -LiteralPath "$dir/finished_context.inc" -Value $context -Encoding UTF8
        Set-Content -LiteralPath "$dir/finished_production.inc" -Value ($body + "`n" + $statusBody) -Encoding UTF8
        Set-Content -LiteralPath "$dir/finished_streamline.inc" -Value $streamline -Encoding UTF8
        $exe = "$dir/outcome.exe"
        $arguments = @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',"/I$dir", "/I$PSScriptRoot", "/I$repo/OptiScaler",
            "/Fo$dir/outcome.obj", "/Fd$dir/outcome.pdb", "/Fe$exe", '/sourceDependencies', "$dir/compiler-inputs.json",
            "$PSScriptRoot/nr_finished_outcome_smoke.cpp", '/link','d3d12.lib','dxgi.lib','dxguid.lib','d3dcompiler.lib','/VERBOSE:LIB')
        Write-Host ("T5_COMPILE_COMMAND=cl.exe " + ($arguments -join ' '))
        & cl.exe @arguments 2>&1 | Tee-Object -FilePath "$dir/compile.log" | Write-Host
        $compileExit = $LASTEXITCODE
        Write-Host "T5_COMPILE_EXIT=$compileExit tag=$tag"
        if ($compileExit) { throw "Task5 fixture compile failed: $tag" }
        Write-Host ("T5_RUN_COMMAND=$exe " + ($case -join ' '))
        & $exe @case 2>&1 | Tee-Object -FilePath "$dir/output.log" | Write-Host
        $runExit = $LASTEXITCODE
        Write-Host "T5_RUN_EXIT=$runExit tag=$tag"
        if ($tag -eq 'green' -and $runExit) { throw 'Task5 positive fixture failed' }
        if ($tag -ne 'green' -and (!$runExit -or (Get-Content -LiteralPath "$dir/output.log" -Raw) -notmatch $assertion)) {
            throw "Negative control missed assertion: $tag / $assertion"
        }
        $commands += [ordered]@{ tag=$tag; compileCommand='cl.exe '+($arguments -join ' '); compileExit=$compileExit;
            command=$exe+' '+($case -join ' '); exit=$runExit; assertion=$assertion; root=$dir }
    }
    foreach ($source in $beforeHashes) {
        if ((Get-FileHash -LiteralPath $source.Path).Hash -ne $source.Hash) {
            throw "Source changed during proof: $($source.Path)"
        }
    }
    [ordered]@{ scope='Task5 actual production bodies and shipped final-color bytecode; owned WARP; provider adapters not NVIDIA';
        commands=$commands; sources=$beforeHashes;
        root=$out; gpu='owned WARP'; nvidia='not_run'; verificationScope=$Scope } |
        ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Write-Host "T5_OUTCOMES_PASS root=$out"
} finally { Stop-Transcript | Out-Null }
