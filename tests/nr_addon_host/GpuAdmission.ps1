$Task13BusyRegex = '(?i)Crimson.?Desert|obs(32|64)?\.exe|nr-qa-host|NRAddonHost|Cyberpunk|Starfield|Hogwarts|MonsterHunter|eldenring|BlackMyth|GTA5|rdr2|FlightSimulator|dota2|cs2\.exe'
$Task13GameLibrary = 'D:/SteamLibrary/steamapps/common/'
function AssertTask15Budget {
    param([string]$Receipt, [string]$ReceiptSha256, [string]$Purpose, [switch]$StructureOnly)
    if (!$Receipt -or !(Test-Path -LiteralPath $Receipt -PathType Leaf)) { throw 'HOST_BUDGET_REQUIRED' }
    if ($ReceiptSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $Receipt).Hash -ne $ReceiptSha256) { throw 'HOST_BUDGET_IDENTITY' }
    try { $budget = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json } catch { throw 'HOST_BUDGET_MALFORMED' }
    $owner = if ($Purpose -ceq 'task23-diagnostic-pair') { 23 } else { 15 }
    if ($Purpose -cnotin @('task15-matrix','task23-diagnostic-pair') -or $budget.schema -ne 1 -or
        $budget.kind -cne 'nrRetainedBudgetReservation' -or $budget.attempt -cne 'e1-20261002-01a0fbd1' -or
        $budget.ownerTask -ne $owner -or $budget.purpose -cne $Purpose -or
        $budget.ceilingBytes -ne 268435456 -or ($budget.retainedBeforeBytes -isnot [long] -and $budget.retainedBeforeBytes -isnot [int]) -or
        ($budget.reservationBytes -isnot [long] -and $budget.reservationBytes -isnot [int]) -or
        $budget.retainedBeforeBytes -lt 0 -or $budget.reservationBytes -lt 16777216 -or
        $budget.reservationBytes -gt 134217728 -or
        $budget.retainedBeforeBytes -gt 268435456 -or $budget.reservationBytes -gt 268435456-$budget.retainedBeforeBytes) {
        throw 'HOST_RETAINED_BUDGET_REFUSED'
    }
    if ($StructureOnly) {
        if ($budget.synthetic -isnot [bool] -or !$budget.synthetic -or
            $budget.parentConfirmed -isnot [bool] -or $budget.parentConfirmed) { throw 'HOST_BUDGET_SYNTHETIC_STRUCTURE' }
    } elseif ($budget.synthetic -isnot [bool] -or $budget.synthetic -or
        $budget.parentConfirmed -isnot [bool] -or !$budget.parentConfirmed) { throw 'HOST_BUDGET_PARENT_REQUIRED' }
    return $budget
}

