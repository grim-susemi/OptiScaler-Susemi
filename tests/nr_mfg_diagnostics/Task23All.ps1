# Task23 candidate All admission and canonical pair dispatch.
# Dot-sourcing only defines functions; it never starts a host or loads a DLL.
function Read-Task23Binding([string]$Path, [string]$Sha256, [string]$Kind) {
    if (!$Path -or !$Sha256) { throw "T23_${Kind}_REQUIRED" }
    if ($Sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw "T23_${Kind}_IDENTITY_MISMATCH" }
    if (![IO.Path]::IsPathRooted($Path) -or !(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "T23_${Kind}_REQUIRED"
    }
    # Qualified source manifests include bounded compiler dependency proof.
    # Lease and budget receipts retain their separate 64 KiB limit.
    $maximum = if ($Kind -ceq 'SOURCE_MANIFEST') { 1048576 } else { 65536 }
    $item = Get-Item -LiteralPath $Path
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $maximum) {
        throw "T23_${Kind}_INVALID"
    }
    $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hash = [Security.Cryptography.SHA256]::Create()
    $reader = $null
    try {
        if ($stream.Length -gt $maximum) { throw "T23_${Kind}_INVALID" }
        $actual = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '')
        if ($actual -ine $Sha256) { throw "T23_${Kind}_IDENTITY_MISMATCH" }
        $stream.Position = 0
        $reader = New-Object IO.StreamReader($stream)
        $jsonParameters = @{}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }
        return ($reader.ReadToEnd() | ConvertFrom-Json @jsonParameters)
    } finally {
        if ($reader) { $reader.Dispose() }
        $hash.Dispose()
        $stream.Dispose()
    }
}

function Assert-Task23Budget($Budget) {
    if ($Budget.schema -ne 1 -or $Budget.kind -cne 'nrRetainedBudgetReservation' -or
        $Budget.attempt -cne 'e1-20261002-01a0fbd1' -or $Budget.ownerTask -ne 23 -or
        $Budget.purpose -cne 'task23-diagnostic-pair' -or
        $Budget.parentConfirmed -isnot [bool] -or !$Budget.parentConfirmed -or
        $Budget.synthetic -isnot [bool] -or $Budget.synthetic) { throw 'T23_BUDGET_AUTHORITY_REFUSED' }
    foreach ($name in @('retainedBeforeBytes','reservationBytes','ceilingBytes')) {
        $value = $Budget.$name
        if ($value -isnot [int] -and $value -isnot [long]) { throw 'T23_BUDGET_INVALID' }
    }
    if ($Budget.ceilingBytes -ne 268435456 -or $Budget.retainedBeforeBytes -lt 0 -or
        $Budget.reservationBytes -lt 16777216 -or $Budget.reservationBytes -gt 134217728 -or
        $Budget.retainedBeforeBytes -gt (268435456 - $Budget.reservationBytes)) {
        throw 'T23_RETAINED_BUDGET_REFUSED'
    }
}

function Assert-Task23Release($Release, [string]$HostSha256, [string]$ManifestSha256,
                             [string]$FinalSha256, [string]$RuntimeSha256, [string]$BudgetSha256) {
    $root = $Release.rootRelease
    if ($Release.schema -ne 1 -or $Release.kind -cne 'task15GpuAdmissionRelease' -or
        $Release.task -ne 15 -or $Release.attempt -cne 'e1-20261002-01a0fbd1' -or
        $Release.synthetic -isnot [bool] -or $Release.synthetic -or
        $root.releasedBy -cne '/root' -or $root.released -isnot [bool] -or !$root.released -or
        $root.purpose -cne 'task23-diagnostic-pair' -or
        @($root.allowedCases).Count -ne 1 -or $root.allowedCases[0] -cne 'B00' -or
        @($root.allowedDiagnosticPairs).Count -ne 2 -or
        'off' -cnotin $root.allowedDiagnosticPairs -or 'on' -cnotin $root.allowedDiagnosticPairs) {
        throw 'T23_GPU_LEASE_REFUSED'
    }
    $issued = [DateTimeOffset]::MinValue
    $expires = [DateTimeOffset]::MinValue
    if (![DateTimeOffset]::TryParse([string]$Release.issuedUtc, [ref]$issued) -or
        ![DateTimeOffset]::TryParse([string]$Release.expiresUtc, [ref]$expires) -or
        $issued.Offset -ne [TimeSpan]::Zero -or $expires.Offset -ne [TimeSpan]::Zero -or
        $issued -gt [DateTimeOffset]::UtcNow -or $expires -le [DateTimeOffset]::UtcNow -or
        $expires -le $issued -or ($expires - $issued).TotalMinutes -gt 30) {
        throw 'T23_GPU_LEASE_EXPIRED'
    }
    $expected = @{hostSha256=$HostSha256; manifestSha256=$ManifestSha256;
        finalCandidateSha256=$FinalSha256; runtimeSha256=$RuntimeSha256; budgetSha256=$BudgetSha256}
    foreach ($name in $expected.Keys) {
        if (!$root.$name -or $root.$name -ine $expected[$name]) { throw 'T23_GPU_LEASE_IDENTITY_MISMATCH' }
    }
    # Exact named availability and native lifetime remain validated by the frozen
    # canonical host admission; this local check never grants a release.
}

