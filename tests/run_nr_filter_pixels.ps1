param(
    [ValidateSet('Generate','Shaders','Product','Negative')][string]$Tier = 'Shaders',
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [string]$SeedRoot
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
$out = Join-Path $EvidenceRoot ('task-8-' + $Tier.ToLower() + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
try {
    # Explicit already-local toolchain, equivalent to the accepted Release x64 inputs.
    $vc = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207'
    $sdk = 'C:/Program Files (x86)/Windows Kits/10'
    $env:PATH = "$vc/bin/HostX86/x64;" + $env:PATH
    $env:INCLUDE = "$vc/include;$sdk/Include/10.0.26100.0/ucrt;$sdk/Include/10.0.26100.0/shared;$sdk/Include/10.0.26100.0/um;$sdk/Include/10.0.26100.0/winrt"
    $env:LIB = "$vc/lib/x64;$sdk/Lib/10.0.26100.0/ucrt/x64;$sdk/Lib/10.0.26100.0/um/x64"
    $fxc = 'C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/fxc.exe'
    $commands = @()
    function Invoke-Native([string]$program, [string[]]$arguments, [string]$name, [int]$expected = 0) {
        Write-Host ("T8_COMMAND=$program " + ($arguments -join ' '))
        $ErrorActionPreference = 'Continue'
        & $program @arguments 2>&1 | Tee-Object -FilePath "$out/$name.log" | Write-Host
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Write-Host "T8_EXIT=$code name=$name expected=$expected"
        $script:commands += [ordered]@{program=$program;arguments=$arguments;exit=$code;expected=$expected}
        if ($code -ne $expected) { throw "$name exited $code, expected $expected" }
    }
    if ($Tier -eq 'Product') {
        $support = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1'
        $msbuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe'
        $queryArgs = @("$repo/OptiScaler/OptiScaler.vcxproj",'/nologo','/p:Configuration=Release',
            '/p:Platform=x64',"/p:SolutionDir=$support/",'/p:OptiScalerNrSelfTest=false',
            '/p:OptiScalerRtx40Mfg=false','/getProperty:IncludePath','/getItem:ClCompile')
        Write-Host ("T8_METADATA_COMMAND=$msbuild " + ($queryArgs -join ' '))
        $query = & $msbuild @queryArgs
        $metadataExit = $LASTEXITCODE
        if ($metadataExit) { throw "Metadata failed: $metadataExit" }
        $query | Set-Content -LiteralPath "$out/metadata.json" -Encoding UTF8
        $metadata = ($query -join "`n") | ConvertFrom-Json
        $env:INCLUDE = $metadata.Properties.IncludePath
        $unit = 'shaders/dlssnr/DlssNr_Dx12_Encode.cpp'
        $item = $metadata.Items.ClCompile | Where-Object { $_.Identity.Replace('\','/') -eq $unit }
        if (!$item) { throw 'Actual normal product encoder item missing' }
        $args = @('/nologo','/c','/std:c++latest','/EHsc','/MD','/W3','/permissive-','/Y-',
            "/Fo$out/Encode.obj","/Fd$out/Encode.pdb",'/sourceDependencies',"$out/Encode.inputs.json")
        foreach ($define in $item.PreprocessorDefinitions.Split(';')) { if ($define) { $args += "/D$define" } }
        $args += "$repo/OptiScaler/$unit"
        Invoke-Native 'cl.exe' $args 'product-compile'
    } else {
        $hlsl = "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl"
        if ($Tier -eq 'Negative') { $hlsl = "$SeedRoot/dlssnr.seed.hlsl" }
        Invoke-Native $fxc @('/nologo','/T','cs_5_0','/E','CSMain','/O3','/Fo',"$out/DlssNr_Shader.cso",$hlsl) 'fxc'
        if ($Tier -eq 'Generate') {
            Invoke-Native 'python.exe' @("$repo/OptiScaler/shaders/shader_tools/create_header.py",
                "$out/DlssNr_Shader.cso","$out/DlssNr_Shader.h",'DlssNr_cso') 'header'
        } else {
            $args = @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',
                "/Fo$out/smoke.obj","/Fd$out/smoke.pdb","/Fe$out/nr_resize_shader_smoke.exe",
                '/sourceDependencies',"$out/smoke.inputs.json")
            if ($Tier -eq 'Negative') {
                $args += ('/DNR_FILTER_SHADER_HEADER=\"' + "$SeedRoot/DlssNr_Shader.seed.h" + '\"')
            }
            $args += @("$PSScriptRoot/nr_resize_shader_smoke.cpp",'/link','d3d11.lib','d3d12.lib',
                'dxgi.lib','/VERBOSE:LIB')
            Invoke-Native 'cl.exe' $args 'compile'
            $expected = if ($Tier -eq 'Negative') { 1 } else { 0 }
            Invoke-Native "$out/nr_resize_shader_smoke.exe" @('--filters',"$out/DlssNr_Shader.cso") 'pixels' $expected
            if ($Tier -eq 'Negative' -and
                !(Select-String -LiteralPath "$out/pixels.log" -SimpleMatch 'T8_FILTER: independent-reference')) {
                throw 'Selector mutation missed the named pixel assertion'
            }
        }
    }
    [ordered]@{tier=$Tier;root=$out;commands=$commands;metadataExit=$metadataExit;
        gpu='WARP software only';selftest=$false;fullDll=$false} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Write-Host "T8_PASS tier=$Tier root=$out"
} finally { Stop-Transcript | Out-Null }
