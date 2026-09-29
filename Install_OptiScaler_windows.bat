@echo off
rem Install_OptiScaler_windows.bat -- one-entry launcher (plan todo T3).
rem Invokes tools\susemi_installer.ps1 with diagnose|install|remove.
rem No arguments = interactive session (language, EXE picker, read-only
rem   diagnosis, same-session install offer) inside that one process.
rem Argument modes (noninteractive, fixture-driven):
rem   diagnose -Exe ^<path^> [-Lang ko^|en]
rem   install  -Exe ^<path^> -Consent yes^|no [-Lang ...]
rem   remove   -Exe ^<path^> [-Lang ...]
rem Exits: 0 ready/success, 1 refused/failed, 2 invalid invocation.
rem
rem ENCODING NOTE (T1 lesson): this file intentionally sets NO codepage.
rem setup_windows.bat starts with chcp 65001, which breaks choice and set /p
rem under redirected stdin (errorlevel 255, empty reads, prompt loops).
rem This launcher keeps the inherited console codepage so piped and redirected
rem stdin semantics are unchanged. All text echoed here is pure ASCII;
rem Korean strings are emitted by the PowerShell side (UTF-8 BOM script)
rem without touching codepages, so a real console renders them correctly.
rem
rem Never chains legacy BATs (setup_windows.bat, Install_AsiLoader_windows.bat,
rem Streamline_fetcher_windows.bat); the coordinator owns the flow.
setlocal
set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%tools\susemi_installer.ps1"

if not exist "%PS1%" (
  echo ERROR: tools\susemi_installer.ps1 was not found next to this script.
  echo status=missing-coordinator reason=coordinator-not-found
  exit /b 1
)

rem No-arg guided session: take the exit code on a line OUTSIDE any ( ) block,
rem because %ERRORLEVEL% inside a block is expanded when the block is parsed (before
rem powershell runs) and would always report the pre-existing 0.
if "%~1"=="" goto :interactive

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%

:interactive
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %ERRORLEVEL%
