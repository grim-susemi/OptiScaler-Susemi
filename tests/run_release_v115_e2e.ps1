param(
  [Parameter(Mandatory=$true)][string]$Zip,
  [Parameter(Mandatory=$true)][string]$PreviousZip,
  [Parameter(Mandatory=$true)][string]$Work,
  [Parameter(Mandatory=$true)][string]$Evidence
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$NEW = 'e050434cd054ebe0ea43882ff60c2f96755fcc9396fcdd7f709649967469feef'
$OLD = '22f3677f922969a7dab3f3332075f74f64488fbffb8b98b929b8851c8b5fbcff'
$UAL = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
if (Test-Path -LiteralPath $Work) { throw 'Use a new private fixture directory' }
New-Item -ItemType Directory -Path $Work | Out-Null
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
$env:SUSEMI_TX_JOURNAL_ROOT = Join-Path $Work 'journals'
$env:SUSEMI_RC2_ZIP = ''
New-Item -ItemType Directory -Path $env:SUSEMI_TX_JOURNAL_ROOT | Out-Null
$results = New-Object System.Collections.ArrayList
function Sha($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Record($name, $ok, $detail) {
  [void]$results.Add([pscustomobject]@{check=$name; pass=[bool]$ok; detail=$detail})
  $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Evidence 'results.json') -Encoding UTF8
  Write-Host ("V115_E2E " + $(if ($ok) {'PASS'} else {'FAIL'}) + " $name :: $detail")
  if (-not $ok) { throw "Release check failed: $name" }
}
function MapGame($root) {
  $map = @{}
  Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object {
    $name=$_.FullName.Substring($root.Length).TrimStart('\')
    if ($name -notlike '.susemi-backup\*') { $map[$name]=Sha $_.FullName }
  }
  return $map
}
function Same($a,$b) {
  if ($a.Count -ne $b.Count) { return $false }
  foreach ($key in $a.Keys) { if (-not $b.ContainsKey($key) -or $a[$key] -ne $b[$key]) { return $false } }
  return $true
}
function NewGame($name) {
  $dir=Join-Path $Work "$name\bin64"
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $exe=Join-Path $dir 'GameA.exe'
  Copy-Item -LiteralPath 'C:\Windows\System32\notepad.exe' -Destination $exe
  return $exe
}
function RunInstaller($package,$arguments,$name) {
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=$env:ComSpec
  $psi.Arguments='/c ""' + (Join-Path $package 'Install_OptiScaler_windows.bat') + '" ' + $arguments + '"'
  $psi.WorkingDirectory=$package
  $psi.UseShellExecute=$false
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.RedirectStandardInput=$true
  $process=[Diagnostics.Process]::Start($psi)
  $process.StandardInput.Close()
  $stdout=$process.StandardOutput.ReadToEndAsync()
  $stderr=$process.StandardError.ReadToEndAsync()
  $timedOut = -not $process.WaitForExit(60000)
  if ($timedOut) {
    & taskkill.exe /PID $process.Id /T /F | Out-Null
    $null=$process.WaitForExit(5000)
  }
  $text=$stdout.Result + "`n--- stderr ---`n" + $stderr.Result
  Set-Content -LiteralPath (Join-Path $Evidence "$name.log") -Value $text -Encoding UTF8
  if ($timedOut) { throw "Installer exceeded 60 seconds: $name; output preserved" }
  return [pscustomobject]@{exit=$process.ExitCode; text=$text}
}

$package=Join-Path $Work 'package'
[IO.Compression.ZipFile]::ExtractToDirectory($Zip,$package)
$listed=@{}
foreach ($line in (Get-Content -LiteralPath (Join-Path $package 'SHA256SUMS.txt'))) {
  if ($line -match '^([0-9A-F]{64}) \*(.+)$') { $listed[$Matches[2]]=$Matches[1].ToLowerInvariant() }
}
$members=@(Get-ChildItem -LiteralPath $package -File -Recurse | ForEach-Object {
  $_.FullName.Substring($package.Length).TrimStart('\').Replace('\','/')
} | Where-Object { $_ -ne 'SHA256SUMS.txt' })
$bad=@($listed.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $package $_)) -or
  (Sha (Join-Path $package $_)) -ne $listed[$_] })
Record 'complete-manifest' ($members.Count -eq 29 -and $listed.Count -eq 29 -and $bad.Count -eq 0 -and
  @($members | Where-Object { -not $listed.ContainsKey($_) }).Count -eq 0) 'all 30 ZIP members, no unlisted/absent/bad hash'
Record 'core-and-UAL' ((Sha (Join-Path $package 'OptiScaler.dll')) -eq $NEW -and
  (Sha (Join-Path $package 'tools\asi-loader\Ultimate-ASI-Loader-x64.dll')) -eq $UAL) 'trusted core and UAL pins'
