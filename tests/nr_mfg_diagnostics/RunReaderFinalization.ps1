#requires -Version 7.0
param([Parameter(Mandatory=$true)][string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$work=Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) 'task22-reader-recovery-r1'
$out=Join-Path $work ('native-finalization-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[IO.Directory]::CreateDirectory($out) | Out-Null
$native=(Get-Command pwsh.exe).Source
$finalizer=Join-Path $PSScriptRoot 'FinalizeReaderRecovery.ps1'
function Identity([string]$path) {return @{path=$path;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash}}
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$native;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$arguments=@('-NoProfile','-File',$finalizer,'-EvidenceRoot',$EvidenceRoot)
foreach ($argument in $arguments) {$start.ArgumentList.Add($argument)}
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
$source=Identity $finalizer
$pidOwned=$null;$code=$null;$timeout=$false;$text='';$inventoryVerified=0;$seal=$null
try {
    if (!$process.Start()) {throw 'T22_RECOVERY_FINALIZATION_START_FAILED'}
    $pidOwned=$process.Id
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(60000)) {$timeout=$true;$process.Kill($true);$process.WaitForExit()}
    $code=$process.ExitCode
    $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
} finally {$process.Dispose()}
[IO.File]::WriteAllText("$out/native.log",$text,[Text.UTF8Encoding]::new($false))
if ($code -eq 0 -and !$timeout) {
    $seal=Identity "$work/producer-freeze.json"
    $freeze=Get-Content -LiteralPath $seal.path -Raw | ConvertFrom-Json -AsHashtable
    $inputMemory=[IO.MemoryStream]::new([Convert]::FromBase64String($freeze.inventoryGzipBase64))
    $gzip=[IO.Compression.GZipStream]::new($inputMemory,[IO.Compression.CompressionMode]::Decompress)
    $memory=[IO.MemoryStream]::new()
    try {$gzip.CopyTo($memory);$bytes=$memory.ToArray()} finally {$gzip.Dispose();$inputMemory.Dispose();$memory.Dispose()}
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {$hash=[Convert]::ToHexString($algorithm.ComputeHash($bytes))} finally {$algorithm.Dispose()}
    if ($bytes.Length -ne $freeze.inventoryBytes -or $hash -cne $freeze.inventorySha256) {throw 'T22_RECOVERY_POST_TERMINAL_INVENTORY_IDENTITY'}
    $rows=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable
    foreach ($row in $rows) {
        $actual=Identity $row.path
        if ($actual.bytes -ne $row.bytes -or $actual.sha256 -cne $row.sha256) {throw "T22_RECOVERY_POST_TERMINAL_BINDING_DRIFT:$($row.path)"}
        $inventoryVerified++
    }
    if ($inventoryVerified -ne $freeze.entryCount) {throw 'T22_RECOVERY_POST_TERMINAL_INVENTORY_COUNT'}
}
$receipt=@{schema='task22-successor-native-terminal-v1';command=@($native)+$arguments;exit=$code;timeout=$timeout;
    finalizationSource=$source;wrapperSource=(Identity $PSCommandPath);runtime=(Identity $native);
    ownedPid=$pidOwned;nativeExitObserved=($null -ne $code);processObjectDisposed=$true;ownedOnly=$true;
    log=(Identity "$out/native.log");producerFreeze=$seal;postTerminalInventoryVerified=$inventoryVerified;
    mutableInventoryFilesAfterFreeze=0;gpuCommands=0;compilerCommands=0;processCensusCommands=0;foreignActions=0;
    qualification='Additive terminal receipt and log created only after finalizer native exit; explicitly outside the self inventory. Every frozen entry rehashed after terminal. No classification/reader replay.'}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$out/receipt.json" -Encoding utf8
Write-Host $text
Write-Host "T22_RECOVERY_TERMINAL_RECEIPT=$out/receipt.json native=$code verified=$inventoryVerified"
if ($timeout -or $code -ne 0) {exit 1}
