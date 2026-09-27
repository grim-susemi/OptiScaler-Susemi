<#
    T5 pinned-loader helper: fetch the official Ultimate ASI Loader (UAL) v9.7.4
    x64 ZIP, verify it twice, and stage the approved filename - or refuse.

    - Outer ZIP must come from the exact release-tag URL and match the pinned
      outer SHA-256 before anything is extracted.
    - The inner dinput8.dll must independently match the pinned inner SHA-256
      before it is staged as tools/asi-loader/Ultimate-ASI-Loader-x64.dll.
    - Any mismatch throws BEFORE staging; the previous staged file (if any) is
      left untouched and no partial output remains.
    - -CheckOnly verifies the already-staged file against the inner pin without
      touching the network.

    Exit: 0 on verified stage/check; nonzero (throw) on any mismatch or fetch
    failure. No B payload, NVIDIA runtime, or game-folder work happens here.
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

$UalUrl = 'https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/download/v9.7.4/Ultimate-ASI-Loader_x64.zip'
$UalOuterSha256 = '8272d83b2692662098746f2d0ad0e2d85f3c8358ab1d63f75fbe835c2c8135fd'
$UalInnerName = 'dinput8.dll'
$UalInnerSha256 = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'

if (-not $Destination) {
    $Destination = Join-Path (Split-Path -Parent $PSCommandPath) 'asi-loader/Ultimate-ASI-Loader-x64.dll'
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

if ($CheckOnly) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Pinned UAL is missing: $Destination. Run tools/Install-PinnedUAL.ps1 to fetch and verify it."
    }
    $actual = Get-Sha256 $Destination
    if ($actual -ne $UalInnerSha256) {
        throw "Pinned UAL mismatch: $Destination sha256=$actual, expected inner pin $UalInnerSha256. Refusing; delete the file and re-run tools/Install-PinnedUAL.ps1."
    }
    Write-Output "Pinned UAL verified: $Destination sha256=$actual"
    exit 0
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ual-pin-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $zipPath = Join-Path $tmp 'Ultimate-ASI-Loader_x64.zip'
    Write-Output "Downloading $UalUrl"
    Invoke-WebRequest -Uri $UalUrl -OutFile $zipPath -UseBasicParsing
    $outer = Get-Sha256 $zipPath
    Write-Output "Outer ZIP sha256=$outer"
    if ($outer -ne $UalOuterSha256) {
        throw "UAL outer ZIP mismatch: observed $outer, expected $UalOuterSha256. Refusing before extract/stage."
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.Name -eq $UalInnerName } | Select-Object -First 1
        if (-not $entry) {
            throw "UAL ZIP has no $UalInnerName entry. Refusing before stage."
        }
        $innerPath = Join-Path $tmp $UalInnerName
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $innerPath, $false)
    } finally { $archive.Dispose() }
    $inner = Get-Sha256 $innerPath
    Write-Output "Inner $UalInnerName sha256=$inner"
    if ($inner -ne $UalInnerSha256) {
        throw "UAL inner DLL mismatch: observed $inner, expected $UalInnerSha256. Refusing before stage."
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $innerPath -Destination $Destination -Force
    Write-Output "Staged pinned UAL: $Destination sha256=$inner"
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
