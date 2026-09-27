@echo off
setlocal
REM Row 3 of .omo/plans/susemi-next-ui-lang.md: the seam runner.
REM Compiles the real vendored ImGui seams, the real Localization unit, the real
REM DlssNr label-key path and the real Config read/load/save statements, then runs
REM the seam cases and the failure fixture. Run from CMD.
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "W=C:\omo-research\susemi-next-ui-lang"
set "E=%W%\.omo\evidence\susemi-next-ui-lang\03"
set "OUT=%W%\x64\i18n-seam"
set "FONT=%WINDIR%\Fonts\malgun.ttf"
set "PYTHONDONTWRITEBYTECODE=1"
cd /d "%W%"

echo === prerequisites
if not exist "%VCVARS%" (echo MISSING "%VCVARS%" & exit /b 1)
if not exist "%FONT%" (echo MISSING "%FONT%" & exit /b 1)
if not exist "%E%" mkdir "%E%"
if not exist "%OUT%" mkdir "%OUT%"

echo === python tools\i18n_extract_seam.py --menus OptiScaler\dlssnr\DlssNr_MenuControls.cpp --config OptiScaler\Config.cpp --out-dir "%OUT%" --evidence "%E%\seam-extraction.json"
python tools\i18n_extract_seam.py --menus "OptiScaler\dlssnr\DlssNr_MenuControls.cpp" --config "OptiScaler\Config.cpp" --out-dir "%OUT%" --evidence "%E%\seam-extraction.json"
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
echo === cl /nologo /std:c++latest /EHsc /MD /O2 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%W%\external\simpleini" /I "%W%\external\freetype" "%W%\tests\i18n_seam_smoke.cpp" ... freetype.lib
cl /nologo /std:c++latest /EHsc /MD /O2 /w34996 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%W%\external\simpleini" /I "%W%\external\freetype" "%W%\tests\i18n_seam_smoke.cpp" "%W%\OptiScaler\menu\Localization.cpp" "%W%\OptiScaler\include\imgui\imgui.cpp" "%W%\OptiScaler\include\imgui\imgui_draw.cpp" "%W%\OptiScaler\include\imgui\imgui_widgets.cpp" "%W%\OptiScaler\include\imgui\imgui_tables.cpp" "%W%\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp" "%W%\external\freetype\freetype.lib" /Fe:"%OUT%\i18n_seam_smoke.exe"
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
