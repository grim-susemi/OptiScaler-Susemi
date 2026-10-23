# Scoped Task24 tiers using the existing resize and active-colour WARP mechanisms.
param(
    [Parameter(Mandatory=$true)][ValidateSet('Contracts','Shaders','Ui','Runtime')][string]$Tier,
    [Parameter(Mandatory=$true)][string]$EvidenceRoot,
    [ValidateSet('Default','Admission','Outcome')][string]$ContractScope = 'Default',
    [string]$AdmissionWrapperRoot,
    [string]$CandidateRoot,
    [ValidateRange(320,4096)][int]$Width = 1280,
    [ValidateRange(256,2160)][int]$Height = 900,
    [ValidateSet('before4','before2','post4','post2','no-runtime','failure')][string]$Fixture = 'before4'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
if ($ContractScope -eq 'Outcome') {
    if ($Tier -ne 'Contracts' -or $CandidateRoot -or $AdmissionWrapperRoot) {
        throw 'Outcome requires Contracts without a candidate or admission receipt'
    }
    & "$PSScriptRoot/run_nr_finished_outcome.ps1" -EvidenceRoot $EvidenceRoot
    return
}
if ($ContractScope -eq 'Admission') {
    if ($Tier -ne 'Contracts' -or $CandidateRoot) { throw 'Admission requires Contracts without a UI-only candidate' }
    $out = Join-Path $EvidenceRoot ('task-4-contracts-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $out | Out-Null
    Start-Transcript -LiteralPath "$out/raw.log" | Out-Null
    try {
        $commands = @()
        foreach ($name in @('nr_present_identity_contracts','nr_finished_queue_smoke','nr_streamline_picture_smoke')) {
            $exe = "$out/$name.exe"
            $arguments = @('/nologo','/std:c++20','/EHsc','/W4','/DNOMINMAX',
                "/Fo$out/$name.obj", "/Fd$out/$name.pdb", "/Fe$exe",
                '/sourceDependencies', "$out/$name.inputs.json", "$PSScriptRoot/$name.cpp")
            if ($name -ne 'nr_present_identity_contracts') {
                $arguments += @('/link','d3d12.lib','dxgi.lib','dxguid.lib','/VERBOSE:LIB')
            }
            Write-Host ("T4_CONTRACT_COMPILE_COMMAND=cl.exe " + ($arguments -join ' '))
            & cl.exe @arguments 2>&1 | Tee-Object -FilePath "$out/$name.compile.log" | Write-Host
            $compileExit = $LASTEXITCODE
            Write-Host "T4_CONTRACT_COMPILE_EXIT=$compileExit case=$name"
            if ($compileExit) { throw "Task4 contract compilation failed: $name" }
            Write-Host "T4_CONTRACT_COMMAND=$exe"
            & $exe 2>&1 | Tee-Object -FilePath "$out/$name.output.log" | Write-Host
            $runExit = $LASTEXITCODE
            Write-Host "T4_CONTRACT_EXIT=$runExit case=$name"
            if ($runExit) { throw "Task4 contract failed: $name" }
            $commands += [ordered]@{ compileCommand='cl.exe '+($arguments -join ' ');
                compileExit=$compileExit; command=$exe; exit=$runExit }
        }
        $wrapperReceipt = $null
        if ($AdmissionWrapperRoot) {
            $wrapperRoot = [IO.Path]::GetFullPath($AdmissionWrapperRoot)
            if (!$wrapperRoot.StartsWith([IO.Path]::GetFullPath($EvidenceRoot), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Admission wrapper receipt must be task-owned'
            }
            $wrapperReceipt = Join-Path $wrapperRoot 'result.json'
            $verified = Get-Content -LiteralPath $wrapperReceipt -Raw | ConvertFrom-Json
            foreach ($tag in @('green','seed-select','seed-guide','seed-promise','seed-close')) {
                $command = @($verified.commands | Where-Object { $_.tag -eq $tag })
                if ($command.Count -ne 1 -or $command[0].compileExit -ne 0 -or
                    ($tag -eq 'green' -and $command[0].runExit -ne 0) -or
                    ($tag -ne 'green' -and $command[0].runExit -eq 0)) { throw "Invalid current wrapper proof: $tag" }
            }
            foreach ($source in $verified.sources) {
                if ((Get-FileHash -LiteralPath $source.Path).Hash -ne $source.Hash) {
                    throw "Stale admission wrapper source: $($source.Path)"
                }
            }
            Write-Host "T4_CURRENT_WRAPPER_RECEIPT_VALIDATED=$wrapperReceipt"
        } else {
            Write-Host "T4_CONTRACT_WRAPPER_COMMAND=$PSScriptRoot/run_nr_streamline_hooks.ps1 -EvidenceRoot $out"
            & "$PSScriptRoot/run_nr_streamline_hooks.ps1" -EvidenceRoot $out
            if ($LASTEXITCODE) { throw "Task4 wrapper failed with exit $LASTEXITCODE" }
        }
        [ordered]@{ scope='Task4 admission, no accepted baseline/UI/config replay'; commands=$commands;
            gpu='owned WARP'; nvidia='not_run'; root=$out; reusedCurrentWrapperReceipt=$wrapperReceipt } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
        Write-Host "T4_CONTRACTS_PASS root=$out"
    } finally { Stop-Transcript | Out-Null }
    return
}
if ($Tier -eq 'Runtime') {
    throw 'HOST_MODE_UNSUPPORTED: Runtime is not implemented in early13.UiReady'
}
if ($Tier -eq 'Ui' -or ($Tier -eq 'Contracts' -and $CandidateRoot)) {
    # Build only after the parent has joined both source writers. This branch
    # consumes that existing host; it cannot compile a concurrently changing menu.
    if (!$CandidateRoot) { throw 'Ui requires -CandidateRoot containing the joined NRAddonHost.exe' }
    $hostExe = Join-Path (Resolve-Path -LiteralPath $CandidateRoot).Path 'NRAddonHost.exe'
    if (!(Test-Path -LiteralPath $hostExe -PathType Leaf)) { throw "UI host missing: $hostExe" }
    $ownedRoot = [IO.Path]::GetFullPath($EvidenceRoot)
    New-Item -ItemType Directory -Path $ownedRoot -Force | Out-Null
    $uiOut = Join-Path $ownedRoot ('task-25-ui-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $uiOut | Out-Null
    $uiLog = Join-Path $uiOut 'raw.log'
    Start-Transcript -LiteralPath $uiLog | Out-Null
    try {
        Write-Host "HOST_UI_ARTIFACT_ROOT=$uiOut"
        Write-Host ("HOST_UI_SHA256=" + (Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash)
        if ($Tier -eq 'Contracts') {
            Write-Host "HOST_UI_COMMAND=$hostExe --ui-contracts --fixture-root $uiOut"
            & $hostExe --ui-contracts --fixture-root $uiOut
            $contractExit = $LASTEXITCODE
            Write-Host "HOST_UI_CONTRACT_EXIT=$contractExit"
            if ($contractExit) { throw "Native UI contracts failed with exit $contractExit" }
            return
        }
        Write-Host "HOST_UI_COMMAND=$hostExe --ui-only --width $Width --height $Height --fixture $Fixture --fixture-root $uiOut"
        # The native monitor owns this command. Readiness comes from the host's
        # first completed window Present; closure comes from exact process exit.
        & $hostExe --ui-only --width $Width --height $Height --fixture $Fixture --fixture-root $uiOut
        $uiExit = $LASTEXITCODE
        Write-Host "HOST_UI_EXIT=$uiExit"
        if ($uiExit) { throw "Native UI host failed with exit $uiExit" }
        Write-Host 'HOST_UI_SURFACE_CLOSED=1'
    } finally {
        Stop-Transcript | Out-Null
    }
    return
}
$out = Join-Path $EvidenceRoot ("task-24-" + $Tier.ToLower() + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
Write-Host "TASK24_ARTIFACT_ROOT=$out"
$log = Join-Path $out 'raw.log'
Start-Transcript -LiteralPath $log | Out-Null
Push-Location $repo
try {
    # Generated fixture input is the exact production option, without unrelated Config dependencies.
    $config = Get-Content -LiteralPath "$repo/OptiScaler/Config.h" -Raw
    $first = $config.IndexOf('enum HasDefaultValue')
    $last = $config.IndexOf('constexpr inline int UnboundKey', $first)
    if ($first -lt 0 -or $last -lt 0) { throw 'Production persistence option extraction failed' }
    $option = Join-Path $out 'ConfigOption.h'
    Set-Content -LiteralPath $option -Value $config.Substring($first, $last-$first) -Encoding UTF8
    $source = "$PSScriptRoot/nr_resize_shader_smoke.cpp"
    $libraries = @('d3d11.lib', 'd3d12.lib', 'dxgi.lib')
    $exe = Join-Path $out 'nr_resize_shader_smoke.exe'
    $optionDefine = '/DNR_CONFIG_OPTION_HEADER=\"' + $option.Replace('\','/') + '\"'
    & cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX $optionDefine "/Fo$out/green.obj" "/Fe$exe" $source @libraries `
        2>&1 | Tee-Object -FilePath "$out/compile.log" | Write-Host
    $compileExit = $LASTEXITCODE
    Write-Host "TASK24_COMPILE_EXIT=$compileExit"
    if ($compileExit) { throw 'Task24 adjacent fixture did not compile' }
    if ($Tier -eq 'Contracts') {
        & $exe --contracts 2>&1 | Tee-Object -FilePath "$out/green-output.log" | Write-Host
        $runExit = $LASTEXITCODE
    } else {
        $fxc = 'C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/fxc.exe'
        # Windows PowerShell wraps native stderr warnings as ErrorRecord. Keep the raw
        # warnings and judge the compiler by its exit code, not the stream wrapper.
        $ErrorActionPreference = 'Continue'
        & $fxc /nologo /T cs_5_0 /E CSMain /O3 /Fo "$out/DlssNr_Shader.cso" `
            "$repo/OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl" `
            2>&1 | Tee-Object -FilePath "$out/fxc.log" | Write-Host
        $shaderExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Write-Host "TASK24_FXC_EXIT=$shaderExit"
        if ($shaderExit) { throw 'Current production HLSL did not compile' }
        & $exe "$out/DlssNr_Shader.cso" 2>&1 | Tee-Object -FilePath "$out/green-output.log" | Write-Host
        $runExit = $LASTEXITCODE
    }
    Write-Host "TASK24_GREEN_EXIT=$runExit"
    if ($runExit) { throw 'Task24 positive fixture failed' }
    if ($Tier -eq 'Shaders') {
        # Owned derived header only. Restore exactly the old unsupported-before composition gate
        # in the shared production decision; the actual output assertion must turn red.
        $header = Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Common.h" -Raw
        $anchor = 'return (!reconstruction.privateEnlargement || enlarge()) && compose();'
        if (($header.Split(@($anchor), [StringSplitOptions]::None).Count-1) -ne 1) {
            throw 'Task24 production negative-seed anchor drifted'
        }
        $seedHeader = Join-Path $out 'DlssNr_Common.seed.h'
        Set-Content -LiteralPath $seedHeader -Encoding UTF8 -Value $header.Replace($anchor,
            'return (!(reconstruction.privateEnlargement || reconstruction.compatibilityFallback) || enlarge()) && compose();')
        $seedExe = Join-Path $out 'nr_resize_shader_seed.exe'
        $seedDefine = '/DNR_RECONSTRUCTION_HEADER=\"' + $seedHeader.Replace('\','/') + '\"'
        & cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX $seedDefine $optionDefine `
            "/Fo$out/seed.obj" "/Fe$seedExe" $source @libraries `
            2>&1 | Tee-Object -FilePath "$out/seed-compile.log" | Write-Host
        $seedCompileExit = $LASTEXITCODE
        Write-Host "TASK24_SEED_COMPILE_EXIT=$seedCompileExit"
        if ($seedCompileExit) { throw 'Task24 negative seed did not compile' }
        $ErrorActionPreference = 'Continue'
        & $seedExe "$out/DlssNr_Shader.cso" 2>&1 | Tee-Object -FilePath "$out/seed-output.log" | Write-Host
        $seedExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Write-Host "TASK24_SEED_EXIT=$seedExit"
        if (!$seedExit -or (Get-Content -LiteralPath "$out/seed-output.log" -Raw) -notmatch 'TASK24_OUTPUT:') {
            throw 'Old unsupported gate did not break the actual composition/output assertion'
        }
    }
    $paths = @('OptiScaler/shaders/dlssnr/DlssNr_Common.h',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Encode.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h',
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp',
        'OptiScaler/dlssnr/DlssNr_Status.h', 'OptiScaler/Config.h', 'OptiScaler/Config.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h',
        'OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl',
        'OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli',
        'OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h',
        'tests/nr_resize_shader_smoke.cpp', 'tests/run_nr_addon_options.ps1',
        'tests/run_nr_prerelease.ps1')
    $hashes = @($paths | ForEach-Object { Get-FileHash -LiteralPath (Join-Path $repo $_) -Algorithm SHA256 })
    $hashes += @(Get-ChildItem -LiteralPath $out -File | Where-Object { $_.Extension -in '.exe','.obj','.h','.cso' } |
        Get-FileHash -Algorithm SHA256)
    [ordered]@{ tier=$Tier; sourceHead=(& git rev-parse HEAD); compileExit=$compileExit;
        greenExit=$runExit; shaderCompileExit=$shaderExit; seedCompileExit=$seedCompileExit;
        seedExit=$seedExit; hashes=$hashes; artifactRoot=$out; rawLog=$log;
        gpu='WARP only'; scope='Task24; not NVIDIA runtime acceptance' } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Write-Host "TASK24_TIER_PASS=$Tier"
} finally {
    Pop-Location
    Stop-Transcript | Out-Null
}
