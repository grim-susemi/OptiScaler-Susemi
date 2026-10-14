# Scoped Task20 extension of the existing Contracts runner. Native(), Bind(),
# Extract(), Dependencies() and LinkInputs() are the existing receipt machinery.
$bodies = [ordered]@{
    parameterGet = (Extract (Get-Content -LiteralPath "$repo/OptiScaler/NVNGX_Parameter.cpp" -Raw) `
        'template <typename T> NVSDK_NGX_Result NVNGX_Parameters::getT(').Replace('NVNGX_Parameters::', 'Params::')
    parameterSet = (Extract (Get-Content -LiteralPath "$repo/OptiScaler/NVNGX_Parameter.cpp" -Raw) `
        'template <typename T> void NVNGX_Parameters::setT(').Replace('NVNGX_Parameters::', 'Params::')
    native = Extract (Get-Content -LiteralPath "$repo/OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp" -Raw) `
        'NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_D3D12_EvaluateFeature('
    replacement = Extract (Get-Content -LiteralPath "$repo/OptiScaler/framegen/nvngx/Nvngx_FG.cpp" -Raw) `
        'NVSDK_NGX_Result Nvngx_FG::D3D12_EvaluateFeature('
    replacementVk = Extract (Get-Content -LiteralPath "$repo/OptiScaler/framegen/nvngx/Nvngx_FG.cpp" -Raw) `
        'NVSDK_NGX_Result Nvngx_FG::VULKAN_EvaluateFeature('
    combo = Extract (Get-Content -LiteralPath "$repo/OptiScaler/framegen/nvngx/Nvngx_Combo.cpp" -Raw) `
        'NVSDK_NGX_Result Nvngx_Combo::D3D12_EvaluateFeature('
    streamline = Extract (Get-Content -LiteralPath "$repo/OptiScaler/hooks/Streamline_Hooks.cpp" -Raw) `
        'sl::Result StreamlineHooks::hkslEvaluateFeature('
    nr = Extract (Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp" -Raw) `
        'bool DlssNr_Dx12::ProcessSeam('
    entry = $entry
    picture = [regex]::Replace((Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp" -Raw),
        '(?m)^#include[^\r\n]*', '')
    publisher = 'namespace DlssNr::NgxDiagnostics {' +
        (Extract (Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp" -Raw) `
            'void ReadMfgObservation(') +
        (Extract (Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp" -Raw) `
            'MfgPreflightRequest CopyMfgRequest(') + '}'
}
$observerSource = Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_MfgObserver.h" -Raw
$parameter = (Extract (Get-Content -LiteralPath "$repo/OptiScaler/NVNGX_Parameter.h" -Raw) 'struct Parameter') + ';' +
    (Extract (Get-Content -LiteralPath "$repo/OptiScaler/shaders/Shader_Vk.h" -Raw) 'struct VkImageInfo') + ';'
$controls = @(
    @{tag='invent-phase'; case='raw'; assertion='T20_NO_INVENTED_PHASE'; target='header';
      anchor='bool phaseKnown = false'; value='bool phaseKnown = true'},
    @{tag='invent-origin'; case='raw'; assertion='T20_NO_INVENTED_PIXEL_ORIGIN'; target='header';
      anchor='pixelOriginKnown = false'; value='pixelOriginKnown = true'},
    @{tag='perturb-forwarding'; case='forwarding'; assertion='T20_FORWARDED_PARAMETERS'; target='native';
      anchor='const auto result = NVNGXProxy::D3D12_EvaluateFeature()(InCmdList, InFeatureHandle, InParameters, InCallback);';
      value='InParameters->Set("DLSSG.MultiFrameIndex", 99u); const auto result = NVNGXProxy::D3D12_EvaluateFeature()(InCmdList, InFeatureHandle, InParameters, InCallback);'},
    @{tag='duplicate-evaluate'; case='forwarding'; assertion='T20_ORIGINAL_EVALUATE_EXACTLY_ONCE'; target='native';
      anchor='const auto result = NVNGXProxy::D3D12_EvaluateFeature()(InCmdList, InFeatureHandle, InParameters, InCallback);';
      value='NVNGXProxy::D3D12_EvaluateFeature()(InCmdList, InFeatureHandle, InParameters, InCallback); const auto result = NVNGXProxy::D3D12_EvaluateFeature()(InCmdList, InFeatureHandle, InParameters, InCallback);'},
    @{tag='stale-association'; case='association'; assertion='T20_CURRENT_ASSOCIATION'; target='nr';
      anchor='_state->late.consumer = consumer.identity;'; value='/* deliberately retain the previous consumer */'},
    @{tag='duplicate-present'; case='streamline'; assertion='T20_ORIGINAL_PRESENT_EXACTLY_ONCE'; target='picture';
      anchor='const auto result = originalPresent1(swapchain, interval, flags, parameters, skip);';
      value='originalPresent1(swapchain, interval, flags, parameters, skip); skip = true; const auto result = originalPresent1(swapchain, interval, flags, parameters, skip);'},
    @{tag='remove-session'; case='entry'; assertion='T20_EXISTING_ENTRY_ACTIVATES'; target='entry';
      anchor='DlssNr::MfgObserver::Begin(this, runs);'; value='(void)runs;'},
    @{tag='owner-only-cap'; case='bounds'; assertion='T20_ALL_NR_APPLICATION_MARKERS_CAPPED'; target='header';
      anchor='if (event.seam == Seam::Nr && (event.stage == 0 || event.stage == 3))';
      value='if (event.seam == Seam::Nr && event.stage == 0 && event.identity.owner == snapshot.owner)'},
    @{tag='uncapped-tag-scan'; case='streamline'; assertion='T20_STREAMLINE_INPUT_SCAN_CAP'; target='streamlineHeader';
      anchor='i < event.resources.size()'; value='event.resourceCount < event.resources.size()'}
)
$variants = @(@{tag='plain'; defines=@(); cases=@('forwarding','raw','association','bounds','entry','streamline')},
              @{tag='rtx40-mfg'; defines=@('/DOPTISCALER_RTX40_MFG'); cases=@('forwarding','raw','association','bounds','entry','streamline')})
foreach ($control in $controls) {
    $variants += @{tag=$control.tag; defines=@('/DOPTISCALER_RTX40_MFG'); cases=@($control.case); control=$control}
}
foreach ($variant in $variants) {
    $dir = Join-Path $out $variant.tag
    New-Item -ItemType Directory -Path $dir | Out-Null
    Set-Content -LiteralPath "$dir/observer-parameter.inc" -Value $parameter -Encoding UTF8
    Bind "$dir/observer-parameter.inc" 'actual-production-parameter-conversion-carrier'
    $headers = @()
    if ($variant.control -and $variant.control.target -in @('header','streamlineHeader')) {
        New-Item -ItemType Directory -Path "$dir/dlssnr" | Out-Null
        $mutated = if ($variant.control.target -eq 'header') {
            ReplaceOnce $observerSource $variant.control.anchor $variant.control.value
        } else { $observerSource }
        Set-Content -LiteralPath "$dir/dlssnr/DlssNr_MfgObserver.h" -Value $mutated -Encoding UTF8
        # Relative production header inclusion must consume the seeded header too.
        foreach ($name in @('DlssNr_MfgObserverNgx.h','DlssNr_MfgObserverStreamline.h',
                            'DlssNr_NgxDiagnostics.h')) {
            if ($variant.control.target -eq 'streamlineHeader' -and $name -eq 'DlssNr_MfgObserverStreamline.h') {
                $source = Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/$name" -Raw
                Set-Content -LiteralPath "$dir/dlssnr/$name" `
                    -Value (ReplaceOnce $source $variant.control.anchor $variant.control.value) -Encoding UTF8
            } else {
                Copy-Item -LiteralPath "$repo/OptiScaler/dlssnr/$name" -Destination "$dir/dlssnr/$name"
            }
            Bind "$dir/dlssnr/$name" 'derived-relative-include-carrier'
        }
        Bind "$dir/dlssnr/DlssNr_MfgObserver.h" 'derived-production-negative-control'
    }
    $production = foreach ($key in $bodies.Keys) {
        $body = $bodies[$key]
        if ($variant.control -and $variant.control.target -eq $key) {
            $body = ReplaceOnce $body $variant.control.anchor $variant.control.value
        }
        $body
    }
    Set-Content -LiteralPath "$dir/observer-production.inc" -Value ($production -join "`n") -Encoding UTF8
    Bind "$dir/observer-production.inc" 'actual-production-forwarding-body-carrier'
    $arguments = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',
        "/I$dir","/I$repo/OptiScaler","/I$repo/OptiScaler/dlssnr","/I$repo/external/nvngx_dlss_sdk","/I$repo/external/streamline",
        "/I$support/external/vulkan/include",
        "/Fo$dir/fixture.obj","/Fd$dir/fixture.pdb","/Fe$dir/contracts.exe",
        '/sourceDependencies',"$dir/dependencies.json") + $variant.defines +
        @("$PSScriptRoot/ObserverContracts.cpp",
          '/link','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$dir/link-inputs.rsp")
    if ((Native $cl $arguments "$dir/compile.log" 'task20-actual-forwarding-fixture-compile') -ne 0) {
        throw "Observer fixture compile failed: $($variant.tag)"
    }
    Dependencies "$dir/dependencies.json"
    LinkInputs "$dir/link-inputs.rsp" "$dir/compile.log"
    Bind "$dir/contracts.exe" 'task20-fixture-executable'
    Bind "$dir/fixture.obj" 'task20-fixture-object'
    foreach ($case in $variant.cases) {
        $caseRoot = Join-Path $metadataRoot ($variant.tag + '/' + $case)
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $exit = Native "$dir/contracts.exe" @($case,$caseRoot) "$dir/$case.log" 'task20-native-cli-case'
        if ($variant.control) {
            if ($exit -ne 41 -or (Get-Content -LiteralPath "$dir/$case.log" -Raw) -notmatch $variant.control.assertion) {
                throw "Observer control missed its named assertion: $($variant.tag)"
            }
        } else {
            if ($exit) { throw "Observer native CLI failed: $($variant.tag)/$case" }
            $json = Get-Content -LiteralPath "$dir/$case.log" -Raw | ConvertFrom-Json
            if (!$json.pass -or $json.displayTimingAvailable -or $json.retainedValueBytes -gt 1048576) {
                throw "Invalid observer limits: $($variant.tag)/$case"
            }
        }
        Bind "$dir/$case.log" 'task20-actual-native-case-output'
    }
}