function Assert-Task23CurrentManifest($Manifest, [string]$HostExecutable, [string]$Candidate,
                                     [string]$RuntimeRoot, [string]$RuntimeSha256) {
    if ($Manifest.schema -ne 1 -or $Manifest.kind -cne 'task15AffectedHostManifest') {
        throw 'T23_CURRENT_MANIFEST_REQUIRED'
    }
    $finalSha = '02CB71546ECB2EA1525F4EA07DC65ADBE344B4C0787464F503FD6C00F7B71C84'
    if (!$Manifest.host.path -or !$Manifest.finalCandidate.path -or !$Manifest.runtime.path -or
        $Manifest.host.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $Manifest.host.sha256 -ieq '223F494CF601B55E6BD6D6B5E8D0CB9D116DB381DFFBDB7289F9E48CE3E56B58' -or
        [IO.Path]::GetFullPath($Manifest.host.path) -ine $HostExecutable -or
        [IO.Path]::GetFullPath($Manifest.finalCandidate.path) -ine $Candidate -or
        $Manifest.finalCandidate.bytes -ne 27289088 -or $Manifest.finalCandidate.sha256 -ine $finalSha -or
        [IO.Path]::GetFullPath($Manifest.runtime.path) -ine
            [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'nvngx_dlssnr.dll')) -or
        $Manifest.runtime.sha256 -ine $RuntimeSha256) { throw 'T23_CURRENT_BINDING_MISMATCH' }
}

function Get-Task23AllPlan {
    param([string]$CandidateRoot, [string]$HostRoot, [string]$EvidenceRoot,
          [string]$SourceManifest, [string]$SourceManifestSha256,
          [string]$RuntimeRoot, [string]$RuntimeSha256,
          [string]$GpuAdmissionReceipt, [string]$GpuAdmissionSha256,
          [string]$BudgetReceipt, [string]$BudgetSha256)
    foreach ($name in @('CandidateRoot','HostRoot','EvidenceRoot','RuntimeRoot')) {
        $value = Get-Variable -Name $name -ValueOnly
        if (!$value -or ![IO.Path]::IsPathRooted($value)) { throw "T23_${name}_REQUIRED" }
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $CandidateRoot 'OptiScaler.dll'))
    $hostExecutable = [IO.Path]::GetFullPath((Join-Path $HostRoot 'NRAddonHost.exe'))
    if ([IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\','/') -ieq
        [IO.Path]::GetFullPath($HostRoot).TrimEnd('\','/')) { throw 'T23_DISTINCT_HOST_ROOT_REQUIRED' }
    if (Test-Path -LiteralPath $EvidenceRoot) { throw 'T23_FRESH_EVIDENCE_REQUIRED' }
    $lease = Read-Task23Binding $GpuAdmissionReceipt $GpuAdmissionSha256 'GPU_LEASE'
    $budget = Read-Task23Binding $BudgetReceipt $BudgetSha256 'BUDGET'
    Assert-Task23Budget $budget
    $manifest = Read-Task23Binding $SourceManifest $SourceManifestSha256 'SOURCE_MANIFEST'
    $finalSha = '02CB71546ECB2EA1525F4EA07DC65ADBE344B4C0787464F503FD6C00F7B71C84'
    Assert-Task23CurrentManifest $manifest $hostExecutable $candidate $RuntimeRoot $RuntimeSha256
    foreach ($binding in @(@{path=$candidate;sha=$finalSha},@{path=$hostExecutable;sha=$manifest.host.sha256},
                          @{path=(Join-Path $RuntimeRoot 'nvngx_dlssnr.dll');sha=$RuntimeSha256})) {
        if (!(Test-Path -LiteralPath $binding.path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $binding.path -Algorithm SHA256).Hash -ine $binding.sha) {
            throw 'T23_CURRENT_FILE_IDENTITY_MISMATCH'
        }
    }
    Assert-Task23Release $lease $manifest.host.sha256 $SourceManifestSha256 $finalSha $RuntimeSha256 $BudgetSha256
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'nr_addon_host/RunHost.ps1'
    $cases = foreach ($pair in @('off','on')) {
        [pscustomobject]@{pair=$pair; runner=$runner; parameters=@{
            Phase='Runtime'; Task15Candidate=$true; RuntimeCase='B00'; DiagnosticPair=$pair
            EvidenceRoot=(Join-Path $EvidenceRoot $pair); CandidateRoot=$HostRoot; FinalCandidate=$candidate
            SourceManifest=$SourceManifest; RuntimeRoot=$RuntimeRoot; RuntimeSha256=$RuntimeSha256
            GpuAdmissionReceipt=$GpuAdmissionReceipt; GpuAdmissionSha256=$GpuAdmissionSha256
            BudgetReceipt=$BudgetReceipt; BudgetSha256=$BudgetSha256
        }}
    }
    return [pscustomobject]@{cases=@($cases); hostSha256=$manifest.host.sha256
        manifestSha256=$SourceManifestSha256; finalCandidateSha256=$finalSha
        budget=$budget; gpuReleaseGranted=$false}
}

function Invoke-Task23CanonicalPair($Plan) {
    # Canonical RunHost owns each registered nested native lifetime capture.
    # Parent owns the outer All native controller. No direct host launch here.
    foreach ($case in $Plan.cases) {
        $parameters = $case.parameters
        & $case.runner @parameters
        if (!$? -or $LASTEXITCODE -ne 0) { throw "T23_PAIR_$($case.pair)_FAILED" }
    }
}
