# ============================================================================
# tests/run_flavour_gate_negative.ps1 - negative proof for the package_release.ps1
# flavour gate plus its fail-closed missing-object path (H9c promotion of
# .omo/evidence/nr-xefg-088-release/18/scratch/flavour-probe.ps1).
#
# The 18/scratch harness carried a verbatim copy of the assertion, so a future edit
# to package_release.ps1 would not be caught by anything. This runner instead
# extracts the LIVE assertion block from package_release.ps1 (between the anchors)
# and executes that text against scratch copies under %TEMP%; the real tree is only
# read. If the anchors vanish the runner exits 6 until it is re-derived.
#
# Requires both flavours' built objects (a Release x64 build):
#   OptiScaler/x64/Release/menu_common.obj, OptiScaler/x64/Release-RTX40-MFG/menu_common.obj
#
# Exit codes:
#   0 = GREEN - every expectation held
#   2 = environment: script/objects missing (build Release x64 first)
#   3 = real-object marker scan was not (plain=False, mfg=True)
#   4 = mismatch case did not throw (gate not discriminating)
#   5 = control case threw (correct flavour rejected)
#   6 = extraction anchors not found / incomplete block in package_release.ps1
#   7 = missing-object case did not throw the fail-closed error
# ============================================================================
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = Join-Path $repo 'package_release.ps1'
$plainObj = Join-Path $repo 'OptiScaler/x64/Release/menu_common.obj'
$mfgObj = Join-Path $repo 'OptiScaler/x64/Release-RTX40-MFG/menu_common.obj'
foreach ($p in @($scriptPath, $plainObj, $mfgObj)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "flavour gate negative: missing $p - build Release x64 first"; exit 2 }
}

function Get-MarkerPresent([string]$path) {
    $marker = 'RTX 40 MFG unlock (restart)'
    [byte[]]$mb = [Text.Encoding]::ASCII.GetBytes($marker)
    $bytes = [IO.File]::ReadAllBytes($path)
    for ($i = 0; $i -le $bytes.Length - $mb.Length; $i++) {
        if ($bytes[$i] -ne $mb[0]) { continue }
        $ok = $true
        for ($j = 1; $j -lt $mb.Length; $j++) { if ($bytes[$i + $j] -ne $mb[$j]) { $ok = $false; break } }
        if ($ok) { return $true }
    }
    return $false
}

Write-Host 'flavour gate negative: marker scan of the real objects (read-only)'
$plainHas = Get-MarkerPresent $plainObj
$mfgHas = Get-MarkerPresent $mfgObj
Write-Host "  x64/Release/menu_common.obj           marker=$plainHas (expect False)"
Write-Host "  x64/Release-RTX40-MFG/menu_common.obj marker=$mfgHas (expect True)"
if ($plainHas -or -not $mfgHas) { Write-Host 'flavour gate negative: FAIL - real-object marker scan unexpected'; exit 3 }

# --- extract the live assertion block from package_release.ps1 (anchored) ---
$lines = [IO.File]::ReadAllText($scriptPath) -split "`r?`n"
$start = -1; $ifLine = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($start -lt 0 -and $lines[$i] -eq '# Also reject a stale/wrong-flavour DLL when using -SkipBuild.') { $start = $i; continue }
    if ($start -ge 0 -and $ifLine -lt 0 -and $lines[$i] -eq 'if ($hasUnlock -ne $EnableRtx40Mfg.IsPresent) {') { $ifLine = $i; continue }
    if ($ifLine -ge 0 -and $lines[$i] -eq '}') { $end = $i; break }
}
if ($start -lt 0 -or $ifLine -lt 0 -or $end -lt 0) {
    Write-Host 'flavour gate negative: FAIL - extraction anchors not found in package_release.ps1; re-derive this runner'
    exit 6
}
$block = $lines[$start..$end]
foreach ($needle in @("`$marker = 'RTX 40 MFG unlock (restart)'", 'Flavour mismatch: menu_common.obj RTX 40 marker=', 'Flavour-probe object not found')) {
    if (-not ($block -match [regex]::Escape($needle))) {
        Write-Host "flavour gate negative: FAIL - extracted block lacks '$needle'; re-derive this runner"
        exit 6
    }
}
$blockText = $block -join "`n"
$blockSha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($blockText))).Replace('-', '').ToLowerInvariant()
Write-Host "  extracted assertion block: lines=$($block.Count) sha256=$blockSha"
$assertion = [scriptblock]::Create($blockText)

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('flavour-gate-negative-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'OptiScaler/x64/Release') -Force | Out-Null
$code = 0
try {
    Copy-Item -LiteralPath $plainObj -Destination (Join-Path $fixture 'OptiScaler/x64/Release/menu_common.obj')
    $root = $fixture
    $buildFolder = 'x64/Release'

    Write-Host 'flavour gate negative: Case A - plain object, -EnableRtx40Mfg ON (expect THROW naming the flavour)'
    $EnableRtx40Mfg = [switch]$true
    $msg = ''; $threw = $false
    try { & $assertion } catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) { Write-Host '  FAIL - gate accepted the wrong flavour'; $code = 4 }
    elseif ($msg -notmatch 'Flavour mismatch: menu_common\.obj RTX 40 marker=False but -EnableRtx40Mfg=True') { Write-Host "  FAIL - threw without the expected discriminator: $msg"; $code = 4 }
    else { Write-Host "  PASS - threw: $msg" }

    if ($code -eq 0) {
        Write-Host 'flavour gate negative: Case B - plain object, -EnableRtx40Mfg OFF (control, expect accept)'
        $EnableRtx40Mfg = [switch]$false
        $threw = $false
        try { & $assertion } catch { $threw = $true; $msg = $_.Exception.Message }
        if ($threw) { Write-Host "  FAIL - control rejected the correct flavour: $msg"; $code = 5 }
        else { Write-Host '  PASS - correct flavour accepted' }
    }

    if ($code -eq 0) {
        Write-Host 'flavour gate negative: Case C - object removed (expect fail-closed throw, -SkipBuild cannot package)'
        Remove-Item -LiteralPath (Join-Path $fixture 'OptiScaler/x64/Release/menu_common.obj') -Force
        $threw = $false
        try { & $assertion } catch { $threw = $true; $msg = $_.Exception.Message }
        if (-not $threw) { Write-Host '  FAIL - missing object did not fail closed'; $code = 7 }
        elseif ($msg -notmatch [regex]::Escape('Flavour-probe object not found')) { Write-Host "  FAIL - threw without the expected message: $msg"; $code = 7 }
        else { Write-Host "  PASS - threw: $msg" }
    }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

if ($code -ne 0) { Write-Host "flavour gate negative: FAIL (exit $code)"; exit $code }
Write-Host 'flavour gate negative: GREEN - mismatch refused, control accepted, missing object refused, live block exercised'
exit 0
