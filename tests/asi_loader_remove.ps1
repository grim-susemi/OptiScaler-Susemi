param([Parameter(Mandatory=$true)][string]$ScriptPath, [Parameter(Mandatory=$true)][string]$LoaderPath, [string]$BatPath = '')
$ErrorActionPreference = 'Stop'
$scriptFile = (Resolve-Path -LiteralPath $ScriptPath).Path
$loader = (Resolve-Path -LiteralPath $LoaderPath).Path
if ((Get-Item -LiteralPath $loader).VersionInfo.OriginalFilename -ne 'Ultimate-ASI-Loader-x64.dll') { throw 'Real bundled UAL required' }
$root = Join-Path $env:TEMP ('asi-remove-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$original = [Text.Encoding]::ASCII.GetBytes('fake third-party winmm.dll')
$passed = 0
$total = 0
try {
    foreach ($case in @('missing-file','missing-directory','valid-restore','no-backup','altered-backup','changed-target','missing-receipt','unreadable-receipt','bat-missing-backup')) {
        if ($case -eq 'bat-missing-backup' -and $BatPath -eq '') { continue }
        $total++
        $dir = Join-Path $root $case
        $backupDir = Join-Path $dir '_asi_loader_backup_fixture'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $target = Join-Path $dir 'winmm.dll'
        $receiptPath = Join-Path $dir '_asi_loader_receipt_winmm.dll.json'
        $backupFile = Join-Path $backupDir 'winmm.dll'
        [IO.File]::WriteAllBytes($backupFile, $original)
        $preSha = (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $loader -Destination $target
        $postSha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        $receipt = [ordered]@{version=1;name='winmm.dll';target=$target;preSha256=$preSha;installedSha256=$postSha;backupDir=$backupDir;installedUtc='2026-09-27T00:00:00Z';owner='asi_loader_install.ps1'}
        if ($case -eq 'no-backup') { $receipt.preSha256=$null; $receipt.backupDir='' }
        ($receipt | ConvertTo-Json) | Set-Content -LiteralPath $receiptPath -Encoding UTF8
        switch ($case) {
            'missing-file' { Remove-Item -LiteralPath $backupFile }
            'missing-directory' { Remove-Item -LiteralPath $backupDir -Recurse }
            'bat-missing-backup' { Remove-Item -LiteralPath $backupDir -Recurse }
            'altered-backup' { [IO.File]::WriteAllBytes($backupFile, [Text.Encoding]::ASCII.GetBytes('tampered original')) }
            'changed-target' { Add-Content -LiteralPath $target -Value changed }
            'missing-receipt' { Remove-Item -LiteralPath $receiptPath }
            'unreadable-receipt' { Set-Content -LiteralPath $receiptPath -Value '{bad json' }
        }
        $beforeTarget = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        $beforeReceipt = if (Test-Path -LiteralPath $receiptPath) { (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash } else { $null }
        $stdout = Join-Path $root ($case + '.stdout')
        $stderr = Join-Path $root ($case + '.stderr')
        if ($case -eq 'bat-missing-backup') {
            $batTools = Join-Path $dir 'tools'
            New-Item -ItemType Directory -Path $batTools | Out-Null
            Copy-Item -LiteralPath $BatPath -Destination (Join-Path $dir 'Install_AsiLoader_windows.bat')
            Copy-Item -LiteralPath $scriptFile -Destination (Join-Path $batTools 'asi_loader_install.ps1')
            $invocation = 'cmd.exe /d /c "' + (Join-Path $dir 'Install_AsiLoader_windows.bat') + '" remove'
            $process = Start-Process -FilePath cmd.exe -ArgumentList @('/d','/c',('"' + (Join-Path $dir 'Install_AsiLoader_windows.bat') + '" remove')) -WorkingDirectory $dir -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        } else {
            $invocation = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $scriptFile + '" -Action remove -Name winmm.dll -TargetDir "' + $dir + '"'
            $process = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptFile+'"'),'-Action','remove','-Name','winmm.dll','-TargetDir',('"'+$dir+'"')) -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        }
        $afterTarget = if (Test-Path -LiteralPath $target) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } else { $null }
        $afterReceipt = if (Test-Path -LiteralPath $receiptPath) { (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash } else { $null }
        if ($case -eq 'valid-restore') { $ok = $process.ExitCode -eq 0 -and $afterTarget -eq $preSha -and $null -eq $afterReceipt }
        elseif ($case -eq 'no-backup') { $ok = $process.ExitCode -eq 0 -and $null -eq $afterTarget -and $null -eq $afterReceipt }
        else { $ok = $process.ExitCode -ne 0 -and $afterTarget -eq $beforeTarget -and $afterReceipt -eq $beforeReceipt }
        $row = [ordered]@{case=$case;invocation=$invocation;exit=$process.ExitCode;beforeTarget=$beforeTarget;afterTarget=$afterTarget;beforeReceipt=$beforeReceipt;afterReceipt=$afterReceipt;originalSha=$preSha;pass=$ok;stdout=[IO.File]::ReadAllText($stdout);stderr=[IO.File]::ReadAllText($stderr)}
        Write-Output ($row | ConvertTo-Json -Compress)
        if ($ok) { $passed++ }
    }
    if ($passed -ne $total) { throw "Only $passed/$total cases passed" }
    Write-Output "PASS $passed/$total"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
    Write-Output ('SCRATCH_CLEAN=' + (-not (Test-Path -LiteralPath $root)))
}
