param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/Task23All.ps1"
$observations = [Collections.Generic.List[object]]::new()
function Assert([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw "T23_CPU_ORACLE_$Name" }
}
function Refusal([string]$Name, [scriptblock]$Operation, [string]$Expected) {
    try { & $Operation | Out-Null } catch {
        if ($_.Exception.Message -cne $Expected) { throw }
        $observations.Add(@{case=$Name; refusal=$_.Exception.Message; passed=$true})
        return
    }
    throw "T23_CPU_ORACLE_$Name"
}
$dispatcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'run_nr_mfg_diagnostics.ps1'
foreach ($path in @($dispatcher, "$PSScriptRoot/Task23All.ps1", "$PSScriptRoot/Task23Pair.ps1", $PSCommandPath)) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'SOURCE_PARSE'
    $observations.Add(@{case='source-parse'; path=$path; errors=@($errors); passed=$true})
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($dispatcher, [ref]$tokens, [ref]$errors)
$tier = @($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq 'Tier'})[0]
$set = @($tier.Attributes | Where-Object {$_.TypeName.Name -ceq 'ValidateSet'})[0]
$values = @($set.PositionalArguments | ForEach-Object {$_.Value})
Assert ($values.Count -eq 4 -and 'All' -cin $values -and
        'Contracts' -cin $values -and 'Capture' -cin $values -and 'Analysis' -cin $values) 'TIERS'
Assert ($tier.DefaultValue.Value -ceq 'Contracts') 'DEFAULT_TIER'
$scope = @($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq 'Scope'})[0]
Assert ($scope.DefaultValue.Value -ceq 'All') 'DEFAULT_SCOPE'
$observations.Add(@{case='current-All-parameter-and-legacy-defaults'; values=$values; passed=$true})
$root = [IO.Path]::GetFullPath($EvidenceRoot)
$arguments = @{CandidateRoot=(Join-Path $root 'finalMFG'); HostRoot=(Join-Path $root 'newhost')
    EvidenceRoot=(Join-Path $root 'never-created'); RuntimeRoot=(Join-Path $root 'runtime')}
Refusal 'current-dispatch-missing-lease' {
    & $dispatcher -Tier All @arguments
} 'T23_GPU_LEASE_REQUIRED'
Assert (!(Test-Path -LiteralPath $arguments.EvidenceRoot)) 'REFUSAL_BEFORE_OUTPUT_OR_HOST'
Refusal 'distinct-final-and-host-roots' {
    Get-Task23AllPlan -CandidateRoot $arguments.HostRoot -HostRoot $arguments.HostRoot `
        -EvidenceRoot $arguments.EvidenceRoot -RuntimeRoot $arguments.RuntimeRoot
} 'T23_DISTINCT_HOST_ROOT_REQUIRED'
Refusal 'missing-budget' {Read-Task23Binding '' '' 'BUDGET'} 'T23_BUDGET_REQUIRED'
Refusal 'budget-identity-format' {
    Read-Task23Binding "$PSScriptRoot/Task23All.ps1" 'wrong' 'BUDGET'
} 'T23_BUDGET_IDENTITY_MISMATCH'
Refusal 'manifest-identity-actual-file' {
    Read-Task23Binding "$PSScriptRoot/Task23All.ps1" ('0' * 64) 'SOURCE_MANIFEST'
} 'T23_SOURCE_MANIFEST_IDENTITY_MISMATCH'
Refusal 'old-manifest-cannot-be-current' {
    Assert-Task23CurrentManifest ([pscustomobject]@{schema=1;kind='legacy'}) `
        'C:\newhost\NRAddonHost.exe' 'C:\finalMFG\OptiScaler.dll' 'C:\runtime' ('4'*64)
} 'T23_CURRENT_MANIFEST_REQUIRED'
$manifest = [pscustomobject]@{schema=1;kind='task15AffectedHostManifest'
    host=[pscustomobject]@{path='C:\newhost\NRAddonHost.exe';sha256='223F494CF601B55E6BD6D6B5E8D0CB9D116DB381DFFBDB7289F9E48CE3E56B58'}
    finalCandidate=[pscustomobject]@{path='C:\finalMFG\OptiScaler.dll';bytes=27288576
        sha256='86C8F55D0E5C7982542B3FD0B21EB8F181E413DEB1E64BD9D1AA30A25FFE10C4'}
    runtime=[pscustomobject]@{path='C:\runtime\nvngx_dlssnr.dll';sha256=('4'*64)}}
