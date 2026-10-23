# Run in a Visual Studio developer shell. EvidenceRoot retains native commands
# and compiler inputs; without it, the adjacent regression uses owned temp space.
param([string]$EvidenceRoot,
      [string]$SdkRoot,
      [switch]$NegativeControls)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (!$SdkRoot) { $SdkRoot = "$repo/external/nvngx_dlss_sdk" }
$root = if ($EvidenceRoot) { $EvidenceRoot } else { [IO.Path]::GetTempPath() }
$build = Join-Path $root ('task-6-proxy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$build/proxies" -Force | Out-Null
Start-Transcript -LiteralPath "$build/raw.log" | Out-Null
try {
    foreach ($header in @('pch.h', 'Config.h', 'Logger.h', 'd3d12.h', 'proxies/NVNGX_Proxy.h')) {
        Set-Content -LiteralPath "$build/$header" -Value '// Dependency supplied by MockNgx.h.'
    }
    $modelsPath = "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Models.cpp"
    $models = [regex]::Replace((Get-Content -LiteralPath $modelsPath -Raw), '(?m)^#include[^\r\n]*', '')
    Set-Content -LiteralPath "$build/models-production.inc" -Value $models -Encoding UTF8
    $proxyPath = "$repo/OptiScaler/dlssnr/DlssNr_Proxy.cpp"
    $proxy = Get-Content -LiteralPath $proxyPath -Raw
    $commands = @()
    $tags = @('green')
    if ($NegativeControls) { $tags += @('wrong-typed', 'unchanged-creation', 'unchanged-role') }
    foreach ($tag in $tags) {
        $args = @('/nologo','/std:c++20','/EHsc','/W4',
            "/FI$PSScriptRoot/MockNgx.h", "/I$build", "/I$SdkRoot", "/I$repo/OptiScaler",
            "/Fo$build/$tag.obj", "/Fd$build/$tag.pdb", "/Fe$build/$tag.exe",
            '/sourceDependencies', "$build/$tag.inputs.json")
        if ($tag -in @('wrong-typed','unchanged-creation')) {
            $anchor = 'params->Set("DLSSNR.UICorrection", settings.uiCorrection);'
            if (($proxy.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) {
                throw 'Creation seed anchor drift'
            }
            $replacement = if ($tag -eq 'wrong-typed') {
                'params->Set("DLSSNR.UICorrection", static_cast<int>(settings.uiCorrection));'
            } else { 'params->Set("DLSSNR.UICorrection", 1u);' }
            $seed = "$build/$tag.cpp"
            Set-Content -LiteralPath $seed -Value $proxy.Replace($anchor,$replacement) -Encoding UTF8
            $args += @("/I$repo/OptiScaler/dlssnr", ('/DNR_PROXY_SOURCE=\"'+$seed.Replace('\','/')+'\"'))
        } elseif ($tag -eq 'unchanged-role') {
            $anchor = 'nr.finishedPicture != frame.FinishedPicture'
            if (($models.Split(@($anchor),[StringSplitOptions]::None).Count-1) -ne 1) {
                throw 'Finished-role seed anchor drift'
            }
            $seed = "$build/models-unchanged-role.inc"
            Set-Content -LiteralPath $seed -Value $models.Replace($anchor,'false') -Encoding UTF8
            $args += ('/DNR_MODELS_SOURCE=\"'+$seed.Replace('\','/')+'\"')
        }
        $args += "$PSScriptRoot/ProxyTests.cpp"
        Write-Host ("T6_COMPILE_COMMAND=cl.exe " + ($args -join ' '))
        & cl.exe @args 2>&1 | Tee-Object -FilePath "$build/$tag.compile.log" | Write-Host
        $compileExit = $LASTEXITCODE
        Write-Host "T6_COMPILE_EXIT=$compileExit tag=$tag"
        if ($compileExit) { throw "DLSS-NR proxy compilation failed: $tag" }
        Write-Host "T6_RUN_COMMAND=$build/$tag.exe"
        & "$build/$tag.exe" 2>&1 | Tee-Object -FilePath "$build/$tag.output.log" | Write-Host
        $runExit = $LASTEXITCODE
        Write-Host "T6_RUN_EXIT=$runExit tag=$tag"
        if ($tag -ne 'green') {
            $log = Get-Content -LiteralPath "$build/$tag.output.log" -Raw
            $expected = if ($tag -eq 'wrong-typed') {
                'T6_CREATION_REJECT expected=1 typedUnsigned=0 actual=2'
            } elseif ($tag -eq 'unchanged-creation') {
                'T6_CREATION_REJECT expected=0 typedUnsigned=1 actual=1'
            } else { 'T6_ROLE_HISTORY_REJECT oldUi=1 newUi=1 recreated=0' }
            if ($runExit -ne 1 -or !$log.Contains($expected)) {
                throw "Negative control did not reach its typed creation assertion: $tag"
            }
        }
        $commands += [ordered]@{ tag=$tag; compileCommand='cl.exe '+($args -join ' ');
            compileExit=$compileExit; command="$build/$tag.exe"; exit=$runExit }
        if (($tag -eq 'green' -and $runExit) -or ($tag -ne 'green' -and !$runExit)) {
            throw "Unexpected Task6 regression result: $tag"
        }
    }
    $sources = @($proxyPath,$modelsPath,"$repo/OptiScaler/dlssnr/PassProfiles.h",
        "$repo/OptiScaler/dlssnr/DlssNr_ModelParameters.h","$repo/OptiScaler/dlssnr/DlssNr_Placement.h",
        "$PSScriptRoot/ProxyTests.cpp","$PSScriptRoot/MockNgx.h","$PSScriptRoot/ModelPreparation.h",
        "$PSScriptRoot/run.ps1") | ForEach-Object { Get-FileHash -LiteralPath $_ }
    [ordered]@{root=$build;commands=$commands;sources=@($sources);
        modelsBody=(Get-FileHash -LiteralPath "$build/models-production.inc");
        sdkRoot=$SdkRoot;gpu='not initialized; typed NGX and allocation/completion adapters';
        pendingCommands=0} | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath "$build/result.json" -Encoding UTF8
    Write-Host "T6_PROXY_SUITE_PASS root=$build"
} finally { Stop-Transcript | Out-Null }
