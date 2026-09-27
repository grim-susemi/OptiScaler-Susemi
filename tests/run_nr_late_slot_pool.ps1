# ============================================================================
# tests/run_nr_late_slot_pool.ps1 - runner for the finished-picture late slot
# ownership machine and the submission-hook ordering.
#
# Run from a Visual Studio x64 developer shell (cl.exe on PATH), e.g. after
#   call "...\VC\Auxiliary\Build\vcvars64.bat"
# No GPU, no game, no NVIDIA runtime.
#
# Phases:
#   1. tests/nr_late_slot_pool_smoke.cpp  - the production state machine
#      (shaders/dlssnr/DlssNr_LateSlot.h, dlssnr/DlssNr_FinishedConsumer.h) driven as a
#      four-slot pool with the production submission/consumer predicates.
#   2. the same smoke with NR_LATE_SLOT_SEED_PREV (the rejected pre-review semantics:
#      promise sets submitted/owned immediately) must break cases - failure-provable.
#   3. tests/nr_promise_hook_order_smoke.cpp - the REAL hkNrExecuteCommandLists body,
#      extracted from resource_tracking/ResTrack_dx12.cpp, proving promise ->
#      real ExecuteCommandLists -> resolution ordering.
#
# Exit codes:
#   0 = GREEN - all scenarios pass, the seed breaks cases, the hook order is proven
#   1 = a check failed, or a seed stopped breaking its cases
#   2 = the environment is broken (cl.exe missing)
# ============================================================================
$ErrorActionPreference = 'Stop'

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
{
    Write-Host 'run_nr_late_slot_pool: cl.exe is not on PATH - run from a Visual Studio x64 developer shell.'
    exit 2
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path ([IO.Path]::GetTempPath()) ('nr-late-slot-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $out | Out-Null

# Extract a production function body verbatim (the run_nr_shutdown.ps1 pattern).
function Extract($path, $signature)
{
    $source = Get-Content -LiteralPath (Join-Path $repo $path) -Raw
    $start = $source.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing production function: $signature" }
    $first = $source.IndexOf('{', $start)
    $depth = 0
    for ($p = $first; $p -lt $source.Length; $p++)
    {
        if ($source[$p] -eq '{') { $depth++ }
        if ($source[$p] -eq '}') { $depth-- }
        if (!$depth) { return $source.Substring($start, $p - $start + 1) }
    }
    throw "Unterminated production function: $signature"
}

function Invoke-Smoke([string]$source, [string[]]$defines, [string]$tag)
{
    $exe = Join-Path $out "$tag.exe"
    & cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX @defines "/I$out" "/Fo$out/" "/Fe$exe" $source | Write-Host
    if ($LASTEXITCODE)
    {
        Write-Host "nr_late_slot: $tag did not compile"
        exit 1
    }
    & $exe | Tee-Object -FilePath (Join-Path $out "$tag.txt") | Write-Host
    return $LASTEXITCODE
}

try
{
    $pool = Join-Path $PSScriptRoot 'nr_late_slot_pool_smoke.cpp'

    $green = Invoke-Smoke $pool @() 'green'
    Write-Host "nr_late_slot_pool_smoke green exit=$green"
    if ($green) { exit 1 }

    $seed = Invoke-Smoke $pool @('/DNR_LATE_SLOT_SEED_PREV') 'seed_prev'
    Write-Host "nr_late_slot_pool_smoke seed_prev exit=$seed (expected nonzero)"
    if ($seed -eq 0)
    {
        Write-Host 'seed NR_LATE_SLOT_SEED_PREV broke no case - the harness is not failure-provable'
        exit 1
    }

    # The H1 selection order has its own seed, so the two-slot regression is red for the
    # right reason (not masked by the submission seed).
    $select = Invoke-Smoke $pool @('/DNR_LATE_SLOT_SEED_SELECT_PREV') 'seed_select_prev'
    Write-Host "nr_late_slot_pool_smoke seed_select_prev exit=$select (expected nonzero)"
    if ($select -eq 0)
    {
        Write-Host 'seed NR_LATE_SLOT_SEED_SELECT_PREV broke no case - the harness is not failure-provable'
        exit 1
    }
    $selectLog = Get-Content -LiteralPath (Join-Path $out 'seed_select_prev.txt') -Raw
    foreach ($case in @('newest_unresolved_capture_is_not_replaced_by_an_older_ready_one',
                        'newer_pinned_capture_is_not_replaced_by_an_older_ready_one',
                        'pinned_only_capture_refuses_instead_of_held_edit'))
    {
        if ($selectLog -notmatch [regex]::Escape($case) + '\s+FAIL')
        {
            Write-Host "seed NR_LATE_SLOT_SEED_SELECT_PREV did not break the identity case: $case"
            exit 1
        }
    }

    $hook = Extract 'OptiScaler/resource_tracking/ResTrack_dx12.cpp' `
        'static void STDMETHODCALLTYPE hkNrExecuteCommandLists'
    Set-Content -LiteralPath (Join-Path $out 'promise_hook_order.inc') -Value $hook
    $order = Invoke-Smoke (Join-Path $PSScriptRoot 'nr_promise_hook_order_smoke.cpp') @() 'hook_order'
    Write-Host "nr_promise_hook_order_smoke exit=$order"
    if ($order) { exit 1 }

    Write-Host 'NR finished-picture late slot ownership + submission order regression passed.'
    exit 0
}
finally
{
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
