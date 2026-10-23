param([Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [ValidateSet('PreFix','Repaired')][string]$Mode,
      [string]$PreFixRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $EvidenceRoot ('task-5-repair-R1-' + $Mode + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
$commands = @()
function Extract([string]$file, [string]$signature) {
    $text = Get-Content -LiteralPath "$repo/$file" -Raw
    $start = $text.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing body: $signature" }
    $first = $text.IndexOf('{', $start); $depth = 0
    for ($i = $first; $i -lt $text.Length; ++$i) {
        if ($text[$i] -eq '{') { ++$depth }
        if ($text[$i] -eq '}') { --$depth }
        if (!$depth) { return $text.Substring($start, $i-$start+1) }
    }
    throw "Unterminated: $signature"
}
function Body([string]$file) {
    return [regex]::Replace((Get-Content -LiteralPath "$repo/$file" -Raw), '(?m)^#include[^\r\n]*', '')
}
function ReplaceOnce([string]$text, [string]$anchor, [string]$replacement) {
    if (($text.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) { throw "Anchor drift: $anchor" }
    return $text.Replace($anchor, $replacement)
}
try {
    $files = @('OptiScaler/shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp',
        'OptiScaler/dlssnr/DlssNr_Status.cpp','OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.h',
        'OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp',
        'tests/nr_finished_outcome_smoke.cpp','tests/nr_deferred_outcome_smoke.cpp',
        'tests/nr_deferred_outcome_support.h','tests/run_nr_deferred_outcome.ps1')
    $hashes = @($files | ForEach-Object { Get-FileHash -LiteralPath "$repo/$_" })
    $state = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h'
    $context = (Extract $state '    struct DeferredSrContext') + ';'
    $context = ReplaceOnce $context 'DlssNr::GpuLifetime lifetime;' 'LifetimeService lifetime;'
    $late = (Extract $state '    struct LateContext') + ';'
    $deferred = @()
    foreach ($name in @('Say','Cancel','UInt','Float','Before','After')) {
        $deferred += Extract $files[0] "auto DlssNr_Dx12::State::DeferredSrContext::$name("
    }
    $deferred = $deferred -join "`n"
    $production = @(
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp' 'bool DlssNr_Dx12::ApplyFinished'),
        (Body 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp'),
        (Body 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp'),
        (Body 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp'),
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp' 'auto DlssNr_Dx12::State::Publish'),
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp' 'auto DlssNr_Dx12::State::ReportSkipOnce'),
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp' 'auto DlssNr_Dx12::State::FinishedPictureSubmitted'),
        (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp' 'auto DlssNr_Dx12::State::FinishedPictureResetCommandList')
    ) -join "`n"
    $production = ReplaceOnce $production 'FAILED(cmd->Close())' 'FAILED(ComposeClose(cmd))'
    $production = ReplaceOnce $production 'FAILED(queue->Signal(slot.fence.Get(), slot.ready))' 'FAILED(ComposeSignal(queue, slot.fence.Get(), slot.ready))'
    $production = ReplaceOnce $production 'FAILED(queue->Signal(slot.fence.Get(), promised))' 'FAILED(ProducerSignal(queue, slot.fence.Get(), promised))'
    $production += "`n" + (Body 'OptiScaler/dlssnr/DlssNr_Status.cpp')
    $support = "namespace DlssNr {`n" +
        (Extract 'OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.h' 'inline bool FormatCanHoldLinearHdr') + "`n}"
    $tags = if ($Mode -eq 'PreFix') { @('pre-fix') } else { @('green','old-publication-seed') }
    foreach ($tag in $tags) {
        $dir = Join-Path $out $tag
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = $deferred
        if ($tag -eq 'old-publication-seed') {
            $red = Get-Content -LiteralPath "$PreFixRoot/result.json" -Raw | ConvertFrom-Json
            if ($red.mode -ne 'PreFix' -or $red.commands.Count -ne 2) { throw 'Missing locked red receipt' }
            $body = Get-Content -LiteralPath "$PreFixRoot/pre-fix/deferred_production.inc" -Raw
            if ((Get-FileHash -LiteralPath "$PreFixRoot/pre-fix/deferred_production.inc").Hash -ne $red.deferredBodySha256) {
                throw 'Old-publication body drift'
            }
        }
        Set-Content -LiteralPath "$dir/deferred_context.inc" -Value $context -Encoding UTF8
        Set-Content -LiteralPath "$dir/deferred_support.inc" -Value $support -Encoding UTF8
        Set-Content -LiteralPath "$dir/deferred_production.inc" -Value $body -Encoding UTF8
        Set-Content -LiteralPath "$dir/finished_context.inc" -Value $late -Encoding UTF8
        Set-Content -LiteralPath "$dir/finished_production.inc" -Value $production -Encoding UTF8
        Set-Content -LiteralPath "$dir/finished_streamline.inc" -Value (Body 'OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp') -Encoding UTF8
        $exe = "$dir/deferred.exe"
        $args = @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',"/I$dir", "/I$PSScriptRoot",
            "/I$repo/OptiScaler",'/IC:/omo-research/optiscaler-hybrid-port-v0.7.1/external/nvngx_dlss_sdk',
            "/Fo$dir/deferred.obj", "/Fd$dir/deferred.pdb", "/Fe$exe", '/sourceDependencies',
            "$dir/compiler-inputs.json", "$PSScriptRoot/nr_deferred_outcome_smoke.cpp",
            '/link','d3d12.lib','dxgi.lib','dxguid.lib','d3dcompiler.lib','/VERBOSE:LIB')
        Write-Host ("R1_COMPILE_COMMAND=cl.exe " + ($args -join ' '))
        & cl.exe @args 2>&1 | Tee-Object -FilePath "$dir/compile.log" | Write-Host
        $compileExit = $LASTEXITCODE
        Write-Host "R1_COMPILE_EXIT=$compileExit tag=$tag"
        if ($compileExit) { throw "R1 compile failed: $tag" }
        $cases = if ($tag -eq 'green') { @('private-failure','composition-failure','success','future-carrier','after-refusal') }
                 else { @('private-failure','composition-failure') }
        foreach ($case in $cases) {
            Write-Host "R1_RUN_COMMAND=$exe $case"
            & $exe $case 2>&1 | Tee-Object -FilePath "$dir/$case.log" | Write-Host
            $code = $LASTEXITCODE
            $assertion = if ($case -eq 'private-failure') { 'R1_PRIVATE_FAILURE_NOT_APPLIED' }
                         else { 'R1_COMPOSITION_FAILURE_NOT_APPLIED' }
            Write-Host "R1_RUN_EXIT=$code case=$case tag=$tag"
            $commands += [ordered]@{tag=$tag;case=$case;compileCommand='cl.exe '+($args -join ' ');
                compileExit=$compileExit;command="$exe $case";exit=$code;assertion=$assertion;root=$dir}
            $log = Get-Content -LiteralPath "$dir/$case.log" -Raw
            if ($log -notmatch 'R1_CLOSURE=owned_COM_scope_closed' -or
                $log -notmatch 'T5_RETIREMENT_PROOF=queue_tail_complete event_closed') { throw 'R1 closure incomplete' }
            if ($tag -eq 'green') {
                if ($code -ne 0 -or $log -notmatch "R1_CASE_PASS=$case") { throw "R1 green failed: $case" }
            } elseif ($code -ne 1 -or $log -notmatch "R1_FAIL=$assertion" -or
                $log -notmatch 'applied=1' -or $log -notmatch 'application=FF000000') {
                throw "R1 red missed exact publication assertion: $case"
            }
        }
    }
    foreach ($hash in $hashes) {
        if ((Get-FileHash -LiteralPath $hash.Path).Hash -ne $hash.Hash) { throw "Source drift: $($hash.Path)" }
    }
    $bodyPath = if ($Mode -eq 'PreFix') { "$out/pre-fix/deferred_production.inc" } else { "$out/green/deferred_production.inc" }
    [ordered]@{mode=$Mode;root=$out;sources=$hashes;commands=$commands;
        deferredBodySha256=(Get-FileHash -LiteralPath $bodyPath).Hash;
        adapters='allocation, private provider, model, arrival-state setup, carrier storage; actual Before/Run/After/submission';
        gpu='owned WARP';pendingCommands=0} | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Write-Host "R1_DELTA_PASS mode=$Mode root=$out"
} catch {
    [ordered]@{mode=$Mode;root=$out;failure=$_.Exception.Message;commands=$commands;pendingCommands=0} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$out/failure.json" -Encoding UTF8
    throw
} finally { Stop-Transcript | Out-Null }
