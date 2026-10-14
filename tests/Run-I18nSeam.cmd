@echo off
setlocal
REM Row 3 of .omo/plans/susemi-next-ui-lang.md: the seam runner.
REM Compiles the real vendored ImGui seams, the real Localization unit, the real
REM DlssNr label-key path and the real Config read/load/save statements, then runs
REM the seam cases and the failure fixture. Run from CMD.
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if "%~1"=="" (echo ROOT_ERROR=SOURCE_REQUIRED & exit /b 64)
if "%~2"=="" (echo ROOT_ERROR=EVIDENCE_REQUIRED & exit /b 64)
set "W=%~f1"
set "W=%W:/=\%"
if "%W:~-1%"=="\" set "W=%W:~0,-1%"
for %%I in ("%~dp0..") do set "CHECKOUT=%%~fI"
if /i not "%W%"=="%CHECKOUT%" (echo ROOT_ERROR=SOURCE_MISMATCH & exit /b 64)
set "E=%~f2"
set "E=%E:/=\%"
powershell -NoProfile -Command "$allowed=Join-Path $env:W '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'; if (![IO.Path]::GetFullPath($env:E).StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { Write-Output 'ROOT_ERROR=EVIDENCE_MISMATCH'; exit 64 }"
if errorlevel 1 exit /b 64
set "D=%OPTISCALER_NR_DEPENDENCY_ROOT%"
if not defined D set "D=%W%\external"
set "OUT=%E%\obj"
echo SOURCE_ROOT=%W%
echo EVIDENCE_ROOT=%E%
echo DEPENDENCY_ROOT=%D%
set "FONT=%WINDIR%\Fonts\malgun.ttf"
set "PYTHONDONTWRITEBYTECODE=1"
cd /d "%W%"

echo === prerequisites
if not exist "%VCVARS%" (echo MISSING "%VCVARS%" & exit /b 1)
if not exist "%FONT%" (echo MISSING "%FONT%" & exit /b 1)
if not exist "%D%\simpleini\SimpleIni.h" (echo MISSING "%D%\simpleini\SimpleIni.h" & exit /b 1)
if not exist "%D%\freetype\freetype.lib" (echo MISSING "%D%\freetype\freetype.lib" & exit /b 1)
if not exist "%E%" mkdir "%E%"
if not exist "%OUT%" mkdir "%OUT%"

echo === python tools\i18n_extract_seam.py --menus OptiScaler\dlssnr\DlssNr_MenuControls.cpp --config OptiScaler\Config.cpp --out-dir "%OUT%" --evidence "%E%\seam-extraction.json"
python "%W%\tools\i18n_extract_seam.py" --menus "%W%\OptiScaler\dlssnr\DlssNr_MenuControls.cpp" --config "%W%\OptiScaler\Config.cpp" --out-dir "%OUT%" --evidence "%E%\seam-extraction.json"
set "EXTRACT=%ERRORLEVEL%"
echo extract-exit=%EXTRACT%
if not "%EXTRACT%"=="0" exit /b 1

echo === stub pch.h: the project build supplies the real precompiled header, this unit is standalone
> "%OUT%\pch.h" echo // empty standalone stub
echo stub-exit=%ERRORLEVEL%

call "%VCVARS%" >nul
echo === cl.exe availability
where cl
echo where-cl-exit=%ERRORLEVEL%

cd /d "%OUT%"
if exist "%OUT%\i18n_seam_smoke.exe" del /Q "%OUT%\i18n_seam_smoke.exe"
echo === cl /sourceDependencies "%OUT%/" /nologo /std:c++latest /EHsc /MD /O2 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%D%\simpleini" /I "%D%\freetype" "%W%\tests\i18n_seam_smoke.cpp" ... freetype.lib
cl /sourceDependencies "%OUT%/" /nologo /std:c++latest /EHsc /MD /O2 /w34996 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%D%\simpleini" /I "%D%\freetype" "%W%\tests\i18n_seam_smoke.cpp" "%W%\OptiScaler\menu\Localization.cpp" "%W%\OptiScaler\include\imgui\imgui.cpp" "%W%\OptiScaler\include\imgui\imgui_draw.cpp" "%W%\OptiScaler\include\imgui\imgui_widgets.cpp" "%W%\OptiScaler\include\imgui\imgui_tables.cpp" "%W%\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp" "%D%\freetype\freetype.lib" /Fe:"%OUT%\i18n_seam_smoke.exe"
set "COMPILE=%ERRORLEVEL%"
echo compile-exit=%COMPILE%
if not "%COMPILE%"=="0" (echo compile failed & exit /b 1)
if not exist "%OUT%\i18n_seam_smoke.exe" (echo MISSING "%OUT%\i18n_seam_smoke.exe" & exit /b 1)

echo === i18n_seam_smoke.exe --evidence "%E%" --root "%W%" --font "%FONT%"
i18n_seam_smoke.exe --evidence "%E%" --root "%W%" --font "%FONT%"
set "SEAM=%ERRORLEVEL%"
echo seam-exit=%SEAM%

echo === failure fixture: the KO label forced into the ID path must fail the runner
i18n_seam_smoke.exe --evidence "%E%" --root "%W%" --font "%FONT%" --inject-trap
set "TRAP=%ERRORLEVEL%"
echo trap-exit=%TRAP% ^(1 = trap detected as designed, 2 = the identity check is blind^)

if not "%SEAM%"=="0" (echo seam cases failed & exit /b 1)
if not "%TRAP%"=="1" (echo the identity fixture did not fail as required & exit /b 1)
echo seam-run: OK
endlocal
exit /b 0
