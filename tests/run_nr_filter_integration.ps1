param(
    [ValidateSet('Contracts','Shaders','Product','Binding')][string]$Tier,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [string]$ContractsRoot,
    [string]$AcceptedReferenceRoot,
    [string]$BytecodePath,
    [string[]]$ReceiptRoots
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
$out = Join-Path $EvidenceRoot ('task-9-' + $Tier.ToLower() + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
try {
    $vc = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207'
    $sdk = 'C:/Program Files (x86)/Windows Kits/10'
    $support = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1'
    $env:PATH = "$vc/bin/HostX86/x64;" + $env:PATH
    $env:INCLUDE = "$vc/include;$sdk/Include/10.0.26100.0/ucrt;$sdk/Include/10.0.26100.0/shared;$sdk/Include/10.0.26100.0/um;$sdk/Include/10.0.26100.0/winrt"
    $env:LIB = "$vc/lib/x64;$sdk/Lib/10.0.26100.0/ucrt/x64;$sdk/Lib/10.0.26100.0/um/x64"
    $commands = @()
    function Invoke-Native([string]$program,[string[]]$arguments,[string]$name,[int]$expected=0) {
        Write-Host ("T9_COMMAND=$program " + ($arguments -join ' '))
        $ErrorActionPreference = 'Continue'
        & $program @arguments 2>&1 | Tee-Object -FilePath "$out/$name.log" | Write-Host
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Write-Host "T9_EXIT=$code name=$name expected=$expected"
        $script:commands += [ordered]@{program=$program;arguments=$arguments;exit=$code;expected=$expected}
        if ($code -ne $expected) { throw "$name exited $code, expected $expected" }
    }
    function Write-Generated([string]$path,[string]$text) {
        # Derived compiler inputs only, never candidate sources. Full source
        # hashes and transformations are retained alongside native dependencies.
        [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
    }
    function Without-Includes([string]$text) { [regex]::Replace($text,'(?m)^#include[^\r\n]*','') }
    function Replace-One([string]$text,[string]$old,[string]$new) {
        if (($text.Split(@($old),[StringSplitOptions]::None).Count-1) -ne 1) { throw "Source anchor drift: $old" }
        $text.Replace($old,$new)
    }
    if ($Tier -eq 'Contracts') {
        New-Item -ItemType Directory -Path "$out/proxies" | Out-Null
        foreach ($header in @('pch.h','Config.h','Logger.h','d3d12.h','proxies/NVNGX_Proxy.h')) {
            Write-Generated "$out/$header" '// Typed dependency supplied by MockNgx.h.'
        }
        # Reuse the signal Contracts boundary: current Proxy includes the real
        # capture header, whose Win32 interfaces cannot coexist with MockNgx.
        # Extract declarations, not policy or implementation replacements.
        $proxyPath = "$repo/OptiScaler/dlssnr/DlssNr_Proxy.cpp"
        $lifetime = [IO.File]::ReadAllText("$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.h")
        $diagnostic = [IO.File]::ReadAllText("$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.h")
        $classStart = $lifetime.IndexOf('class GpuLifetime')
        $classEnd = $lifetime.IndexOf('};', $classStart) + 2
        $scopeStart = $diagnostic.IndexOf('class Scope')
        $scopeEnd = $diagnostic.IndexOf('// Explicit ordinary-thread', $scopeStart)
        if ($classStart -lt 0 -or $classEnd -le $classStart -or $scopeStart -lt 0 -or $scopeEnd -le $scopeStart) {
            throw 'Current completion/diagnostic declaration boundaries drifted'
        }
        Write-Generated "$out/proxy-declarations.inc" ('#include <functional>' + "`n" +
            '#include <dlssnr/DlssNr_Proxy.h>' + "`n" +
            '#include <dlssnr/DlssNr_CompatibilityRuntime.h>' + "`n" +
            'namespace DlssNr { struct CaptureCompletion;' + $lifetime.Substring($classStart,$classEnd-$classStart) + '}' + "`n" +
            'namespace DlssNr::NgxDiagnostics {' + $diagnostic.Substring($scopeStart,$scopeEnd-$scopeStart) + '}')
        Write-Generated "$out/proxy-production.inc" (Without-Includes ([IO.File]::ReadAllText($proxyPath)))
        $proxyDefine = '/DNR_PROXY_SOURCE=\"' + $out.Replace('\','/') + '/proxy-production.inc\"'
        $models = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Models.cpp")
        $encode = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Encode.cpp")
        $run = [IO.File]::ReadAllText("$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp")
        $proxyServices = [IO.File]::ReadAllText("$PSScriptRoot/dlssnr_proxy/ProxyTests.cpp")
        $start = $proxyServices.IndexOf('namespace DlssNr::NgxDiagnostics')
        $end = $proxyServices.IndexOf('#include "ModelPreparation.h"')
        if ($start -lt 0 -or $end -le $start) { throw 'Typed proxy service source drift' }
        Write-Generated "$out/proxy-services.inc" $proxyServices.Substring($start,$end-$start)
        Write-Generated "$out/models-production.inc" (Without-Includes $models)
        Write-Generated "$out/encode-production.inc" (Without-Includes $encode)
        Write-Generated "$out/run-production.inc" (Without-Includes $run)
        $historySeed = Replace-One $models 'PassSettings(cfg, pass, uiCorrection, effectiveInputFilter, effectiveSignalEncoding)' 'PassSettings(cfg, pass, uiCorrection, 0u, effectiveSignalEncoding)'
        Write-Generated "$out/history-seed.inc" (Without-Includes $historySeed)
        $referenceSeed = Replace-One $run 'superDownOk ? nr.colorCopy : modelInput' 'superDownOk ? nr.colorCopy : nr.colorCopy'
        Write-Generated "$out/reference-seed.inc" (Without-Includes $referenceSeed)
        # Keep the current caller drift check, but do not erase later accepted
        # signal/status/capture changes and mislabel those bytes as the old baseline.
        $callerRecovery = Replace-One $run ("PassSettings(cfg, pass, outputStatus.uiCorrection,`n" +
            '                                                                  nr.effectiveInputFilter, nr.effectiveSignalEncoding)') 'PassSettings(cfg, pass, outputStatus.uiCorrection)'
        $oldBlock = @'
            DlssNr_Common::SetInputFilter(down, width, height,
                static_cast<uint32_t>(cfg.DlssNrInputFilter.value_or_default()),
                outputStatus.optionContext.nativeDx12);
            shader.DispatchPass(cmdList, down, modelInput, nullptr, nullptr, nullptr, nullptr, nr.colorSmall,
                                nullptr);
'@
        $newBlock = @'
            const bool filterSupported = DlssNr_Common::SetInputFilter(down, width, height,
                nr.effectiveInputFilter, outputStatus.optionContext.nativeDx12);
            if (shader.DispatchPass(cmdList, down, modelInput, nullptr, nullptr, nullptr, nullptr, nr.colorSmall,
                                    nullptr))
            {
                outputStatus.inputFilter = down.InputFilter;
                outputStatus.inputFilterOverrideSupported = filterSupported;
            }
'@
        $encodeRecovery = Replace-One $encode $newBlock $oldBlock
        Write-Generated "$out/current-filter-caller-recovery.cpp" $callerRecovery
        Write-Generated "$out/current-filter-encode-recovery.cpp" $encodeRecovery
        if (!$AcceptedReferenceRoot) { throw 'Accepted immutable filter Contracts reference root required' }
        $reference = (Resolve-Path -LiteralPath $AcceptedReferenceRoot).Path
        $oldRunPath = Join-Path $reference 'accepted-run.cpp'
        $oldEncodePath = Join-Path $reference 'accepted-encode.cpp'
        if ((Get-FileHash -LiteralPath $oldRunPath).Hash -ne 'DA05DAD23F16284F4C27F99B02C728B1E536351D61FF4F05C3A3B8DEBCA5C278') { throw 'Accepted Task7 Run identity mismatch' }
        if ((Get-FileHash -LiteralPath $oldEncodePath).Hash -ne 'F30841B14D70A6D2B2BF14B1A5A31EC2CB1BFBE7E5416D4BCC58A75F76EBD314') { throw 'Accepted Task8 Encode identity mismatch' }
        $oldRun = [IO.File]::ReadAllText($oldRunPath)
        $oldEncode = [IO.File]::ReadAllText($oldEncodePath)
        [ordered]@{run=[ordered]@{path=$oldRunPath;sha256=(Get-FileHash $oldRunPath).Hash};
            encode=[ordered]@{path=$oldEncodePath;sha256=(Get-FileHash $oldEncodePath).Hash};
            currentRunSha256=(Get-FileHash "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp").Hash;
            currentEncodeSha256=(Get-FileHash "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Encode.cpp").Hash;
            method='Exact immutable accepted references; current filter-only recovery retained separately';
            referenceSourcesModified=$false} | ConvertTo-Json -Depth 6 |
            Set-Content "$out/reference-lineage.json" -Encoding UTF8
        Write-Generated "$out/baseline-run.inc" (Without-Includes $oldRun)
        Write-Generated "$out/baseline-encode.inc" (Without-Includes $oldEncode)
        foreach ($tag in @('green','history-negative','reference-negative','baseline')) {
            $args = @('/nologo','/std:c++20','/EHsc','/W4','/DNR_FILTER_INTEGRATION',
                "/FI$PSScriptRoot/dlssnr_proxy/MockNgx.h","/I$out",
                "/I$support/external/nvngx_dlss_sdk","/I$repo/OptiScaler",
                "/Fo$out/$tag.obj","/Fd$out/$tag.pdb","/Fe$out/$tag.exe",
                '/sourceDependencies',"$out/$tag.inputs.json",$proxyDefine)
            if ($tag -eq 'history-negative') { $args += ('/DNR_MODELS_SOURCE=\"'+$out.Replace('\','/')+'/history-seed.inc\"') }
            if ($tag -eq 'reference-negative') { $args += ('/DNR_RUN_SOURCE=\"'+$out.Replace('\','/')+'/reference-seed.inc\"') }
            if ($tag -eq 'baseline') {
                $args += '/DNR_BASELINE'
                $args += ('/DNR_RUN_SOURCE=\"'+$out.Replace('\','/')+'/baseline-run.inc\"')
                $args += ('/DNR_ENCODE_SOURCE=\"'+$out.Replace('\','/')+'/baseline-encode.inc\"')
            }
            $args += @("$PSScriptRoot/dlssnr_proxy/FilterIntegration.cpp",'/link','/VERBOSE:LIB')
            Invoke-Native 'cl.exe' $args "$tag-compile"
            $expected = if ($tag -like '*negative') { 1 } else { 0 }
            Invoke-Native "$out/$tag.exe" @("$out/$tag-recipes.bin") "$tag-contracts" $expected
            if ($expected) {
                $named = if ($tag -eq 'history-negative') { 'T9_HISTORY: effective-filter-reset' } else { 'T9_REFERENCE: immutable-model-input' }
                if (!(Select-String -LiteralPath "$out/$tag-contracts.log" -SimpleMatch -Pattern $named)) { throw "Named mutation assertion missed: $tag" }
            }
        }
    } elseif ($Tier -eq 'Shaders') {
        if (!$ContractsRoot) { throw 'Current ContractsRoot required' }
        $processes = @(Get-CimInstance Win32_Process | Select-Object ProcessId,Name,ExecutablePath,CommandLine)
        $processes | ConvertTo-Json -Depth 4 | Set-Content "$out/runtime-processes.json" -Encoding UTF8
        $busy = @($processes | Where-Object { $_.Name -match '^(obs64|obs32|ffxiv_dx11|eldenring|Cyberpunk2077|bg3_dx11|bg3|HogwartsLegacy|LosslessScaling|tlou-i|ACShadows|ACMirage|MonsterHunterWilds|re4|DragonAgeTheVeilguard|TheFirstDescendant|BlackMythWukong)\.exe$' })
        if ($busy.Count) { throw ('GPU_OWNER_BUSY pids=' + (($busy.ProcessId) -join ',')) }
        Write-Host 'T9_RUNTIME_PREFLIGHT WARP-only no-known-game-OBS-owner=1'
        $fxc = "$sdk/bin/10.0.26100.0/x64/fxc.exe"
        if ($BytecodePath) {
            # Reuse only the exact already-fresh Task8/9 bytes while this kernel
            # is unchanged. The executable still compares the shipped array.
            if ((Get-FileHash "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl").Hash -ne
                '39CF06900E3399DAAD8CA8FEEB005DDEE5C92AB02EAF668620797F1162289A11' -or
                (Get-FileHash "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli").Hash -ne
                'D47EFC0A8EB04611799227F2FBDDF6BE42B03771546D1259BE34F364F5459A83' -or
                (Get-FileHash $BytecodePath).Hash -ne
                '195AD4D5C7C33F44377280FFE43E709CB1306752E59BA416690286ECB18F2DC1') {
                throw 'Unchanged fresh bytecode identity mismatch'
            }
            $cso = $BytecodePath
        } else {
            $cso = "$out/DlssNr_Shader.cso"
            Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3','/Fo',$cso,
                "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl") 'fxc'
        }
        Invoke-Native 'cl.exe' @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',
            "/Fo$out/pixels.obj","/Fd$out/pixels.pdb","/Fe$out/nr_resize_shader_smoke.exe",
            '/sourceDependencies',"$out/pixels.inputs.json","$PSScriptRoot/nr_resize_shader_smoke.cpp",
            '/link','d3d11.lib','d3d12.lib','dxgi.lib','/VERBOSE:LIB') 'pixel-compile'
        Invoke-Native "$out/nr_resize_shader_smoke.exe" @('--integration',$cso,
            "$ContractsRoot/green-recipes.bin","$ContractsRoot/baseline-recipes.bin") 'pixels'
    } elseif ($Tier -eq 'Product') {
        $msbuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe'
        $queryArgs = @("$repo/OptiScaler/OptiScaler.vcxproj",'/nologo','/p:Configuration=Release',
            '/p:Platform=x64',"/p:SolutionDir=$support/",'/p:OptiScalerNrSelfTest=false',
            '/p:OptiScalerRtx40Mfg=false','/getProperty:IncludePath','/getItem:ClCompile')
        Write-Host ("T9_METADATA_COMMAND=$msbuild " + ($queryArgs -join ' '))
        $query = & $msbuild @queryArgs
        $metadataExit = $LASTEXITCODE
        if ($metadataExit) { throw "Metadata failed: $metadataExit" }
        $query | Set-Content "$out/metadata.json" -Encoding UTF8
        $metadata = ($query -join "`n") | ConvertFrom-Json
        $env:INCLUDE = $metadata.Properties.IncludePath
        foreach ($unit in @('shaders/dlssnr/DlssNr_Dx12_Models.cpp','shaders/dlssnr/DlssNr_Dx12_Encode.cpp',
                            'shaders/dlssnr/DlssNr_Dx12_Run.cpp','dlssnr/DlssNr_Proxy.cpp')) {
            $item = $metadata.Items.ClCompile | Where-Object { $_.Identity.Replace('\','/') -eq $unit }
            if (!$item) { throw "Actual product item missing: $unit" }
            $name = [IO.Path]::GetFileNameWithoutExtension($unit)
            $args = @('/nologo','/c','/std:c++latest','/EHsc','/MD','/W3','/permissive-','/Y-',
                "/Fo$out/$name.obj","/Fd$out/$name.pdb",'/sourceDependencies',"$out/$name.inputs.json")
            foreach ($define in $item.PreprocessorDefinitions.Split(';')) { if ($define) { $args += "/D$define" } }
            $args += "$repo/OptiScaler/$unit"
            Invoke-Native 'cl.exe' $args "$name-compile"
        }
    } else {
        if (!$ReceiptRoots) { throw 'Current receipt roots required' }
        $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $dependencies = @(); $libraries = @()
        foreach ($root in $ReceiptRoots) {
            foreach ($dep in Get-ChildItem $root -Filter '*.inputs.json') {
                $record = Get-Content $dep.FullName -Raw | ConvertFrom-Json
                $dependencies += $record
                [void]$paths.Add($record.Data.Source)
                foreach ($include in $record.Data.Includes) { [void]$paths.Add($include) }
            }
            foreach ($log in Get-ChildItem $root -Filter '*compile.log') {
                $text = Get-Content $log.FullName -Raw
                foreach ($match in [regex]::Matches($text,'(?im)^\s*(?:Searching\s+)?([A-Za-z]:[\\/][^"<>\r\n]*?\.lib)(?:\s+\uAC80\uC0C9 \uC911)?\s*:\s*$')) {
                    $library = $match.Groups[1].Value.Trim()
                    $libraries += [ordered]@{log=$log.FullName;path=$library}
                    [void]$paths.Add($library)
                }
            }
            foreach ($artifact in Get-ChildItem $root -File) { [void]$paths.Add($artifact.FullName) }
        }
        foreach ($file in @("$vc/bin/HostX86/x64/cl.exe","$vc/bin/HostX86/x64/c1xx.dll",
            "$vc/bin/HostX86/x64/c2.dll","$vc/bin/HostX86/x64/link.exe",
            "$sdk/bin/10.0.26100.0/x64/fxc.exe","$repo/tests/run_nr_filter_integration.ps1",
            "$sdk/bin/10.0.26100.0/x64/d3dcompiler_47.dll",
            'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe',
            'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
            "$repo/OptiScaler/OptiScaler.vcxproj",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl",
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli",
            "$repo/OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_ModelState.h",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp",
            "$repo/OptiScaler/shaders/Shader_Dx12Utils.h",
            "$repo/OptiScaler/shaders/output_scaling/OS_Dx12.cpp",
            "$repo/OptiScaler/shaders/output_scaling/OS_Dx12.h",
            "$repo/OptiScaler/shaders/output_scaling/OS_Common.h",
            "$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.cpp",
            "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Resources.cpp")) { [void]$paths.Add($file) }
        if (!$libraries.Count) { throw 'Actual native library search records missing' }
        if ($BytecodePath) {
            [void]$paths.Add($BytecodePath)
            [void]$paths.Add((Join-Path ([IO.Path]::GetDirectoryName($BytecodePath)) 'fxc.log'))
        }
        $prior = Get-Content "$EvidenceRoot/task-7-binding-11a39c053b424774986248ce073ee865/identities.json" -Raw | ConvertFrom-Json
        $protected = @()
        foreach ($relative in @('OptiScaler/Config.cpp','OptiScaler/Config.h','OptiScaler.ini',
            'OptiScaler/dlssnr/DlssNr_Options.h','OptiScaler/dlssnr/DlssNr_Menu.cpp',
            'OptiScaler/dlssnr/DlssNr_MenuControls.cpp')) {
            $path = [IO.Path]::GetFullPath("$repo/$relative")
            $old = @($prior | Where-Object { $_.path -eq $path })
            if ($old.Count -ne 1 -or (Get-FileHash $path).Hash -ne $old[0].sha256) { throw "Protected Task7 source changed: $relative" }
            [void]$paths.Add($path)
            $protected += [ordered]@{path=$relative;sha256=$old[0].sha256;matchesAcceptedTask7=$true}
        }
        $identities = @($paths | Sort-Object | ForEach-Object {
            if (!(Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Consumed input missing: $_" }
            $file = Get-Item -LiteralPath $_
            [ordered]@{path=$file.FullName;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $_).Hash}
        })
        $identities | ConvertTo-Json -Depth 5 | Set-Content "$out/identities.json" -Encoding UTF8
        $dependencies | ConvertTo-Json -Depth 12 | Set-Content "$out/compiler-inputs.json" -Encoding UTF8
        $libraries | ConvertTo-Json -Depth 5 | Set-Content "$out/library-inputs.json" -Encoding UTF8
        $protected | ConvertTo-Json -Depth 5 | Set-Content "$out/protected-inputs.json" -Encoding UTF8
        Write-Host "T9_BINDING identities=$($identities.Count) dependency-records=$($dependencies.Count) library-records=$($libraries.Count)"
        Invoke-Native 'git.exe' @('-C',$repo,'diff','--check') 'whitespace'
        Invoke-Native 'git.exe' @('-C',$repo,'rev-parse','HEAD') 'head'
    }
    [ordered]@{tier=$Tier;root=$out;commands=$commands;metadataExit=$metadataExit;
        gpu='WARP only in Shaders; typed services in Contracts';fullDll=$false;independentAcceptance=$false} |
        ConvertTo-Json -Depth 10 | Set-Content "$out/result.json" -Encoding UTF8
    Write-Host "T9_PASS tier=$Tier root=$out"
} finally { Stop-Transcript | Out-Null }
