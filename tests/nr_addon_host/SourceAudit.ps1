# Source-only build-contract audit. No Build target, compiler or UI is run.
param([string]$MSBuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$project = Join-Path $repo 'OptiScaler/OptiScaler.vcxproj'
$runner = Join-Path $repo 'tests/run_nr_addon_options.ps1'
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }
Write-Host 'HOST_SOURCE_POWERSHELL_PARSE=PASS'

function Query([bool]$SelfTest) {
    $flag = $SelfTest.ToString().ToLowerInvariant()
    $arguments = @($project, '/nologo', '/p:Configuration=Release', '/p:Platform=x64',
        "/p:SolutionDir=$repo\", '/p:OptiScalerRtx40Mfg=true', "/p:OptiScalerNrSelfTest=$flag",
        '/getProperty:ConfigurationType,TargetName,TargetExt,OutDir,IntDir,PreBuildEventUseInBuild,PostBuildEventUseInBuild',
        '/getItem:ClCompile,ResourceCompile')
    Write-Host ('HOST_SOURCE_COMMAND=' + $MSBuild + ' ' + ($arguments -join ' '))
    $output = & $MSBuild @arguments
    $code = $LASTEXITCODE
    Write-Host "HOST_SOURCE_MSBUILD_EVALUATION_EXIT=$code"
    if ($code) { throw "Project evaluation failed: $output" }
    return (($output -join "`n") | ConvertFrom-Json)
}

$hostProject = Query $true
$releaseProject = Query $false
if ($hostProject.Properties.ConfigurationType -ne 'Application' -or
    $hostProject.Properties.TargetName -ne 'NRAddonHost' -or
    $hostProject.Properties.TargetExt -ne '.exe') { throw 'Host target contract mismatch' }
if ($releaseProject.Properties.ConfigurationType -ne 'DynamicLibrary' -or
    $releaseProject.Properties.TargetExt -ne '.dll') { throw 'Release DLL contract mismatch' }
if ($hostProject.Properties.OutDir -eq $releaseProject.Properties.OutDir -or
    $hostProject.Properties.IntDir -eq $releaseProject.Properties.IntDir) { throw 'Host/product staging collision' }
if ($hostProject.Properties.PreBuildEventUseInBuild -ne 'false' -or
    $hostProject.Properties.PostBuildEventUseInBuild -ne 'false') { throw 'Host build events are enabled' }
$hostSources = @($hostProject.Items.ClCompile | ForEach-Object { $_.Identity.Replace('\','/') })
$expected = @('dlssnr/DlssNr_Menu.cpp','dlssnr/DlssNr_MenuControls.cpp','dlssnr/DlssNr_Status.cpp',
    'include/imgui/imgui.cpp','include/imgui/imgui_draw.cpp','include/imgui/imgui_tables.cpp',
    'include/imgui/imgui_widgets.cpp','include/imgui/imgui_impl_win32.cpp','include/imgui/imgui_impl_dx11.cpp',
    'include/imgui/misc/freetype/imgui_freetype.cpp',
    '../tests/nr_addon_host/Main.cpp','../tests/nr_addon_host/UiServices.cpp','../tests/nr_addon_host/UiContracts.cpp')
if (@(Compare-Object $expected $hostSources).Count) { throw 'Host compilation source set mismatch' }
if (@($hostProject.Items.ResourceCompile).Count) { throw 'Product resources entered the host' }
if (@($releaseProject.Items.ClCompile | Where-Object { $_.Identity -match 'nr_addon_host' }).Count) {
    throw 'Test services entered the product build'
}
if (@($hostProject.Items.ClCompile | Where-Object { $_.PrecompiledHeader -ne 'NotUsing' }).Count) {
    throw 'Host accidentally requires the product PCH'
}
if (@($hostProject.Items.ClCompile | Where-Object { $_.RuntimeLibrary -ne 'MultiThreaded' }).Count) {
    throw 'Host CRT does not match the retained static FreeType library'
}
Write-Host "HOST_SOURCE_PROJECT_CONTRACT=PASS hostSources=$($hostSources.Count) releaseSources=$(@($releaseProject.Items.ClCompile).Count)"
Push-Location $repo
try {
    & git diff --check -- OptiScaler/OptiScaler.vcxproj tests/run_nr_addon_options.ps1 tests/nr_addon_host
    $code = $LASTEXITCODE
    Write-Host "HOST_SOURCE_DIFF_CHECK_EXIT=$code"
    if ($code) { throw 'Host source whitespace check failed' }
    foreach ($relative in @('OptiScaler/OptiScaler.vcxproj','tests/run_nr_addon_options.ps1',
        'tests/nr_addon_host/Main.cpp','tests/nr_addon_host/UiServices.cpp',
        'tests/nr_addon_host/UiServices.h','tests/nr_addon_host/SourceAudit.ps1',
        'tests/nr_addon_host/UiContracts.cpp')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $repo $relative) -Algorithm SHA256).Hash
        Write-Host "HOST_SOURCE_HASH=$relative $hash"
    }
    Write-Host 'HOST_SOURCE_AUDIT_PASS=1'
} finally {
    Pop-Location
}
