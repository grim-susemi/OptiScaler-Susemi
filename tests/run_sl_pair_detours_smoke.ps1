# ============================================================================
# tests/run_sl_pair_detours_smoke.ps1 - runner for the R12 review H1 failure-path test.
#
# Run from a Visual Studio x64 developer shell (cl.exe on PATH), e.g. after
#   call "...\VC\Auxiliary\Build\vcvars64.bat"
# No GPU, no game, no Streamline runtime: the smoke drives the production installation policy
# (OptiScaler/hooks/SlPairDetours.h) against the real Detours library with one step injected to fail.
#
# Exit codes: 0 = green, 1 = a case failed or the smoke did not compile, 2 = environment broken.
# ============================================================================
$ErrorActionPreference = 'Stop'

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
{
    Write-Host 'run_sl_pair_detours_smoke: cl.exe is not on PATH - run from a Visual Studio x64 developer shell.'
    exit 2
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path ([IO.Path]::GetTempPath()) ('sl-pair-detours-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $out | Out-Null

& cl.exe /nologo /std:c++20 /EHsc /W4 /Od /DNOMINMAX `
    "/I$repo/OptiScaler" "/I$repo/OptiScaler/include" `
    "/Fo$out/" "/Fe$out/sl_pair_detours_smoke.exe" `
    "$PSScriptRoot/sl_pair_detours_smoke.cpp" `
    /link "$repo/OptiScaler/library/detours/detours.lib"
if ($LASTEXITCODE)
{
    Write-Host "sl_pair_detours_smoke: build failed (exit $LASTEXITCODE)"
    exit 1
}

& "$out/sl_pair_detours_smoke.exe"
$code = $LASTEXITCODE
if ($code)
{
    Write-Host "sl_pair_detours_smoke: FAILED (exit $code)"
    exit 1
}

Write-Host 'sl_pair_detours_smoke: green'
exit 0
