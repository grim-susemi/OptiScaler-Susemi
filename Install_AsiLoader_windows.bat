@echo off
chcp 65001 >nul
setlocal
title ASI loader setup
set "PS1=%~dp0tools\asi_loader_install.ps1"
set "ARG_MODE="

if /i "%~1"=="install" goto arg_install
if /i "%~1"=="check" goto arg_check
if /i "%~1"=="remove" goto arg_remove
if not "%~1"=="" goto arg_name_install

echo.
echo  [1] Korean (default)
echo  [2] English
echo.
choice /c 12 /n /m "Select language: "
set "LANG=ko"
if errorlevel 2 set "LANG=en"
if "%LANG%"=="ko" goto menu_ko

:menu_en
echo ==========================================
echo  ASI loader setup (Ultimate ASI Loader)
echo ==========================================
echo.
echo  Needed for the ASI install method: OptiScaler.asi loads only when an
echo  ASI loader, winmm.dll by default, sits next to the game exe.
echo.
echo  [1] Install the loader as winmm.dll (recommended)
echo  [2] Install the loader under another name
echo  [3] Check whether a loader is already installed
echo  [4] Remove the loader (restores a backup when one exists)
echo  [0] Exit
echo.
choice /c 12340 /n /m "Select an option: "
goto menu_done

:menu_ko
echo ==========================================
echo  ASI 로더 설치 (Ultimate ASI Loader)
echo ==========================================
echo.
echo  ASI 설치 방법에 필요한 것: OptiScaler.asi는 ASI 로더
echo  (기본: winmm.dll)가 게임 exe 옆에 있어야만 로드됩니다.
echo.
echo  [1] winmm.dll(으)로 로더 설치 (권장)
echo  [2] 다른 이름으로 로더 설치
echo  [3] 로더가 이미 설치되어 있는지 확인
echo  [4] 로더 제거 (백업이 있으면 복원)
echo  [0] 종료
echo.
choice /c 12340 /n /m "선택하세요: "
goto menu_done

:menu_done
if errorlevel 5 goto done
if errorlevel 4 set "ARGS=-Action remove" & goto run
if errorlevel 3 set "ARGS=-Action check" & goto run
if errorlevel 2 goto ask_name
set "ARGS=-Action install" & goto run

:ask_name
set "NAME="
set /p "NAME=Loader name (default winmm.dll): "
if "%NAME%"=="" set "NAME=winmm.dll"
set "ARGS=-Action install -Name %NAME%" & goto run

:arg_install
set "ARG_MODE=1"
set "ARGS=-Action install"
goto run

:arg_check
set "ARG_MODE=1"
set "ARGS=-Action check"
goto run

:arg_remove
set "ARG_MODE=1"
set "ARGS=-Action remove"
goto run

:arg_name_install
set "ARG_MODE=1"
set "ARGS=-Action install -Name %~1"
goto run

:run
if exist "%PS1%" goto have_helper
echo.
echo ERROR: tools\asi_loader_install.ps1 was not found next to this script.
echo Extract the whole package and run this file again.
if defined ARG_MODE goto arg_failed
goto done
:arg_failed
exit /b 1
:have_helper
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
set "RC=%ERRORLEVEL%"
echo.
echo asi-loader-exit=%RC%
if defined ARG_MODE goto arg_exit
goto done
:arg_exit
exit /b %RC%

:done
pause
exit /b 0
