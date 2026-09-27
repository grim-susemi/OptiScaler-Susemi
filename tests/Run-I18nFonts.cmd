@echo off
setlocal
REM Row 4 of .omo/plans/susemi-next-ui-lang.md: the font runner.
REM Extracts the real MenuCommon::Init font statements, compiles them with the real
REM Localization font unit against the real vendored ImGui, then runs the happy
REM cases (Hangul source present) and the failure fixture (the Hangul chain
REM redirected at an empty directory). Run from CMD.
set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "W=C:\omo-research\susemi-next-ui-lang"
set "E=%W%\.omo\evidence\susemi-next-ui-lang\04"
set "OUT=%W%\x64\i18n-fonts"
set "EMPTY=%OUT%\fonts-empty"
set "HANGUL=%WINDIR%\Fonts\malgun.ttf"
set "USERFONT=%WINDIR%\Fonts\consola.ttf"
set "PYTHONDONTWRITEBYTECODE=1"
cd /d "%W%"

echo === prerequisites
if not exist "%VCVARS%" (echo MISSING "%VCVARS%" & exit /b 1)
if not exist "%HANGUL%" (echo MISSING "%HANGUL%" & exit /b 1)
if not exist "%USERFONT%" (echo MISSING "%USERFONT%" & exit /b 1)
if not exist "%E%" mkdir "%E%"
if not exist "%OUT%" mkdir "%OUT%"
if not exist "%EMPTY%" mkdir "%EMPTY%"

echo === python tools\i18n_extract_fonts.py --root "%W%" --out "%OUT%\production-init-fonts.inc" --evidence "%E%\font-extraction.json"
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
echo === cl /nologo /std:c++latest /EHsc /MD /O2 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" ... i18n_font_smoke.exe
cl /nologo /std:c++latest /EHsc /MD /O2 /w34996 /I "%OUT%" /I "%W%\OptiScaler" /I "%W%\OptiScaler\include" /I "%W%\OptiScaler\include\imgui" /I "%W%\external\simpleini" /I "%W%\external\freetype" "%W%\tests\i18n_font_smoke.cpp" "%W%\OptiScaler\menu\Localization.cpp" "%W%\OptiScaler\include\imgui\imgui.cpp" "%W%\OptiScaler\include\imgui\imgui_draw.cpp" "%W%\OptiScaler\include\imgui\imgui_widgets.cpp" "%W%\OptiScaler\include\imgui\imgui_tables.cpp" "%W%\OptiScaler\include\imgui\misc\freetype\imgui_freetype.cpp" "%W%\external\freetype\freetype.lib" /Fe:"%OUT%\i18n_font_smoke.exe"
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
