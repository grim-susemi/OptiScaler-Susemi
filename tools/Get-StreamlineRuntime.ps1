<#
.SYNOPSIS
  Fetch the NVIDIA Streamline runtime DLLs into the folder OptiScaler loads them from.
.DESCRIPTION
  Downloads the official Streamline SDK release from NVIDIA-RTX/Streamline (GitHub),
  verifies the archive digest, extracts bin/x64/*.dll and copies them into
  <game>\OptiScaler\streamline (the hardcoded folder OptiScaler reads), then records a
  SOURCES.json manifest with per-file hashes and Authenticode status.
  No NVIDIA binaries are redistributed: everything is fetched from NVIDIA at run time.
.PARAMETER Action
  latest | version | verify | remove
.PARAMETER Version
  Tag for -Action version, e.g. v2.14.1
.PARAMETER Destination
  Explicit destination folder. Defaults to <package root>\OptiScaler\streamline when the
  OptiScaler folder exists, otherwise <package root>\streamline.
#>
[CmdletBinding()]
param(
    [ValidateSet('latest','version','verify','remove')]
    [string]$Action = 'latest',
    [string]$Version = '',
    [string]$Destination = ''
)

$ErrorActionPreference = 'Stop'
$repo = 'NVIDIA-RTX/Streamline'
$manifestName = 'SOURCES.json'

function Write-Info([string]$m) { Write-Host $m }
function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$root = Split-Path -Parent $PSScriptRoot
if ($Destination -ne '') {
    $dest = $Destination
} elseif (Test-Path -LiteralPath (Join-Path $root 'OptiScaler')) {
    $dest = Join-Path $root 'OptiScaler\streamline'
} else {
    $dest = Join-Path $root 'streamline'
}
$manifestPath = Join-Path $dest $manifestName

function Get-Release([string]$tag) {
    $uri = if ($tag -eq '') { "https://api.github.com/repos/$repo/releases/latest" } else { "https://api.github.com/repos/$repo/releases/tags/$tag" }
    $headers = @{ 'User-Agent' = 'optiscaler-streamline-fetcher'; 'Accept' = 'application/vnd.github+json' }
    Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
}

function Select-ZipAsset($release) {
    $asset = $release.assets | Where-Object { $_.name -match '^streamline-sdk-v[0-9.]+\.zip$' } | Select-Object -First 1
    if (-not $asset) { Fail 'No streamline-sdk zip asset found in the release.' }
    $asset
}

function Download-File([string]$url, [string]$path) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --silent --show-error -o $path $url
        if ($LASTEXITCODE -ne 0) { Fail 'Download failed (curl).' }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    }
}

function Install-Runtime([string]$tag) {
    $release = Get-Release $tag
    $asset = Select-ZipAsset $release
    $expected = $null
    if ($asset.digest -and $asset.digest -like 'sha256:*') { $expected = $asset.digest.Substring(7).ToLowerInvariant() }

    $work = Join-Path $env:TEMP ('streamline_fetch_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $work | Out-Null
    $zip = Join-Path $work $asset.name
    try {
        Write-Info ("Downloading {0} ({1:N0} bytes)" -f $asset.name, $asset.size)
        Download-File $asset.browser_download_url $zip

        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Info ("Archive sha256 {0}" -f $hash)
        if ($expected) {
            if ($hash -ne $expected) { Fail 'Archive digest does not match the GitHub release digest.' }
            Write-Info 'Archive digest matches the release digest.'
        } else {
            Write-Info 'Release did not expose an asset digest; recorded hash for the manifest.'
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $zip).Path)
        try {
            $entries = @($zipFile.Entries | Where-Object { $_.FullName -match '^bin/x64/[^/]+\.dll$' })
            if ($entries.Count -eq 0) { Fail 'No bin/x64/*.dll entries found inside the Streamline archive.' }

            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $files = @{}
            foreach ($e in $entries) {
                $target = Join-Path $dest $e.Name
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                $sig = (Get-AuthenticodeSignature -LiteralPath $target).Status.ToString()
                $h = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                $files[$e.Name] = [ordered]@{ sha256 = $h; bytes = $e.Length; signature = $sig }
                $mark = if ($sig -eq 'Valid') { '' } else { ' (signature: ' + $sig + ')' }
                Write-Info ("  + {0}{1}" -f $e.Name, $mark)
            }
        } finally {
            $zipFile.Dispose()
        }

        $required = @('sl.interposer.dll','sl.common.dll','nvngx_dlssg.dll')
        $missing = $required | Where-Object { -not $files.ContainsKey($_) }
        if ($missing) { Write-Host ('WARNING: missing expected file(s): ' + ($missing -join ', ')) -ForegroundColor Yellow }

        $manifest = [ordered]@{
            source = "https://github.com/$repo"
            tag = $release.tag_name
            asset = $asset.name
            asset_sha256 = $hash
            fetched_utc = (Get-Date).ToUniversalTime().ToString('o')
            destination = $dest
            files = $files
        }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Write-Info ("Installed {0} file(s) to {1}" -f $files.Count, $dest)
        Write-Info ("Manifest: {0}" -f $manifestPath)
        Write-Info 'Done.'
        exit 0
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Verify-Runtime {
    if (-not (Test-Path -LiteralPath $manifestPath)) { Fail 'No SOURCES.json manifest found; nothing recorded to verify.' }
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $bad = 0
    foreach ($name in $m.files.PSObject.Properties.Name) {
        $path = Join-Path $dest $name
        if (-not (Test-Path -LiteralPath $path)) { Write-Host ("  MISSING {0}" -f $name) -ForegroundColor Red; $bad++; continue }
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $sig = (Get-AuthenticodeSignature -LiteralPath $path).Status.ToString()
        if ($h -ne $m.files.$name.sha256) { Write-Host ("  CHANGED {0}" -f $name) -ForegroundColor Red; $bad++ }
        elseif ($sig -eq 'Valid') { Write-Info ("  ok {0}" -f $name) }
        else { Write-Host ("  ok(hash) {0} signature={1}" -f $name, $sig) -ForegroundColor Yellow }
    }
    if ($bad -gt 0) { Fail "$bad file(s) failed verification." }
    Write-Info 'All recorded files verified.'
    exit 0
}

function Remove-Runtime {
    if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Info 'No SOURCES.json manifest found; nothing to remove.'; exit 0 }
    $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($name in $m.files.PSObject.Properties.Name) {
        $path = Join-Path $dest $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Info ("  removed {0}" -f $name) }
    }
    Remove-Item -LiteralPath $manifestPath -Force
    Write-Info 'Removed the files recorded in the manifest.'
    exit 0
}

switch ($Action) {
    'latest'  { Install-Runtime '' }
    'version' { if ($Version -eq '') { Fail 'Provide -Version for -Action version.' }; $tag = if ($Version -like 'v*') { $Version } else { 'v' + $Version }; Install-Runtime $tag }
    'verify'  { Verify-Runtime }
    'remove'  { Remove-Runtime }
}
