<#
.SYNOPSIS
  Install, check or remove the Ultimate ASI Loader bundled with this package.
.DESCRIPTION
  The ASI install method needs a loader: OptiScaler.asi (and every other .asi mod)
  is only loaded when an ASI loader such as winmm.dll sits next to the game exe.
  This package carries the MIT-licensed Ultimate ASI Loader v9.7.4 unchanged.
.PARAMETER Action
  install | check | remove
.PARAMETER Name
  Proxy name for the loader, for example winmm.dll (default).
.PARAMETER Force
  Replace an existing non-loader file after backing it up, without prompting.
.PARAMETER TargetDir
  Game folder; defaults to the parent of this script's folder.
#>
[CmdletBinding()]
param(
    [ValidateSet('install','check','remove')]
    [string]$Action = 'check',
    [string]$Name = 'winmm.dll',
    [switch]$Force,
    [string]$TargetDir = ''
)

$ErrorActionPreference = 'Stop'
function Info([string]$m) { Write-Host $m }
function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$root = if ($TargetDir -ne '') { $TargetDir } else { Split-Path -Parent $PSScriptRoot }
$source = Join-Path $PSScriptRoot 'asi-loader\Ultimate-ASI-Loader-x64.dll'
$licenseSource = Join-Path $PSScriptRoot 'asi-loader\LICENSE_Ultimate_ASI_Loader.txt'
$licenseName = 'LICENSE_Ultimate_ASI_Loader.txt'
$candidates = @('winmm.dll','dinput8.dll','version.dll','dsound.dll','dbghelp.dll','d3d12.dll','wininet.dll','winhttp.dll')

function Test-Loader([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return ((Get-Item -LiteralPath $path).VersionInfo.OriginalFilename -eq 'Ultimate-ASI-Loader-x64.dll')
}

function Show-Check {
    $found = @()
    foreach ($c in $candidates) { if (Test-Loader (Join-Path $root $c)) { $found += $c } }
    if ($found.Count -gt 0) { Info ('ASI loader present: ' + ($found -join ', ')) }
    else { Info 'No ASI loader found in the game folder.' }
}

switch ($Action) {
    'check' { Show-Check; exit 0 }
    'install' {
        if (-not (Test-Path -LiteralPath $source)) { Fail 'Bundled loader is missing: tools\asi-loader\Ultimate-ASI-Loader-x64.dll' }
        $target = Join-Path $root $Name
        if (Test-Loader $target) {
            Info ('The ASI loader is already installed as ' + $Name + '.')
        } else {
            if (Test-Path -LiteralPath $target) {
                if (-not $Force) {
                    Write-Host ($Name + ' already exists and is not the ASI loader.') -ForegroundColor Yellow
                    $answer = Read-Host 'Back it up and replace it? (y/N)'
                    if ($answer -notmatch '^(?i)y') { Fail 'Aborted; nothing was changed.' }
                }
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backup = Join-Path $root ('_asi_loader_backup_' + $stamp)
                New-Item -ItemType Directory -Path $backup | Out-Null
                Copy-Item -LiteralPath $target -Destination (Join-Path $backup $Name) -Force
                Info ('Backed up the existing file to ' + $backup)
            }
            Copy-Item -LiteralPath $source -Destination $target -Force
            Info ('Installed the ASI loader as ' + $Name)
        }
        if ((Test-Path -LiteralPath $licenseSource) -and -not (Test-Path -LiteralPath (Join-Path $root $licenseName))) {
            Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $root $licenseName) -Force
            Info ('Copied ' + $licenseName)
        }
        Info ('sha256 ' + (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)
        Show-Check
        Info 'Next: run setup_windows.bat and choose [8] OptiScaler.asi, then start the game.'
        exit 0
    }
    'remove' {
        $target = Join-Path $root $Name
        if (-not (Test-Loader $target)) { Info ('No bundled ASI loader found as ' + $Name + '.'); exit 0 }
        $restored = $false
        $backups = Get-ChildItem -LiteralPath $root -Directory -Filter '_asi_loader_backup_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($b in $backups) {
            $candidate = Join-Path $b.FullName $Name
            if (Test-Path -LiteralPath $candidate) { Copy-Item -LiteralPath $candidate -Destination $target -Force; Info ('Restored the previous ' + $Name + ' from ' + $b.FullName); $restored = $true; break }
        }
        if (-not $restored) { Remove-Item -LiteralPath $target -Force; Info ('Removed ' + $Name) }
        exit 0
    }
}
