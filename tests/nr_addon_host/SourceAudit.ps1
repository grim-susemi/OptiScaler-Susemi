# Source-only build-contract audit. No Build target, compiler or UI is run.
param([string]$MSBuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe',
    [string]$DependencyRoot, [string]$EvidenceRoot,
    [string]$ReceivingProjectArchive = $env:OPTISCALER_NR_RECEIVING_PROJECT_ARCHIVE)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$project = Join-Path $repo 'OptiScaler/OptiScaler.vcxproj'
$runner = Join-Path $repo 'tests/run_nr_addon_options.ps1'
[xml]$projectXml = Get-Content -LiteralPath $project -Raw
$ns = [Xml.XmlNamespaceManager]::new($projectXml.NameTable)
$ns.AddNamespace('p', $projectXml.DocumentElement.NamespaceURI)
$archivePath = if ($ReceivingProjectArchive) { (Resolve-Path -LiteralPath $ReceivingProjectArchive).Path } else {
    Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task13-host/preimages-receiving.json'
}
$archive = Get-Content -LiteralPath $archivePath -Raw | ConvertFrom-Json
$originalRecord = @($archive.records | Where-Object { $_.path -eq 'OptiScaler/OptiScaler.vcxproj' })
if ($originalRecord.Count -ne 1) { throw 'Receiving project preimage is ambiguous' }
$packed = [IO.MemoryStream]::new([Convert]::FromBase64String($originalRecord[0].content))
$gzip = [IO.Compression.GZipStream]::new($packed, [IO.Compression.CompressionMode]::Decompress)
$unpacked = [IO.MemoryStream]::new()
$gzip.CopyTo($unpacked)
$gzip.Dispose()
$originalBytes = $unpacked.ToArray()
$hashAlgorithm = [Security.Cryptography.SHA256]::Create()
$originalHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($originalBytes)).Replace('-','')
$hashAlgorithm.Dispose()
if ($originalHash -ne $originalRecord[0].sha256 -or $originalBytes.Length -ne $originalRecord[0].bytes) {
    throw 'Receiving project raw preimage binding changed'
}
[xml]$originalXml = [Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xFEFF)
$originalNs = [Xml.XmlNamespaceManager]::new($originalXml.NameTable)
$originalNs.AddNamespace('p', $originalXml.DocumentElement.NamespaceURI)
$currentGroups = @($projectXml.SelectNodes('/p:Project/p:ItemDefinitionGroup', $ns) | Where-Object {
    $_.Condition -ne "'`$(OptiScalerNrSelfTest)'=='true'" })
$originalGroups = @($originalXml.SelectNodes('/p:Project/p:ItemDefinitionGroup', $originalNs) | Where-Object {
    $_.Condition -ne "'`$(OptiScalerNrSelfTest)'=='true'" })