foreach ($bat in (Get-ChildItem -LiteralPath $package -Filter '*.bat')) {
  $text=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($bat.FullName))
  Record ('CRLF-' + $bat.Name) (-not [regex]::IsMatch($text,"(?<!`r)`n")) 'Windows batch transport preserved'
}
foreach ($ps in (Get-ChildItem -LiteralPath "$package\tools" -Filter '*.ps1')) {
  $tokens=$null; $parseErrors=$null
  [Management.Automation.Language.Parser]::ParseFile($ps.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
  Record ('parse-' + $ps.Name) ($parseErrors.Count -eq 0) 'PowerShell parse only; no runtime download'
}
$manifest=Get-Content -LiteralPath "$package\RELEASE-MANIFEST.json" -Raw | ConvertFrom-Json
Record 'source-binding' ($manifest.version -eq 'v11.5' -and $manifest.source_commit -match '^[0-9a-f]{40}$' -and
  $manifest.core_sha256 -eq $NEW -and $manifest.integrated_gpu_gameplay_tested -eq $false) $manifest.source_commit

$exe=NewGame 'fresh'; $dir=Split-Path -Parent $exe; $before=MapGame $dir
$d=RunInstaller $package ('diagnose -Exe "' + $exe + '" -Lang en') 'fresh-diagnose'
Record 'bare-diagnosis' ($d.exit -eq 1 -and $d.text -match 'no-loader-or-optiscaler' -and
  (Same $before (MapGame $dir))) 'expected missing-input refusal, no game-file changes'
$i=RunInstaller $package ('install -Exe "' + $exe + '" -Consent yes -Lang en') 'fresh-install'
Record 'fresh-install-11' ($i.exit -eq 0 -and $i.text -match 'status=installed' -and
  $i.text -match 'setup_verified=11' -and (Sha "$dir\OptiScaler.asi") -eq $NEW -and
  (Sha "$dir\winmm.dll") -eq $UAL) 'actual BAT -> coordinator -> staged setup -> schema2 apply'
$resources=@($listed.Keys | Where-Object { $_ -like 'OptiScaler/*' })
Record 'nine-resource-hashes' ($resources.Count -eq 9 -and
  @($resources | Where-Object { (Sha (Join-Path $dir $_)) -ne $listed[$_] }).Count -eq 0) 'all bundled backend resources match'
Record 'no-generated-user-INI' (-not (Test-Path -LiteralPath "$dir\OptiScaler.ini")) 'installer leaves NR/FG settings alone'
$same=MapGame $dir
$i2=RunInstaller $package ('install -Exe "' + $exe + '" -Consent yes -Lang en') 'fresh-no-op'
Record 'repeat-no-op' ($i2.exit -eq 0 -and $i2.text -match 'no-op|already' -and
  (Same $same (MapGame $dir))) 'equal installed bytes stay equal'
$r=RunInstaller $package ('remove -Exe "' + $exe + '" -Consent yes -Lang en') 'fresh-remove'
Record 'fresh-remove' ($r.exit -eq 0 -and (Same $before (MapGame $dir))) 'pristine game payload; retained installer backup metadata excluded'

$previous=Join-Path $Work 'previous'
[IO.Compression.ZipFile]::ExtractToDirectory($PreviousZip,$previous)
Record 'previous-v11.4-pin' ((Sha "$previous\OptiScaler.dll") -eq $OLD) 'real previous public package'
$exe=NewGame 'upgrade'; $dir=Split-Path -Parent $exe
[IO.File]::WriteAllText("$dir\OptiScaler.ini","[Log]`r`nLogToFile=false`r`n; USER-KEEP`r`n")
$before=MapGame $dir
$previousInstall=RunInstaller $previous ('install -Exe "' + $exe + '" -Consent yes -Lang en') 'previous-install'
Record 'previous-install' ($previousInstall.exit -eq 0 -and (Sha "$dir\OptiScaler.asi") -eq $OLD) 'v11.4 installed through its actual BAT'
$upgrade=RunInstaller $package ('install -Exe "' + $exe + '" -Consent yes -Lang en') 'upgrade-install'
Record 'v11.4-upgrade' ($upgrade.exit -eq 0 -and (Sha "$dir\OptiScaler.asi") -eq $NEW -and
  $upgrade.text -match 'setup_verified=11') 'new core, preserved linked transaction lineage'
Record 'user-INI-preserved' ((Sha "$dir\OptiScaler.ini") -eq $before['OptiScaler.ini']) 'user log/config bytes unchanged'
$resource=Join-Path $dir 'OptiScaler\libxell.dll'
[IO.File]::WriteAllText($resource,'user-modified-fixture')
$changed=MapGame $dir
$refused=RunInstaller $package ('remove -Exe "' + $exe + '" -Consent yes -Lang en') 'changed-remove-refused'
Record 'changed-resource-refusal' ($refused.exit -ne 0 -and (Same $changed (MapGame $dir))) 'whole linked removal refuses without partial writes'
Copy-Item -LiteralPath "$package\OptiScaler\libxell.dll" -Destination $resource
$remove=RunInstaller $package ('remove -Exe "' + $exe + '" -Consent yes -Lang en') 'upgrade-remove'
Record 'linked-upgrade-remove' ($remove.exit -eq 0 -and (Same $before (MapGame $dir))) 'previous installer group restored; user INI preserved'
Write-Host ("V115_E2E_RESULT exit=0 checks=" + $results.Count + " gpu=false game_launch=false download=false")