function AssertTask15GpuAdmission {
    param([string]$Receipt, [string]$ReceiptSha256, [string]$HostSha256, [string]$ManifestSha256,
        [string]$FinalCandidateSha256, [string]$RuntimeSha256, [string]$BudgetSha256,
        [string]$RuntimeCase, [string]$Purpose = 'task15-matrix', [string]$DiagnosticPair,
        [switch]$StructureOnly)
    if (!$Receipt -or !(Test-Path -LiteralPath $Receipt -PathType Leaf)) { throw 'HOST_GPU_ADMISSION_REQUIRED' }
    if ($ReceiptSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $Receipt).Hash -ne $ReceiptSha256) { throw 'HOST_GPU_ADMISSION_IDENTITY' }
    $jsonParameters = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }
    try { $release = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json @jsonParameters } catch { throw 'HOST_GPU_ADMISSION_MALFORMED' }
    if ($release.schema -ne 1 -or $release.kind -cne 'task15GpuAdmissionRelease' -or $release.task -ne 15 -or
        $release.attempt -cne 'e1-20261002-01a0fbd1') { throw 'HOST_GPU_ADMISSION_SCHEMA' }
    $issued = [DateTimeOffset]::MinValue; $expires = [DateTimeOffset]::MinValue
    if ($release.issuedUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$' -or
        $release.expiresUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$' -or
        ![DateTimeOffset]::TryParse($release.issuedUtc,[ref]$issued) -or
        ![DateTimeOffset]::TryParse($release.expiresUtc,[ref]$expires)) { throw 'HOST_GPU_ADMISSION_TIME' }
    $now = [DateTimeOffset]::UtcNow
    if ($issued -gt $now -or $expires -le $now -or $expires -le $issued -or
        ($expires-$issued).TotalMinutes -gt 30 -or ($now-$issued).TotalMinutes -gt 30) { throw 'HOST_GPU_ADMISSION_STALE' }
    $available = $release.availability
    if (!$available.path -or $available.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        !(Test-Path -LiteralPath $available.path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $available.path).Hash -ne $available.sha256) { throw 'HOST_GPU_AVAILABILITY_IDENTITY' }
    try { $named = Get-Content -LiteralPath $available.path -Raw | ConvertFrom-Json @jsonParameters } catch { throw 'HOST_GPU_AVAILABILITY_MALFORMED' }
    if ($named.synthetic -isnot [bool] -or $named.synthetic -ne $release.synthetic) { throw 'HOST_GPU_AVAILABILITY_SYNTHETIC' }
    $names = @('CrimsonDesert.exe','Witcher3.exe','obs.exe','obs32.exe','obs64.exe','NRAddonHost.exe','nr-qa-host.exe')
    if ($named.schema -ne 1 -or $named.kind -cne 'task15NamedAvailability' -or
        $named.issuedUtc -cne $release.issuedUtc -or $named.complete -isnot [bool] -or !$named.complete -or
        (@($named.queriedNames | Sort-Object) -join ',') -cne (@($names | Sort-Object) -join ',') -or
        $named.fixtureOwnershipComplete -isnot [bool] -or !$named.fixtureOwnershipComplete -or
        @($named.fixtureOwners).Count -eq 0) { throw 'HOST_GPU_AVAILABILITY_INCOMPLETE' }
    if ($named.activeCount -ne 0 -or @($named.active).Count -ne 0) { throw 'HOST_GPU_ADMISSION_BUSY' }
    if ($named.unknownCount -ne 0 -or @($named.unknown).Count -ne 0) { throw 'HOST_GPU_OWNERSHIP_UNKNOWN' }
    foreach ($fixture in $named.fixtureOwners) {
        if (!$fixture.image -or !$fixture.source -or $fixture.sourceVerified -isnot [bool] -or !$fixture.sourceVerified -or
            $fixture.disposition -cnotin @('absentResolved','nativeClosed') -or
            ($fixture.disposition -ceq 'nativeClosed' -and (!$fixture.nativeClosureReceipt -or !$fixture.nativeIdentity))) {
            throw 'HOST_GPU_OWNERSHIP_UNKNOWN'
        }
    }
    $authorization = $release.rootRelease
    $driver = $authorization.driverAssociation
    if (!$driver.path -or $driver.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $driver.adapterLuidLow -lt 0 -or $driver.adapterLuidLow -gt 4294967295 -or
        $driver.adapterLuidHigh -lt 0 -or $driver.adapterLuidHigh -gt 4294967295 -or
        $driver.currentAdapterVerified -isnot [bool]) { throw 'HOST_GPU_DRIVER_ASSOCIATION_REQUIRED' }
    if (!$StructureOnly -and (!$driver.currentAdapterVerified -or
        !(Test-Path -LiteralPath $driver.path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $driver.path).Hash -ne $driver.sha256)) {
        throw 'HOST_GPU_DRIVER_ASSOCIATION_STALE'
    }
    if ($authorization.releasedBy -cne '/root' -or $authorization.purpose -cne $Purpose -or
        $Purpose -cnotin @('task15-matrix','task23-diagnostic-pair') -or
        $RuntimeCase -cnotin @($authorization.allowedCases) -or
        ($DiagnosticPair -and $DiagnosticPair -cnotin @($authorization.allowedDiagnosticPairs)) -or
        ($Purpose -ceq 'task23-diagnostic-pair' -and (!$DiagnosticPair -or $RuntimeCase -cne 'B00')) -or
        $authorization.hostSha256 -ne $HostSha256 -or $authorization.manifestSha256 -ne $ManifestSha256 -or
        $authorization.finalCandidateSha256 -ne $FinalCandidateSha256 -or $authorization.runtimeSha256 -ne $RuntimeSha256 -or
        $authorization.budgetSha256 -ne $BudgetSha256) { throw 'HOST_GPU_ADMISSION_BOUNDARY' }
    if ($StructureOnly) {
        if ($release.synthetic -isnot [bool] -or !$release.synthetic -or
            $authorization.released -isnot [bool] -or $authorization.released) { throw 'HOST_GPU_ADMISSION_SYNTHETIC_STRUCTURE' }
        return [ordered]@{structureValid=$true;authorized=$false;synthetic=$true;gpuChildStarts=0}
    }
    if ($release.synthetic -isnot [bool] -or $release.synthetic -or
        $authorization.released -isnot [bool] -or !$authorization.released) { throw 'HOST_GPU_ADMISSION_ROOT_RELEASE_REQUIRED' }
    return [ordered]@{authorized=$true;synthetic=$false;expiresUtc=$release.expiresUtc;purpose=$Purpose}
}