if ($currentGroups.Count -ne $originalGroups.Count) { throw 'Non-selftest build group count changed' }
for ($index = 0; $index -lt $currentGroups.Count; $index++) {
    if ($currentGroups[$index].OuterXml -cne $originalGroups[$index].OuterXml) {
        throw "Non-selftest build group changed from receiving preimage: $($currentGroups[$index].Condition)"
    }
}
Write-Host "HOST_SOURCE_RELEASE_GROUPS_EXACT=PASS groups=$($currentGroups.Count) receivingProjectSha256=$originalHash"
$dumpbin = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/dumpbin.exe'
$libraryRecords = @()
foreach ($relative in @('external/freetype/freetype.lib','OptiScaler/library/fsr2/ffx_fsr2_api_x64.lib',
    'OptiScaler/library/fsr2/ffx_fsr2_api_dx12_x64.lib')) {
    $library = Join-Path $repo $relative
    $directives = (& $dumpbin /directives $library | Out-String)
    $nativeExit = $LASTEXITCODE
    if ($nativeExit) { throw "Native library directive inspection failed: $relative" }
    if ($relative -like '*freetype*') {
        if ($directives -notmatch '/DEFAULTLIB:LIBCMT' -or $directives -match '(?i)FAILIFMISMATCH.*RuntimeLibrary') {
            throw 'Retained C FreeType directive assumptions changed'
        }
    } elseif ($directives -notmatch 'RuntimeLibrary=MD_DynamicRelease' -or $directives -match 'RuntimeLibrary=MT_') {
        throw 'Genuine FSR2 library dynamic release ABI changed'
    }
    $libraryRecords += [ordered]@{path=$library;bytes=(Get-Item -LiteralPath $library).Length;
        sha256=(Get-FileHash -LiteralPath $library).Hash;nativeExit=$nativeExit;command="$dumpbin /directives $library";
        rawDirectives=$directives}
    Write-Host "HOST_SOURCE_LIBRARY_CRT=PASS path=$relative sha256=$((Get-FileHash -LiteralPath $library).Hash)"
}
if ($EvidenceRoot) {
    $evidence = [IO.Path]::GetFullPath($EvidenceRoot)
    $allowed = Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'
    if (!$evidence.StartsWith($allowed + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native library audit evidence escaped the current attempt'
    }
    [ordered]@{schema=1;dumpbin=$dumpbin;dumpbinSha256=(Get-FileHash -LiteralPath $dumpbin).Hash;
        runtime='MD_DynamicRelease';preciseIgnoredCDefaultLibrary='LIBCMT';libraries=$libraryRecords} |
        ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $evidence 'native-library-crt.json') -Encoding UTF8
}
foreach ($node in $projectXml.SelectNodes('//p:ClCompile/p:WholeProgramOptimization | //p:ClCompile/p:AdditionalOptions', $ns)) {
    if ($node.LocalName -eq 'WholeProgramOptimization' -and $node.InnerText -ne 'false') { continue }
    if ($node.LocalName -eq 'AdditionalOptions' -and $node.InnerText -notmatch '/sourceDependencies') { continue }
    if ($node.ParentNode.ParentNode.Condition -ne "'`$(OptiScalerNrSelfTest)'=='true'") {
        throw 'Host compiler instrumentation escaped the selftest-only group'
    }
}
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
    if ($DependencyRoot) { $arguments += "/p:OptiScalerNrDependencyRoot=$DependencyRoot" }
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
$expected = @('dlssnr/DlssNr_Menu.cpp','dlssnr/DlssNr_MenuControls.cpp','dlssnr/DlssNr_Status.cpp','menu/Localization.cpp',
    'include/imgui/imgui.cpp','include/imgui/imgui_draw.cpp','include/imgui/imgui_tables.cpp',
    'include/imgui/imgui_widgets.cpp','include/imgui/imgui_impl_win32.cpp','include/imgui/imgui_impl_dx11.cpp',
    'include/imgui/misc/freetype/imgui_freetype.cpp',
    '../tests/nr_addon_host/Main.cpp','../tests/nr_addon_host/UiServices.cpp','../tests/nr_addon_host/UiContracts.cpp')
$expected += @('../tests/nr_addon_host/RuntimeContracts.cpp','../tests/nr_addon_host/RuntimeDriver.cpp',
    '../tests/nr_addon_host/RuntimeGpu.cpp','dlssnr/DlssNr_Proxy.cpp','dlssnr/DlssNr_GpuLifetime.cpp',
    'dlssnr/DlssNr_CompatibilityRuntime.cpp','dlssnr/DlssNr_CompatibilityRuntimePaths.cpp',
    'dlssnr/DlssNr_NgxDiagnostics.cpp','dlssnr/DlssNr_Pipeline_Dx12.cpp','dlssnr/DlssNr_StreamlinePicture.cpp',
    'shaders/dlssnr/DlssNr_Dx12.cpp','shaders/dlssnr/DlssNr_Dx12_Resources.cpp',
    'shaders/dlssnr/DlssNr_Dx12_Models.cpp','shaders/dlssnr/DlssNr_Dx12_Encode.cpp',
    'shaders/dlssnr/DlssNr_Dx12_Run.cpp','shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp',
    'shaders/dlssnr/DlssNr_Dx12_Late.cpp','shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp',
    'shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp','shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp',
    'shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp','shaders/dlssnr/DlssNr_Dx12_Hold.cpp',
    'shaders/dlssnr/DlssNr_Dx12_Status.cpp','shaders/dlssnr/DlssNr_Upscaler_Dx12.cpp',
    'resource_tracking/ResTrack_dx12.cpp','shaders/Shader_Dx12.cpp','shaders/output_scaling/OS_Dx12.cpp',
    'gpu_time/GpuTime_Dx12.cpp','Util.cpp','Logger.cpp','framegen/dlssg/MfgUnlock.cpp')
