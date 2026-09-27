param([Parameter(Mandatory=$true)][string]$GameDll)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$out = Join-Path $repo 'x64/kcd2-hdr-validation'
New-Item -ItemType Directory -Force "$out/seams" | Out-Null
foreach ($header in @('pch.h', 'State.h')) {
    Set-Content -LiteralPath "$out/seams/$header" -Value '// Test supplies engine-independent application state.'
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$build = @"
@echo off
call "$vs/VC/Auxiliary/Build/vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /EHsc /W4 /D_CRT_SECURE_NO_WARNINGS /I "$out/seams" "$PSScriptRoot/CallbackTests.cpp" /Fe:"$out/callback.exe" /Fo:"$out/callback.obj"
"@
Set-Content -LiteralPath "$out/build.cmd" -Value $build
& "$out/build.cmd"
if ($LASTEXITCODE) { throw 'KCD2 HDR regression build failed' }
$before = (Get-FileHash -LiteralPath $GameDll -Algorithm SHA256).Hash
& "$out/callback.exe" $GameDll
if ($LASTEXITCODE) { throw 'KCD2 HDR callback regression failed' }
if ((Get-FileHash -LiteralPath $GameDll -Algorithm SHA256).Hash -ne $before) { throw 'Game DLL changed on disk' }
