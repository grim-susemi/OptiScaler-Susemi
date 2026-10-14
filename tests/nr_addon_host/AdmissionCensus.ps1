param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/GpuAdmission.ps1"
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
$root=[IO.Path]::GetFullPath($EvidenceRoot)
$expected=Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task13-host'
if(!$root.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Admission census must remain task-owned'}
if(Test-Path -LiteralPath $root){throw 'HOST_CENSUS_ALREADY_EXISTS: no repeated admission census'}
New-Item -ItemType Directory -Path $root | Out-Null
Start-Transcript -LiteralPath "$root/raw.log"|Out-Null
try {
    $issued=[DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop|Select-Object ProcessId,Name,ExecutablePath|Sort-Object ProcessId)
    if(!$processes.Count -or @($processes|Group-Object ProcessId|Where-Object Count -ne 1).Count){throw 'HOST_CENSUS_INCOMPLETE'}
    $busy=@($processes|Where-Object{$_.Name -match $Task13BusyRegex -or $_.Name -ieq 'Witcher3.exe' -or
        ($_.ExecutablePath -and $_.ExecutablePath.Replace('\','/').StartsWith($Task13GameLibrary,[StringComparison]::OrdinalIgnoreCase))})
    $census=[ordered]@{schema=1;task=13;attempt='e1-20261002-01a0fbd1';kind='completeGpuBusyOwnerCensus';complete=$true;
        issuedUtc=$issued;processCount=$processes.Count;processes=$processes;busyCount=$busy.Count;busy=$busy;
        busyRegex=$Task13BusyRegex;additionalBusyName='Witcher3.exe';gameLibraryPrefix=$Task13GameLibrary;
        observedSource='Win32_Process complete single native query';gpuCommands=0;authorizationIssued=$false}
    $census|ConvertTo-Json -Depth 6|Set-Content -LiteralPath "$root/census.json" -Encoding UTF8
    Write-Host "HOST_COMPLETE_CENSUS processes=$($processes.Count) busy=$($busy.Count) path=$root/census.json sha256=$((Get-FileHash "$root/census.json").Hash)"
    if($busy.Count){throw 'HOST_GPU_ADMISSION_BUSY: no native GPU child may start'}
} catch {
    [ordered]@{schema=1;task=13;failure=$_.Exception.Message;gpuCommands=0;authorizationIssued=$false}|
        ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$root/failure.json" -Encoding UTF8
    throw
} finally {Stop-Transcript|Out-Null}