$expected += @('framegen/IFGFeature.cpp','hooks/D3D12_Hooks.cpp','hudfix/Hudfix_Dx12.cpp',
    'menu/menu_overlay_dx.cpp','shaders/Shader_Common.cpp','misc/SkipSpoof.cpp','scanner/scanner.cpp','misc/IdentifyGpu.cpp')
$expected += @('../tests/nr_addon_host/GameStartupGuards.cpp','framegen/IFGFeature_Dx12.cpp',
    'shaders/format_transfer/FT_Dx12.cpp','include/imgui/imgui_impl_dx12.cpp','include/device_info/device_info.cpp','nvapi/NvApiTypes.cpp')
$expected += 'shaders/resource_flip/RF_Dx12.cpp'
$plannedGuiUnits = @('menu/menu_common.cpp','menu/input/input_system.cpp','dlssnr/DlssNr_MenuOverlay.cpp',
    'version_check.cpp','framegen/dlssg/AmpereMfgLoader.cpp','BuildInfo.cpp','OptiTypes.cpp',
    'shaders/hud_copy/HudCopy_Dx12.cpp')
$requiredSources = @($expected)
$expected += @($plannedGuiUnits | Where-Object { $_ -in $hostSources })
if (@($hostSources | Sort-Object -Unique).Count -ne $hostSources.Count -or
    @(Compare-Object $expected $hostSources).Count) { throw 'Host compilation source set mismatch' }
$activeSources = @($hostSources | Sort-Object | ForEach-Object {
    $path = [IO.Path]::GetFullPath((Join-Path (Split-Path $project) $_))
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Active source unit missing: $path" }
    [ordered]@{identity=$_;path=$path;bytes=(Get-Item -LiteralPath $path).Length;
        sha256=(Get-FileHash -LiteralPath $path).Hash;required=($_ -in $requiredSources)}
})
if (@($hostProject.Items.ResourceCompile).Count) { throw 'Product resources entered the host' }
if (@($releaseProject.Items.ClCompile | Where-Object { $_.Identity -match 'nr_addon_host' }).Count) {
    throw 'Test services entered the product build'
}
if ($releaseProject.Items.ClCompile | Where-Object { $_.AdditionalIncludeDirectories -match 'nr_addon_host' }) {
    throw 'Host startup service headers entered the release include path'
}
if (@($hostProject.Items.ClCompile | Where-Object { $_.PrecompiledHeader -ne 'NotUsing' }).Count) {
    throw 'Host accidentally requires the product PCH'
}
if (@($hostProject.Items.ClCompile | Where-Object { $_.RuntimeLibrary -ne 'MultiThreadedDLL' }).Count) {
    throw 'Host CRT does not match genuine FSR2 dynamic release libraries'
}
if (@($projectXml.SelectNodes('//p:ItemDefinitionGroup/p:Link/p:IgnoreSpecificDefaultLibraries', $ns) | Where-Object {
    $_.ParentNode.ParentNode.Condition -eq "'`$(OptiScalerNrSelfTest)'=='true'" -and $_.InnerText -ceq 'LIBCMT'
}).Count -ne 1) { throw 'Precise host C FreeType default runtime exclusion missing' }
if (@($hostProject.Items.ClCompile | Where-Object { $_.WholeProgramOptimization -ne 'false' -or
    $_.FunctionLevelLinking -ne 'true' -or $_.AdditionalOptions -notmatch '/sourceDependencies' }).Count) {
    throw 'Host evaluated compiler options do not match recorded ownership'
}
Write-Host "HOST_SOURCE_PROJECT_CONTRACT=PASS hostSources=$($hostSources.Count) releaseSources=$(@($releaseProject.Items.ClCompile).Count)"
if ($EvidenceRoot) {
    [ordered]@{schema=1;kind='activeHostSourceInventory';project=$project;
        projectSha256=(Get-FileHash -LiteralPath $project).Hash;
        receivingProjectArchive=$archivePath;receivingProjectArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash;
        requiredSourceIdentities=$requiredSources;permittedAddedGuiIdentities=$plannedGuiUnits;units=$activeSources} |
        ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $evidence 'active-source-inventory.json') -Encoding UTF8
}
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