Refusal 'predecessor-host-cannot-be-newhost' {
    Assert-Task23CurrentManifest $manifest 'C:\newhost\NRAddonHost.exe' `
        'C:\finalMFG\OptiScaler.dll' 'C:\runtime' ('4'*64)
} 'T23_CURRENT_BINDING_MISMATCH'
$manifest.host.sha256 = '1'*64
$manifest.finalCandidate.path = 'C:\newhost\OptiScaler.dll'
Refusal 'hostroot-cannot-substitute-finalMFGroot' {
    Assert-Task23CurrentManifest $manifest 'C:\newhost\NRAddonHost.exe' `
        'C:\finalMFG\OptiScaler.dll' 'C:\runtime' ('4'*64)
} 'T23_CURRENT_BINDING_MISMATCH'
# Helper-only synthetic CPU data never represents an actual lease or GPU PASS.
$budget = [pscustomobject]@{schema=1; kind='nrRetainedBudgetReservation'; attempt='e1-20261002-01a0fbd1'
    ownerTask=23; purpose='task23-diagnostic-pair'; retainedBeforeBytes=251658240
    reservationBytes=16777216; ceilingBytes=268435456; parentConfirmed=$true; synthetic=$true}
Refusal 'synthetic-budget-refused' {Assert-Task23Budget $budget} 'T23_BUDGET_AUTHORITY_REFUSED'
$budget.synthetic = $false
Assert-Task23Budget $budget
$observations.Add(@{case='integer-exact-budget-boundary-helper-only'; retained=$budget.retainedBeforeBytes
    reservation=$budget.reservationBytes; ceiling=$budget.ceilingBytes; syntheticCPUFixture=$true; passed=$true})
$budget.retainedBeforeBytes++
Refusal 'shared-budget-over-by-one-without-images' {Assert-Task23Budget $budget} 'T23_RETAINED_BUDGET_REFUSED'
$budget.retainedBeforeBytes = 0
$budget.ownerTask = 15
Refusal 'wrong-budget-owner' {Assert-Task23Budget $budget} 'T23_BUDGET_AUTHORITY_REFUSED'
$budget.ownerTask = 23
$budget.reservationBytes = '16777216'
Refusal 'string-budget-invalid' {Assert-Task23Budget $budget} 'T23_BUDGET_INVALID'
$release = [pscustomobject]@{schema=1; kind='task15GpuAdmissionRelease'; task=15
    attempt='e1-20261002-01a0fbd1'; synthetic=$true
    rootRelease=[pscustomobject]@{releasedBy='/root'; released=$true; purpose='task23-diagnostic-pair'
        allowedCases=@('B00'); allowedDiagnosticPairs=@('off','on')}}
Refusal 'synthetic-lease-refused' {
    Assert-Task23Release $release ('1'*64) ('2'*64) ('3'*64) ('4'*64) ('5'*64)
} 'T23_GPU_LEASE_REFUSED'
$identities = foreach ($path in @($dispatcher, "$PSScriptRoot/Task23All.ps1", "$PSScriptRoot/Task23Pair.ps1", $PSCommandPath)) {
    @{path=$path; bytes=(Get-Item -LiteralPath $path).Length
      sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
$result = @{schema=1; kind='task23-current-All-CPU-boundary'; passed=$true
    observations=$observations.ToArray(); sources=@($identities)
    syntheticCPUFixture=$true; actualCandidateHostExecuted=$false; siblingSourcesExecuted=$false
    providerRuntimeOrReleaseDllLoaded=$false; actualAllGpuExecuted=$false; gpuReleaseGranted=$false
    childLaunches=0; generatedImages=0; generatedQaFiles=0; ownedAssets=0; pending=0}
Write-Output ('T23_CPU_RESULT=' + ($result | ConvertTo-Json -Depth 10 -Compress))
Write-Output 'T23_CPU_NATIVE_EXIT=0'
