# Package OptiScaler and its ordinary dependencies, including the built-in NR backend.
# NVIDIA model/FG runtimes and unrelated optional payloads are never collected from build folders.
# T5 A-only: the RTX 20/30 (SM75/SM86) MFG payload is never shipped - -IncludeAmpereMfg is refused
# with or without -AcceptAmpereMfgLicenses. The staged UAL binary is verified against the official
# v9.7.4 inner pin before staging (see tools/Install-PinnedUAL.ps1).
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Version = 'nr-dev',
    [switch]$SkipBuild,
    [switch]$EnableRtx40Mfg,
    [switch]$IncludeAmpereMfg,
    [switch]$AcceptAmpereMfgLicenses
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
# T23 rc2 guard: -Version v11.2-rc2 is never packaged by this ordinary script. The approved
# rc2 candidate is the byte-pinned repack of the published rc1 ZIP produced by the tracked
# recipe tools/repack_rc2.py (output OptiScaler-NR-v11.2-rc2.zip, sha256 42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a).
# Refuse before the -SkipBuild/-IncludeAmpereMfg gates, the pinned-loader check, any build and
# any staging so no same-name rc2 output can exist; every other -Version keeps the prior
# behavior below unchanged.
if ($Version -eq 'v11.2-rc2') {
    throw 'Refusing: -Version v11.2-rc2 must not be packaged by this ordinary script; the rc2 candidate is reproduced by the pinned repack recipe tools/repack_rc2.py. No output was staged.'
}
# Repair-r2 (B1): -SkipBuild is rejected unconditionally for release packaging. A timestamp
# check cannot prove the DLL was linked from current source (equal timestamps admit
# source-stale or substituted binaries), so no -SkipBuild invocation may stage a ZIP.
# T10 clean rebuilds never pass -SkipBuild and are unaffected.
if ($SkipBuild) {
    throw 'Refusing: -SkipBuild is not allowed for release packaging. Rebuild from current source without -SkipBuild so the staged DLL is proven fresh; no output was staged.'
}
# T5 A-only gate: the RTX 20/30 (SM75/SM86) MFG payload variant is not distributed from this
# worktree - no affirmative redistribution rights were found (vendor/dlssg_sm86/THIRD_PARTY_NOTICES.txt,
# docs/rtx2030-payload-contract.md). Refuse with or without -AcceptAmpereMfgLicenses, before the
# output-exists guard and before staging, so no B output is ever staged. vendor/dlssg_sm86/PIN.json
# stays as historical hash information only.
if ($IncludeAmpereMfg) {
    throw 'Refusing: the RTX 20/30 (SM75/SM86) MFG payload variant is not shipped (no redistribution rights). -IncludeAmpereMfg is rejected with or without -AcceptAmpereMfgLicenses; no B output was staged.'
}
# T5 pinned-loader gate: the staged UAL binary must be the independently verified official v9.7.4
# inner dinput8.dll (fetched via tools/Install-PinnedUAL.ps1, which checks the outer ZIP pin first).
# Refuse a missing or tampered loader before staging.
$UalInnerSha256 = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$ualPath = Join-Path $root 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
if (-not (Test-Path -LiteralPath $ualPath -PathType Leaf)) {
    throw "Pinned UAL is missing: $ualPath. Run tools/Install-PinnedUAL.ps1 to fetch and verify it."
}
$ualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ualPath).Hash.ToLowerInvariant()
if ($ualHash -ne $UalInnerSha256) {
    throw "Pinned UAL mismatch: $ualPath sha256=$ualHash, expected $UalInnerSha256. Refusing before staging."
}
$stage = Join-Path $root "release/$Version"
$zip = Join-Path $root "release/OptiScaler-NR-$Version.zip"
if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $zip)) {
    throw 'Release output already exists. Choose a new -Version; existing packages are not overwritten.'
}

if (-not $SkipBuild) {
    $msbuild = (Get-Command MSBuild.exe -ErrorAction SilentlyContinue).Source
    if (-not $msbuild) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild/Current/Bin/MSBuild.exe'
        }
    }
    if (-not $msbuild) { throw 'MSBuild.exe was not found. Use a Visual Studio developer PowerShell.' }
    & $msbuild (Join-Path $root 'OptiScaler.sln') /p:Configuration=Release /p:Platform=x64 /p:PostBuildEventUseInBuild=false "/p:OptiScalerRtx40Mfg=$($EnableRtx40Mfg.IsPresent.ToString().ToLowerInvariant())" /v:minimal /m
    if ($LASTEXITCODE -ne 0) { throw 'OptiScaler build failed.' }
}