function AssertTask13GpuAdmission {
    param([string]$Receipt, [string]$ReceiptSha256, [string]$Phase,
        [string]$HostSha256, [string]$ManifestSha256, [string]$RuntimeSha256,
        [switch]$StructureOnly)
    if (!$Receipt -or !(Test-Path -LiteralPath $Receipt -PathType Leaf)) { throw 'HOST_GPU_ADMISSION_REQUIRED' }
    if ($ReceiptSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Receipt).Hash -ne $ReceiptSha256) { throw 'HOST_GPU_ADMISSION_IDENTITY' }
    $jsonParameters = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }
    try { $release = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json @jsonParameters } catch { throw 'HOST_GPU_ADMISSION_MALFORMED' }
    if (!$release -or $release.schema -ne 1 -or $release.kind -ne 'task13GpuAdmissionRelease' -or
        $release.task -ne 13 -or $release.attempt -ne 'e1-20261002-01a0fbd1') { throw 'HOST_GPU_ADMISSION_SCHEMA' }
    $issued = [DateTimeOffset]::MinValue
    $expires = [DateTimeOffset]::MinValue
    if ($release.issuedUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$' -or
        $release.expiresUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$' -or
        ![DateTimeOffset]::TryParse($release.issuedUtc,[ref]$issued) -or
        ![DateTimeOffset]::TryParse($release.expiresUtc,[ref]$expires)) { throw 'HOST_GPU_ADMISSION_TIME' }
    $now = [DateTimeOffset]::UtcNow
    if ($issued -gt $now -or $expires -le $now -or $expires -le $issued -or
        ($expires-$issued).TotalMinutes -gt 30 -or ($now-$issued).TotalMinutes -gt 30) { throw 'HOST_GPU_ADMISSION_STALE' }
    if ($release.busyRegex -cne $Task13BusyRegex -or $release.additionalBusyName -cne 'Witcher3.exe' -or
        $release.gameLibraryPrefix -cne $Task13GameLibrary) { throw 'HOST_GPU_ADMISSION_POLICY' }
    if (!$release.censusPath -or $release.censusSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        !(Test-Path -LiteralPath $release.censusPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $release.censusPath).Hash -ne $release.censusSha256) { throw 'HOST_GPU_ADMISSION_CENSUS_IDENTITY' }
    try { $census = Get-Content -LiteralPath $release.censusPath -Raw | ConvertFrom-Json @jsonParameters } catch { throw 'HOST_GPU_ADMISSION_CENSUS_MALFORMED' }
    $processes = @($census.processes)
    if ('busy' -notin $census.PSObject.Properties.Name -or 'busyCount' -notin $census.PSObject.Properties.Name) { throw 'HOST_GPU_ADMISSION_CENSUS_INCOMPLETE' }
    if ($census.schema -ne 1 -or $census.complete -isnot [bool] -or !$census.complete -or
        $processes.Count -eq 0 -or $census.processCount -ne $processes.Count -or
        $census.busyRegex -cne $Task13BusyRegex -or $census.additionalBusyName -cne 'Witcher3.exe' -or
        $census.gameLibraryPrefix -cne $Task13GameLibrary -or $census.issuedUtc -cne $release.issuedUtc) { throw 'HOST_GPU_ADMISSION_CENSUS_INCOMPLETE' }
    $seen = @{}
    foreach ($process in $processes) {
        if ($null -eq $process.ProcessId -or $process.ProcessId -lt 0 -or !$process.Name -or $seen.ContainsKey([string]$process.ProcessId)) {
            throw 'HOST_GPU_ADMISSION_CENSUS_INCOMPLETE'
        }
        $seen[[string]$process.ProcessId] = $true
    }
    $busy = @($processes | Where-Object {
        $_.Name -match $Task13BusyRegex -or $_.Name -ieq 'Witcher3.exe' -or
        ($_.ExecutablePath -and $_.ExecutablePath.Replace('\','/').StartsWith($Task13GameLibrary,[StringComparison]::OrdinalIgnoreCase))
    })
    $actualIds = @($busy | ForEach-Object { [string]$_.ProcessId } | Sort-Object)
    $recordedIds = @($census.busy | ForEach-Object { [string]$_.ProcessId } | Sort-Object)
    if ($census.busyCount -ne $busy.Count -or ($actualIds -join ',') -cne ($recordedIds -join ',') -or
        $release.busyCount -ne $busy.Count -or $release.completeCensus -isnot [bool] -or !$release.completeCensus) {
        throw 'HOST_GPU_ADMISSION_BUSY_MISMATCH'
    }
    if ($busy.Count -ne 0) { throw 'HOST_GPU_ADMISSION_BUSY' }
    $authorization = $release.rootRelease
    if (!$authorization -or 'candidateDllSha256' -notin $authorization.PSObject.Properties.Name) { throw 'HOST_GPU_ADMISSION_BOUNDARY' }
    if (!$authorization -or $authorization.releasedBy -cne '/root' -or
        @($authorization.allowedPhases).Count -ne 2 -or
        (@($authorization.allowedPhases | Sort-Object) -join ',') -cne 'Runtime,Warp' -or
        $Phase -notin @('Warp','Runtime') -or $Phase -notin $authorization.allowedPhases -or
        $authorization.hostSha256 -ne $HostSha256 -or $authorization.candidateSourceManifestSha256 -ne $ManifestSha256 -or
        $authorization.runtimeSha256 -ne $RuntimeSha256 -or $authorization.candidateDllSha256 -ne $null -or
        $authorization.candidateDllState -cne 'unbuiltPendingTask14') { throw 'HOST_GPU_ADMISSION_BOUNDARY' }
    if ($StructureOnly) {
        if ($release.synthetic -isnot [bool] -or !$release.synthetic -or $authorization.released -ne $false) { throw 'HOST_GPU_ADMISSION_SYNTHETIC_STRUCTURE' }
        return [ordered]@{structureValid=$true;authorized=$false;synthetic=$true;gpuChildStarts=0}
    }
    if ($release.synthetic -ne $false -or $authorization.released -isnot [bool] -or !$authorization.released) {
        throw 'HOST_GPU_ADMISSION_ROOT_RELEASE_REQUIRED'
    }
    return [ordered]@{authorized=$true;synthetic=$false;receiptSha256=$ReceiptSha256;censusSha256=$release.censusSha256;expiresUtc=$release.expiresUtc}
}
