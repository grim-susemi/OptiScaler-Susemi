param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
$root=[IO.Path]::GetFullPath($EvidenceRoot)
$expected=Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task13-host'
if(!$root.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Cancellation evidence must remain task-owned'}
$owner=Get-CimInstance Win32_Process -Filter 'ProcessId = 37364'
if(!$owner -or $owner.Name -ine 'powershell.exe' -or
    $owner.CommandLine -notmatch ' -File tests/nr_addon_host/BuildHost\.ps1 ' -or
    $owner.CommandLine -notlike '*-FinalizeExistingBuild*build-7d2b0bccf8bc4f419243d83d0ed13389*' -or
    ([DateTimeOffset]$owner.CreationDate).ToUnixTimeMilliseconds() -ne 1791109187772){throw 'Exact owned finalizer identity changed'}
$process=Get-Process -Id 37364
$before=[ordered]@{pid=$owner.ProcessId;parentPid=$owner.ParentProcessId;creationUtc=$owner.CreationDate.ToUniversalTime().ToString('o');
    commandLine=[string]::Copy([string]$owner.CommandLine);readBytes=$owner.ReadTransferCount;readOperations=$owner.ReadOperationCount;workingSet=$owner.WorkingSetSize}
Stop-Process -Id $process.Id
$process.WaitForExit()
if(!$process.HasExited){throw 'Owned finalizer cancellation did not reach native terminal'}
New-Item -ItemType Directory -Path $root | Out-Null
[ordered]@{schema=1;task=13;kind='ownedFinalizerCancellation';producerPassed=$false;nativeCompilerAndLinkExit=0;
    reason='Observed CPU-only metadata JSON expansion after I/O stagnation and growing >14GB working set';
    ownerBefore=$before;terminal=$process.HasExited;nativeExit=$process.ExitCode;cancelledUtc=[DateTimeOffset]::UtcNow.ToString('o');
    gpuCommands=0;compilerInvocations=0}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath "$root/result.json" -Encoding UTF8
Write-Host "HOST_OWNED_FINALIZER_CANCELLED pid=37364 terminal=$($process.HasExited) exit=$($process.ExitCode) root=$root"