$buildFolder = if ($EnableRtx40Mfg) { 'x64/Release-RTX40-MFG' } else { 'x64/Release' }
$buildRoot = Join-Path $root $buildFolder
# Also reject a stale/wrong-flavour DLL when using -SkipBuild.
# Object-level assertion: menu_common.obj is flavour-bound (the #if defined(OPTISCALER_RTX40_MFG)
# guard controls the 'RTX 40 MFG unlock (restart)' string).  The KO catalog embeds the same string
# via Localization.obj in BOTH flavours, so a raw-DLL probe cannot discriminate (known defect).
$objPath = Join-Path $root "OptiScaler/$buildFolder/menu_common.obj"
if (-not (Test-Path -LiteralPath $objPath)) { throw "Flavour-probe object not found: $objPath" }
$objBytes = [IO.File]::ReadAllBytes($objPath)
$marker = 'RTX 40 MFG unlock (restart)'
[byte[]]$mb = [Text.Encoding]::ASCII.GetBytes($marker)
$hasUnlock = $false
for ($i = 0; $i -le $objBytes.Length - $mb.Length; $i++) {
    if ($objBytes[$i] -ne $mb[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt $mb.Length; $j++) { if ($objBytes[$i + $j] -ne $mb[$j]) { $ok = $false; break } }
    if ($ok) { $hasUnlock = $true; break }
}
if ($hasUnlock -ne $EnableRtx40Mfg.IsPresent) {
    throw "Flavour mismatch: menu_common.obj RTX 40 marker=$hasUnlock but -EnableRtx40Mfg=$($EnableRtx40Mfg.IsPresent). Rebuild with the correct build configuration."
}
# Report-only stale-pair diagnostics (followups plan T4/H9b). The flavour assertion above cannot
# distinguish a stale DLL from a fresh object (18/RECEIPT-todo18.md risks). Prints a warning when
# the DLL predates the flavour-probe object it was linked from, including the mtime/SHA256
# pairing of both files. Warnings only by design - a fail gate needs separate F2 approval;
# this block never throws.
function Write-StalePairReport {
    param([string]$ObjectPath, [string]$DllPath)
    try {
        $objItem = Get-Item -LiteralPath $ObjectPath -ErrorAction Stop
        $dllItem = Get-Item -LiteralPath $DllPath -ErrorAction Stop
        if ($dllItem.LastWriteTimeUtc -lt $objItem.LastWriteTimeUtc) {
            $objHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ObjectPath).Hash
            $dllHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DllPath).Hash
            Write-Warning ("Stale-pair candidate: the DLL (mtime={0:o}, sha256={1}) predates the flavour-probe object (mtime={2:o}, sha256={3}). If the object was rebuilt without re-linking the DLL, the DLL may be stale. Report-only, packaging continues." -f $dllItem.LastWriteTimeUtc, $dllHash, $objItem.LastWriteTimeUtc, $objHash)
        }
    } catch {
        Write-Warning ("Pairing report failed: {0} Report-only, packaging continues." -f $_.Exception.Message)
    }
}
Write-StalePairReport -ObjectPath $objPath -DllPath (Join-Path $buildRoot 'OptiScaler.dll')
# Validate every source before creating the staging tree. An explicit manifest prevents stale
# Streamline/MFG, removed NR helpers or discarded experiment files entering this package.
$files = @{}
# T9 (owner-ordered slim package, 2026-09-23): the 16 dead files removed from this manifest
# are recorded in .omo/evidence/nr-xefg-followups/09/RECEIPT-todo09.md (16 drops, 0 adds).
$files['OptiScaler.dll'] = Join-Path $buildRoot 'OptiScaler.dll'
$files['docs/RELEASE-v0.8.8.md'] = Join-Path $root 'docs/RELEASE-v0.8.8.md'
# H10 (owner decision, followups plan T4): the r3 Korean release note ships inside the zip.
# T3 load-order doc ships byte-equal inside the ZIP (T5).
$files['docs/RELEASE-NOTES-r3-KO.md'] = Join-Path $root 'docs/RELEASE-NOTES-r3-KO.md'
$files['docs/RELEASE-v11.2-rc1.md'] = Join-Path $root 'docs/RELEASE-v11.2-rc1.md'
$files['docs/XEFG-NR-RESHADE-LOAD-ORDER.md'] = Join-Path $root 'docs/XEFG-NR-RESHADE-LOAD-ORDER.md'
foreach ($name in @('OptiScaler.ini', 'setup_windows.bat', 'setup_linux.sh', 'Streamline_fetcher_windows.bat', 'Install_AsiLoader_windows.bat', 'README.md', 'INSTALL-KO.md', 'INSTALL-DLSSNR.md', 'LICENSE',
                    'Features.md', 'Config.md', 'Spoofing.md',
                    'CONTRIBUTING.md', 'OptiScaler/dlssnr/README.md')) {
    $files[$name] = Join-Path $root $name
}
$files['tools/Get-StreamlineRuntime.ps1'] = Join-Path $root 'tools/Get-StreamlineRuntime.ps1'
$files['tools/asi_loader_install.ps1'] = Join-Path $root 'tools/asi_loader_install.ps1'
$files['tools/asi-loader/Ultimate-ASI-Loader-x64.dll'] = Join-Path $root 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
$files['tools/asi-loader/LICENSE_Ultimate_ASI_Loader.txt'] = Join-Path $root 'tools/asi-loader/LICENSE_Ultimate_ASI_Loader.txt'
foreach ($name in @('libxess.dll', 'libxess_dx11.dll', 'libxell.dll', 'libxess_fg.dll')) {
    $files["OptiScaler/$name"] = Join-Path $root "external/xess/bin/$name"
}
$files['OptiScaler/amd_fidelityfx_vk.dll'] = Join-Path $root 'external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll'
foreach ($name in @('amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll', 'amd_fidelityfx_framegeneration_dx12.dll')) {
    $files["OptiScaler/$name"] = Join-Path $root "external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/$name"
}
$files['OptiScaler/D3D12_OptiScaler/D3D12Core.dll'] = Join-Path $root 'external/directx_agility_sdk/lib/D3D12Core.dll'
$files['Licenses/XeSS_LICENSE.txt'] = Join-Path $root 'external/xess/LICENSE.txt'
$files['Licenses/FidelityFX_v1_LICENSE.md'] = Join-Path $root 'external/FidelityFX-SDK/docs/license.md'
$files['Licenses/FidelityFX_v2_LICENSE.md'] = Join-Path $root 'external/FidelityFX-SDK-v2/docs/license.md'
$files['Licenses/DirectX_LICENSE.txt'] = Join-Path $root 'external/directx_agility_sdk/LICENSE.txt'
$files['Licenses/RenoDX_ATTRIBUTION.txt'] = Join-Path $root 'Licenses/RenoDX_ATTRIBUTION.txt'
if ($EnableRtx40Mfg) {
    $files['Licenses/MFGUnlock_LICENSE.txt'] = Join-Path $root 'Licenses/MFGUnlock_LICENSE.txt'
}
# A-only: no SM75/SM86 payload members are ever staged (see the -IncludeAmpereMfg refusal above).
foreach ($name in @('CREDITS.md', 'NR-COMPATIBILITY.md', 'NR-MOTION-METADATA.md', 'NR-PIPELINE-UI.md', 'NR-FINISHED-BRIDGES.md',
                    'DEFERRED-NR-DLSS.md',
                    'NR-DLSS-ENLARGEMENT.md', 'NR-GPU-RETIREMENT.md', 'NR-NATIVE-STREAMLINE-PRESENT.md',
                    'NR-VULKAN.md', 'NR-PHOTO-DIAGNOSTIC.md',
                    'RTX40-MFG.md', 'NR-INITIALIZATION-DIAGNOSTICS.md', 'NR-DIRECT-RUNTIME.md')) {
    $files["docs/$name"] = Join-Path $root "docs/$name"
}
foreach ($entry in $files.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Required release file is missing: $($entry.Value)"
    }
}

