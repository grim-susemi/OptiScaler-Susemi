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

function Get-FileSha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Get-ReceiptPath([string]$dir, [string]$name) {
    return (Join-Path $dir ('_asi_loader_receipt_' + $name + '.json'))
}

function Write-InstallReceipt([string]$receiptPath, [string]$targetPath, [string]$name, [string]$preSha, [string]$postSha, [string]$backupDir) {
    $receipt = [ordered]@{
        version = 1
        name = $name
        target = $targetPath
        preSha256 = $preSha
        installedSha256 = $postSha
        backupDir = $backupDir
        installedUtc = (Get-Date).ToUniversalTime().ToString('o')
        owner = 'asi_loader_install.ps1'
    }
    ($receipt | ConvertTo-Json) | Set-Content -LiteralPath $receiptPath -Encoding UTF8
}

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
        $receiptPath = Get-ReceiptPath $root $Name
        if (Test-Loader $target) {
            Info ('The ASI loader is already installed as ' + $Name + '.')
        } else {
            $preSha = $null
            $backup = ''
            if (Test-Path -LiteralPath $target) {
                if (-not $Force) {
                    Write-Host ($Name + ' already exists and is not the ASI loader.') -ForegroundColor Yellow
                    $answer = Read-Host 'Back it up and replace it? (y/N)'
                    if (($null -eq $answer) -or ($answer -notmatch '^(?i)y')) { Fail 'Aborted; nothing was changed.' }
                }
                $preSha = Get-FileSha256 $target
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backup = Join-Path $root ('_asi_loader_backup_' + $stamp)
                New-Item -ItemType Directory -Path $backup | Out-Null
                Copy-Item -LiteralPath $target -Destination (Join-Path $backup $Name) -Force
                Info ('Backed up the existing file to ' + $backup)
            }
            Copy-Item -LiteralPath $source -Destination $target -Force
            $postSha = Get-FileSha256 $target
            $sourceSha = Get-FileSha256 $source
            if ($postSha -ne $sourceSha) { Fail 'Install verification failed: installed file hash differs from the bundled loader.' }
            Write-InstallReceipt $receiptPath $target $Name $preSha $postSha $backup
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
        $receiptPath = Get-ReceiptPath $root $Name
        $hasReceipt = Test-Path -LiteralPath $receiptPath
        if (-not (Test-Loader $target)) {
            if (-not $hasReceipt) { Info ('No bundled ASI loader found as ' + $Name + '.'); exit 0 }
            Fail ('Refusing to remove ' + $Name + ': installed file was replaced or deleted after install. Nothing was changed.')
        }
        if (-not $hasReceipt) { Fail ('Refusing to remove ' + $Name + ': no installer receipt, so this file was not installed by this tool. Bytes preserved.') }
        try { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
        catch { Fail ('Refusing to remove ' + $Name + ': installer receipt is unreadable. Bytes preserved.') }
        $currentSha = Get-FileSha256 $target
        if (($receipt.target -ne $target) -or ($receipt.installedSha256 -ne $currentSha)) { Fail ('Refusing to remove ' + $Name + ': file changed since install or was installed elsewhere. Bytes preserved.') }
        $restored = $false
        if (($null -ne $receipt.backupDir) -and ($receipt.backupDir -ne '')) {
            $backupFile = Join-Path $receipt.backupDir $Name
            if (Test-Path -LiteralPath $backupFile) {
                $backupSha = Get-FileSha256 $backupFile
                if (($null -ne $receipt.preSha256) -and ($receipt.preSha256 -ne '') -and ($backupSha -ne $receipt.preSha256)) { Fail ('Refusing to restore ' + $Name + ': backup hash differs from the pre-install receipt. Installed file left unchanged.') }
                Copy-Item -LiteralPath $backupFile -Destination $target -Force
                $restoredSha = Get-FileSha256 $target
                if (($null -ne $receipt.preSha256) -and ($receipt.preSha256 -ne '') -and ($restoredSha -ne $receipt.preSha256)) { Fail ('Restore verification failed: restored file hash differs from the pre-install backup.') }
                Info ('Restored the previous ' + $Name + ' from ' + $receipt.backupDir)
                $restored = $true
            } else {
                Fail ('Refusing to remove ' + $Name + ': receipt backup is missing (' + $receipt.backupDir + '). Installed file and receipt preserved.')
            }
        }
        if (-not $restored) { Remove-Item -LiteralPath $target -Force; Info ('Removed ' + $Name) }
        Remove-Item -LiteralPath $receiptPath -Force
        exit 0
    }
}
