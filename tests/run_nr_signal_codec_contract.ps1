# Contracts-only local signal pair proof. No GPU, game, product build or prior suite.
param(
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [ValidateSet('Contracts')][string]$Tier = 'Contracts'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$evidence = (Resolve-Path $EvidenceRoot).Path
$out = Join-Path $evidence ('task-10-native-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
$identities = @{}
$commands = New-Object 'System.Collections.Generic.List[object]'
$receipt = [ordered]@{
    schema = 'nr-task10-native-v1'; producer = 'st_01a10279'; tier = $Tier
    status = 'RUNNING'; receiver = $repo; outputRoot = $out
    startedUtc = [DateTime]::UtcNow.ToString('o'); runnerPid = $PID
    expected = @{ normalCompileExit = 0; normalLinkExit = 0; nativeExit = 0; checks = 1012
        negativeCompileExit = 0; negativeLinkExit = 0; negativeExit = 1
        negativeAssertion = 'T10_PQ_100_NIT_ENCODE'; fxcExit = 0; tolerance = 1e-6 }
    environment = @{ VCToolsVersion = $env:VCToolsVersion; WindowsSDKVersion = $env:WindowsSDKVersion
        include = $env:INCLUDE; lib = $env:LIB; platform = $env:VSCMD_ARG_TGT_ARCH }
    commands = $commands
}

function Save-Receipt
{
    $receipt | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
function Bind([string]$path, [string]$kind)
{
    $full = (Resolve-Path -LiteralPath $path).Path
    $key = $full.ToLowerInvariant()
    if ($identities.ContainsKey($key)) { return }
    $item = Get-Item -LiteralPath $full
    $identities[$key] = [ordered]@{ path = $full; kind = $kind; bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
}
function Run-Native([string]$path, [string[]]$arguments, [string]$tag, [int]$expectedExit)
{
    $command = [ordered]@{ tag = $tag; path = $path; arguments = $arguments
        exactCommand = ('"' + $path + '" ' + (($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '))
        expectedExit = $expectedExit; declaredUtc = [DateTime]::UtcNow.ToString('o') }
    $commands.Add($command)
    Save-Receipt # Commands and expectations are durable before native execution.
    Write-Host ("T10_COMMAND " + ($command | ConvertTo-Json -Depth 5 -Compress))
    $savedPreference = $ErrorActionPreference
    try
    {
        # Collect every native stderr line before evaluating the exit. This
        # does not suppress warnings/errors or alter the compiler's /WX.
        $ErrorActionPreference = 'Continue'
        $lines = @(& $path @arguments 2>&1)
        $nativeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    $log = Join-Path $out ($tag + '.log')
    $lines | ForEach-Object { $_.ToString() } | Set-Content -LiteralPath $log -Encoding UTF8
    $lines | ForEach-Object { Write-Host $_ }
    $command.exit = $nativeExit
    $command.completedUtc = [DateTime]::UtcNow.ToString('o')
    $command.log = $log
    Save-Receipt
    Write-Host "T10_EXIT $tag=$nativeExit expected=$expectedExit"
    if ($nativeExit -ne $expectedExit) { throw "Unexpected $tag exit $nativeExit" }
    return @{ exit = $nativeExit; lines = $lines; log = $log }
}
function Bind-Dependencies([string]$path)
{
    $dependencies = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Bind $dependencies.Data.Source 'compiler-source'
    foreach ($include in $dependencies.Data.Includes) { Bind $include 'compiler-include' }
    Bind $path 'compiler-dependency-record'
}
function Build-Contract([string]$tag, [string[]]$extra, [string]$cl, [string]$link, [string]$source)
{
    $obj = Join-Path $out ($tag + '.obj')
    $exe = Join-Path $out ($tag + '.exe')
    $deps = Join-Path $out ($tag + '.dependencies.json')
    $compileArgs = @('/nologo', '/std:c++20', '/EHsc', '/O2', '/W4', '/WX', '/fp:strict', '/MT', '/Z7',
        '/c', '/sourceDependencies', $deps, "/Fo$obj") + $extra + @($source)
    $compiled = Run-Native $cl $compileArgs ($tag + '-compile') 0
    Bind-Dependencies $deps
    Bind $obj 'compiler-output'
    $linked = Run-Native $link @('/NOLOGO', '/DEBUG', '/INCREMENTAL:NO', '/VERBOSE:LIB',
        "/OUT:$exe", "/PDB:$(Join-Path $out ($tag + '.pdb'))", $obj) ($tag + '-link') 0
    $actualLibraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $linked.lines)
    {
        foreach ($match in [regex]::Matches($line.ToString(), '(?i)[A-Z]:\\[^\r\n]*?\.lib'))
        {
            $library = $match.Value
            Bind $library 'actual-linker-library'
            if (-not $actualLibraries.Contains($library)) { $actualLibraries.Add($library) }
        }
    }
    if ($actualLibraries.Count -eq 0) { throw 'No actual linker library paths bound' }
    Bind $exe 'linked-executable'
    Bind (Join-Path $out ($tag + '.pdb')) 'linker-output'
    return @{ compileExit = $compiled.exit; linkExit = $linked.exit; exe = $exe
        dependencies = $deps; actualLibraries = $actualLibraries.ToArray() }
}

try
{
    Save-Receipt
    $cl = (Get-Command cl.exe -ErrorAction Stop).Source
    $link = (Get-Command link.exe -ErrorAction Stop).Source
    $fxc = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\fxc.exe'
    if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64') { throw 'Requires existing VS x64 developer environment' }
    foreach ($tool in @($cl, $link, $fxc)) { Bind $tool 'native-tool' }
    foreach ($file in @('c1xx.dll', 'c2.dll', 'clui.dll', 'mspdb140.dll'))
    {
        $toolInput = Join-Path (Split-Path $cl) $file
        if (Test-Path -LiteralPath $toolInput) { Bind $toolInput 'compiler-tool-input' }
    }
    $source = Join-Path $PSScriptRoot 'nr_signal_codec_contract.cpp'
    $adapter = Join-Path $PSScriptRoot 'nr_signal_codec_adapter.h'
    $helper = Join-Path $repo 'OptiScaler/shaders/dlssnr/precompile/dlssnr_signal.hlsli'
    $seedDir = Join-Path $evidence 'task-10-negative'
    $seed = Join-Path $seedDir 'dlssnr_signal.seed.hlsli'
    $wrapper = Join-Path $evidence 'task-10-helper-compile.hlsl'
    foreach ($input in @($PSCommandPath, $source, $adapter, $helper, $seed, $wrapper)) { Bind $input 'owned-input' }
    $original = [IO.File]::ReadAllText($helper)
    $needle = 'kNrSignalPqNitsPerUnit = 100.0;'
    if ([regex]::Matches($original, [regex]::Escape($needle)).Count -ne 1) { throw 'Seed must match one production convention' }
    if ([IO.File]::ReadAllText($seed) -cne $original.Replace($needle, 'kNrSignalPqNitsPerUnit = 203.0;'))
    { throw 'Negative control is not the exact one-literal source mutation' }
    $receipt.negativeMutation = @{ exactSingleLiteral = $true; from = $needle; to = 'kNrSignalPqNitsPerUnit = 203.0;'
        original = $helper; derived = $seed; productionSourceEdited = $false }
    $receipt.normalBuild = Build-Contract 'nr_signal_codec_contract' @() $cl $link $source
    $normal = Run-Native $receipt.normalBuild.exe @() 'normal-native' 0
    $normalResult = @($normal.lines | ForEach-Object { $_.ToString() } | Where-Object { $_ -match '^T10_RESULT ' })
    if ($normalResult.Count -ne 1) { throw 'Missing unique native result' }
    $parsed = $normalResult[0].Substring('T10_RESULT '.Length) | ConvertFrom-Json
    if ($parsed.status -ne 'PASS' -or $parsed.checks -ne 1012 -or $parsed.expectedChecks -ne 1012 -or
        $parsed.scalarBits -ne 64 -or $parsed.tolerance -ne 1e-6 -or $parsed.ownedResourcesRemaining -ne 0 -or
        $parsed.maxEncodeError -gt 1e-6 -or $parsed.maxDecodeError -gt 1e-6 -or $parsed.maxRoundtripError -gt 1e-6)
    { throw 'Native result violates predeclared CPU contract' }
    $receipt.native = @{ exit = $normal.exit; log = $normal.log; parsed = $parsed }
    $receipt.negativeBuild = Build-Contract 'nr_signal_codec_negative' @("/I$seedDir",
        '/DNR_SIGNAL_HELPER_HEADER=<dlssnr_signal.seed.hlsli>') $cl $link $source
    $negative = Run-Native $receipt.negativeBuild.exe @() 'negative-native' 1
    $failure = @($negative.lines | ForEach-Object { $_.ToString() } | Where-Object { $_ -match '^T10_ASSERT_FAIL ' })
    if ($failure.Count -ne 1) { throw 'Missing unique negative assertion' }
    $failed = $failure[0].Substring('T10_ASSERT_FAIL '.Length) | ConvertFrom-Json
    if ($failed.assertion -cne 'T10_PQ_100_NIT_ENCODE' -or $failed.checksBeforeExit -ne 1 -or
        $failed.ownedResourcesRemaining -ne 0) { throw 'Negative control failed the wrong assertion' }
    $receipt.negative = @{ exit = $negative.exit; log = $negative.log; parsed = $failed }
    $shaderOutput = Join-Path $out 'helper-syntax-only.cso'
    $shader = Run-Native $fxc @('/nologo', '/T', 'cs_5_0', '/E', 'CSMain', '/O3', '/WX',
        '/Fo', $shaderOutput, $wrapper) 'helper-hlsl-compile' 0
    Bind $shaderOutput 'syntax-only-generated-bytecode'
    $receipt.hlsl = @{ exit = $shader.exit; log = $shader.log; output = $shaderOutput
        dispatched = $false; shippedBytecode = $false }
    foreach ($identity in @($identities.Values))
    {
        if ((Get-FileHash -LiteralPath $identity.path -Algorithm SHA256).Hash -cne $identity.sha256)
        { throw "Bound input/output drift: $($identity.path)" }
    }
    $nativeProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($out, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object ProcessId, Name, ExecutablePath, CommandLine)
    if ($nativeProcesses.Count -ne 0) { throw 'Owned native processes remain' }
    $receipt.cleanup = @{ censusUtc = [DateTime]::UtcNow.ToString('o'); nativeProcesses = $nativeProcesses
        ownedNativeProcessesRemaining = 0; windows = 0; gpuDevices = 0; pendingNativeCommands = 0
        inputOutputDrift = 0; runnerClosure = 'Outer monitor completion is required before DoneClaim' }
    $receipt.status = 'PASS'
}
catch
{
    $receipt.status = 'FAILED'
    $receipt.failure = $_.Exception.Message
    Write-Host ("T10_RUNNER_FAIL " + $_.Exception.Message)
}
finally
{
    foreach ($file in Get-ChildItem -LiteralPath $out -File)
    {
        if ($file.Name -ne 'result.json' -and $file.Name -ne 'identities.json') { Bind $file.FullName 'generated-receipt' }
    }
    $ledger = Join-Path $out 'identities.json'
    @($identities.Values | Sort-Object path) | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ledger -Encoding UTF8
    $receipt.binding = @{ ledger = $ledger; count = $identities.Count
        sha256 = (Get-FileHash -LiteralPath $ledger -Algorithm SHA256).Hash
        scope = 'Actual current consumed source/include/compiler/SDK/library and generated outputs, no dependency tree copy' }
    $receipt.completedUtc = [DateTime]::UtcNow.ToString('o')
    Save-Receipt
    Write-Host ("T10_RECEIPT " + (Join-Path $out 'result.json'))
    Write-Host ("T10_RUNNER_STATUS " + $receipt.status)
}
if ($receipt.status -ne 'PASS') { exit 1 }
exit 0
