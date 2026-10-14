param(
    [ValidateSet('Build','Run','ContainedInitBuild','OutputOnlyBuild','OutputContractBuild','SdkOutputBuild','ContainedRuntimeBuild')][string]$Mode='Build',
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [string]$BuildRoot,
    [ValidateSet('none','stale-input')][string]$Mutation='none'
)
$ErrorActionPreference='Stop'
if($Mode -eq 'Run') {
    # The measured public dispatcher Init writes its system model cache and
    # launches updater children despite dataPath/environment redirection.
    # Do not repeat it until a supported isolated initialization is proved.
    throw 'TASK14_RUNTIME_ISOLATION_REFUSED'
}
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$contained=$Mode -in @('ContainedInitBuild','OutputOnlyBuild','OutputContractBuild','SdkOutputBuild','ContainedRuntimeBuild')
if($contained -and ($Mutation -ne 'none' -or $BuildRoot)) { throw 'TASK14_CONTAINED_MIXED_BUILD_REFUSED' }
$e=Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/resume-ui-feedback-01a12466-aa9f-74e8-9f13-887e8c17715c'
$owned=Join-Path $e 'task-14-owned'
if($contained) { $owned=Join-Path $repo '.omo/e14-contained-init-r3-01a12466' }
if($Mode -eq 'OutputOnlyBuild') { $owned=Join-Path $repo '.omo/e14-output-only-r4-01a12466' }
if($Mode -eq 'OutputContractBuild') { $owned=Join-Path $repo '.omo/e14-output-contract-r5-01a12466' }
if($Mode -eq 'SdkOutputBuild') { $owned=Join-Path $repo '.omo/e14-sdk-output-r6-01a12466' }
if($Mode -eq 'ContainedRuntimeBuild') { $owned=Join-Path $repo '.omo/e14-contained-runtime-r7-01a12466' }
function OwnedPath([string]$path) {
    if(-not [IO.Path]::IsPathRooted($path) -or -not [IO.Path]::GetFullPath($path).StartsWith(
        [IO.Path]::GetFullPath($owned).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) { throw 'TASK14_MALFORMED_OWNED_ROOT_REFUSED' }
    [IO.Path]::GetFullPath($path)
}
$full=OwnedPath $EvidenceRoot
if($Mode -eq 'Run') { $BuildRoot=OwnedPath $BuildRoot }
if(Test-Path -LiteralPath "$full/result.json") { throw 'TASK14_OVERWRITE_REFUSED' }
if($contained -and (Test-Path -LiteralPath "$full/build.json")) { throw 'TASK14_OVERWRITE_REFUSED' }
if($Mode -eq 'Run') {
    $build=Get-Content -LiteralPath "$BuildRoot/build.json" -Raw | ConvertFrom-Json
    foreach($pin in $build.sourcePins) {
        if((Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.sha256) { throw 'TASK14_CURRENT_SOURCE_REFUSED' }
    }
    foreach($pin in $build.runtimeInputs) {
        $expected=if($Mutation -eq 'stale-input' -and $pin.role -eq 'nr-runtime'){'0'*64}else{$pin.sha256}
        if((Get-FileHash -LiteralPath $pin.path).Hash -ne $expected) { throw 'TASK14_STALE_INPUT_REFUSED' }
    }
    if((Get-FileHash -LiteralPath $build.exe).Hash -ne $build.exeSha256) { throw 'TASK14_CURRENT_BINARY_REFUSED' }
}
New-Item -ItemType Directory -Force -Path $full | Out-Null
$children=if($contained){@('data')}else{@('temp','profile','appdata','localappdata','programdata','data')}
foreach($child in $children) {
    New-Item -ItemType Directory -Force -Path (Join-Path $full $child) | Out-Null
}
$temporary=Join-Path $owned $(if($contained){'temp'}else{'t'})
New-Item -ItemType Directory -Force -Path $temporary | Out-Null
$env:TEMP=$temporary;$env:TMP=$temporary
if(-not $contained) {
    $env:USERPROFILE="$full/profile";$env:APPDATA="$full/appdata";$env:LOCALAPPDATA="$full/localappdata"
    $env:PROGRAMDATA="$full/programdata";$env:NV_SHADER_DISK_CACHE='0';$env:__GL_SHADER_DISK_CACHE='0'
    Set-Location -LiteralPath $full
} else { Set-Location -LiteralPath $repo }
if(-not $contained) {
$absence=@(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(CrimsonDesert.*|obs64|obs32)\.exe$'
} | Select-Object ProcessId,CreationDate,ExecutablePath,CommandLine)
[ordered]@{observedUtc=[DateTimeOffset]::UtcNow.ToString('o');gameObsCount=$absence.Count;matches=$absence} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$full/absence.json" -Encoding UTF8
if($absence.Count) { throw 'TASK14_GAME_OBS_OCCUPIED_REFUSED' }
$accepted=Get-Content -LiteralPath "$e/task-2/source-bindings.json" -Raw | ConvertFrom-Json
foreach($pin in $accepted.changedInputs) {
    if((Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.sha256) { throw 'TASK14_ACCEPTED_SOURCE_DRIFT' }
}
[ordered]@{cwd=$full;dataPath="$full/data";temporary=$temporary;userProfile="$full/profile";
    appData="$full/appdata";localAppData="$full/localappdata";programData="$full/programdata";
    shaderDiskCacheDisabled=$true;gameObsCount=0;acceptedSourcePins=$accepted.changedInputs.Count
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$full/isolation.json" -Encoding UTF8
}
if($Mode -eq 'Build' -or $contained) {
    if(-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'TASK14_COMPILER_MISSING' }
    $d='C:/omo-research/rw-nr3-0985d/external'
    $n='D:/SteamLibrary/steamapps/common/The Witcher 3/bin/x64_dx12'
    $driver='C:/Windows/System32/DriverStore/FileRepository/nv_dispi.inf_amd64_da865124972e1f80/_nvngx.dll'
    $inputPaths=@(
        @{role='nr-runtime';path="$n/nvngx_dlssnr.dll"},
        @{role='ngx-driver';path=$driver},
        @{role='xefg-runtime';path="$d/xess/bin/libxess_fg.dll"},
        @{role='xell-runtime';path="$d/xess/bin/libxell.dll"},
        @{role='sample-reference-not-launched';path="$d/xess/bin/basic_sample_frame_generation.exe"}
    )
    if($contained) { $inputPaths=@(@{role='ngx-driver';path=$driver}) }
    if($Mode -eq 'ContainedRuntimeBuild') {
        $inputPaths=@(@{role='ngx-driver';path=$driver},
            @{role='nr-runtime';path="$n/nvngx_dlssnr.dll"},
            @{role='xefg-runtime';path="$d/xess/bin/libxess_fg.dll"},
            @{role='xell-runtime';path="$d/xess/bin/libxell.dll"})
    }
    $runtimeInputs=@($inputPaths | ForEach-Object {
        [ordered]@{role=$_.role;path=$_.path;bytes=(Get-Item -LiteralPath $_.path).Length;
            sha256=(Get-FileHash -LiteralPath $_.path).Hash}
    })
    if($contained) {
        if($runtimeInputs[0].bytes -ne 1428200 -or
            $runtimeInputs[0].sha256 -ne '66767018C36B3BAB46398DADE3ADF173DAA3730FDA75965689EA848C9BC4E79B') {
            throw 'TASK14_PINNED_DRIVER_DRIFT'
        }
        $signature=Get-AuthenticodeSignature -LiteralPath $driver
        if($signature.Status -ne 'Valid') { throw 'TASK14_DRIVER_SIGNATURE_REFUSED' }
        [ordered]@{path=$driver;status=[string]$signature.Status;
            signerThumbprint=$signature.SignerCertificate.Thumbprint;vendorLoad=$false
        } | ConvertTo-Json | Set-Content -LiteralPath "$full/driver-signature.json" -Encoding UTF8
    }
    $sourcePaths=@(
        "$PSScriptRoot/TemporalRuntime.cpp","$PSScriptRoot/RunRuntime.ps1",
        "$PSScriptRoot/runtime_support/pch.h","$PSScriptRoot/runtime_support/Logger.h",
        "$repo/tests/nr_compatibility/Adapter.h","$repo/tests/run_nr_ui_temporal.ps1",
        "$repo/OptiScaler/dlssnr/DlssNr_CompatibilityRuntime.cpp",
        "$repo/OptiScaler/dlssnr/DlssNr_CompatibilityRuntime.h",
        "$repo/OptiScaler/dlssnr/DlssNr_RuntimeImports.h",
        "$repo/OptiScaler/dlssnr/DlssNr_ModelParameters.h",
        "$repo/OptiScaler/shaders/dlssnr/DlssNr_Guides.h",
        "$repo/external/nvngx_dlss_sdk/nvsdk_ngx.h",
        "$repo/external/nvngx_dlss_sdk/nvsdk_ngx_defs.h",
        "$repo/external/nvngx_dlss_sdk/nvsdk_ngx_params.h",
        "$d/xess/inc/xess_fg/xefg_swapchain.h",
        "$d/xess/inc/xess_fg/xefg_swapchain_d3d12.h",
        "$d/xess/inc/xell/xell.h","$d/xess/inc/xell/xell_d3d12.h",
        "$d/xess/samples/basic_sample_frame_generation/basic_sample.cpp"
    )
    if($contained) { $sourcePaths=@($sourcePaths | Where-Object {$_ -ne "$d/xess/samples/basic_sample_frame_generation/basic_sample.cpp"}) }
    $sourcePins=@($sourcePaths | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} })
    New-Item -ItemType Directory -Force:$contained -Path "$full/dependencies" | Out-Null
    $exe="$full/TemporalRuntime.exe"
    $arguments=@('/nologo','/std:c++20','/EHsc','/W4','/MD','/DNOMINMAX',
        "/FI$repo/tests/nr_compatibility/Adapter.h","/I$PSScriptRoot/runtime_support",
        "/I$repo/OptiScaler","/I$repo/external/nvngx_dlss_sdk","/I$d/xess/inc",
        "/Fo$full/","/Fd$full/runtime.pdb","/Fe$exe",'/sourceDependencies',"$full/dependencies/",
        "$PSScriptRoot/TemporalRuntime.cpp","$repo/OptiScaler/dlssnr/DlssNr_CompatibilityRuntime.cpp",
        '/link','d3d12.lib','dxgi.lib','dxguid.lib','user32.lib','psapi.lib','d3dcompiler.lib')
    if($contained) {
        $arguments=@('/showIncludes','/WX')+$arguments+@('advapi32.lib','/VERBOSE:LIB',"/MAP:$full/TemporalRuntime.map",'/INCREMENTAL:NO')
        $observed=$arguments -join ' '
        if($observed -notmatch '(?:^|\s)/MD(?:\s|$)' -or
            $observed -match '(?i)(?:^|\s)/(?:GL|MT)(?:\s|$)|/FORCE|/IGNORE|/NODEFAULTLIB') {
            throw 'TASK14_CONTAINED_CRT_CONTRACT_REFUSED'
        }
    }
    Write-Host ('TASK14_COMPILE_COMMAND=cl.exe '+($arguments -join ' '))
    & cl.exe @arguments 2>&1 | Tee-Object -Variable lines | Write-Host
    $compileExit=$LASTEXITCODE
    $lines | Set-Content -LiteralPath "$full/compile.log" -Encoding UTF8
    if($compileExit) { throw "TASK14_COMPILE_EXIT=$compileExit" }
    foreach($pin in $sourcePins) {
        if((Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.sha256) { throw 'TASK14_BUILD_SOURCE_DRIFT' }
    }
    $compiler=Get-Command cl.exe
    $objects=@(Get-ChildItem -LiteralPath $full -Filter '*.obj' | ForEach-Object {
        [ordered]@{file=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
    })
    $compiledHeaders=@(Get-ChildItem -LiteralPath "$full/dependencies" -Filter '*.json' | ForEach-Object {
        $unit=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        [ordered]@{source=$unit.Data.Source;includes=@($unit.Data.Includes | ForEach-Object {
            [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
        })}
    })
    [ordered]@{compileExit=0;exe=$exe;exeSha256=(Get-FileHash -LiteralPath $exe).Hash;
        sourcePins=$sourcePins;runtimeInputs=$runtimeInputs;objects=$objects;compiledHeaders=$compiledHeaders;
        compiler=$compiler.Source;compilerSha256=(Get-FileHash -LiteralPath $compiler.Source).Hash;
        command='cl.exe '+($arguments -join ' ');stage=$(if($contained){'ContainedInitCPUPrepared'}else{'CreationAdmissionOnly'});fullTask3=$false
    } | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath "$full/build.json" -Encoding UTF8
    Write-Host 'TASK14_BUILD_COMPLETE'
    exit 0
}
$lease=New-Object Threading.Mutex($false,'Local\OptiScaler-NR-UI-Feedback-01a12466')
$acquired=$false;$native=$null
try {
    try { $acquired=$lease.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired=$true;throw 'TASK14_ABANDONED_GPU_LEASE_REFUSED' }
    if(-not $acquired) { throw 'TASK14_SOLE_GPU_LEASE_OCCUPIED_REFUSED' }
    $self=Get-Process -Id $PID
    try {
        [ordered]@{mutex='Local\OptiScaler-NR-UI-Feedback-01a12466';pid=$PID;
            birthUtc=$self.StartTime.ToUniversalTime().ToString('o');exe=$self.MainModule.FileName;
            argv=[Environment]::CommandLine;executor='st_01a127f6';simultaneousGpuOwners=1;acquired=1
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$full/lease-acquired.json" -Encoding UTF8
    } finally { $self.Dispose() }
    Write-Host 'TASK14_GPU_LEASE_ACQUIRED=1'
    $driver=($build.runtimeInputs | Where-Object {$_.role -eq 'ngx-driver'}).path
    $nr=($build.runtimeInputs | Where-Object {$_.role -eq 'nr-runtime'}).path
    $fg=($build.runtimeInputs | Where-Object {$_.role -eq 'xefg-runtime'}).path
    $ll=($build.runtimeInputs | Where-Object {$_.role -eq 'xell-runtime'}).path
    $arguments=@("$full/data",$driver,$nr,$fg,$ll)
    Write-Host ('TASK14_RUN_COMMAND='+$build.exe+' '+($arguments -join ' '))
    & $build.exe @arguments 2>&1 | Tee-Object -Variable lines | Write-Host
    $native=$LASTEXITCODE
    $lines | Set-Content -LiteralPath "$full/runtime.log" -Encoding UTF8
    [ordered]@{nativeExit=$native;exe=$build.exe;exeSha256=$build.exeSha256;arguments=$arguments;
        sourcePins=$build.sourcePins;runtimeInputs=$build.runtimeInputs;
        stage='CreationAdmissionOnly';independentAcceptance=$false;fullTask3=$false
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$full/result.json" -Encoding UTF8
} finally {
    if($acquired) { $lease.ReleaseMutex() }
    $lease.Dispose()
    [ordered]@{acquired=[int]$acquired;released=[int]$acquired;handlesAcquired=1;handlesClosed=1;
        remainingGpuLeases=0;remainingLeaseHandles=0;nativeExit=$native
    } | ConvertTo-Json | Set-Content -LiteralPath "$full/lease-released.json" -Encoding UTF8
    Write-Host 'TASK14_GPU_LEASE_RELEASED=1 REMAINING_LEASES=0'
}
exit $native
