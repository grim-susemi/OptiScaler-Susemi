param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$build = if ($EvidenceRoot) { Join-Path $EvidenceRoot ('task-4-wrappers-' + [guid]::NewGuid().ToString('N')) }
         else { Join-Path $repo 'x64/nr-streamline-hooks' }
New-Item -ItemType Directory -Force $build | Out-Null
Start-Transcript -LiteralPath "$build/raw.log" | Out-Null
try {
# Compile the actual wrapper body against test application services, with real DXGI/D3D12 objects.
$source = Get-Content -Raw -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp"
Set-Content -LiteralPath "$build/StreamlinePicture.cpp" -Value ([regex]::Replace($source, '(?m)^#include[^\r\n]*', ''))
& cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX "/I$build" "/Fo$build/" "/Fe$build/hooks.exe" `
    "$PSScriptRoot/nr_streamline_hooks.cpp" /link d3d12.lib dxgi.lib dxguid.lib
if ($LASTEXITCODE) { throw 'Streamline hook test build failed.' }
& "$build/hooks.exe"
if ($LASTEXITCODE) { throw 'Streamline hook test failed.' }

# The adjacent fixture compiles actual capture, promise/enqueue, admission,
# finished compositor, public callback and wrapper bodies, not a mirrored route.
function Extract([string]$path, [string]$signature) {
    $text = Get-Content -LiteralPath "$repo/$path" -Raw
    $start = $text.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing production body: $signature" }
    $first = $text.IndexOf('{', $start)
    $depth = 0
    for ($i = $first; $i -lt $text.Length; ++$i) {
        if ($text[$i] -eq '{') { ++$depth }
        if ($text[$i] -eq '}') { --$depth }
        if (!$depth) { return $text.Substring($start, $i-$start+1) }
    }
    throw "Unterminated production body: $signature"
}
$dx12 = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp'
$queue = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp'
$late = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp'
$compose = 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp'
$context = (Extract 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h' '    struct LateContext') + ';'
$bodies = @(
    (Extract 'OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp' 'DlssNr::InputStates_Dx12 DlssNr::ResolveInputStates_Dx12'),
    (Extract $dx12 'bool DlssNr_Dx12::ProcessSeam'),
    (Extract $dx12 'bool DlssNr_Dx12::ApplyFinished'),
    (Extract $dx12 'bool DlssNr_Dx12::PendingFinishedCapture'),
    (Extract $dx12 'bool DlssNr_Dx12::State::PendingFinishedCapture'),
    (Extract $dx12 'void DlssNr_Dx12::State::CloseFinishedCaptures'),
    (Extract $queue 'auto DlssNr_Dx12::State::FinishedPictureResetCommandList'),
    (Extract $queue 'auto DlssNr_Dx12::State::FinishedPicturePromised'),
    (Extract $queue 'auto DlssNr_Dx12::State::FinishedPictureSubmitted'),
    ([regex]::Replace((Get-Content -LiteralPath "$repo/$late" -Raw), '(?m)^#include[^\r\n]*', '')),
    ([regex]::Replace((Get-Content -LiteralPath "$repo/$compose" -Raw), '(?m)^#include[^\r\n]*', '')),
    ([regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp" -Raw), '(?m)^#include[^\r\n]*', '')),
    'namespace DlssNr {',
    (Extract $dx12 'StreamlinePicture::ConsumerSnapshot CaptureFinishedConsumer'),
    (Extract $dx12 'static DXGI_COLOR_SPACE_TYPE ReadFinishedSpace'),
    (Extract $dx12 'void ApplyToStreamlinePicture'),
    (Extract $dx12 'void SkipFinishedPicture'),
    (Extract $dx12 'void ApplyToFinishedPicture(IDXGISwapChain*'),
    (Extract $dx12 'void FinishedPicturePromise('),
    (Extract $dx12 'void FinishedPictureSubmitted('),
    (Extract $dx12 'bool XeFGPendingCapture('),
    (Extract $dx12 'bool ApplyXeFGPicture('),
    (Extract $dx12 'void XeFGCloseCaptures('),
    '}',
    (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'bool XeFG_Dx12::OwnsFinishedConsumer'),
    (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'bool XeFG_Dx12::ClaimsFinishedConsumer'),
    (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'void XeFG_Dx12::ResetNrHandoff'),
    (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'void XeFG_Dx12::OwnedNrHandoff'),
    (Extract 'OptiScaler/resource_tracking/ResTrack_dx12.cpp' 'static void STDMETHODCALLTYPE hkNrExecuteCommandLists')
) -join "`n"
$sdk = "$repo/external/nvngx_dlss_sdk"
if (!(Test-Path -LiteralPath "$sdk/nvsdk_ngx_params.h")) {
    # Accepted offline support, not a donor product overlay or mutable cache.
    $sdk = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1/external/nvngx_dlss_sdk'
}
if (!(Test-Path -LiteralPath "$sdk/nvsdk_ngx_params.h")) { throw 'Retained NGX headers missing' }
$results = @()
foreach ($tag in @('green','seed-select','seed-guide','seed-promise','seed-close')) {
    $out = Join-Path $build $tag
    New-Item -ItemType Directory -Path $out | Out-Null
    $production = $bodies
    if ($tag -eq 'seed-select' -or $tag -eq 'seed-guide') {
        $anchor = '(!newest || slot.serial > newest->serial)'
        if (($production.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) { throw 'Selection seed anchor drift' }
        $filter = if ($tag -eq 'seed-guide') { 'slot.guidesValid && ' } else {
            'DlssNr::LateCaptureSelectable(slot.pending, slot.pinned, slot.submitted, slot.promisePending) && '
        }
        $production = $production.Replace($anchor, $filter + $anchor)
    }
    if ($tag -eq 'seed-promise') {
        $anchor = 'DlssNr::RecordLateSlotPromise(slot.ready, slot.promisedValue, slot.promisePending);'
        if (($production.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) { throw 'Promise seed anchor drift' }
        $production = $production.Replace($anchor, $anchor +
            ' slot.producerQueue = queue; DlssNr::EnqueueLateSlotPromise(slot.promisedValue, slot.done, slot.submitted, slot.owned, slot.promisePending); queue->Signal(slot.fence.Get(), slot.promisedValue);')
    }
    if ($tag -eq 'seed-close') {
        $anchor = 'DlssNr::XeFGCloseCaptures(closeAllCaptures ? std::numeric_limits<uint64_t>::max() : facts.serial);'
        if (($production.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) { throw 'Untracked-close seed anchor drift' }
        $production = $production.Replace($anchor, 'DlssNr::XeFGCloseCaptures(facts.serial);')
    }
    Set-Content -LiteralPath "$out/present_late_context.inc" -Value $context -Encoding UTF8
    Set-Content -LiteralPath "$out/present_production.inc" -Value $production -Encoding UTF8
    Copy-Item -LiteralPath "$build/StreamlinePicture.cpp" -Destination "$out/StreamlinePicture.cpp"
    $arguments = @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',"/I$out", "/I$sdk",
        "/I$repo/OptiScaler", "/Fo$out/wrapper.obj", "/Fd$out/wrapper.pdb", "/Fe$out/wrapper.exe",
        '/sourceDependencies', "$out/compiler-inputs.json", "$PSScriptRoot/nr_present_admission_smoke.cpp",
        '/link','d3d12.lib','dxgi.lib','dxguid.lib', "/VERBOSE:LIB")
    Write-Host ("T4_WRAPPER_COMPILE_COMMAND=cl.exe " + ($arguments -join ' '))
    & cl.exe @arguments 2>&1 | Tee-Object -Variable compileLines | Write-Host
    $compileExit = $LASTEXITCODE
    $compileLines | Set-Content -LiteralPath "$out/compile.log" -Encoding UTF8
    Write-Host "T4_WRAPPER_COMPILE_EXIT=$compileExit tag=$tag"
    if ($compileExit) { throw "Production wrapper fixture compile failed: $tag" }
    $ErrorActionPreference = 'Continue'
    $runArguments = if ($tag -eq 'seed-close') { @('--case','skip_test_discontinuity_untracked_gpu_retention') } else { @() }
    Write-Host ("T4_WRAPPER_COMMAND=$out/wrapper.exe " + ($runArguments -join ' '))
    & "$out/wrapper.exe" @runArguments 2>&1 | Tee-Object -Variable runLines | Write-Host
    $runExit = $LASTEXITCODE
    $runLines | Set-Content -LiteralPath "$out/output.log" -Encoding UTF8
    $ErrorActionPreference = 'Stop'
    Write-Host "T4_WRAPPER_RUN_EXIT=$runExit tag=$tag"
    $output = Get-Content -LiteralPath "$out/output.log" -Raw
    if ($tag -eq 'green' -and $runExit) { throw 'Production wrapper positive run failed' }
    $marker = if ($tag -eq 'seed-select') { 'T4_NEWEST_UNRESOLVED' }
              elseif ($tag -eq 'seed-guide') { 'T4_NEWEST_UNUSABLE' }
              elseif ($tag -eq 'seed-close') { 'T4_XEFG_UNTRACKED_SKIP_RESET' } else { 'T4_PROMISE_NOT_SUBMISSION' }
    if ($tag -ne 'green' -and (!$runExit -or $output -notmatch $marker)) {
        throw "Seed did not break its actual production assertion: $tag / $marker"
    }
    $results += [ordered]@{ tag=$tag; compileCommand='cl.exe '+($arguments -join ' ');
        compileExit=$compileExit; command="$out/wrapper.exe "+($runArguments -join ' '); runExit=$runExit; root=$out }
}
$sources = @($dx12,$queue,$late,$compose,'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h',
    'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp','OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp',
    'OptiScaler/resource_tracking/ResTrack_dx12.cpp','OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp',
    'OptiScaler/dlssnr/DlssNr_StreamlinePicture.h','OptiScaler/dlssnr/DlssNr_FinishedConsumer.h',
    'OptiScaler/framegen/xefg/XeFG_Dx12.cpp',
    'tests/nr_present_admission_smoke.cpp','tests/run_nr_streamline_hooks.ps1')
$hashes = @($sources | ForEach-Object { Get-FileHash -LiteralPath "$repo/$_" -Algorithm SHA256 })
[ordered]@{ scope='Task4 actual production wrappers; owned WARP; Run/provider services are fixture adapters';
    commands=$results; sources=$hashes; gpu='WARP'; nvidia='not_run' } |
    ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$build/result.json" -Encoding UTF8
Write-Host "T4_WRAPPER_PASS root=$build"
} finally { Stop-Transcript | Out-Null }
exit 0
