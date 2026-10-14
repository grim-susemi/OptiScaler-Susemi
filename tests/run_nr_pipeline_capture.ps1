param([Parameter(Mandatory=$true)][string]$EvidenceRoot, [switch]$CompileOnly, [switch]$FixtureOnly, [switch]$NegativeOnly, [switch]$BatchOnly, [switch]$ProductOnly, [switch]$EntryOnly, [switch]$FixtureCompileOnly, [switch]$GpuOnly, [string]$ReuseCaptureRoot, [string]$AdmissionPath, [string]$ReuseCpuManifest, [string]$ProductUnit, [switch]$OriginNegativeCompileOnly, [switch]$PrepareOnly, [switch]$RetireProductChecks)
$ErrorActionPreference = 'Stop'
if ($RetireProductChecks -and ($CompileOnly -or $FixtureOnly -or $NegativeOnly -or $BatchOnly -or $ProductOnly -or
    $EntryOnly -or $FixtureCompileOnly -or $GpuOnly -or $OriginNegativeCompileOnly -or $PrepareOnly -or
    $PSBoundParameters.ContainsKey('ReuseCaptureRoot') -or $PSBoundParameters.ContainsKey('ReuseCpuManifest') -or
    $PSBoundParameters.ContainsKey('ProductUnit'))) { throw 'RetireProductChecks requires a complete fresh run' }
$ownedRoot = $null
if ($RetireProductChecks) {
    # Local fresh product-output ownership, not a general cleanup or file-activity service.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class T16ProductOutput {
    [StructLayout(LayoutKind.Sequential)]
    public struct Identity {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Disposition { public byte Delete; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateDirectoryW(string path, IntPtr security);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFileAttributesW(string path);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Identity info);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref Disposition info, uint size);
    static Identity Info(SafeFileHandle h) {
        Identity i;
        if (!GetFileInformationByHandle(h, out i)) throw new Win32Exception();
        return i;
    }
    static SafeFileHandle DirectoryHandle(string path) {
        // Read/write sharing permits cl.exe to create children; no delete sharing pins the namespace.
        var h = CreateFileW(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) { h.Dispose(); throw new Win32Exception(); }
        try {
            var i = Info(h);
            if ((i.Attributes & 0x410) != 0x10) throw new IOException("Non-normal product ancestor: "+path);
            return h;
        } catch { h.Dispose(); throw; }
    }
    public sealed class DirectoryOwner : IDisposable {
        readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
        public string Path { get; private set; }
        public Identity NativeIdentity { get; private set; }
        public Identity[] Ancestors { get; private set; }
        internal DirectoryOwner(string path, bool ancestors) {
            Path = System.IO.Path.GetFullPath(path);
            try {
                var identities = new List<Identity>();
                if (ancestors) {
                    var parents = new Stack<string>();
                    for (var p = Directory.GetParent(Path); p != null; p = p.Parent) parents.Push(p.FullName);
                    foreach (var p in parents) {
                        var h = DirectoryHandle(p); handles.Add(h); identities.Add(Info(h));
                    }
                }
                if (!CreateDirectoryW(Path, IntPtr.Zero)) throw new Win32Exception();
                var own = DirectoryHandle(Path); handles.Add(own);
                NativeIdentity = Info(own); Ancestors = identities.ToArray();
            } catch { Dispose(); throw; }
        }
        public DirectoryOwner NewProductDirectory(string name) {
            if (System.IO.Path.GetFileName(name) != name || !name.StartsWith("product-", StringComparison.Ordinal))
                throw new IOException("Exact product child required");
            return new DirectoryOwner(System.IO.Path.Combine(Path, name), false);
        }
        public void Dispose() {
            for (int i = handles.Count-1; i >= 0; --i) handles[i].Dispose();
            handles.Clear();
        }
    }
    public static DirectoryOwner NewRoot(string path) {
        if (!System.IO.Path.IsPathRooted(path)) throw new IOException("Absolute fresh capture root required");
        return new DirectoryOwner(path, true);
    }
    public static void RequireAbsent(string path) {
        if (GetFileAttributesW(path) != UInt32.MaxValue || Marshal.GetLastWin32Error() != 2)
            throw new IOException("Fresh product object must be absent: "+path);
    }
    static bool Same(Identity a, Identity b) {
        return a.Attributes == b.Attributes && a.Volume == b.Volume && a.IndexHigh == b.IndexHigh &&
            a.IndexLow == b.IndexLow && a.Links == 1 && b.Links == 1 &&
            a.SizeHigh == b.SizeHigh && a.SizeLow == b.SizeLow &&
            a.CreationHigh == b.CreationHigh && a.CreationLow == b.CreationLow &&
            a.WriteHigh == b.WriteHigh && a.WriteLow == b.WriteLow;
    }
    public sealed class ObjectOwner : IDisposable {
        readonly SafeFileHandle handle;
        FileStream stream;
        public Identity NativeIdentity { get; private set; }
        public long Bytes { get; private set; }
        public string Sha256 { get; private set; }
        public ObjectOwner(string path) {
            // One exclusive postcompile handle spans length, hash, identity recheck and disposition.
            handle = CreateFileW(path, 0x80010000, 0, IntPtr.Zero, 3, 0x08200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(); }
            try {
                NativeIdentity = Info(handle);
                if ((NativeIdentity.Attributes & 0x410) != 0 || NativeIdentity.Links != 1)
                    throw new IOException("Non-normal or multiply linked product object");
                Bytes = ((long)NativeIdentity.SizeHigh << 32) | NativeIdentity.SizeLow;
                stream = new FileStream(handle, FileAccess.Read, 65536, false);
                if (Bytes <= 0 || stream.Length != Bytes) throw new IOException("Product object length mismatch");
                using (var hash = SHA256.Create()) {
                    Sha256 = BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "");
                }
                if (!Same(NativeIdentity, Info(handle))) throw new IOException("Product object changed during hash");
            } catch { Dispose(); throw; }
        }
        public void DeleteExact() {
            if (!Same(NativeIdentity, Info(handle))) throw new IOException("Product disposition identity mismatch");
            var disposition = new Disposition { Delete = 1 };
            if (!SetFileInformationByHandle(handle, 4, ref disposition, 1)) throw new Win32Exception();
        }
        public void Dispose() {
            if (stream != null) { stream.Dispose(); stream = null; }
            handle.Dispose();
        }
    }
    public static void DurableReceipt(string path, string json) {
        var bytes = new UTF8Encoding(false).GetBytes(json+"\n");
        using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read)) {
            file.Write(bytes, 0, bytes.Length);
            file.Flush(true);
        }
    }
}
'@
}
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $EvidenceRoot ('task-21-capture-' + [guid]::NewGuid().ToString('N').Substring(0,8))
if ($RetireProductChecks) { $ownedRoot = [T16ProductOutput]::NewRoot($out); $out = $ownedRoot.Path }
else { New-Item -ItemType Directory -Path $out | Out-Null }
try { Start-Transcript -LiteralPath "$out/raw.log" | Out-Null }
catch { if ($null -ne $ownedRoot) { $ownedRoot.Dispose() }; throw }
$commands = @()
$bindings = @{}
$productOutputs = @()
$passed = $false
$captureScenarios = @('device-origin','device-origin-copy','device-origin-removed','pixels','off-on','replay',
    'promised-reset','multi-list','discard','cancel','ring','caps','readback-cap','session-cap',
    'signal-failure','replay-overflow','device-removal')
