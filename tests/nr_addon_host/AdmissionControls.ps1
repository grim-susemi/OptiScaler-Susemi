param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/GpuAdmission.ps1"
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
$expected=Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1/task13-host'
$root=[IO.Path]::GetFullPath($EvidenceRoot)
if (!$root.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Admission controls must remain in Task13 evidence' }
New-Item -ItemType Directory -Path $root | Out-Null
$hash='A'*64
$now=[DateTimeOffset]::UtcNow
$census=[ordered]@{schema=1;complete=$true;issuedUtc=$now.ToString('yyyy-MM-ddTHH:mm:ssZ');processCount=1;
    busyRegex=$Task13BusyRegex;additionalBusyName='Witcher3.exe';gameLibraryPrefix=$Task13GameLibrary;
    processes=@([ordered]@{ProcessId=123;Name='owned-cpu-fixture.exe';ExecutablePath='C:/owned/cpu.exe'});busyCount=0;busy=@()}
$censusPath="$root/synthetic-census.json"
$census|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $censusPath -Encoding UTF8
$release=[ordered]@{schema=1;kind='task13GpuAdmissionRelease';task=13;attempt='e1-20261002-01a0fbd1';synthetic=$true;
    issuedUtc=$census.issuedUtc;expiresUtc=$now.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ssZ');
    completeCensus=$true;busyCount=0;busyRegex=$Task13BusyRegex;additionalBusyName='Witcher3.exe';gameLibraryPrefix=$Task13GameLibrary;
    censusPath=$censusPath;censusSha256=(Get-FileHash -LiteralPath $censusPath).Hash;
    rootRelease=[ordered]@{released=$false;releasedBy='/root';allowedPhases=@('Warp','Runtime');hostSha256=$hash;
        candidateSourceManifestSha256=$hash;runtimeSha256=$hash;candidateDllSha256=$null;candidateDllState='unbuiltPendingTask14'}}
$results=@()
foreach($case in @('empty','malformed','busy','stale','wrong-identity','synthetic-not-release','positive-structure')) {
    $fixture=$release|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $expectedError=switch($case){'empty'{'HOST_GPU_ADMISSION_SCHEMA'}'malformed'{'HOST_GPU_ADMISSION_MALFORMED'}
        'busy'{'HOST_GPU_ADMISSION_BUSY'}'stale'{'HOST_GPU_ADMISSION_STALE'}'wrong-identity'{'HOST_GPU_ADMISSION_BOUNDARY'}
        'synthetic-not-release'{'HOST_GPU_ADMISSION_ROOT_RELEASE_REQUIRED'}default{''}}
    if($case -eq 'busy'){
        $busy=$census|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $busy.processes[0].Name='Witcher3.exe';$busy.busyCount=1;$busy.busy=@($busy.processes[0])
        $busy|ConvertTo-Json -Depth 8|Set-Content -LiteralPath "$root/busy-census.json" -Encoding UTF8
        $fixture.censusPath="$root/busy-census.json";$fixture.censusSha256=(Get-FileHash $fixture.censusPath).Hash;$fixture.busyCount=1
    }
    if($case -eq 'stale'){$fixture.issuedUtc=$now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ');$fixture.expiresUtc=$now.AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')}
    if($case -eq 'wrong-identity'){$fixture.rootRelease.hostSha256='B'*64}
    $path="$root/$case.json"
    if($case -eq 'empty'){[IO.File]::WriteAllText($path,'')}
    elseif($case -eq 'malformed'){[IO.File]::WriteAllText($path,'{')}
    else{$fixture|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8}
    $actual=''
    try {
        $result=AssertTask13GpuAdmission -Receipt $path -ReceiptSha256 (Get-FileHash $path).Hash -Phase Warp -HostSha256 $hash -ManifestSha256 $hash -RuntimeSha256 $hash -StructureOnly:($case -eq 'positive-structure')
        if($result.authorized -or !$result.structureValid -or !$result.synthetic){throw 'Synthetic structure fixture became an authorization'}
    }catch{$actual=$_.Exception.Message}
    if($actual -cne $expectedError){throw "Admission control mismatch $case expected=$expectedError actual=$actual"}
    $results+=[ordered]@{case=$case;expectedError=$expectedError;actualError=$actual;fixture=$path;sha256=(Get-FileHash $path).Hash;gpuChildStarts=0;nativeHostStarts=0;synthetic=$true}
}
[ordered]@{schema=1;task=13;kind='cpuAdmissionControls';passed=$true;synthetic=$true;authorizationIssued=$false;
    gpuChildStarts=0;nativeHostStarts=0;validatorSha256=(Get-FileHash "$PSScriptRoot/GpuAdmission.ps1").Hash;cases=$results}|
    ConvertTo-Json -Depth 8|Set-Content -LiteralPath "$root/result.json" -Encoding UTF8
Write-Host "HOST_ADMISSION_CPU_CONTROLS_PASS cases=$($results.Count) gpuChildStarts=0 root=$root"
