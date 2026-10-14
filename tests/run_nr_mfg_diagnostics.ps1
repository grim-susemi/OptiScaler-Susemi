param([ValidateSet('Contracts','Capture','Analysis','All')][string]$Tier = 'Contracts',
      [Parameter(Mandatory=$true)][string]$EvidenceRoot,
      [ValidateSet('All','EntryDelta','Observer')][string]$Scope = 'All',
      [string]$PriorContractsRoot,
      [string]$ReuseProductRoot,
      [string]$CaptureResumeManifest,
      [string]$AnalysisInputRoot,
      [string]$CandidateRoot,
      [string]$HostRoot,
      [string]$SourceManifest,
      [string]$SourceManifestSha256,
      [string]$RuntimeRoot,
      [string]$RuntimeSha256,
      [string]$GpuAdmissionReceipt,
      [string]$GpuAdmissionSha256,
      [string]$BudgetReceipt,
      [string]$BudgetSha256)
$ErrorActionPreference = 'Stop'
if ($Tier -eq 'All') {
    . "$PSScriptRoot/nr_mfg_diagnostics/Task23All.ps1"
    $allParameters = @{
        CandidateRoot=$CandidateRoot; HostRoot=$HostRoot; EvidenceRoot=$EvidenceRoot
        SourceManifest=$SourceManifest; SourceManifestSha256=$SourceManifestSha256
        RuntimeRoot=$RuntimeRoot; RuntimeSha256=$RuntimeSha256
        GpuAdmissionReceipt=$GpuAdmissionReceipt; GpuAdmissionSha256=$GpuAdmissionSha256
        BudgetReceipt=$BudgetReceipt; BudgetSha256=$BudgetSha256
    }
    $plan = Get-Task23AllPlan @allParameters
    $pairRuntime = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $pairArguments = @('-NoProfile','-File',"$PSScriptRoot/nr_mfg_diagnostics/Task23Pair.ps1")
    foreach ($name in $allParameters.Keys) { $pairArguments += @("-$name", $allParameters[$name]) }
    & $pairRuntime @pairArguments
    if ($LASTEXITCODE -ne 0) { throw "T23_ALL_FAILED nativeExit=$LASTEXITCODE" }
    return
}
if ($Tier -eq 'Analysis') {
    $analysisRuntime = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $analysisArguments = @('-NoProfile','-File',"$PSScriptRoot/nr_mfg_diagnostics/Analysis.ps1",'-EvidenceRoot',$EvidenceRoot)
    if ($AnalysisInputRoot) { $analysisArguments += @('-AnalysisInputRoot',$AnalysisInputRoot) }
    & $analysisRuntime @analysisArguments
    if ($LASTEXITCODE -ne 0) { throw "Task22 Analysis failed with native exit $LASTEXITCODE" }
    return
}
if ($Tier -eq 'Capture') {
    if ($CaptureResumeManifest) {
        $resume = Get-Content -LiteralPath $CaptureResumeManifest -Raw | ConvertFrom-Json
        & "$PSScriptRoot/run_nr_pipeline_capture.ps1" -EvidenceRoot $EvidenceRoot -GpuOnly -ReuseCaptureRoot $resume.fixtureRoot -AdmissionPath $resume.admission -ReuseCpuManifest $resume.cpuReuse
        return
    }
    & "$PSScriptRoot/run_nr_pipeline_capture.ps1" -EvidenceRoot $EvidenceRoot
    return
}
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $EvidenceRoot ('task-19-contracts-' + [guid]::NewGuid().ToString('N'))
$metadataRoot = Join-Path $repo ('.omo/task-19-metadata/' + [guid]::NewGuid().ToString('N'))
if ($Scope -eq 'Observer') {
    $out = Join-Path $repo ('.omo/t20/' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $metadataRoot = Join-Path $out 'meta'
}
New-Item -ItemType Directory -Path $out | Out-Null
Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
$commands = @()
$bindings = @{}
$passed = $false
function Bind([string]$path, [string]$kind) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $key = $resolved.ToLowerInvariant()
    if (!$bindings.ContainsKey($key)) {
        $bindings[$key] = [ordered]@{path=$resolved; kind=$kind;
            bytes=(Get-Item -LiteralPath $resolved).Length;
            sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash}
    }
}
function Native([string]$exe, [string[]]$arguments, [string]$log, [string]$kind) {
    $command = '"' + $exe + '" ' + (($arguments | ForEach-Object {'"' + $_ + '"'}) -join ' ')
    Write-Host "T19_COMMAND=$command"
    & $exe @arguments 2>&1 | ForEach-Object {
        $_ | Out-File -LiteralPath $log -Encoding UTF8 -Append
        Write-Host $_
    }
    $code = $LASTEXITCODE
    Write-Host "T19_NATIVE_EXIT=$code kind=$kind"
    $script:commands += [ordered]@{command=$command; exit=$code; kind=$kind; log=$log}
    return $code
}
function Dependencies([string]$path) {
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Bind $data.Data.Source 'actual-compiler-source'
    foreach ($include in $data.Data.Includes) { Bind $include 'actual-compiler-include' }
    Bind $path 'compiler-dependency-manifest'
}
function ReplaceOnce([string]$text, [string]$anchor, [string]$value) {
    if (($text.Split(@($anchor), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw "Mutation anchor drift: $anchor"
    }
    return $text.Replace($anchor, $value)
}
function Extract([string]$text, [string]$signature) {
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
function LinkInputs([string]$path, [string]$log) {
    Bind $path 'native-linker-full-path-response'
    $text = Get-Content -LiteralPath $path -Raw
    $count = 0
    # LINKREPROFULLPATHRSP is a machine input receipt, independent of linker prose locale.
    foreach ($match in [regex]::Matches($text, '(?im)"([^"]+\.lib)"|([A-Z]:[\\/][^\r\n"]+?\.lib)(?=\s|$)')) {
        $library = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        Bind $library 'actual-linker-resolved-library'
        ++$count
    }
    # Default libraries may be absent from FULLPATHRSP. Extract only absolute path tokens
    # from native /VERBOSE:LIB output, not English/Korean sentence prefixes.
    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $log -Raw),
             '(?im)([A-Z]:[\\/][^\r\n]*?\.lib)(?=[:(\s]|$)')) {
        Bind $match.Groups[1].Value 'native-linker-observed-library'
        ++$count
    }
    if (!$count) { throw "No actual library paths in native full-path receipt: $path" }
}
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$vs) { throw 'No installed x64 compiler; no download/initialization permitted' }
    $envCommand = 'call "' + $vs + '/VC/Auxiliary/Build/vcvars64.bat" >nul && set'
    $environment = & $env:ComSpec /d /s /c $envCommand
    $envExit = $LASTEXITCODE
    $commands += [ordered]@{command='cmd.exe /d /s /c '+$envCommand; exit=$envExit; kind='compiler-environment'}
    if ($envExit) { throw 'vcvars64 environment failed' }
    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    $cl = (Get-Command cl.exe).Source
    Bind $cl 'compiler'
    Bind (Get-Command link.exe).Source 'linker'
    Bind "$vs/VC/Auxiliary/Build/vcvars64.bat" 'compiler-environment-script'
    $compilerVersion = (Get-Item -LiteralPath $cl).VersionInfo.FileVersion
    $sourcePaths = @('OptiScaler/framegen/dlssg/MfgUnlock.cpp','OptiScaler/framegen/dlssg/MfgUnlock.h',
        'OptiScaler/framegen/dlssg/MfgUnlockStatus.h','OptiScaler/framegen/dlssg/MfgUnlockMethod.h',
        'OptiScaler/framegen/dlssg/MfgUnlockProvider.h','OptiScaler/dlssnr/DlssNr_MfgDiagnostics.h',
        'OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp','OptiScaler/dlssnr/DlssNr_NgxDiagnostics.h',
        'OptiScaler/misc/IdentifyGpu.h','OptiScaler/OptiScaler.vcxproj',
        'tests/nr_mfg_diagnostics/Contracts.cpp','tests/nr_mfg_diagnostics/Services.h',
        'tests/nr_diagnostics/Adapter.h','tests/nr_diagnostics/CallbackTests.cpp',
        'tests/nr_diagnostics/run.ps1','tests/run_nr_mfg_diagnostics.ps1',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp','OptiScaler/upscalers/IFeature_Dx12.cpp')
    $sourcesBefore = @($sourcePaths | ForEach-Object { Get-FileHash -LiteralPath "$repo/$_" -Algorithm SHA256 })
    if ($Scope -eq 'Observer') {
        $observerPaths = @('OptiScaler/dlssnr/DlssNr_MfgObserver.h','OptiScaler/dlssnr/DlssNr_MfgObserverNgx.h',
            'OptiScaler/dlssnr/DlssNr_MfgObserverStreamline.h','OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp',
            'OptiScaler/framegen/nvngx/Nvngx_FG.cpp','OptiScaler/framegen/nvngx/Nvngx_Combo.cpp',
            'OptiScaler/hooks/Streamline_Hooks.cpp','OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp',
            'tests/nr_mfg_diagnostics/ObserverServices.h','tests/nr_mfg_diagnostics/ObserverContracts.cpp',
            'tests/nr_mfg_diagnostics/Observer.ps1','OptiScaler/NVNGX_Parameter.h','OptiScaler/NVNGX_Parameter.cpp',
            'OptiScaler/shaders/Shader_Vk.h')
        $sourcesBefore += @($observerPaths | ForEach-Object { Get-FileHash -LiteralPath "$repo/$_" -Algorithm SHA256 })
    }
    foreach ($source in $sourcesBefore) { Bind $source.Path 'current-task-source' }
    $entry = Extract (Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp" -Raw) `
        'void DlssNr_Dx12::DiagnosePipeline('
    $projection = Extract (Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_MfgDiagnostics.h" -Raw) `
        'inline Report Read('
    Set-Content -LiteralPath "$out/projection-read.inc" -Value $projection -Encoding UTF8
    Bind "$out/projection-read.inc" 'current-production-projection-body'
    if ($Scope -eq 'EntryDelta') {
        if (!$PriorContractsRoot) { throw 'EntryDelta needs the retained prior Task19 Contracts root' }
        $priorResult = Get-Content -LiteralPath "$PriorContractsRoot/result.json" -Raw | ConvertFrom-Json
        if (!$priorResult.passed) { throw 'Prior scoped Contracts receipt did not pass' }
        $priorHeader = Get-Content -LiteralPath "$PriorContractsRoot/negative-plain-as-unlock/dlssnr/DlssNr_MfgDiagnostics.h" -Raw
        $priorHeader = ReplaceOnce $priorHeader 'Report report; report.builtInUnlock = true;' 'Report report;'
        if ((Extract $priorHeader 'inline Report Read(') -cne $projection) { throw 'Projection body changed; prior proof cannot be reused' }
        Bind "$PriorContractsRoot/result.json" 'retained-task19-contracts-no-replay'
        Bind "$PriorContractsRoot/negative-plain-as-unlock/dlssnr/DlssNr_MfgDiagnostics.h" 'retained-exact-production-body-carrier'
    }
    $support = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1'
    # Exact current project include list; uninitialized gitlinks use explicit read-only references.
    [xml]$project = Get-Content -LiteralPath "$repo/OptiScaler/OptiScaler.vcxproj" -Raw
    $group = $project.Project.PropertyGroup | Where-Object { $_.Condition -eq "'`$(Configuration)|`$(Platform)'=='Release|x64'" }
    $projectIncludes = ([string]$group.IncludePath).Split(';') | Where-Object { $_ -ne '$(IncludePath)' }
    $gitlinks = @('vulkan','xess','FidelityFX-SDK','FidelityFX-SDK-v2','simpleini','unordered_dense','spdlog','nvapi','magic_enum')
    $includeDirs = foreach ($item in $projectIncludes) {
        $expanded = $item.Trim().Replace('$(ProjectDir)', "$repo/OptiScaler/").Replace('$(SolutionDir)', "$repo/")
        foreach ($gitlink in $gitlinks) {
            $expanded = $expanded.Replace("$repo/external\$gitlink", "$support/external/$gitlink")
            $expanded = $expanded.Replace("$repo/external/$gitlink", "$support/external/$gitlink")
        }
        $expanded
    }
    $productIncludes = @($includeDirs | ForEach-Object { '/I' + $_ })
    foreach ($flavor in @('plain','rtx40-mfg')) {
        $defines = if ($flavor -eq 'rtx40-mfg') { @('/DOPTISCALER_RTX40_MFG') } else { @() }
        $units = @('dlssnr/DlssNr_NgxDiagnostics.cpp','shaders/dlssnr/DlssNr_Dx12.cpp')
        if ($Scope -eq 'Observer') {
            $units += @('inputs/NVNGX_DLSS_Dx12.cpp','framegen/nvngx/Nvngx_FG.cpp',
                'framegen/nvngx/Nvngx_Combo.cpp','hooks/Streamline_Hooks.cpp','dlssnr/DlssNr_StreamlinePicture.cpp')
        }
        if ($Scope -eq 'All') { $units += 'framegen/dlssg/MfgUnlock.cpp' }
        foreach ($unit in $units) {
            $name = [IO.Path]::GetFileNameWithoutExtension($unit)
            $dir = "$out/product-$flavor-$name"
            if ($ReuseProductRoot) {
                $priorDir = "$ReuseProductRoot/product-$flavor-$name"
                $prior = Get-Content -LiteralPath "$ReuseProductRoot/result.json" -Raw | ConvertFrom-Json
                $dependency = Get-Content -LiteralPath "$priorDir/dependencies.json" -Raw | ConvertFrom-Json
                foreach ($path in @($dependency.Data.Source) + @($dependency.Data.Includes)) {
                    $bound = @($prior.inputs | Where-Object {$_.path -eq $path})
                    if ($bound.Count -ne 1 -or (Get-FileHash -LiteralPath $path).Hash -ne $bound[0].sha256) {
                        throw "Retained product input changed: $path"
                    }
                }
                $native = @($prior.commands | Where-Object { $_.log -and
                    [IO.Path]::GetFullPath($_.log) -eq [IO.Path]::GetFullPath("$priorDir/compile.log") })
                if ($native.Count -ne 1 -or $native[0].exit -ne 0) { throw "Retained native product exit missing: $unit" }
                $commands += [ordered]@{command=$native[0].command; exit=0; kind='retained-current-product-unit';
                    log=$native[0].log; retainedFrom=$ReuseProductRoot}
                Dependencies "$priorDir/dependencies.json"
                $boundObject = @($prior.inputs | Where-Object {
                    [IO.Path]::GetFullPath($_.path) -eq [IO.Path]::GetFullPath("$priorDir/unit.obj") })
                if ($boundObject.Count -ne 1 -or (Get-FileHash -LiteralPath "$priorDir/unit.obj").Hash -ne $boundObject[0].sha256) {
                    throw "Retained product object identity changed: $unit"
                }
                Bind "$priorDir/unit.obj" 'retained-current-product-object'
                continue
            }
            New-Item -ItemType Directory -Path $dir | Out-Null
            $args = @('/nologo','/c','/std:c++latest','/EHsc','/MD','/W3','/permissive-','/Y-',
                '/DNDEBUG','/D_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR','/D_WINDOWS','/D_USRDLL','/D_WINDLL',
                '/D_UNICODE','/DUNICODE',"/Fo$dir/unit.obj","/Fd$dir/unit.pdb",
                '/sourceDependencies',"$dir/dependencies.json") + $defines + $productIncludes + @("$repo/OptiScaler/$unit")
            if ((Native $cl $args "$dir/compile.log" 'actual-product-unit') -ne 0) { throw "Product compile failed: $flavor/$unit" }
            Dependencies "$dir/dependencies.json"
            Bind "$dir/unit.obj" 'actual-product-object'
        }
    }
    if ($Scope -eq 'Observer') {
        . "$PSScriptRoot/nr_mfg_diagnostics/Observer.ps1"
        foreach ($source in $sourcesBefore) {
            if ((Get-FileHash -LiteralPath $source.Path).Hash -ne $source.Hash) { throw "Source drift during proof: $($source.Path)" }
        }
        $passed = $true
        Write-Host "T20_CONTRACTS_PASS root=$out"
        return
    }
    $seams = "$out/seams"
    New-Item -ItemType Directory -Path "$seams/proxies","$seams/misc","$seams/framegen/dlssg" | Out-Null
    foreach ($header in @('pch.h','Config.h','State.h','Util.h','proxies/NVNGX_Proxy.h','misc/IdentifyGpu.h','framegen/dlssg/MfgUnlock.h')) {
        Set-Content -LiteralPath "$seams/$header" -Value '// Services.h supplies only bounded dependency/status values.' -Encoding UTF8
        Bind "$seams/$header" 'fixture-dependency-seam'
    }
    foreach ($flavor in @('plain','rtx40-mfg')) {
        $dir = "$out/fixture-$flavor"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $defines = if ($flavor -eq 'rtx40-mfg') { @('/DOPTISCALER_RTX40_MFG') } else { @() }
        $args = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',
            "/FI$PSScriptRoot/nr_mfg_diagnostics/Services.h","/I$seams","/I$repo/OptiScaler",
            "/I$repo/external/nvngx_dlss_sdk","/Fo$dir/","/Fd$dir/fixture.pdb","/Fe$dir/contracts.exe",
            '/sourceDependencies',"$dir/") + $defines +
            @("$PSScriptRoot/nr_mfg_diagnostics/Contracts.cpp","$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp",
                '/link','d3d12.lib','dxgi.lib','bcrypt.lib','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$dir/link-inputs.rsp")
        if ((Native $cl $args "$dir/compile.log" 'production-adapter-fixture') -ne 0) { throw "Adapter compile failed: $flavor" }
        foreach ($dependency in Get-ChildItem -LiteralPath $dir -Filter '*.json') { Dependencies $dependency.FullName }
        Bind "$dir/contracts.exe" 'fixture-executable'
        LinkInputs "$dir/link-inputs.rsp" "$dir/compile.log"
        $cases = if ($flavor -eq 'rtx40-mfg') {
            @('active','absent','mismatched','version-mismatched','requested-but-not-applied','unknown-version',
              'ota','unknown-identity','unread-state','raw-pacing','collector')
        } else { @('plain','absent','collector') }
        if ($Scope -eq 'EntryDelta') { $cases = @('collector') }
        foreach ($case in $cases) {
            if ((Native "$dir/contracts.exe" @($case) "$dir/$case.log" 'positive-adapter-case') -ne 0) { throw "Case failed: $flavor/$case" }
            $json = Get-Content -LiteralPath "$dir/$case.log" -Raw | ConvertFrom-Json
            if ($json.qualityFixProven -or $json.displayTimingAvailable) { throw 'Unsupported quality/timing claim' }
            if ($case -eq 'collector') {
                if ($json.modules.optiscaler.sha256 -ne (Get-FileHash -LiteralPath "$dir/contracts.exe").Hash) { throw 'Real collector hash differs' }
                if ($json.driverVersion -or $json.adapter -or $json.modules.provider.loaded) { throw 'Collector invented unavailable facts' }
            }
            if ($case -eq 'raw-pacing' -and $json.pacingRaw -cne "unsupported `"plugin`"`nraw") { throw 'Raw pacing serialization changed' }
            if ($case -eq 'unread-state' -and $null -ne $json.presented) { throw 'Unread state presented as observed' }
            if ($case -eq 'unknown-version' -and $null -ne $json.modules.provider.version) { throw 'Unknown version hidden' }
        }
    }
    $header = Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_MfgDiagnostics.h" -Raw
    $controls = @(
        @{tag='request-as-activity'; case='requested-but-not-applied'; assertion='T19_REQUEST_IS_NOT_ACTIVITY';
          anchor='report.correctionActivity = report.builtInUnlock && report.identityMatched &&';
          value='report.correctionActivity = report.builtInUnlock || report.identityMatched &&'},
        @{tag='hide-mismatch'; case='mismatched'; assertion='T19_MISMATCH_NOT_ACTIVITY';
          anchor='actual != recorded'; value='false'},
        @{tag='invent-presented'; case='unread-state'; assertion='T19_UNREAD_STATE_NOT_PRESENTED';
          anchor='report.stateSeen = telemetry->stateSeen.load(std::memory_order_acquire);'; value='report.stateSeen = true;'},
        @{tag='pacing-as-patched'; case='raw-pacing'; assertion='T19_RAW_PACING_NOT_PATCHED';
          anchor='report.inputs = inputs;'; value='report.inputs = inputs; report.inputs.status.FlipMetering = "patched";'},
        @{tag='invent-version'; case='unknown-version'; assertion='T19_UNKNOWN_VERSION_RETAINED';
          anchor='report.inputs = inputs;'; value='report.inputs = inputs; report.inputs.provider.version = "310.9.1";'},
        @{tag='plain-as-unlock'; case='plain'; assertion='T19_PLAIN_NOT_UNLOCK_PROOF';
          anchor='Report report;'; value='Report report; report.builtInUnlock = true;'}
    )
    if ($Scope -eq 'EntryDelta') { $controls = @() }
    foreach ($control in $controls) {
        $dir = "$out/negative-$($control.tag)"
        New-Item -ItemType Directory -Path "$dir/dlssnr" | Out-Null
        $mutated = ReplaceOnce $header $control.anchor $control.value
        Set-Content -LiteralPath "$dir/dlssnr/DlssNr_MfgDiagnostics.h" -Value $mutated -Encoding UTF8
        Copy-Item -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.h" -Destination "$dir/dlssnr/DlssNr_NgxDiagnostics.h"
        Bind "$dir/dlssnr/DlssNr_MfgDiagnostics.h" 'derived-production-negative-control'
        $defines = if ($control.case -eq 'plain') { @() } else { @('/DOPTISCALER_RTX40_MFG') }
        $args = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX','/DT19_ADAPTER_ONLY',
            "/I$dir","/I$repo/OptiScaler","/I$repo/external/nvngx_dlss_sdk","/Fo$dir/control.obj",
            "/Fe$dir/control.exe",'/sourceDependencies',"$dir/dependencies.json") + $defines +
            @("$PSScriptRoot/nr_mfg_diagnostics/Contracts.cpp")
        if ((Native $cl $args "$dir/compile.log" 'negative-control-compile') -ne 0) { throw "Negative compile failed: $($control.tag)" }
        Dependencies "$dir/dependencies.json"
        $exit = Native "$dir/control.exe" @($control.case) "$dir/output.log" 'expected-negative-control'
        if ($exit -ne 41 -or (Get-Content -LiteralPath "$dir/output.log" -Raw) -notmatch $control.assertion) {
            throw "Negative missed named assertion: $($control.tag)"
        }
    }
    # Execute the entire unchanged production shortcut body and real native enqueue/worker in an owned DLL.
    $workerSource = Get-Content -LiteralPath "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp" -Raw
    foreach ($flavor in @('plain','rtx40-mfg')) {
        $dir = "$out/entry-$flavor"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $defines = if ($flavor -eq 'rtx40-mfg') { @('/DOPTISCALER_RTX40_MFG') } else { @() }
        Set-Content -LiteralPath "$dir/entry.inc" -Value $entry -Encoding UTF8
        $dllArgs = @('/nologo','/LD','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX','/DT19_JOB_DLL',
            "/FI$PSScriptRoot/nr_mfg_diagnostics/Services.h","/I$dir","/I$seams","/I$repo/OptiScaler",
            "/I$repo/external/nvngx_dlss_sdk","/Fo$dir/","/Fe$dir/entry.dll",'/sourceDependencies',"$dir/") +
            $defines + @("$PSScriptRoot/nr_mfg_diagnostics/Contracts.cpp","$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp",
            '/link','d3d12.lib','dxgi.lib','bcrypt.lib','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$dir/dll-link-inputs.rsp")
        if ((Native $cl $dllArgs "$dir/dll-compile.log" 'actual-entry-worker-dll') -ne 0) { throw "Entry DLL compile failed: $flavor" }
        foreach ($dependency in Get-ChildItem -LiteralPath $dir -Filter '*.json') { Dependencies $dependency.FullName }
        LinkInputs "$dir/dll-link-inputs.rsp" "$dir/dll-compile.log"; Bind "$dir/entry.dll" 'owned-actual-entry-worker-dll'
        $hostArgs = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX','/DT19_ENTRY_HOST',
            "/I$repo/OptiScaler","/I$repo/external/nvngx_dlss_sdk","/Fo$dir/host.obj","/Fe$dir/host.exe",
            '/sourceDependencies',"$dir/host-dependencies.json") + $defines +
            @("$PSScriptRoot/nr_mfg_diagnostics/Contracts.cpp",'/link','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$dir/host-link-inputs.rsp")
        if ((Native $cl $hostArgs "$dir/host-compile.log" 'entry-event-host') -ne 0) { throw "Entry host compile failed: $flavor" }
        Dependencies "$dir/host-dependencies.json"; LinkInputs "$dir/host-link-inputs.rsp" "$dir/host-compile.log"
        foreach ($case in @('off','unfocused','busy','other-stage','accepted','held','exhausted','queue-failure','reference-failure')) {
            $caseRoot = "$metadataRoot/$flavor/$case"
            New-Item -ItemType Directory -Path $caseRoot | Out-Null
            if ((Native "$dir/host.exe" @("$dir/entry.dll",$caseRoot,$case) "$dir/$case.log" 'actual-entry-event-case') -ne 0) {
                throw "Entry event proof failed: $flavor/$case"
            }
            foreach ($metadata in Get-ChildItem -LiteralPath $caseRoot -Recurse -Filter 'mfg-preflight.json') {
                $json = Get-Content -LiteralPath $metadata.FullName -Raw | ConvertFrom-Json
                if ($json.modules.optiscaler.sha256 -ne (Get-FileHash -LiteralPath "$dir/entry.dll").Hash) { throw 'Worker DLL hash differs' }
                if ($json.buildFlavor -ne $flavor -or $json.qualityFixProven -or $json.displayTimingAvailable) { throw 'Worker flavor/limits claim differs' }
                if ($json.modules.provider.loaded -or $json.adapter -or $json.driverVersion) { throw 'Worker invented unavailable provider/cache/driver fact' }
                if ($flavor -eq 'plain' -and ($json.builtInUnlockCompiled -or $null -ne $json.configuredTemporalMethod)) { throw 'Plain worker invents unlock/config proof' }
                Bind $metadata.FullName 'real-worker-metadata-artifact'
            }
        }
    }
    $entryControls = @(
        @{tag='remove-enqueue'; case='accepted'; assertion='T19_ACTUAL_ENTRY_ENQUEUE'; target='entry';
          anchor="DlssNr::NgxDiagnostics::EnqueueMfgPreflight(std::move(request)) ==`n                    DlssNr::NgxDiagnostics::MfgQueueResult::Submitted";
          value='false'},
        @{tag='leak-queue-failure-reference'; case='queue-failure'; assertion='T19_QUEUE_FAILURE_RELEASES_DLL'; target='worker';
          anchor='        FreeLibrary(job->self);'; value='        // Deliberately leaked reference for the negative control.'},
        @{tag='leak-callback-reference'; case='accepted'; assertion='T19_CALLBACK_RETURN_DLL_RELEASE'; target='worker';
          anchor='    FreeLibraryWhenCallbackReturns(instance, job->self);'; value='    (void)instance;'},
        @{tag='late-mutable-config'; case='accepted'; assertion='T19_COPY_CONFIG_SURVIVES_RETIREMENT'; target='worker';
          anchor='    inputs.configured = request.configured;'; value='    inputs.configured = MfgUnlock::ConfiguredTemporalMethod();'}
    )
    foreach ($control in $entryControls) {
        $dir = "$out/entry-negative-$($control.tag)"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = if ($control.target -eq 'entry') { ReplaceOnce $entry $control.anchor $control.value } else { $entry }
        $worker = if ($control.target -eq 'worker') { ReplaceOnce $workerSource $control.anchor $control.value } else { $workerSource }
        Set-Content -LiteralPath "$dir/entry.inc" -Value $body -Encoding UTF8
        Set-Content -LiteralPath "$dir/worker.cpp" -Value $worker -Encoding UTF8
        $args = @('/nologo','/LD','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX','/DT19_JOB_DLL','/DOPTISCALER_RTX40_MFG',
            "/FI$PSScriptRoot/nr_mfg_diagnostics/Services.h","/I$dir","/I$seams","/I$repo/OptiScaler",
            "/I$repo/OptiScaler/dlssnr","/I$repo/external/nvngx_dlss_sdk","/Fo$dir/","/Fe$dir/entry.dll",
            '/sourceDependencies',"$dir/","$PSScriptRoot/nr_mfg_diagnostics/Contracts.cpp","$dir/worker.cpp",
            '/link','d3d12.lib','dxgi.lib','bcrypt.lib','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$dir/link-inputs.rsp")
        if ((Native $cl $args "$dir/compile.log" 'entry-negative-control-compile') -ne 0) { throw "Entry seed compile failed: $($control.tag)" }
        foreach ($dependency in Get-ChildItem -LiteralPath $dir -Filter '*.json') { Dependencies $dependency.FullName }
        LinkInputs "$dir/link-inputs.rsp" "$dir/compile.log"
        $caseRoot = "$metadataRoot/negative-$($control.tag)"
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $exit = Native "$out/entry-rtx40-mfg/host.exe" @("$dir/entry.dll",$caseRoot,$control.case) `
            "$dir/output.log" 'expected-entry-negative-control'
        if ($exit -ne 41 -or (Get-Content -LiteralPath "$dir/output.log" -Raw) -notmatch $control.assertion) {
            throw "Entry negative missed assertion: $($control.tag)"
        }
    }
    # Existing callback forwarding remains behavior of record after the diagnostics include changes.
    $dir = "$out/callback-regression"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $args = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',
        "/FI$PSScriptRoot/nr_diagnostics/Adapter.h","/I$seams","/I$repo/OptiScaler",
        "/I$repo/external/nvngx_dlss_sdk","/Fo$dir/","/Fe$dir/callback.exe",
        '/sourceDependencies',"$dir/","$PSScriptRoot/nr_diagnostics/CallbackTests.cpp",
        "$repo/OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp",'/link','d3d12.lib','dxgi.lib','bcrypt.lib','/VERBOSE:LIB',
        "/LINKREPROFULLPATHRSP:$dir/link-inputs.rsp")
    if ((Native $cl $args "$dir/compile.log" 'existing-callback-regression-compile') -ne 0) { throw 'Callback compile failed' }
    foreach ($dependency in Get-ChildItem -LiteralPath $dir -Filter '*.json') { Dependencies $dependency.FullName }
    if ((Native "$dir/callback.exe" @() "$dir/output.log" 'existing-callback-regression') -ne 0) { throw 'Callback behavior changed' }
    LinkInputs "$dir/link-inputs.rsp" "$dir/compile.log"
    foreach ($source in $sourcesBefore) {
        if ((Get-FileHash -LiteralPath $source.Path).Hash -ne $source.Hash) { throw "Source drift during proof: $($source.Path)" }
    }
    $passed = $true
    Write-Host "T19_CONTRACTS_PASS root=$out"
} finally {
    $owned = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($out, [StringComparison]::OrdinalIgnoreCase) })
    [ordered]@{tier=$Tier; verificationScope=$Scope; passed=$passed; root=$out; commands=$commands;
        compiler=$cl; compilerVersion=$compilerVersion; inputs=@($bindings.Values);
        scope=$(if ($Scope -eq 'Observer') {'Actual current normal units both flavors and production observer/forwarding bodies with typed services; no collector/full DLL/GPU/game'}
                else {'Actual changed product units both flavors; actual production adapter/collector with bounded services; no full DLL/GPU/game'});
        existingEntryWiring=$(if ($Scope -eq 'Observer') {'Actual production shortcut and observer activation; controlled metadata submission boundary; Task19 native worker proof retained separately'}
                              else {'actual production shortcut -> native threadpool metadata-only worker'});
        priorProjectionRoot=$PriorContractsRoot; priorAggregateExit=$null;
        reusedCurrentProductRoot=$ReuseProductRoot;
        metadataRoot=$metadataRoot;
        independentAcceptance=$false; ownedProcessesRemaining=@($owned | ForEach-Object {$_.ProcessId}); cleanupComplete=($owned.Count -eq 0)} |
        ConvertTo-Json -Depth 9 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Stop-Transcript | Out-Null
}
