@echo off
setlocal
title Streamline runtime fetcher
set "PS1=%~dp0tools\Get-StreamlineRuntime.ps1"

REM Argument mode: Streamline_fetcher_windows.bat [latest|verify|remove|<version>]
if not "%~1"=="" (
  if /i "%~1"=="latest" set "ACTION=-Action latest" & goto runarg
  if /i "%~1"=="verify" set "ACTION=-Action verify" & goto runarg
  if /i "%~1"=="remove" set "ACTION=-Action remove" & goto runarg
  set "ACTION=-Action version -Version %~1"
  goto runarg
)

echo ==========================================
echo  Streamline runtime fetcher (NVIDIA SDK)
echo ==========================================
echo.
echo  Fetches the official NVIDIA Streamline release and installs the DLLs
echo  into the folder OptiScaler loads them from: OptiScaler\streamline
echo.
echo  [1] Install or update to the latest release
echo  [2] Install or update to a specific version
echo  [3] Verify the installed files
echo  [4] Remove the installed files
echo  [0] Exit
echo.
choice /c 12340 /n /m "Select an option: "
if errorlevel 5 goto done
if errorlevel 4 set "ACTION=-Action remove" & goto runarg
if errorlevel 3 set "ACTION=-Action verify" & goto runarg
if errorlevel 2 goto askversion
set "ACTION=-Action latest"
goto runarg

:askversion
set "VER="
set /p "VER=Version tag (for example v2.14.1): "
if "%VER%"=="" goto done
set "ACTION=-Action version -Version %VER%"
goto runarg

:runarg
if not exist "%PS1%" (
  echo.
  echo ERROR: tools\Get-StreamlineRuntime.ps1 was not found next to this script.
  echo Extract the whole package and run this file again.
  goto done
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ACTION%
echo.
echo fetcher-exit=%errorlevel%

:done
pause
exit /b 0
