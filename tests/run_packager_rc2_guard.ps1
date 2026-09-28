# ============================================================================
# tests/run_packager_rc2_guard.ps1 - T23 regression for the package_release.ps1
# rc2 guard.
#
# The approved rc2 candidate is the byte-pinned repack of the published rc1 ZIP
# (tracked recipe tools/repack_rc2.py). The ordinary packager must refuse the
# exact -Version v11.2-rc2 before any output exists, naming that recipe, and
# every other -Version must keep reaching the pre-existing gates unchanged.
#
# Exercises the REAL package_release.ps1 in a child powershell. Asserts only
# machine-checkable facts (exit codes, the recipe file pointer, absence of
# output artifacts); no prose phrasing is pinned.
#
# Exit codes:
#   0 = GREEN - rc2 refused with the recipe pointer and no output staged;
#       non-rc2 control still refused by the prior gates with the guard silent
#   2 = environment: package_release.ps1 missing
#   3 = rc2 invocation did not refuse (exit 0)
#   4 = rc2 refusal does not point to tools/repack_rc2.py
#   5 = an invocation produced output artifacts (zip/stage appeared)
#   6 = non-rc2 control behaved unexpectedly (guard over-fired or exited 0)
# ============================================================================
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = Join-Path $repo 'package_release.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { Write-Host 'rc2 guard negative: missing package_release.ps1'; exit 2 }
$zipOut = Join-Path $repo 'release/OptiScaler-NR-v11.2-rc2.zip'
$stageOut = Join-Path $repo 'release/v11.2-rc2'
if ((Test-Path -LiteralPath $zipOut) -or (Test-Path -LiteralPath $stageOut)) {
    Write-Host 'rc2 guard negative: FAIL - rc2 output already exists before any invocation'; exit 5
}

Write-Host 'rc2 guard negative: Case A - exact -Version v11.2-rc2 must be refused before UAL/build/staging'
$ErrorActionPreference = 'Continue' # capture native stderr; child failures are expected refusals
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Version v11.2-rc2 -EnableRtx40Mfg 2>&1
$exitA = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$textA = $out | Out-String
if ($exitA -eq 0) { Write-Host '  FAIL - rc2 packaging did not refuse (exit 0)'; exit 3 }
if (-not $textA.Contains('repack_rc2.py')) { Write-Host '  FAIL - refusal does not point to tools/repack_rc2.py'; exit 4 }
if ((Test-Path -LiteralPath $zipOut) -or (Test-Path -LiteralPath $stageOut)) {
    Write-Host '  FAIL - refusal produced output artifacts'; exit 5
}
Write-Host "  PASS - refused (exit $exitA), recipe pointer present, no output staged"

Write-Host 'rc2 guard negative: Case B - non-rc2 version keeps prior gates; rc2 guard must stay silent'
$ErrorActionPreference = 'Continue'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Version rc2-guard-control -SkipBuild 2>&1
$exitB = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$textB = $out | Out-String
if ($exitB -eq 0) { Write-Host '  FAIL - non-rc2 control exited 0'; exit 6 }
if ($textB.Contains('repack_rc2')) { Write-Host '  FAIL - rc2 guard fired for a non-rc2 version'; exit 6 }
if ((Test-Path -LiteralPath $zipOut) -or (Test-Path -LiteralPath $stageOut)) {
    Write-Host '  FAIL - control produced output artifacts'; exit 5
}
Write-Host "  PASS - non-rc2 control refused by the prior gates (exit $exitB), rc2 guard silent"

Write-Host 'rc2 guard negative: GREEN - rc2 refused with recipe pointer, non-rc2 unchanged, no output'
exit 0