$ini = Get-Content -LiteralPath $files['OptiScaler.ini'] -Raw
if ($ini -match '(?mi)^Enabled=true\s*$') { throw 'A feature is enabled in the default INI.' }
foreach ($key in @('FinishedPicture', 'DeferredDLSS', 'UnlockPasses', 'AdaMfgUnlock', 'AdaFlipMeteringPatch', 'AmpereMfgUnlock', 'UnlockMFG')) {
    if ($ini -match "(?mi)^$key=true\s*$") { throw "Experimental option $key is enabled in the default INI." }
}
if ($ini -notmatch '(?mi)^TargetProcessName=auto\s*$') { throw 'The INI contains a game-specific process filter.' }

New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($entry in $files.GetEnumerator()) {
    $destination = Join-Path $stage $entry.Key
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $entry.Value -Destination $destination
}
if (-not $EnableRtx40Mfg) {
    $ini = $ini -replace '(?m)^; Experimental built-in RTX 40 MFG unlock[^\r\n]*\r?\n', ''
    $ini = $ini -replace '(?m)^AdaMfgUnlock=[^\r\n]*\r?\n', ''
    $ini = $ini -replace '(?ms)^; Frame timing fix for the extra frames.*?^AdaFlipMeteringPatch=[^\r\n]*\r?\n', ''
    [IO.File]::WriteAllText((Join-Path $stage 'OptiScaler.ini'), $ini, [Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText((Join-Path $stage '!! EXTRACT ALL FILES TO GAME FOLDER !!'), '')

$checksums = Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($stage.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
    '{0} *{1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash, $relative
}
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'), $checksums, [Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Build the archive with explicit forward-slash entry names: the .NET Framework helpers
# write backslashes on Windows, which does not match the wil/zip convention.
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $stagePrefix = $stage.TrimEnd('\', '/')
    foreach ($file in (Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName)) {
        $relName = $file.FullName.Substring($stagePrefix.Length).TrimStart('\', '/').Replace('\', '/')
        $entry = $archive.CreateEntry($relName, [IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        $fileStream = [IO.File]::OpenRead($file.FullName)
        try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose(); $entryStream.Dispose() }
    }
} finally { $archive.Dispose() }
Write-Output "Created $zip"
