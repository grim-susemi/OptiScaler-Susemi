param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$Old
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue))
{
    $vcvars = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat"
    $environment = & $env:ComSpec /d /s /c "`"$vcvars`" >nul && set"
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    foreach ($line in $environment)
    {
        if ($line -match '^([^=]+)=(.*)$')
        {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$defines = @()
if ($Old) { $defines += '/DCOMMON_LIFECYCLE_OLD' }
& cl.exe /nologo /std:c++20 /EHsc /W4 /Od /DNOMINMAX @defines `
    "/I$repo/OptiScaler" "/I$repo/OptiScaler/include" `
    "/Fo$OutputDirectory/" "/Fd$OutputDirectory/test.pdb" "/Fe$OutputDirectory/common_detours_smoke.exe" `
    "$PSScriptRoot/common_detours_smoke.cpp" `
    /link "$repo/OptiScaler/library/detours/detours.lib"
$compile = $LASTEXITCODE
Write-Host "COMMON_COMPILE_EXIT=$compile"
if ($compile) { exit $compile }
& "$OutputDirectory/common_detours_smoke.exe"
$native = $LASTEXITCODE
Write-Host "COMMON_NATIVE_EXIT=$native"
exit $native
