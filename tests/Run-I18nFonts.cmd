@echo off
setlocal
REM Row 4 of .omo/plans/susemi-next-ui-lang.md: the font runner.
REM Extracts the real MenuCommon::Init font statements, compiles them with the real
REM Localization font unit against the real vendored ImGui, then runs the happy
REM cases (Hangul source present) and the failure fixture (the Hangul chain
REM redirected at an empty directory). Run from CMD.
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
set "EMPTY=%OUT%\fonts-empty"
set "HANGUL=%WINDIR%\Fonts\malgun.ttf"
set "USERFONT=%WINDIR%\Fonts\consola.ttf"
set "PYTHONDONTWRITEBYTECODE=1"
cd /d "%W%"

echo === prerequisites
if not exist "%VCVARS%" (echo MISSING "%VCVARS%" & exit /b 1)
if not exist "%HANGUL%" (echo MISSING "%HANGUL%" & exit /b 1)
if not exist "%USERFONT%" (echo MISSING "%USERFONT%" & exit /b 1)
if not exist "%D%\simpleini\SimpleIni.h" (echo MISSING "%D%\simpleini\SimpleIni.h" & exit /b 1)
if not exist "%D%\freetype\freetype.lib" (echo MISSING "%D%\freetype\freetype.lib" & exit /b 1)
if not exist "%E%" mkdir "%E%"
if not exist "%OUT%" mkdir "%OUT%"
if not exist "%EMPTY%" mkdir "%EMPTY%"

echo === python "%W%\tools\i18n_extract_fonts.py" --root "%W%" --out "%OUT%\production-init-fonts.inc" --evidence "%E%\font-extraction.json"
python tools\i18n_extract_fonts.py --root "%W%" --out "%OUT%\production-init-fonts.inc" --evidence "%E%\font-extraction.json"
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
if exist "%OUT%\i18n_font_smoke.exe" del /Q "%OUT%\i18n_font_smoke.exe"
echo === cl /sourceDependencies "%OUT%/" /nologo /std:c++latest /EHsc /MD /O2 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" ... i18n_font_smoke.exe
cl /sourceDependencies "%OUT%/" /nologo /std:c++latest /EHsc /MD /O2 /w34996 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%D%\simpleini" /I "%D%\freetype" "%W%\tests\i18n_font_smoke.cpp" "%W%\OptiScaler\menu\Localization.cpp" "%W%\OptiScaler\include\imgui\imgui.cpp" "%W%\OptiScaler\include\imgui\imgui_draw.cpp" "%W%\OptiScaler\include\imgui\imgui_widgets.cpp" "%W%\OptiScaler\include\imgui\imgui_tables.cpp" "%W%\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp" "%D%\freetype\freetype.lib" /Fe:"%OUT%\i18n_font_smoke.exe"
set "COMPILE=%ERRORLEVEL%"
echo compile-exit=%COMPILE%
if not "%COMPILE%"=="0" (echo compile failed & exit /b 1)
if not exist "%OUT%\i18n_font_smoke.exe" (echo MISSING "%OUT%\i18n_font_smoke.exe" & exit /b 1)

echo === i18n_font_smoke.exe --evidence "%E%" --root "%W%" --user-font "%USERFONT%"  (happy: malgun.ttf present)
i18n_font_smoke.exe --evidence "%E%" --root "%W%" --user-font "%USERFONT%"
set "HAPPY=%ERRORLEVEL%"
echo happy-exit=%HAPPY%

echo === i18n_font_smoke.exe --empty-chain "%EMPTY%"  (failure fixture: chain resolves nothing)
i18n_font_smoke.exe --evidence "%E%" --root "%W%" --user-font "%USERFONT%" --empty-chain "%EMPTY%"
set "FALLBACK=%ERRORLEVEL%"
echo fallback-exit=%FALLBACK% ^(0 = the degrade engaged as designed, 2 = Korean stayed effective without a source^)

if not "%HAPPY%"=="0" (echo font cases failed & exit /b 1)
if not "%FALLBACK%"=="0" (echo the missing-source fixture did not engage as required & exit /b 1)
echo font-run: OK
endlocal
exit /b 0
