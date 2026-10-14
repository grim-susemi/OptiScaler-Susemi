param(
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$DependencyRoot,
    [ValidateSet('Build','Rebuild')][string]$BuildTarget = 'Build',
    [ValidatePattern('^[A-Za-z0-9-]{1,8}$')][string]$BuildLeaf,
    [string]$FinalizeExistingBuild,
    [string]$MSBuild = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$root = [IO.Path]::GetFullPath($EvidenceRoot)
$expectedRoot = Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'
if (!$root.StartsWith($expectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build evidence must remain in the current Task13 evidence directory'
}
if ($BuildLeaf -and $FinalizeExistingBuild) { throw 'A fresh build leaf cannot finalize existing evidence' }
$out = if ($FinalizeExistingBuild) { (Resolve-Path -LiteralPath $FinalizeExistingBuild).Path } else {
    Join-Path $root $(if ($BuildLeaf) { $BuildLeaf } else { 'b-' + [guid]::NewGuid().ToString('N').Substring(0,8) })
}
if (!$out.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Existing build must remain under current host evidence' }
if (!$FinalizeExistingBuild) {
    if (Test-Path -LiteralPath $out) { throw 'Refuse to overwrite an existing host build attempt' }
    New-Item -ItemType Directory -Path $out | Out-Null
}
$project = Join-Path $repo 'OptiScaler/OptiScaler.vcxproj'
$dependencies = (Resolve-Path -LiteralPath $DependencyRoot).Path
$arguments = @($project, '/nologo', "/t:$BuildTarget", '/m:1', '/v:minimal', '/p:Configuration=Release',
    '/p:Platform=x64', "/p:SolutionDir=$repo\", '/p:OptiScalerRtx40Mfg=true', '/p:OptiScalerNrSelfTest=true',
    "/bl:$out/build.binlog", '/fl', "/flp:LogFile=$out/build.full.log;Verbosity=diagnostic")
$arguments += "/p:OptiScalerNrDependencyRoot=$dependencies"
$arguments += @("/p:OutDir=$out/bin/", "/p:IntDir=$out/obj/", "/p:TLogLocation=$out/t/")
$exit = $null
$finalizationRoot = if ($FinalizeExistingBuild) { Join-Path $out ('f-' + [guid]::NewGuid().ToString('N').Substring(0,8)) } else { $out }
if ($FinalizeExistingBuild) { New-Item -ItemType Directory -Path $finalizationRoot | Out-Null }
$immutableBindings = @{}
function BindActualFile([string]$Path) {
    if (!$immutableBindings.ContainsKey($Path)) {
        $immutableBindings[$Path] = [ordered]@{path=[string]::Copy($Path);bytes=(Get-Item -LiteralPath $Path).Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}
    }
    return $immutableBindings[$Path]
}
Start-Transcript -LiteralPath $(if($FinalizeExistingBuild){"$finalizationRoot/raw.log"}else{"$out/raw.log"}) | Out-Null
try {
    Write-Host "HOST_BUILD_ROOT=$out"
    & "$PSScriptRoot/SourceAudit.ps1" -MSBuild $MSBuild -DependencyRoot $dependencies -EvidenceRoot $finalizationRoot
    $inventoryPath = Join-Path $finalizationRoot 'active-source-inventory.json'
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    if ($inventory.kind -ne 'activeHostSourceInventory' -or !$inventory.units -or
        $inventory.projectSha256 -ne (Get-FileHash -LiteralPath $project).Hash) {
        throw 'Active host source inventory is incomplete or stale'
    }
    $expectedSources = @($inventory.units | ForEach-Object { $_.path })
    if ($FinalizeExistingBuild) {
        $failed = Get-Content -LiteralPath "$out/failure.json" -Raw | ConvertFrom-Json
        if ($failed.nativeExit -ne 0) { throw 'Existing build did not finish native compilation and link successfully' }
        $pins = Get-Content -LiteralPath "$root/native0-finalization-inputs.json" -Raw | ConvertFrom-Json
        if ($pins.nativeExit -ne 0 -or $pins.sourceUnits -ne $expectedSources.Count -or
            !$pins.sources -or @(Compare-Object $expectedSources @($pins.sources)).Count) {
            throw 'Native0 finalization input inventory is incomplete'
        }
        foreach ($unit in $inventory.units) {
            if (@($pins.files | Where-Object { $_.path -ieq $unit.path -and
                $_.bytes -eq $unit.bytes -and $_.sha256 -eq $unit.sha256 }).Count -ne 1) {
                throw "Native0 finalization source binding missing or stale: $($unit.path)"
            }
        }
        foreach ($pin in $pins.files) {
            $bound = BindActualFile $pin.path
            if ($bound.bytes -ne $pin.bytes -or $bound.sha256 -ne $pin.sha256) { throw "Native0 finalization input changed: $($pin.path)" }
        }
        $exit = 0
        Write-Host 'HOST_FINALIZE_NATIVE0_REUSE=1 compilerInvocations=0'
    } else {
    $prebuild = @(Get-ChildItem -LiteralPath "$PSScriptRoot" -Recurse -File | ForEach-Object {
        [ordered]@{path=$_.FullName;bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
    $prebuild | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/host-inputs-before-build.json" -Encoding UTF8
    Write-Host ('HOST_BUILD_COMMAND=' + $MSBuild + ' ' + ($arguments -join ' '))
    & $MSBuild @arguments
    $exit = $LASTEXITCODE
    }
    Write-Host "HOST_BUILD_NATIVE_EXIT=$exit"
    if ($exit) { throw "Current production host native compilation/link failed: $exit" }
    $compileCommands = @(Get-Content -LiteralPath "$out/build.full.log" | Where-Object {
        $_ -match '\\CL\.exe /c .* /sourceDependencies ' } | ForEach-Object { [string]::Copy([string]$_) })
    if (!$compileCommands.Count) { throw 'Observed compiler commands are missing' }
    if ($compileCommands | Where-Object { $_ -match '(?i)(?:^|\s)/GL(?:\s|$)' }) {
        throw 'Observed compiler commands still enable whole program optimization'
    }
    Write-Host "HOST_BUILD_OBSERVED_NO_GL=PASS commands=$($compileCommands.Count)"
    if ($compileCommands | Where-Object { $_ -notmatch '(?:^|\s)/MD(?:\s|$)' -or $_ -match '(?:^|\s)/MT(?:\s|$)' }) {
        throw 'Observed compiler commands do not select one dynamic release CRT'
    }
    $linkCommands = @(Get-Content -LiteralPath "$out/build.full.log" | Where-Object { $_ -match '\\link\.exe /' } | ForEach-Object { [string]::Copy([string]$_) })
    if (!$linkCommands.Count -or ($linkCommands | Where-Object {
        $_ -notmatch '(?i)/NODEFAULTLIB:LIBCMT(?:\.lib)?(?:\s|$)' -or $_ -notmatch '(?i)/VERBOSE:LIB' -or
        $_ -match '(?i)/FORCE|/IGNORE:2038|/NODEFAULTLIB(?:\s|$)'
    })) { throw 'Observed native link options do not match precise C archive CRT isolation' }
    Write-Host "HOST_BUILD_OBSERVED_MD_AND_LINK=PASS clCommands=$($compileCommands.Count) linkCommands=$($linkCommands.Count)"
    $exe = Join-Path $out 'bin/NRAddonHost.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Current host artifact is missing' }
    $int = Join-Path $out 'obj'
    $commandCache = Join-Path $out 't/CL.command.1.tlog'
    $commandLines = @(Get-Content -LiteralPath $commandCache | ForEach-Object { [string]::Copy([string]$_) })
    $commandsBySource = @{}
    for ($index = 0; $index -lt $commandLines.Count; $index++) {
        if ($commandLines[$index].StartsWith('^')) {
            if ($index + 1 -ge $commandLines.Count -or $commandLines[$index] -match '\|') {
                throw 'Actual per-source compiler command cache is ambiguous'
            }
            $command = $commandLines[++$index]
            if ($command -notmatch '(?:^|\s)/MD(?:\s|$)' -or $command -match '(?i)(?:^|\s)/(GL|MT)(?:\s|$)') {
                throw 'Actual per-object compiler cache has inconsistent options'
            }
            $commandsBySource[$commandLines[$index - 1].Substring(1)] = $command
        }
    }
    $records = @()
    foreach ($dependency in Get-ChildItem -LiteralPath $int -Filter '*.inputs.json') {
        $inputs = Get-Content -LiteralPath $dependency.FullName -Raw | ConvertFrom-Json
        $files = @($inputs.Data.Source) + @($inputs.Data.Includes)
        $bound = @($files | ForEach-Object {
            BindActualFile $_
        })
        $object = Join-Path $int ($dependency.Name.Replace('.inputs.json','.obj'))
        if (!$commandsBySource.ContainsKey($inputs.Data.Source)) { throw "Current compiler command binding missing: $($inputs.Data.Source)" }
        if (!(Test-Path -LiteralPath $object)) { throw "Object binding missing: $object" }
        $objectBinding = BindActualFile $object
        $receiptBinding = BindActualFile $dependency.FullName
        $records += [ordered]@{ source=$inputs.Data.Source; dependencies=$bound; compilerCommand=$commandsBySource[$inputs.Data.Source];
            dependencyReceipt=$dependency.FullName; dependencySha256=$receiptBinding.sha256;
            object=$object; objectBytes=$objectBinding.bytes;
            objectSha256=$objectBinding.sha256 }
    }
    $actualSources = @($records | ForEach-Object { $_.source })
    if (@($actualSources | Sort-Object -Unique).Count -ne $records.Count -or
        @(Compare-Object $expectedSources $actualSources).Count) {
        throw 'Current host must bind every active compiler source dependency unit exactly once'
    }
    foreach ($unit in $inventory.units) {
        $bound = BindActualFile $unit.path
        if ($bound.bytes -ne $unit.bytes -or $bound.sha256 -ne $unit.sha256) {
            throw "Active host source changed during build: $($unit.path)"
        }
    }
    $localizationUnit = @($records | Where-Object { $_.source -like '*menu*Localization.cpp' })
    if ($localizationUnit.Count -ne 1) { throw 'Production Localization object must be bound exactly once' }
    foreach ($header in @('Localization.h','ko_catalog.inc')) {
        if (@($localizationUnit[0].dependencies | Where-Object {
            [IO.Path]::GetFileName($_.path) -ieq $header }).Count -ne 1) {
            throw "Production Localization object lacks current header binding: $header"
        }
    }
    Write-Host 'HOST_PRODUCTION_LOCALIZATION_OBJECT=PASS units=1 currentHeaderBindings=2'
    $menuUnit = @($records | Where-Object { $_.source -like '*menu*menu_common.cpp' })
    $inputUnit = @($records | Where-Object { $_.source -like '*menu*input*input_system.cpp' })
    if ($menuUnit.Count -ne 1 -or $inputUnit.Count -ne 1) {
        throw 'Actual production menu and owned input objects must be bound exactly once'
    }
    foreach ($header in @('menu_common.h','input_system.h','Localization.h','IdentifyGpu.h')) {
        if (@($menuUnit[0].dependencies | Where-Object {
            [IO.Path]::GetFileName($_.path) -ieq $header }).Count -ne 1) {
            throw "Actual production menu lacks current header binding: $header"
        }
    }
    if (@($menuUnit[0].dependencies | Where-Object {
        $_.path -like '*tests*nr_addon_host*services*proxies*FfxApi_Proxy.h' }).Count -ne 1) {
        throw 'Actual production menu bypasses the registered owned FfxApi service'
    }
    Write-Host 'HOST_PRODUCTION_MENU_OBJECT=PASS ownedInput=1 currentHeaders=1 ownedFfxService=1'
    $buildInfo = @($records | Where-Object { [IO.Path]::GetFileName($_.source) -ieq 'BuildInfo.cpp' })
    if ($buildInfo.Count -ne 1) { throw 'Actual production BuildInfo object is missing or ambiguous' }
    foreach ($header in @('resource_build_date.h','resource_build_commit.h')) {
        $generated = @($buildInfo[0].dependencies | Where-Object { [IO.Path]::GetFileName($_.path) -ieq $header })
        if ($generated.Count -ne 1 -or
            !$generated[0].path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Actual production BuildInfo lacks owned generated header binding: $header"
        }
    }
    Write-Host 'HOST_PRODUCTION_BUILD_METADATA=PASS currentSource=1 ownedGeneratedHeaders=2'
    $privateUnit = @($records | Where-Object { $_.source -like '*DlssNr_Upscaler_Dx12.cpp' })
    if ($privateUnit.Count -ne 1) { throw 'Actual private upscaler object is missing or ambiguous' }
    foreach ($header in @('NVNGX_Proxy.h','XeSS_Proxy.h','FfxApi_Proxy.h')) {
        if (@($privateUnit[0].dependencies | Where-Object { $_.path -like "*tests*nr_addon_host*services*proxies*$header" }).Count -ne 1) {
            throw "Private upscaler object does not bind current host startup service: $header"
        }
    }
    $log = Get-Content -LiteralPath "$out/build.full.log" -Raw
    $libraryPaths = @([regex]::Matches($log, '(?im)^\s*([A-Za-z]:[\\/][^"\r\n]*?\.lib)(?:\s|$)') | ForEach-Object {
        $path = $_.Groups[1].Value
        if (Test-Path -LiteralPath $path -PathType Leaf) { (Resolve-Path -LiteralPath $path).Path }
    } | Sort-Object -Unique)
    $libraries = @($libraryPaths | ForEach-Object { BindActualFile $_ })
    [xml]$compiledProject = Get-Content -LiteralPath $project -Raw
    $namespace = [Xml.XmlNamespaceManager]::new($compiledProject.NameTable)
    $namespace.AddNamespace('p', $compiledProject.DocumentElement.NamespaceURI)
    $selftestLink = @($compiledProject.SelectNodes('/p:Project/p:ItemDefinitionGroup', $namespace) | Where-Object {
        $_.Condition -eq "'`$(OptiScalerNrSelfTest)'=='true'" })[0].Link
    $explicitLibraries = @($selftestLink.AdditionalDependencies.Split(';') | Where-Object { $_ })
    foreach ($name in $explicitLibraries) {
        if (!($libraries | Where-Object { [IO.Path]::GetFileName($_.path) -ieq $name })) {
            throw "Actual verbose link library binding missing: $name"
        }
    }
    $manifest = [ordered]@{schema=1;task=13;kind='candidateSourceManifest';candidateDllSha256=$null;
        candidateDllState='unbuiltPendingTask14';host=$exe;hostSha256=(Get-FileHash -LiteralPath $exe).Hash;
        project=$project;projectSha256=(Get-FileHash -LiteralPath $project).Hash;
        compilerDefinitions=@('NDEBUG','_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR','_CONSOLE','UNICODE','_UNICODE','OPTISCALER_NR_SELF_TEST','OPTISCALER_RTX40_MFG');
        startupService='tests/nr_addon_host/services/proxies/NVNGX_Proxy.h';
        applicationMetadata='owned typed argument table; never passed to provider APIs';
        providerParameters='retained real driver allocated, unchanged production Proxy and CompatibilityRuntime';
        vendorStartupIsolation=@('XeSS_Proxy.h','FfxApi_Proxy.h');alternateVendorRoutingParity=$false;
        allowedReadinessPath='NVIDIA Legacy directPresent onepass';
        compilerCommands=$compileCommands;linkCommands=$linkCommands;
        actualPerObjectCommandCache=$commandCache;actualPerObjectCommandCacheSha256=(Get-FileHash -LiteralPath $commandCache).Hash;
        runtimeLibrary='MultiThreadedDLL';preciseCArchiveDefaultLibraryExclusion='LIBCMT';
        linkLibraryBinding='Every existing native verbose search/consumption artifact; selection edges remain in pinned full log';
        linkLibraries=$libraries;dependencyRoot=$dependencies;materializedHeadersAreGitlinkRevisionProof=$false;
        nativeDiagnosticLog="$out/build.full.log";nativeDiagnosticLogSha256=(Get-FileHash -LiteralPath "$out/build.full.log").Hash;
        nativeBinlog="$out/build.binlog";nativeBinlogSha256=(Get-FileHash -LiteralPath "$out/build.binlog").Hash;
        activeSourceInventory=$inventoryPath;activeSourceInventorySha256=(Get-FileHash -LiteralPath $inventoryPath).Hash;
        units=$records}
    $json = $manifest | ConvertTo-Json -Depth 10
    foreach ($binding in $immutableBindings.Values) {
        if ((Get-Item -LiteralPath $binding.path).Length -ne $binding.bytes -or (Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256) { throw "Finalization input drift: $($binding.path)" }
    }
    $json | Set-Content -LiteralPath "$finalizationRoot/source-object-manifest.json" -Encoding UTF8
    [ordered]@{schema=1;task=13;nativeCompilerAndLinkExit=$exit;compilerInvocations=$(if($FinalizeExistingBuild){0}else{$compileCommands.Count});
        producerPassed=$true;sourceUnits=$records.Count;uniqueFileBindings=$immutableBindings.Count;finalDriftCheck=$true;
        manifest="$finalizationRoot/source-object-manifest.json";manifestSha256=(Get-FileHash "$finalizationRoot/source-object-manifest.json").Hash} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$finalizationRoot/result.json" -Encoding UTF8
    Write-Host "HOST_CURRENT_MANIFEST=$finalizationRoot/source-object-manifest.json"
    Write-Host "HOST_CURRENT_BUILD_PASS=$exe"
} catch {
    [ordered]@{schema=1;task=13;failure=$_.Exception.Message;nativeExit=$exit;
        command=$MSBuild+' '+($arguments -join ' ');gpuRun=$false;artifactRoot=$out} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $(if($FinalizeExistingBuild){"$finalizationRoot/failure.json"}else{"$out/failure.json"}) -Encoding UTF8
    throw
} finally { Stop-Transcript | Out-Null }