function CaptureCases([string]$fixture) {
    foreach ($scenario in $captureScenarios) {
        [ordered]@{scenario=$scenario;binary="$fixture/smoke.exe";
            arguments=@($scenario,"$out/images-$scenario");log="$out/$scenario.log"}
    }
}
function NegativeCase($control,[string]$binary) {
    [ordered]@{id=$control.id;scenario=$control.scenario;assertion=$control.assertion;binary=$binary;
        arguments=@($control.scenario,"$out/negative-$($control.id)");log="$out/negative-$($control.id).log"}
}
function RunNegative($case) {
    $code = Native $case.binary $case.arguments $case.log 'behavior-negative-expected-failure'
    if ($code -eq 0 -or !(Get-Content -LiteralPath $case.log -Raw).Contains('FAIL '+$case.assertion)) {
        throw "Negative control did not fail named assertion $($case.assertion)"
    }
}
function CurrentControls([string]$sourceRoot) {
    $lifetimePath = "$sourceRoot/dlssnr/DlssNr_GpuLifetime.h"
    $pipelinePath = "$sourceRoot/dlssnr/DlssNr_PipelineCapture.h"
    $readbackPath = "$sourceRoot/dlssnr/DlssNr_Readback.h"
    $cppPath = "$sourceRoot/dlssnr/DlssNr_GpuLifetime.cpp"
    $sourcePaths = @($lifetimePath,$pipelinePath,$readbackPath,$cppPath)
    foreach ($path in $sourcePaths) { Bind $path 'current-negative-baseline' }
    $controls = @(
        @{id='recording-open';from='        if (!closed) return Result::Pending;';to='';assertion='T21_RECORDING_OPEN'},
        @{id='max-ready';from='value != UINT64_MAX && value >= 1';to='value >= 1';assertion='T21_UINT64_MAX_NOT_READY'},
        @{id='failed-signal';from='!point->failed && value != UINT64_MAX';to='value != UINT64_MAX';assertion='T21_FAILED_SIGNAL_RETAINED'},
        @{id='replay-overflow';from='bool complete = !failed, removed = false;';to='bool complete = true, removed = false;';assertion='T21_REPLAY_OVERFLOW_RETAINED'},
        @{id='promised-reset';from='for (unsigned i = 0; i < count; ++i) discarded |= !points[i]->resolved;';to='discarded = false;';assertion='T21_PROMISED_RESET_RETAINED'}
    )
    foreach ($control in $controls) { $control.file='DlssNr_GpuLifetime.h'; $control.scenario='cpu-readiness-no-idle'; $control.gpu=$false }
    $controls += @(
        @{id='queue-origin';file='DlssNr_GpuLifetime.cpp';from='point->failed = !originEstablished ||';to='point->failed = false ||';scenario='device-origin';assertion='T21_QUEUE_DEVICE_ORIGIN_REFUSAL';gpu=$true},
        @{id='foreign-removal';file='DlssNr_GpuLifetime.cpp';from='if (!originEstablished) capture->failed = true;';to='';scenario='device-origin-removed';assertion='T21_FOREIGN_QUEUE_NEVER_READY';gpu=$true},
        @{id='copy-origin';file='DlssNr_PipelineCapture.h';from='commandIdentity.Get() != providedIdentity.Get() || sourceIdentity.Get() != providedIdentity.Get()';to='false';scenario='device-origin-copy';assertion='T21_COPY_DEVICE_ORIGIN_REFUSAL';gpu=$true}
    )
    $controlIndex = 0
    foreach ($control in $controls) {
        $text = [IO.File]::ReadAllText("$sourceRoot/dlssnr/$($control.file)")
        $count = [regex]::Matches($text,[regex]::Escape($control.from)).Count
        if ($count -ne 1) { throw "Negative mutation must match exactly once: $($control.id) count=$count" }
        $clone = "$out/n$controlIndex"
        ++$controlIndex
        New-Item -ItemType Directory -Path "$clone/dlssnr" | Out-Null
        foreach ($path in $sourcePaths) {
            [IO.File]::WriteAllBytes("$clone/dlssnr/$([IO.Path]::GetFileName($path))",[IO.File]::ReadAllBytes($path))
        }
        [IO.File]::WriteAllText("$clone/dlssnr/$($control.file)",$text.Replace($control.from,$control.to),[Text.UTF8Encoding]::new($false))
        foreach ($path in Get-ChildItem -LiteralPath "$clone/dlssnr" -File) { Bind $path.FullName 'current-source-negative-clone' }
        $control.clone = $clone
        $control.matches = $count
        $control.mutatedHash = (Get-FileHash -LiteralPath "$clone/dlssnr/$($control.file)").Hash
    }
    foreach ($path in $sourcePaths) {
        $identity = $bindings[(Resolve-Path -LiteralPath $path).Path]
        if ((Get-FileHash -LiteralPath $path).Hash -ne $identity.sha256 -or
            (Get-Item -LiteralPath $path).Length -ne $identity.bytes) { throw 'Current negative source baseline drifted' }
    }
    $manifest = "$out/current-negative-manifest.json"
    [ordered]@{schema=1;pipelineHash=(Get-FileHash -LiteralPath $pipelinePath).Hash;
        lifetimeHash=(Get-FileHash -LiteralPath $lifetimePath).Hash;cases=$controls} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
    Bind $manifest 'current-source-negative-manifest'
    return $controls
}
function Bind([string]$path,[string]$kind) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (!$bindings.ContainsKey($resolved)) {
        $bindings[$resolved] = [ordered]@{path=$resolved;kind=$kind;bytes=(Get-Item -LiteralPath $resolved).Length;
            sha256=(Get-FileHash -LiteralPath $resolved).Hash}
    }
}
function Native([string]$exe,[string[]]$arguments,[string]$log,[string]$kind) {
    $line = '"' + $exe + '" ' + (($arguments | ForEach-Object {'"'+$_+'"'}) -join ' ')
    Write-Host "T21_COMMAND=$line"
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $exe @arguments 2>&1 | ForEach-Object { $_ | Out-File -LiteralPath $log -Append -Encoding UTF8; Write-Host $_ }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    $script:commands += [ordered]@{command=$line;exit=$code;log=$log;kind=$kind}
    Write-Host "T21_EXIT=$code"
    return $code
}
function Dependencies([string]$path) {
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Bind $data.Data.Source 'compiler-source'
    foreach ($include in $data.Data.Includes) { Bind $include 'compiler-include' }
    Bind $path 'compiler-dependencies'
}
function Extract([string]$text, [string]$signature) {
    $start = $text.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing production body $signature" }
    $open = $text.IndexOf('{', $start)
    $depth = 0
    for ($index = $open; $index -lt $text.Length; ++$index) {
        if ($text[$index] -eq '{') { ++$depth }
        elseif ($text[$index] -eq '}') { --$depth }
        if (!$depth) { return $text.Substring($start, $index-$start+1) }
    }
    throw "Unterminated production body $signature"
}
try {
    if ($PrepareOnly) {
        if ($GpuOnly -or $CompileOnly -or $FixtureOnly -or $NegativeOnly -or $BatchOnly -or $ProductOnly -or
            $EntryOnly -or $FixtureCompileOnly -or $OriginNegativeCompileOnly) { throw 'PrepareOnly cannot select an execution mode' }
        Bind "$PSScriptRoot/run_nr_pipeline_capture.ps1" 'preparation-only-runner'
        $controls = @(CurrentControls "$repo/OptiScaler")
        [ordered]@{schema=1;preparationOnly=$true;runtimeExecuted=$false;gpuCommands=0;cases=@(CaptureCases "$out/fixture");
            negativeControls=$controls;negativeCommands=@($controls | ForEach-Object { NegativeCase $_ "$out/fixture/negative-$($_.id).exe" })} |
            ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$out/preparation.json" -Encoding UTF8
        Bind "$out/preparation.json" 'current-command-construction'
        Write-Host "T21_PREPARATION_ONLY root=$out; runtime not executed; GPU0"
        return
    }
    if ($GpuOnly) {
        Bind "$PSScriptRoot/run_nr_pipeline_capture.ps1" 'gpu-successor-runner'
        Bind "$PSScriptRoot/run_nr_mfg_diagnostics.ps1" 'gpu-successor-dispatch'
        $preimagePath = Join-Path $EvidenceRoot 'task21-gpu-successor-runner-preimages.json'
        $preimages = Get-Content -LiteralPath $preimagePath -Raw | ConvertFrom-Json
        Bind $preimagePath 'historical-compile-runner-lossless-preimages'
        $currentPreimagePath = Join-Path $EvidenceRoot 'task21-current-fixture-runner-preimage.json'
        $currentPreimages = Get-Content -LiteralPath $currentPreimagePath -Raw | ConvertFrom-Json
        Bind $currentPreimagePath 'current-fixture-compile-runner-lossless-preimage'
        $dispatchPreimagePath = Join-Path $EvidenceRoot 'task21-current-dispatch-preimage.json'
        $dispatchPreimages = Get-Content -LiteralPath $dispatchPreimagePath -Raw | ConvertFrom-Json
        Bind $dispatchPreimagePath 'current-fixture-dispatch-lossless-preimage'
        $priorPath = Join-Path $ReuseCaptureRoot 'result.json'
        $prior = Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json
        Bind $priorPath 'current-fixture-compile-receipt'
        if (!$prior.compileOnly -or $prior.commands.Count -ne 1 -or $prior.commands[0].exit -ne 0) {
            throw 'Current fixture compile receipt incomplete'
        }
        foreach ($binding in $prior.inputs) {
            if ($binding.kind -in @('runner','capture-dispatch')) {
                $relative = 'tests/'+[IO.Path]::GetFileName($binding.path)
                $image = @(@($preimages.files)+@($currentPreimages.files)+@($dispatchPreimages.files) | Where-Object { $_.path -eq $relative -and $_.sha256 -eq $binding.sha256 })
                if ($image.Count -ne 1 -or $image[0].sha256 -ne $binding.sha256 -or $image[0].bytes -ne $binding.bytes) {
                    throw 'Historical compile runner identity mismatch'
                }
            }
            elseif ((Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256 -or
                    (Get-Item -LiteralPath $binding.path).Length -ne $binding.bytes) {
                throw "Compiled fixture input drift: $($binding.path)"
            }
            else { Bind $binding.path ('reused-'+$binding.kind) }
        }
        $reuse = Get-Content -LiteralPath $ReuseCpuManifest -Raw | ConvertFrom-Json
        Bind $ReuseCpuManifest 'scoped-cpu-proof-reuse'
        foreach ($binding in $reuse.inputs) {
            if ((Get-FileHash -LiteralPath $binding.path).Hash -ne $binding.sha256 -or
                (Get-Item -LiteralPath $binding.path).Length -ne $binding.bytes) { throw 'CPU reuse binding drift' }
            Bind $binding.path 'reused-cpu-evidence'
        }
        $admission = Get-Content -LiteralPath $AdmissionPath -Raw | ConvertFrom-Json
        Bind $AdmissionPath 'single-fresh-complete-gpu-admission'
        if ($admission.busyCount -ne 0 -or !$admission.complete -or !$admission.processes.Count) {
            throw 'GPU admission incomplete or held'
        }
        $fixture = Join-Path $ReuseCaptureRoot 'fixture'
        foreach ($case in CaptureCases $fixture) {
            if ((Native $case.binary $case.arguments $case.log 'new-gpu-capture-case') -ne 0) {
                throw "Capture case failed $($case.scenario)"
            }
        }
        foreach ($control in $reuse.originNegatives) {
            RunNegative (NegativeCase $control $control.binary)
        }
        $passed = $true
        Write-Host "T21_GPU_SUCCESSOR_PASS root=$out; independent full Task21 acceptance pending"
        return
    }
    $vs = 'C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools'
    $envCommand = 'call "'+$vs+'/VC/Auxiliary/Build/vcvars64.bat" >nul && set'
    $environment = & $env:ComSpec /d /s /c $envCommand
    if ($LASTEXITCODE) { throw 'Compiler environment failed' }
    foreach ($line in $environment) { if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')
    }}
    $cl = (Get-Command cl.exe).Source
    Bind $cl 'compiler'
    Bind (Get-Command link.exe).Source 'linker'
    Bind "$PSScriptRoot/run_nr_pipeline_capture.ps1" 'runner'
    Bind "$PSScriptRoot/run_nr_mfg_diagnostics.ps1" 'capture-dispatch'
    if ($OriginNegativeCompileOnly) {
        $negativePath = Join-Path $EvidenceRoot 'task21-origin-negative-manifest.json'
        $negative = Get-Content -LiteralPath $negativePath -Raw | ConvertFrom-Json
        Bind $negativePath 'origin-source-negative-manifest'
        foreach ($source in $negative.production) {
            if ((Get-FileHash -LiteralPath $source.path).Hash -ne $source.sha256) { throw 'Origin source baseline drift' }
            Bind $source.path 'origin-production-baseline'
        }
        $fixture = Join-Path $ReuseCaptureRoot 'fixture'
        foreach ($control in $negative.cases) {
            $clone = Join-Path $EvidenceRoot ('task21-origin-negative-'+$control.id)
            $target = "$out/$($control.id)"
            New-Item -ItemType Directory -Path $target | Out-Null
            Bind (Join-Path $clone $control.file) 'single-behavior-mutated-origin-source'
            $units = if ($control.file -eq 'lifetime.cpp') { @("$clone/lifetime.cpp") } else { @("$fixture/DlssNr_GpuLifetime.obj") }
            $arguments = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',"/I$clone","/I$fixture","/I$repo/OptiScaler",
                "/Fo$target/","/Fe$target/control.exe",'/sourceDependencies',"$target/","$PSScriptRoot/nr_pipeline_capture_smoke.cpp") +
                $units + @('/link','d3d12.lib','dxgi.lib','ole32.lib','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$target/link-inputs.rsp")
            if ((Native $cl $arguments "$target/compile.log" 'origin-source-negative-compile') -ne 0) { throw 'Origin negative compile failed' }
            foreach ($dependency in Get-ChildItem -LiteralPath $target -Filter '*.json') { Dependencies $dependency.FullName }
            Bind "$target/control.exe" 'origin-negative-binary'
            Bind "$target/link-inputs.rsp" 'origin-negative-link-inputs'
            $libraries = [regex]::Matches((Get-Content -LiteralPath "$target/compile.log" -Raw),
                '(?im)([A-Z]:[\\/][^\r\n]*?\.lib)(?=[:(\s]|$)')
            if (!$libraries.Count) { throw 'Origin negative resolved libraries missing' }
            foreach ($library in $libraries) { Bind $library.Groups[1].Value 'origin-negative-resolved-library' }
        }
        Write-Host "T21_ORIGIN_NEGATIVE_COMPILE_ONLY root=$out; GPU0"
        return
    }
    if ($EntryOnly) {
        $sourcePath = "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp"
        $runPath = "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp"
        $entry = Extract (Get-Content -LiteralPath $sourcePath -Raw) 'void DlssNr_Dx12::DiagnosePipeline('
        $observation = Extract (Get-Content -LiteralPath $runPath -Raw) '    if (pipelineCapture)'
        Bind $sourcePath 'current-production-capture-entry-source'
        Bind $runPath 'current-production-run-observation-source'
        Bind "$PSScriptRoot/nr_capture_entry.in.cpp" 'typed-input-admission-schema-template'
        $template = Get-Content -LiteralPath "$PSScriptRoot/nr_capture_entry.in.cpp" -Raw
        $template.Replace('@PRODUCTION_ENTRY@', $entry).Replace('@PRODUCTION_RUN_OBSERVATION@', $observation) |
            Set-Content -LiteralPath "$out/capture-entry.cpp" -Encoding UTF8
        Set-Content -LiteralPath "$out/pch.h" -Value '' -Encoding UTF8
        Set-Content -LiteralPath "$out/Util.h" -Value '#include <unknwn.h>
namespace Util { inline bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; } }' -Encoding UTF8
        Bind "$out/capture-entry.cpp" 'exact-extracted-entry-and-run-observation'
        $entryArgs = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',"/I$out","/I$repo/OptiScaler",
            "/I$repo/external/nvngx_dlss_sdk","/Fo$out/","/Fe$out/capture-entry.exe",'/sourceDependencies',"$out/",
            "$out/capture-entry.cpp","$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.cpp",'/link','d3d12.lib','dxgi.lib','ole32.lib')
        if ((Native $cl $entryArgs "$out/entry-compile.log" 'current-entry-schema-compile') -ne 0) { throw 'Entry/schema fixture compile failed' }
        foreach ($dependency in Get-ChildItem -LiteralPath $out -Filter '*.json') { Dependencies $dependency.FullName }
        Bind "$out/capture-entry.exe" 'current-entry-schema-binary'
        if ($CompileOnly) { Write-Host "T21_ENTRY_SCHEMA_COMPILE_ONLY root=$out"; return }
        if ((Native "$out/capture-entry.exe" @("$out/schema") "$out/entry.log" 'cpu-entry-raw-resolved-schema') -ne 0) {
            throw 'Capture entry/raw/schema case failed'
        }
        Write-Host "T21_ENTRY_SCHEMA_CPU_ONLY root=$out"
        return
    }
    if ($BatchOnly) {
        $sourcePath = "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp"
        $source = Get-Content -LiteralPath $sourcePath -Raw
        $promise = Extract $source 'void DlssNr_Dx12::PromiseFinishedCommands('
        $submit = Extract $source 'void DlssNr_Dx12::SubmitFinishedCommands('
        Bind $sourcePath 'exact-production-capture-wrapper-source'
        Bind "$PSScriptRoot/nr_capture_batch.in.cpp" 'typed-batch-service-template'
        $template = Get-Content -LiteralPath "$PSScriptRoot/nr_capture_batch.in.cpp" -Raw
        $template.Replace('@PRODUCTION_BODIES@', $promise + [Environment]::NewLine + $submit) |
            Set-Content -LiteralPath "$out/capture-batch.cpp" -Encoding UTF8
        Bind "$out/capture-batch.cpp" 'exact-extracted-production-wrappers'
        $batchArgs = @('/nologo','/std:c++20','/EHsc','/MD','/W4',"/I$repo/OptiScaler",
            "/Fo$out/capture-batch.obj","/Fe$out/capture-batch.exe",'/sourceDependencies',"$out/batch-dependencies.json",
            "$out/capture-batch.cpp")
        if ((Native $cl $batchArgs "$out/batch-compile.log" 'actual-capture-wrapper-compile') -ne 0) { throw 'Batch fixture compile failed' }
        Dependencies "$out/batch-dependencies.json"
        Bind "$out/capture-batch.exe" 'actual-capture-wrapper-binary'
        if ((Native "$out/capture-batch.exe" @() "$out/batch.log" 'cpu-per-call-multiowner-wrapper') -ne 0) {
            throw 'Capture wrapper batch case failed'
        }
        Write-Host "T21_BATCH_CPU_ONLY root=$out"
        return
    }
    $support = 'C:/omo-research/optiscaler-hybrid-port-v0.7.1'
    [xml]$project = Get-Content -LiteralPath "$repo/OptiScaler/OptiScaler.vcxproj" -Raw
    $group = $project.Project.PropertyGroup | Where-Object { $_.Condition -eq '''$(Configuration)|$(Platform)''==''Release|x64''' }
    $projectIncludes = ([string]$group.IncludePath).Split(';') | Where-Object { $_ -ne '$(IncludePath)' }
    $includeDirs = foreach ($item in $projectIncludes) {
        $expanded = $item.Trim().Replace('$(ProjectDir)',"$repo/OptiScaler/").Replace('$(SolutionDir)',"$repo/")
        foreach ($name in @('vulkan','xess','FidelityFX-SDK','FidelityFX-SDK-v2','simpleini','unordered_dense','spdlog','nvapi','magic_enum')) {
            $expanded = $expanded.Replace("$repo/external\$name","$support/external/$name")
            $expanded = $expanded.Replace("$repo/external/$name","$support/external/$name")
        }
        $expanded
    }
    foreach ($flavor in $(if ($FixtureOnly) { @() } else { @('plain','rtx40-mfg') })) {
        $defines = if ($flavor -eq 'rtx40-mfg') { @('/DOPTISCALER_RTX40_MFG') } else { @() }
        $affectedUnits = @('dlssnr/DlssNr_GpuLifetime.cpp','dlssnr/DlssNr_Proxy.cpp') +
            @(Get-ChildItem -LiteralPath "$repo/OptiScaler/shaders/dlssnr" -Filter 'DlssNr_Dx12*.cpp' |
              ForEach-Object {'shaders/dlssnr/'+$_.Name})
        if ($ProductUnit) {
            if ($ProductUnit -notin $affectedUnits) { throw 'ProductUnit outside affected capture units' }
            $affectedUnits = @($ProductUnit)
        }
        if ($RetireProductChecks -and $affectedUnits.Count -ne 15) { throw 'Full product flavor must contain fifteen units' }
        foreach ($unit in $affectedUnits) {
            $name = [IO.Path]::GetFileNameWithoutExtension($unit)
            $dir = "$out/product-$flavor-$name"
            $ownedDir = $null
            $object = $null
            try {
            if ($RetireProductChecks) {
                $ownedDir = $ownedRoot.NewProductDirectory("product-$flavor-$name")
                [T16ProductOutput]::RequireAbsent("$dir/unit.obj")
                Bind "$repo/OptiScaler/$unit" 'compiler-source'
            } else { New-Item -ItemType Directory -Path $dir | Out-Null }
            $args = @('/nologo','/c','/std:c++latest','/EHsc','/MD','/W3','/permissive-','/Y-',
                '/DNDEBUG','/D_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR','/D_WINDOWS','/D_USRDLL','/D_WINDLL',
                '/D_UNICODE','/DUNICODE',"/Fo$dir/unit.obj","/Fd$dir/unit.pdb",'/sourceDependencies',"$dir/dependencies.json") +
                $defines + @($includeDirs | ForEach-Object {'/I'+$_}) + @("$repo/OptiScaler/$unit")
            if ((Native $cl $args "$dir/compile.log" 'affected-product-unit') -ne 0) { throw "Product compile failed $flavor/$unit" }
            Dependencies "$dir/dependencies.json"
            if (!$RetireProductChecks) { Bind "$dir/unit.obj" 'product-object' }
            else {
                $dependency = Get-Content -LiteralPath "$dir/dependencies.json" -Raw | ConvertFrom-Json
                $source = (Resolve-Path -LiteralPath "$repo/OptiScaler/$unit").Path
                if ((Resolve-Path -LiteralPath $dependency.Data.Source).Path -ine $source) { throw 'Product compiler source mismatch' }
                $consumed = @($source) + @($dependency.Data.Includes | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
                foreach ($path in $consumed) {
                    if ((Get-FileHash -LiteralPath $path).Hash -ne $bindings[$path].sha256 -or
                        (Get-Item -LiteralPath $path).Length -ne $bindings[$path].bytes) { throw 'Product compiler input drift' }
                }
                Bind "$dir/compile.log" 'product-compile-log'
                $object = [T16ProductOutput+ObjectOwner]::new("$dir/unit.obj")
                $keep = $unit -ceq 'shaders/dlssnr/DlssNr_Dx12.cpp'
                $receipt = "$dir/object-observation.json"
                $record = [ordered]@{path="$dir/unit.obj";flavor=$flavor;unit=$unit;bytes=$object.Bytes;sha256=$object.Sha256;
                    nativeIdentity=$object.NativeIdentity;kind='observed-product-compilation';receipt=$receipt;
                    disposition=$(if ($keep) {'retained-representative'} else {'delete-pending'});physicallyAvailable=$true;
                    availableAsLinkInput=$keep}
                $productOutputs += $record
                $observation = [ordered]@{schema=1;kind='fresh-owned-product-check';compiler=$bindings[(Resolve-Path -LiteralPath $cl).Path];
                    command=$commands[-1];arguments=$args;source=$bindings[$source];definitions=$defines;includeDirectories=@($includeDirs);
                    consumedInputs=@($consumed | ForEach-Object { $bindings[$_] });
                    dependencies=$bindings[(Resolve-Path -LiteralPath "$dir/dependencies.json").Path];
                    log=$bindings[(Resolve-Path -LiteralPath "$dir/compile.log").Path];object=$record;
                    captureDirectory=$ownedRoot.Path;captureIdentity=$ownedRoot.NativeIdentity;ancestorIdentities=$ownedRoot.Ancestors;
                    productDirectory=$ownedDir.Path;productIdentity=$ownedDir.NativeIdentity;
                    origin='fresh-owned-directory; absent-before-exact-cl-command; exit0; matching-dependency-source';
                    lastUse='product /c check only; dependency capture complete; never a link input';
                    disposition=$(if ($keep) {'retain-physical-representative'} else {'authorize-same-handle-delete-after-durable-receipt'})}
                [T16ProductOutput]::DurableReceipt($receipt,($observation | ConvertTo-Json -Depth 10))
                Bind $receipt 'product-compilation-observation'
                if ($keep) {
                    $bindings[[IO.Path]::GetFullPath("$dir/unit.obj")] = [ordered]@{path=[IO.Path]::GetFullPath("$dir/unit.obj");
                        kind='product-object';bytes=$object.Bytes;sha256=$object.Sha256;nativeIdentity=$object.NativeIdentity}
                    $object.Dispose(); $object = $null
                } else {
                    $object.DeleteExact()
                    $record.disposition = 'delete-marked'
                    $record.physicallyAvailable = $null
                    $object.Dispose(); $object = $null
                    [T16ProductOutput]::RequireAbsent("$dir/unit.obj")
                    $record.disposition = 'retired'
                    $record.physicallyAvailable = $false
                    $completion = "$dir/object-disposition.json"
                    [T16ProductOutput]::DurableReceipt($completion,([ordered]@{schema=1;disposition='retired';physicallyAvailable=$false;
                        observation=$bindings[(Resolve-Path -LiteralPath $receipt).Path];object=$record;
                        exactHandleDelete=$true;closed=$true;absenceObserved=$true} | ConvertTo-Json -Depth 10))
                    Bind $completion 'product-object-disposition'
                    $record.completion = $completion
                }
            }
            } finally {
                if ($null -ne $object) { $object.Dispose() }
                if ($null -ne $ownedDir) { $ownedDir.Dispose() }
            }
        }
    }
    if ($RetireProductChecks -and ($productOutputs.Count -ne 30 -or
        @($productOutputs | Where-Object { $_.disposition -eq 'retired' }).Count -ne 28 -or
        @($productOutputs | Where-Object { $_.disposition -eq 'retained-representative' }).Count -ne 2)) {
        throw 'Full product retention disposition incomplete'
    }
    if ($ProductOnly) { Write-Host "T21_PRODUCT_COMPILE_ONLY root=$out"; return }
    $fixture = "$out/fixture"
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-Content -LiteralPath "$fixture/pch.h" -Value '' -Encoding UTF8
    Set-Content -LiteralPath "$fixture/Util.h" -Value '#include <unknwn.h>
namespace Util { inline bool CheckForRealObject(const char*, IUnknown*, IUnknown**) { return false; } }' -Encoding UTF8
    $args = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',
        '/DT16_R54_CAPS_PROOF','/DT16_R63_CAPS_HANDOFF','/DT16_R63_GREEN=1',"/I$fixture","/I$repo/OptiScaler",
        "/Fo$fixture/","/Fd$fixture/smoke.pdb","/Fe$fixture/smoke.exe",'/sourceDependencies',"$fixture/",
        "$PSScriptRoot/nr_pipeline_capture_smoke.cpp","$repo/OptiScaler/dlssnr/DlssNr_GpuLifetime.cpp",
        '/link','d3d12.lib','dxgi.lib','ole32.lib','/VERBOSE:LIB',"/LINKREPROFULLPATHRSP:$fixture/link-inputs.rsp")
    if ((Native $cl $args "$fixture/compile.log" 'production-capture-fixture') -ne 0) { throw 'Fixture compilation failed' }
    foreach ($dependency in Get-ChildItem -LiteralPath $fixture -Filter '*.json') { Dependencies $dependency.FullName }
    Bind "$fixture/smoke.exe" 'native-fixture'
    Bind "$fixture/link-inputs.rsp" 'native-link-inputs'
    $paths = [regex]::Matches((Get-Content -LiteralPath "$fixture/compile.log" -Raw),
        '(?im)([A-Z]:[\\/][^\r\n]*?\.lib)(?=[:(\s]|$)')
    foreach ($match in $paths) { Bind $match.Groups[1].Value 'resolved-library' }
    if (!$paths.Count) { throw 'Resolved linker libraries missing' }
    if ($FixtureCompileOnly) { Write-Host "T21_FIXTURE_COMPILE_ONLY root=$out"; return }
    $cpuCase = if ($NegativeOnly) { 'cpu-readiness-no-idle' } else { 'cpu-readiness' }
    if ((Native "$fixture/smoke.exe" @($cpuCase,"$out/cpu-readiness") "$out/cpu-readiness.log" 'cpu-only-failure-transitions') -ne 0) {
        throw 'CPU capture readiness failed'
    }
    if (!$NegativeOnly) {
    $dllArgs = @('/nologo','/LD','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',"/I$fixture","/I$repo/OptiScaler",
        "/Fo$fixture/capture-dll.obj","/Fe$fixture/capture-test.dll","$PSScriptRoot/nr_pipeline_capture_dll.cpp",
        "$fixture/DlssNr_GpuLifetime.obj",
        '/link','d3d12.lib','dxgi.lib','ole32.lib')
    if ((Native $cl $dllArgs "$fixture/dll-compile.log" 'owned-capture-dll') -ne 0) { throw 'Capture DLL compile failed' }
    $hostArgs = @('/nologo','/std:c++20','/EHsc','/MD','/W4',"/Fo$fixture/dll-host.obj","/Fe$fixture/dll-host.exe",
        "$PSScriptRoot/nr_pipeline_capture_dll_host.cpp")
    if ((Native $cl $hostArgs "$fixture/host-compile.log" 'owned-dll-host') -ne 0) { throw 'Capture DLL host compile failed' }
    foreach ($path in @("$PSScriptRoot/nr_pipeline_capture_dll.cpp","$PSScriptRoot/nr_pipeline_capture_dll_host.cpp",
        "$fixture/capture-test.dll","$fixture/dll-host.exe")) { Bind $path 'dll-lifecycle-proof' }
    $dllExit = Native "$fixture/dll-host.exe" @("$fixture/capture-test.dll",'cpu-readiness',"$out/dll-idle") "$out/dll-idle.log" 'real-dll-owned-resource-closure'
    if ($dllExit -ne 0) { throw 'DLL capture closure failed' }
    }
    $gpuControls = @()
    foreach ($control in CurrentControls "$repo/OptiScaler") {
        $clone = $control.clone
        $target = "$fixture/negative-$($control.id)"
        Bind "$clone/dlssnr/DlssNr_GpuLifetime.h" 'one-behavior-mutated-production-body'
        Bind "$clone/dlssnr/DlssNr_PipelineCapture.h" 'negative-include-routing'
        $units = if ($control.file -eq 'DlssNr_GpuLifetime.cpp') { @("$clone/dlssnr/DlssNr_GpuLifetime.cpp") } else { @("$fixture/DlssNr_GpuLifetime.obj") }
        $negativeArgs = @('/nologo','/std:c++20','/EHsc','/MD','/W4','/DNOMINMAX',"/I$clone","/I$fixture",
            "/I$repo/OptiScaler","/Fo$target-dependencies/","/Fe$target.exe","$PSScriptRoot/nr_pipeline_capture_smoke.cpp",
            '/sourceDependencies',"$target-dependencies/") + $units + @('/link','d3d12.lib','dxgi.lib','ole32.lib')
        New-Item -ItemType Directory -Path "$target-dependencies" | Out-Null
        if ((Native $cl $negativeArgs "$target-compile.log" 'behavior-negative-compile') -ne 0) { throw 'Negative compile failed' }
        Bind "$target.exe" 'behavior-negative-binary'
        foreach ($dependency in Get-ChildItem -LiteralPath "$target-dependencies" -Filter '*.json') { Dependencies $dependency.FullName }
        $control.binary = "$target.exe"
        if ($control.gpu) { $gpuControls += $control; continue }
        RunNegative (NegativeCase $control $control.binary)
    }
    if ($CompileOnly) { Write-Host "T21_COMPILE_ONLY root=$out"; return }
    if (!$AdmissionPath) { throw 'Current owned availability receipt required' }
    $availability = Get-Content -LiteralPath $AdmissionPath -Raw | ConvertFrom-Json
    $expectedNames = @('CrimsonDesert.exe','Witcher3.exe','obs.exe','obs32.exe','obs64.exe','NRAddonHost.exe','nr-qa-host.exe')
    if (!$availability.available -or $availability.generalCensus -or $availability.ownerManipulation -or
        @($availability.processes).Count -ne 0 -or
        (@($availability.exactNames) -join '|') -cne ($expectedNames -join '|')) {
        throw 'GPU admission held: current exact-name owned availability evidence is not clear'
    }
    Bind $AdmissionPath 'current-owned-exact-name-availability'
    foreach ($control in $gpuControls) {
        RunNegative (NegativeCase $control $control.binary)
    }
    foreach ($case in CaptureCases $fixture) {
        if ((Native $case.binary $case.arguments $case.log 'positive-capture-case') -ne 0) { throw "Capture case failed $($case.scenario)" }
    }
    $passed = $true
    Write-Host "T21_CAPTURE_PASS root=$out"
}
finally {
    try {
    [ordered]@{schema=1;passed=$passed;out=$out;commands=$commands;inputs=@($bindings.Values);
        compileOnly=[bool]$CompileOnly;gpuOnly=[bool]$GpuOnly;prepareOnly=[bool]$PrepareOnly;reuseCaptureRoot=$ReuseCaptureRoot;
        admission=$AdmissionPath;cpuReuse=$ReuseCpuManifest;independentAcceptance=$false;
        retireProductChecks=[bool]$RetireProductChecks;productOutputs=$productOutputs} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$out/result.json" -Encoding UTF8
    Stop-Transcript | Out-Null
    } finally { if ($null -ne $ownedRoot) { $ownedRoot.Dispose() } }
}
