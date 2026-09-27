# ============================================================================
# tests/run_nr_native_probe_budget.ps1 - runner for the R10 NR_XEFG_NATIVE_GATE
# admission/selection policy.
#
# Run from a Visual Studio x64 developer shell (cl.exe on PATH), e.g. after
#   call "...\VC\Auxiliary\Build\vcvars64.bat"
# No GPU, no game, no NVIDIA runtime, no Streamline.
#
# Phases:
#   1. tests/nr_native_probe_budget_smoke.cpp - the production policy
#      (shaders/dlssnr/DlssNr_NativeProbe.h, the header DlssNr_Dx12.cpp includes):
#      stable classification, alternating 6/5 and 6/14, exhaustion/non-wrapping, and the
#      producer selection (null, duplicate, cap, order).
#   2. the same smoke with NR_NATIVE_PROBE_SEED_EDGE_ONLY (the rejected v3 semantics: the
#      classification transition alone admits, no latch) must break the two alternating
#      sequences - failure-provable, and specifically red for the H1 reason.
#
# Exit codes:
#   0 = GREEN - every case passes and the seed breaks the alternating cases
#   1 = a check failed, or a seed stopped breaking its cases
#   2 = the environment is broken (cl.exe missing)
# ============================================================================
$ErrorActionPreference = 'Stop'

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
{
    Write-Host 'run_nr_native_probe_budget: cl.exe is not on PATH - run from a Visual Studio x64 developer shell.'
    exit 2
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path ([IO.Path]::GetTempPath()) ('nr-native-probe-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $out | Out-Null

function Invoke-Smoke([string]$source, [string[]]$defines, [string]$tag)
{
    $exe = Join-Path $out "$tag.exe"
    & cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX @defines "/I$out" "/Fo$out/" "/Fe$exe" $source | Write-Host
    if ($LASTEXITCODE)
    {
        Write-Host "nr_native_probe_budget: $tag did not compile"
        exit 1
    }
    & $exe | Tee-Object -FilePath (Join-Path $out "$tag.txt") | Write-Host
    return $LASTEXITCODE
}

try
{
    $smoke = Join-Path $PSScriptRoot 'nr_native_probe_budget_smoke.cpp'

    $green = Invoke-Smoke $smoke @() 'green'
    Write-Host "nr_native_probe_budget_smoke green exit=$green"
    if ($green) { exit 1 }

    $seed = Invoke-Smoke $smoke @('/DNR_NATIVE_PROBE_SEED_EDGE_ONLY') 'seed_edge_only'
    Write-Host "nr_native_probe_budget_smoke seed_edge_only exit=$seed (expected nonzero)"
    if ($seed -eq 0)
    {
        Write-Host 'seed NR_NATIVE_PROBE_SEED_EDGE_ONLY broke no case - the harness is not failure-provable'
        exit 1
    }
    $seedLog = Get-Content -LiteralPath (Join-Path $out 'seed_edge_only.txt') -Raw
    foreach ($case in @('alternating_6_5_cannot_bypass_exhaustion',
                        'alternating_6_14_cannot_bypass_exhaustion'))
    {
        if ($seedLog -notmatch [regex]::Escape($case) + '\s+FAIL')
        {
            Write-Host "seed NR_NATIVE_PROBE_SEED_EDGE_ONLY did not break the H1 case: $case"
            exit 1
        }
    }

    Write-Host 'R10 native probe admission budget regression passed.'
    exit 0
}
finally
{
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
