param(
    [ValidateSet('Generate','GuardCompile','AdmissionCheck','Product','ProductShader','Math','Contracts','ShaderCompile','NegativeCompile','Shaders','GraphDiagnostic','ScopeDiagnostic','Negative','Binding','Task12Compile','Task12Shaders','Task12CodecNegative','Task12FilterCompile','Task12FilterNegative','Task12Transport','Task12TransportResume')][string]$Tier,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [string]$ContractsRoot,
    [string]$GenerateRoot,
    [string]$ShaderRoot,
    [string]$NegativeRoot,
    [string]$GuardBaselineRoot,
    [uint32]$GraphRecipe = 0,
    [string]$VerifiedScopeRoot,
    [string]$GraphComparisonRoot,
    [string[]]$ReceiptRoots,
    [string]$TransportReuseManifest
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
$prefix=if ($Tier.StartsWith('Task12')) { 'task-12-' } else { 'task-11-' }
$out = Join-Path $EvidenceRoot ($prefix + $Tier.ToLower() + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
try {
    $vc = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207'
    $sdk = 'C:/Program Files (x86)/Windows Kits/10'
    $support = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1'
    $env:PATH = "$vc/bin/HostX86/x64;" + $env:PATH
    $env:INCLUDE = "$vc/include;$sdk/Include/10.0.26100.0/ucrt;$sdk/Include/10.0.26100.0/shared;$sdk/Include/10.0.26100.0/um;$sdk/Include/10.0.26100.0/winrt"
    $env:LIB = "$vc/lib/x64;$sdk/Lib/10.0.26100.0/ucrt/x64;$sdk/Lib/10.0.26100.0/um/x64"
    $fxc = "$sdk/bin/10.0.26100.0/x64/fxc.exe"
    $commands = @()
    function Invoke-Native([string]$program,[string[]]$arguments,[string]$name,[int]$expected=0) {
        $resolved = (Get-Command $program -ErrorAction Stop).Source
        Write-Host ("T11_COMMAND=$resolved " + ($arguments -join ' '))
        $ErrorActionPreference = 'Continue'
        & $resolved @arguments 2>&1 | Tee-Object -FilePath "$out/$name.log" | Write-Host
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Write-Host "T11_EXIT=$code name=$name expected=$expected"
        $script:commands += [ordered]@{program=$resolved;arguments=$arguments;exit=$code;expected=$expected;log="$out/$name.log"}
        if ($code -ne $expected) { throw "$name exited $code, expected $expected" }
    }
    function Generated([string]$path,[string]$text) {
        # Derived build inputs/measurements only, never candidate/manual sources.
        [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
    }
    function Without-Includes([string]$text) { [regex]::Replace($text,'(?m)^#include[^\r\n]*','') }
    function Replace-One([string]$text,[string]$old,[string]$new) {
        if (($text.Split(@($old),[StringSplitOptions]::None).Count-1) -ne 1) { throw "Source anchor drift: $old" }
        $text.Replace($old,$new)
    }
    function Busy-Owners([object[]]$owners) {
        @($owners | Where-Object { $_.Name -match '^(nr-qa-host|obs64|obs32|ffxiv_dx11|eldenring|Cyberpunk2077|bg3_dx11|bg3|HogwartsLegacy|LosslessScaling|tlou-i|ACShadows|ACMirage|MonsterHunterWilds|re4|DragonAgeTheVeilguard|TheFirstDescendant|BlackMythWukong|CrimsonDesert)\.exe$' })
    }
    $legacyCso = "$EvidenceRoot/task-9-shaders-32e166cb09c242fd8f131a27b08afaae/DlssNr_Shader.cso"
    $acceptedRecipes = "$EvidenceRoot/task-9-contracts-9e96bf0475be45389242beff4768503b/green-recipes.bin"
    if ($Tier -eq 'Generate') {
        Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3','/Fo',"$out/DlssNr_Shader.cso",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl") 'fxc'
        Invoke-Native 'python.exe' @("$repo/OptiScaler/shaders/shader_tools/create_header.py",
            "$out/DlssNr_Shader.cso","$out/DlssNr_Shader.h",'DlssNr_cso') 'header'
        Invoke-Native 'python.exe' @('-c','import sys; print(sys.executable); print(sys.base_prefix); print(sys.version)') 'python-identity'
        if (!(Test-Path "$out/DlssNr_Shader.h")) { throw 'Header generator produced no header' }
    } elseif ($Tier -eq 'GuardCompile') {
        $hlsl = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl")
        $guard = @'
    // Native composed zero edits retain headroom without FP32-to-FP16 boundary drift.
    if (gSignalEncoding != 0 && gPassthrough == 0 && !modelRanSmall && gTransfer <= 1 &&
        gReversibleMode != 2 && gReversibleMode != 4 && gColourStrength <= 1 && all(edit == 0))
        result = originalSample.rgb;
'@
        $guard = $guard.Replace("`r`n","`n")
        $hlsl = $hlsl.Replace("`r`n","`n")
        $offset=$hlsl.IndexOf($guard)
        $mutant=Replace-One $hlsl $guard ''
        Generated "$out/guard-removed.hlsl" $mutant
        $guardSourceHashes=@("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli") | ForEach-Object {
            [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
        }
        [ordered]@{removedExactText=$guard;normalizedCharacterOffset=$offset;normalizedCharacterLength=$guard.Length;
            derivedSourceSha256=(Get-FileHash "$out/guard-removed.hlsl").Hash;
            sourceInputs=$guardSourceHashes;onlySemanticMutation='remove native composed zero-edit guard'} |
            ConvertTo-Json -Depth 6 | Set-Content "$out/guard-mutation.json" -Encoding UTF8
        Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3',
            '/I',"$repo/OptiScaler/shaders/dlssnr/precompile",'/Fo',"$out/DlssNr_Shader.cso",
            "$out/guard-removed.hlsl") 'guard-fxc'
    } elseif ($Tier -eq 'NegativeCompile') {
        $hlsl = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl")
        $mutant = Replace-One $hlsl 'return NrSignalDecodeRgb(code, gSignalEncoding, gPassthrough != 0);' 'return gPassthrough != 0 ? code : SrgbToLinear(code);'
        Generated "$out/dlssnr-domain.seed.hlsl" $mutant
        Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3',
            '/I',"$repo/OptiScaler/shaders/dlssnr/precompile",'/Fo',"$out/domain.seed.cso",
            "$out/dlssnr-domain.seed.hlsl") 'domain-fxc'
        $negativeSourceHashes=@(
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli"
        ) | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} }
    } elseif ($Tier -eq 'Math') {
        $env:VSCMD_ARG_TGT_ARCH='x64'
        $env:VCToolsVersion='14.44.35207'
        $env:WindowsSDKVersion='10.0.26100.0\'
        New-Item -ItemType Directory -Path "$out/task-10-negative" | Out-Null
        $helper=[IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli")
        Generated "$out/task-10-negative/dlssnr_signal.seed.hlsli" (
            Replace-One $helper 'kNrSignalPqNitsPerUnit = 100.0;' 'kNrSignalPqNitsPerUnit = 203.0;')
        Generated "$out/task-10-helper-compile.hlsl" (
            [IO.File]::ReadAllText("$EvidenceRoot/task-10-helper-compile.hlsl"))
        Invoke-Native 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
            '-File',"$PSScriptRoot/run_nr_signal_codec_contract.ps1",'-Tier','Contracts',
            '-EvidenceRoot',$out) 'independent-codec-math'
    } elseif ($Tier -in @('Product','ProductShader')) {
        $msbuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe'
        $queryArgs = @("$repo/OptiScaler/OptiScaler.vcxproj",'/nologo','/p:Configuration=Release',
            '/p:Platform=x64',"/p:SolutionDir=$support/",'/p:OptiScalerNrSelfTest=false',
            '/p:OptiScalerRtx40Mfg=false','/getProperty:IncludePath','/getItem:ClCompile')
        $query = & $msbuild @queryArgs
        $metadataExit = $LASTEXITCODE
        if ($metadataExit) { throw "Metadata failed: $metadataExit" }
        $query | Set-Content "$out/metadata.json" -Encoding UTF8
        $metadata = ($query -join "`n") | ConvertFrom-Json
        $env:INCLUDE = $metadata.Properties.IncludePath
        $units=if ($Tier -eq 'ProductShader') { @('shaders/dlssnr/DlssNr_Dx12.cpp') } else {
            @('shaders/dlssnr/DlssNr_Dx12_Models.cpp','shaders/dlssnr/DlssNr_Dx12_Encode.cpp',
            'shaders/dlssnr/DlssNr_Dx12_Run.cpp','shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp',
            'dlssnr/DlssNr_Proxy.cpp','dlssnr/DlssNr_Status.cpp')
        }
        foreach ($unit in $units) {
            $item = $metadata.Items.ClCompile | Where-Object { $_.Identity.Replace('\','/') -eq $unit }
            if (!$item) { throw "Actual product item missing: $unit" }
            $name = [IO.Path]::GetFileNameWithoutExtension($unit)
            $args = @('/nologo','/c','/std:c++latest','/EHsc','/MD','/W3','/permissive-','/Y-',
                "/Fo$out/$name.obj","/Fd$out/$name.pdb",'/sourceDependencies',"$out/$name.inputs.json")
            foreach ($define in $item.PreprocessorDefinitions.Split(';')) { if ($define) { $args += "/D$define" } }
            $args += "$repo/OptiScaler/$unit"
            Invoke-Native 'cl.exe' $args "$name-compile"
        }
    } elseif ($Tier -eq 'Contracts') {
        New-Item -ItemType Directory -Path "$out/proxies" | Out-Null
        foreach ($header in @('pch.h','Config.h','Logger.h','d3d12.h','proxies/NVNGX_Proxy.h')) {
            Generated "$out/$header" '// Typed dependency boundary supplied by MockNgx.h.'
        }
        $proxyPath = "$repo/OptiScaler/dlssnr/DlssNr_Proxy.cpp"
        $lifetimePath = "$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.h"
        $diagnosticPath = "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.h"
        $lifetime = [IO.File]::ReadAllText($lifetimePath)
        $diagnostic = [IO.File]::ReadAllText($diagnosticPath)
        $classStart = $lifetime.IndexOf('class GpuLifetime')
        $classEnd = $lifetime.IndexOf('};', $classStart) + 2
        $scopeStart = $diagnostic.IndexOf('class Scope')
        $scopeEnd = $diagnostic.IndexOf('// Explicit ordinary-thread', $scopeStart)
        if ($classStart -lt 0 -or $classEnd -le $classStart -or $scopeStart -lt 0 -or $scopeEnd -le $scopeStart) {
            throw 'Current completion/diagnostic declaration boundaries drifted'
        }
        Generated "$out/proxy-declarations.inc" ('#include <functional>' + "`n" +
            '#include <dlssnr/DlssNr_Proxy.h>' + "`n" +
            '#include <dlssnr/DlssNr_CompatibilityRuntime.h>' + "`n" +
            'namespace DlssNr { struct CaptureCompletion;' + $lifetime.Substring($classStart,$classEnd-$classStart) + '}' + "`n" +
            'namespace DlssNr::NgxDiagnostics {' + $diagnostic.Substring($scopeStart,$scopeEnd-$scopeStart) + '}')
        Generated "$out/proxy-production.inc" (Without-Includes ([IO.File]::ReadAllText($proxyPath)))
        $contractsSourceHashes = @($proxyPath,$lifetimePath,$diagnosticPath,
            "$out/proxy-declarations.inc","$out/proxy-production.inc") | ForEach-Object {
            [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
        }
        $proxyDefine = '/DNR_PROXY_SOURCE=\"' + $out.Replace('\','/') + '/proxy-production.inc\"'
        $models = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Models.cpp")
        $encode = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Encode.cpp")
        $run = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp")
        $services = [IO.File]::ReadAllText("$PSScriptRoot/dlssnr_proxy/ProxyTests.cpp")
        $start = $services.IndexOf('namespace DlssNr::NgxDiagnostics')
        $end = $services.IndexOf('#include "ModelPreparation.h"')
        if ($start -lt 0 -or $end -le $start) { throw 'Typed service source drift' }
        Generated "$out/proxy-services.inc" $services.Substring($start,$end-$start)
        Generated "$out/models-production.inc" (Without-Includes $models)
        Generated "$out/encode-production.inc" (Without-Includes $encode)
        Generated "$out/run-production.inc" (Without-Includes $run)
        Generated "$out/carrier-production.inc" (Without-Includes (
            [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp")))
        $history = Replace-One $models 'PassSettings(cfg, pass, uiCorrection, effectiveInputFilter, effectiveSignalEncoding)' 'PassSettings(cfg, pass, uiCorrection, effectiveInputFilter, 0u)'
        $domain = Replace-One $encode 'SetSignalEncoding(resolveParams, nr.effectiveSignalEncoding,' 'SetSignalEncoding(resolveParams, 0u,'
        Generated "$out/history-seed.inc" (Without-Includes $history)
        Generated "$out/domain-seed.inc" (Without-Includes $domain)
        foreach ($tag in @('green','history-negative','domain-negative')) {
            $args = @('/nologo','/std:c++20','/EHsc','/W4','/DNR_FILTER_INTEGRATION',
                "/FI$PSScriptRoot/dlssnr_proxy/MockNgx.h","/I$out",
                "/I$support/external/nvngx_dlss_sdk","/I$repo/OptiScaler",
                "/Fo$out/$tag.obj","/Fd$out/$tag.pdb","/Fe$out/$tag.exe",
                '/sourceDependencies',"$out/$tag.inputs.json",$proxyDefine)
            if ($tag -eq 'history-negative') { $args += ('/DNR_MODELS_SOURCE=\"'+$out.Replace('\','/')+'/history-seed.inc\"') }
            if ($tag -eq 'domain-negative') { $args += ('/DNR_ENCODE_SOURCE=\"'+$out.Replace('\','/')+'/domain-seed.inc\"') }
            $args += @("$PSScriptRoot/dlssnr_proxy/SignalIntegration.cpp",'/link','/VERBOSE:LIB')
            Invoke-Native 'cl.exe' $args "$tag-compile"
            $expected = if ($tag -eq 'green') { 0 } else { 1 }
            Invoke-Native "$out/$tag.exe" @("$out/$tag-recipes.bin") "$tag-contracts" $expected
            if ($expected) {
                $named = if ($tag -eq 'history-negative') { 'T11_HISTORY: effective-signal-reset' } else { 'T11_DOMAIN: paired-prepared-code' }
                if (!(Select-String -LiteralPath "$out/$tag-contracts.log" -SimpleMatch -Pattern $named)) {
                    throw "Named mutation missed: $named"
                }
            }
        }
        Invoke-Native 'cl.exe' @('/nologo','/std:c++20','/EHsc','/W4',
            '/DNR_FILTER_INTEGRATION','/DNR_SIGNAL_CARRIER',
            "/FI$PSScriptRoot/dlssnr_proxy/MockNgx.h","/I$out",
            "/I$support/external/nvngx_dlss_sdk","/I$repo/OptiScaler",
            "/Fo$out/carrier.obj","/Fd$out/carrier.pdb","/Fe$out/carrier.exe",
            '/sourceDependencies',"$out/carrier.inputs.json",$proxyDefine,
            "$PSScriptRoot/dlssnr_proxy/SignalCarrier.cpp",'/link','/VERBOSE:LIB') 'carrier-compile'
        Invoke-Native "$out/carrier.exe" @() 'carrier-contracts'
    } elseif ($Tier -in @('ShaderCompile','Task12Compile')) {
        Generated "$out/pch.h" '// Standalone fixture, no product PCH.'
        Invoke-Native 'cl.exe' @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',"/I$out",
            "/Fo$out/pixels.obj","/Fd$out/pixels.pdb","/Fe$out/nr_signal_integration_shader.exe",
            '/sourceDependencies',"$out/pixels.inputs.json","$PSScriptRoot/nr_signal_integration_shader.cpp",
            '/link','d3d11.lib','d3d12.lib','dxgi.lib','/VERBOSE:LIB') 'pixel-compile'
        $shaderSourceHashes=@(
            "$PSScriptRoot/nr_signal_integration_shader.cpp",
            "$PSScriptRoot/nr_resize_shader_smoke.cpp",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.h",
            "$repo/OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h"
        ) | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} }
} elseif ($Tier -eq 'Task12FilterCompile') {
        $hlsl=[IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl")
        Generated "$out/filter.seed.hlsl" (Replace-One $hlsl 'if (gInputFilter == 1)' 'if (gInputFilter == 999)')
        Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3','/I',
            "$repo/OptiScaler/shaders/dlssnr/precompile",'/Fo',"$out/filter.seed.cso","$out/filter.seed.hlsl") 'filter-fxc'
        $negativeSourceHashes=@("$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli") | ForEach-Object {
            [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
        }
    } elseif ($Tier -in @('Task12Shaders','Task12CodecNegative','Task12FilterNegative','Task12Transport','Task12TransportResume')) {
        if (!$ShaderRoot -or !$GenerateRoot) { throw 'Task12 current ShaderRoot and accepted GenerateRoot required' }
        $compiled=Get-Content "$ShaderRoot/result.json" -Raw | ConvertFrom-Json
        if ($compiled.status -ne 'PASS' -or $compiled.tier -ne 'Task12Compile') { throw 'Task12Compile receipt required' }
        foreach ($input in $compiled.shaderSourceHashes) {
            if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Task12 compiled input changed: $($input.path)" }
        }
        if ($Tier -eq 'Task12TransportResume') {
            if (!$TransportReuseManifest) { throw 'Task12 exact transport predecessor manifest required' }
            $reuse=Get-Content -LiteralPath $TransportReuseManifest -Raw | ConvertFrom-Json
            foreach ($input in $reuse.identities) {
                if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Task12 predecessor identity changed: $($input.path)" }
            }
            $old=Get-Content -LiteralPath $reuse.sourceArchive -Raw
            $current=Get-Content -LiteralPath "$repo/tests/nr_signal_integration_shader.cpp" -Raw
            if ($old.Substring(0,$old.IndexOf('void T12Transport(')).TrimEnd() -cne
                $current.Substring(0,$current.IndexOf('float T12StoredHalfReference(')).TrimEnd()) { throw 'Task12 shared math/WARP/matrix/finished/PQ prefix changed' }
            foreach ($region in $reuse.exactRegions) {
                $a=$old.IndexOf($region.start);$b=$current.IndexOf($region.start)
                $ae=$old.IndexOf($region.end,$a);$be=$current.IndexOf($region.end,$b)
                if ($a -lt 0 -or $b -lt 0 -or $ae -lt $a -or $be -lt $b -or
                    $old.Substring($a,$ae-$a) -cne $current.Substring($b,$be-$b)) { throw "Task12 reused source region changed: $($region.name)" }
            }
            $priorLog=Get-Content -LiteralPath "$($reuse.priorRuntimeRoot)/pixels.log" -Raw
            foreach ($line in $reuse.passedCaseLines) { if (!$priorLog.Contains($line)) { throw 'Task12 passed predecessor case missing' } }
            $priorRows=@(Import-Csv -LiteralPath "$($reuse.priorRuntimeRoot)/pixel-comparisons.csv" | Where-Object { [int]$_.case -le 7 })
            if ($priorRows.Count -ne 64) { throw 'Task12 exact predecessor reference extent changed' }
            foreach ($row in $priorRows) { foreach ($channel in @('R','G','B','A')) {
                $actual=[double]$row.("actual"+$channel);$expectedValue=[double]$row.("expected"+$channel)
                if ([double]::IsNaN($actual) -or [double]::IsInfinity($actual) -or
                    [Math]::Abs($actual-$expectedValue) -gt [double]$row.limit) { throw 'Task12 predecessor captured pixel reference failed' }
            } }
            [ordered]@{manifest=$TransportReuseManifest;priorRuntimeRoot=$reuse.priorRuntimeRoot;priorBinary=$reuse.priorBinary;
                reusedConnectedCases=7;reusedExternalAnchors=4;reusedReferenceRows=64;sharedPrefixExact=$true;
                exactRegions=$reuse.exactRegions.name;currentCompileRoot=$ShaderRoot;oldMainInvoked=$false} |
                ConvertTo-Json -Depth 6 | Set-Content "$out/transport-reuse-binding.json" -Encoding UTF8
        }
        $processes=@(Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine)
        $processes | ConvertTo-Json -Depth 4 | Set-Content "$out/runtime-processes.json" -Encoding UTF8
        $busy=@(Busy-Owners $processes)
        if ($busy.Count) { throw ('GPU_OWNER_BUSY pids='+(($busy.ProcessId)-join ',')) }
        Invoke-Native 'nvidia-smi.exe' @('--query-gpu=name,utilization.gpu,memory.used','--format=csv,noheader') 'gpu-census'
        Invoke-Native 'nvidia-smi.exe' @('--query-compute-apps=pid,process_name,used_memory','--format=csv,noheader') 'gpu-owners'
        if ((Get-FileHash $legacyCso).Hash -ne '195AD4D5C7C33F44377280FFE43E709CB1306752E59BA416690286ECB18F2DC1') { throw 'Accepted Legacy identity changed' }
        $mutant='-';$expected=0
        if ($Tier -notin @('Task12Shaders','Task12Transport','Task12TransportResume')) {
            $negative=Get-Content "$NegativeRoot/result.json" -Raw | ConvertFrom-Json
            $required=if ($Tier -eq 'Task12CodecNegative') { 'NegativeCompile' } else { 'Task12FilterCompile' }
            if ($negative.status -ne 'PASS' -or $negative.tier -ne $required) { throw 'Exact negative compile receipt required' }
            foreach ($input in $negative.negativeSourceHashes) {
                if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Task12 mutant input changed: $($input.path)" }
            }
            $mutant=if ($Tier -eq 'Task12CodecNegative') { "$NegativeRoot/domain.seed.cso" } else { "$NegativeRoot/filter.seed.cso" }
            $expected=1
        }
        $mode=if ($Tier -eq 'Task12TransportResume') { '--task12-transport-resume' } elseif ($Tier -eq 'Task12Transport') { '--task12-transport' } else { '--task12' }
        Invoke-Native "$ShaderRoot/nr_signal_integration_shader.exe" @($mode,
            "$GenerateRoot/DlssNr_Shader.cso",$legacyCso,"$out/pixel-comparisons.csv",$mutant) 'pixels' $expected
        if ($expected) {
            $assertion=if ($Tier -eq 'Task12CodecNegative') { 'T12_INDEPENDENT_PAIRED_DECODE' } else { 'T12_INDEPENDENT_FILTER' }
            if (!(Select-String -LiteralPath "$out/pixels.log" -SimpleMatch "reason=$assertion")) { throw 'Task12 behavioral negative assertion missing' }
        }
    } elseif ($Tier -eq 'AdmissionCheck') {
        $injected=@([pscustomobject]@{Name='CrimsonDesert.exe';ProcessId=1001},
            [pscustomobject]@{Name='obs64.exe';ProcessId=1002},
            [pscustomobject]@{Name='steamwebhelper.exe';ProcessId=1003})
        $detected=@(Busy-Owners $injected)
        if ($detected.Count -ne 2 -or $detected.ProcessId -contains 1003) { throw 'T11_CPU_ADMISSION_INJECTED_NEGATIVE' }
        $actual=@(Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine)
        $busy=@(Busy-Owners $actual)
        [ordered]@{utc=[DateTime]::UtcNow.ToString('o');cpuOnly=$true;injected=$injected;
            injectedRejected=$detected;actualBusyOwners=$busy;runtimeAdmission=($busy.Count -eq 0);
            nativeGpuCommands=0;foreignProcessActions=0} | ConvertTo-Json -Depth 5 |
            Set-Content "$out/admission-check.json" -Encoding UTF8
        Write-Host "T11_CPU_ADMISSION_CHECK injectedRejected=$($detected.Count) actualBusy=$($busy.Count) nativeGpuCommands=0"
    } elseif ($Tier -in @('Shaders','GraphDiagnostic','ScopeDiagnostic','Negative')) {
        if (!$ContractsRoot -or !$GenerateRoot) { throw 'Current ContractsRoot and GenerateRoot required' }
        if (!$ShaderRoot) { throw 'Current ShaderCompile root required' }
        $processes = @(Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine)
        $processes | ConvertTo-Json -Depth 4 | Set-Content "$out/runtime-processes.json" -Encoding UTF8
        $busy = @(Busy-Owners $processes)
        if ($busy.Count) { throw ('GPU_OWNER_BUSY pids=' + (($busy.ProcessId) -join ',')) }
        Invoke-Native 'nvidia-smi.exe' @('--query-gpu=name,utilization.gpu,memory.used',
            '--format=csv,noheader') 'gpu-census'
        Invoke-Native 'nvidia-smi.exe' @('--query-compute-apps=pid,process_name,used_memory',
            '--format=csv,noheader') 'gpu-owners'
        Write-Host 'T11_RUNTIME_PREFLIGHT WARP-only no-known-game-OBS-owner=1'
        if ((Get-FileHash $legacyCso).Hash -ne '195AD4D5C7C33F44377280FFE43E709CB1306752E59BA416690286ECB18F2DC1') {
            throw 'Accepted Legacy bytecode mismatch'
        }
        $compiled = Get-Content "$ShaderRoot/result.json" -Raw | ConvertFrom-Json
        if ($compiled.status -ne 'PASS' -or $compiled.tier -ne 'ShaderCompile') { throw 'Current shader compile receipt missing' }
        foreach ($input in $compiled.shaderSourceHashes) {
            if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Shader input changed after compile: $($input.path)" }
        }
        $pixelArgs = @("$GenerateRoot/DlssNr_Shader.cso","$ContractsRoot/green-recipes.bin",$legacyCso,$acceptedRecipes)
        if (!$GuardBaselineRoot) { throw 'Guard baseline required' }
        $baseline=Get-Content "$GuardBaselineRoot/result.json" -Raw | ConvertFrom-Json
        if ($baseline.tier -eq 'GuardCompile' -and $baseline.status -eq 'PASS') {
            foreach ($input in $baseline.guardSourceHashes) {
                if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Guard baseline input changed: $($input.path)" }
            }
            $mutation=Get-Content "$GuardBaselineRoot/guard-mutation.json" -Raw | ConvertFrom-Json
            if ((Get-FileHash "$GuardBaselineRoot/guard-removed.hlsl").Hash -ne $mutation.derivedSourceSha256) { throw 'Guard baseline derived source changed' }
        } elseif ((Get-FileHash "$GuardBaselineRoot/DlssNr_Shader.cso").Hash -ne
            'ACFFBA27B981374E42918794EFAC210EDDE87EF6D15E6AFC39A93A5B31D66474') {
            throw 'Exact preserved pre-guard or current guard-only mutation required'
        }
        $pixelArgs += "$GuardBaselineRoot/DlssNr_Shader.cso"
        $expected = 0
        if ($Tier -eq 'GraphDiagnostic') {
            $option="--diagnose-graph=$GraphRecipe"
            if ($GraphComparisonRoot) {
                if ((Get-FileHash "$GraphComparisonRoot/DlssNr_Shader.cso").Hash -ne 'A7B3634398142B0B2B830C19617009104AD11BD8289C37267B76816C83574D04') { throw 'Exact pre-q7 shader required' }
                $option += ",$GraphComparisonRoot/DlssNr_Shader.cso"
            }
            $pixelArgs += $option
        }
        if ($Tier -eq 'ScopeDiagnostic') { $pixelArgs += '--diagnose-scope' }
        if ($Tier -eq 'Shaders' -and $VerifiedScopeRoot) {
            $scope=Get-Content "$VerifiedScopeRoot/result.json" -Raw | ConvertFrom-Json
            if ($scope.status -ne 'PASS' -or $scope.tier -ne 'ScopeDiagnostic') { throw 'Verified scope receipt required' }
            $scopeCommand=@($scope.commands | Where-Object { $_.log -like '*/pixels.log' })[0]
            if ($scopeCommand.exit -ne 0 -or $scopeCommand.arguments[-1] -ne '--diagnose-scope') { throw 'Exact successful scope command required' }
            for ($i=0;$i -lt $pixelArgs.Count;++$i) {
                if ($scopeCommand.arguments[$i] -cne $pixelArgs[$i]) { throw 'Scope source/recipe/bytecode inputs differ' }
            }
            $oldCompileRoot=[IO.Path]::GetDirectoryName($scopeCommand.program)
            $oldCompile=Get-Content "$oldCompileRoot/result.json" -Raw | ConvertFrom-Json
            foreach ($input in $oldCompile.shaderSourceHashes) {
                if ($input.path -notlike '*nr_signal_integration_shader.cpp' -and (Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw 'Scope shared input changed' }
            }
            $source=[IO.File]::ReadAllText("$repo/tests/nr_signal_integration_shader.cpp").Replace("`r`n","`n")
            $prefix=$source.Substring(0,$source.IndexOf('int main(')).TrimEnd()
            $savedPrefix=[IO.File]::ReadAllText("$EvidenceRoot/task-11-verified-scope-prefix.cpp").TrimEnd()
            if ($prefix -cne $savedPrefix) { throw 'Verified scope implementation changed' }
            $bound=@($pixelArgs + @($scopeCommand.program,"$ShaderRoot/nr_signal_integration_shader.exe","$EvidenceRoot/task-11-verified-scope-prefix.cpp")) | ForEach-Object {
                [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash;bytes=(Get-Item -LiteralPath $_).Length}
            }
            [ordered]@{scopeReceipt="$VerifiedScopeRoot/result.json";scopeExecutable=$scopeCommand.program;
                graphExecutable="$ShaderRoot/nr_signal_integration_shader.exe";functionPrefixExact=$true;
                sameActualScopeInputs=$true;identities=$bound;graphRecipes=7776;graphFormatCases=15552;
                scopeCases=72;exclusionCases=90;separateNativeReceipts=$true} | ConvertTo-Json -Depth 6 |
                Set-Content "$out/scope-reuse-binding.json" -Encoding UTF8
            $pixelArgs += '--graph-only'
        }
        if ($Tier -eq 'Negative') {
            if (!$NegativeRoot) { throw 'Current NegativeCompile root required' }
            $negative = Get-Content "$NegativeRoot/result.json" -Raw | ConvertFrom-Json
            if ($negative.status -ne 'PASS' -or $negative.tier -ne 'NegativeCompile') { throw 'Current negative compile receipt missing' }
            foreach ($input in $negative.negativeSourceHashes) {
                if ((Get-FileHash -LiteralPath $input.path).Hash -ne $input.sha256) { throw "Negative source changed: $($input.path)" }
            }
            $pixelArgs += "$NegativeRoot/domain.seed.cso"; $expected = 1
        }
        Invoke-Native "$ShaderRoot/nr_signal_integration_shader.exe" $pixelArgs 'pixels' $expected
        if ($expected -and !(Select-String -LiteralPath "$out/pixels.log" -Pattern 'T11_.*(DECODE|DOMAIN|decode|domain)' )) {
            throw 'Named shader domain mutation assertion missing'
        }
    } elseif ($Tier -eq 'Binding') {
        if (!$ReceiptRoots) { throw 'Current receipt roots required' }
        $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $dependencies=@(); $libraries=@()
        foreach ($root in $ReceiptRoots) {
            $receipt = Get-Content "$root/result.json" -Raw | ConvertFrom-Json
            foreach ($command in $receipt.commands) { [void]$paths.Add($command.program) }
            foreach ($dep in Get-ChildItem $root -Recurse -File | Where-Object {
                $_.Name -like '*.inputs.json' -or $_.Name -like '*.dependencies.json'
            }) {
                $record = Get-Content $dep.FullName -Raw | ConvertFrom-Json
                $dependencies += $record; [void]$paths.Add($record.Data.Source)
                foreach ($include in $record.Data.Includes) { [void]$paths.Add($include) }
            }
            foreach ($log in Get-ChildItem $root -Recurse -File | Where-Object {
                $_.Name -like '*compile.log' -or $_.Name -like '*-link.log'
            }) {
                $text = Get-Content $log.FullName -Raw
                foreach ($match in [regex]::Matches($text,'(?im)^\s*(?:Searching\s+)?([A-Za-z]:[\\/][^"<>\r\n]*?\.lib)(?:\s+\uAC80\uC0C9 \uC911)?\s*:\s*$')) {
                    $library=$match.Groups[1].Value.Trim()
                    $libraries += [ordered]@{log=$log.FullName;path=$library}; [void]$paths.Add($library)
                }
            }
            foreach ($artifact in Get-ChildItem $root -Recurse -File) { [void]$paths.Add($artifact.FullName) }
        }
        if (!$libraries.Count) { throw 'Actual library records absent' }
        foreach ($path in @("$vc/bin/HostX86/x64/c1xx.dll","$vc/bin/HostX86/x64/c2.dll",
            "$vc/bin/HostX86/x64/mspdb140.dll","$vc/bin/HostX86/x64/link.exe",
            "$sdk/bin/10.0.26100.0/x64/d3dcompiler_47.dll",
            'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe',
            'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
            "$repo/OptiScaler/OptiScaler.vcxproj","$repo/CONTRIBUTING.md",
            "$repo/tests/run_nr_signal_integration.ps1","$repo/OptiScaler/shaders/shader_tools/create_header.py",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Resources.cpp",
            "$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.cpp",$legacyCso,$acceptedRecipes,
            "$repo/tests/run_nr_signal_codec_contract.ps1",
            "$EvidenceRoot/task-10-helper-compile.hlsl","$EvidenceRoot/task-10-reference-decimal.json",
            'C:/Users/USER/.bun/bin/bun.exe','C:/Windows/System32/nvml.dll',
            "$EvidenceRoot/task-9-filter-integration.json","$EvidenceRoot/task-10-codec-contract.json")) {
            [void]$paths.Add($path)
        }
        $python = (Get-Command python.exe).Source
        foreach ($dll in Get-ChildItem ([IO.Path]::GetDirectoryName($python)) -Filter 'python*.dll') { [void]$paths.Add($dll.FullName) }
        $identities=@($paths | Sort-Object | ForEach-Object {
            if (!(Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Consumed input missing: $_" }
            $file=Get-Item -LiteralPath $_
            [ordered]@{path=$file.FullName;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $_).Hash}
        })
        $identities | ConvertTo-Json -Depth 5 | Set-Content "$out/identities.json" -Encoding UTF8
        $dependencies | ConvertTo-Json -Depth 12 | Set-Content "$out/compiler-inputs.json" -Encoding UTF8
        $libraries | ConvertTo-Json -Depth 5 | Set-Content "$out/library-inputs.json" -Encoding UTF8
        Invoke-Native 'git.exe' @('-C',$repo,'diff','--check') 'whitespace'
        Invoke-Native 'git.exe' @('-C',$repo,'rev-parse','HEAD') 'head'
        $owned=@(Get-CimInstance Win32_Process | Where-Object {
            $_.ProcessId -ne $PID -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($EvidenceRoot) -and
            $_.ExecutablePath -match 'task-11-'
        } | Select-Object ProcessId,Name,ExecutablePath)
        if ($owned.Count) { throw 'Owned native process remains' }
        [ordered]@{utc=[DateTime]::UtcNow.ToString('o');ownedProcesses=$owned;ownedProcessCount=0;
            pendingNativeCommands=0;ownedWindows=0;gpu='software WARP resources released on native exit'} |
            ConvertTo-Json -Depth 5 | Set-Content "$out/cleanup.json" -Encoding UTF8
        Write-Host "T11_BINDING identities=$($identities.Count) dependencies=$($dependencies.Count) libraries=$($libraries.Count)"
    }
    [ordered]@{status='PASS';tier=$Tier;root=$out;commands=$commands;metadataExit=$metadataExit;
        contractsSourceHashes=$contractsSourceHashes;
        shaderSourceHashes=$shaderSourceHashes;
        negativeSourceHashes=$negativeSourceHashes;
        guardSourceHashes=$guardSourceHashes;
        legacyCso=$legacyCso;acceptedRecipeKeys=$acceptedRecipes;fullDll=$false;physicalProvider=$false;
        independentAcceptance=$false;completedUtc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 10 | Set-Content "$out/result.json" -Encoding UTF8
    Write-Host "T11_PASS tier=$Tier root=$out"
} finally { Stop-Transcript | Out-Null }
