REM Setup OptiScaler for your game
@echo off
REM --- Orchestrated (noninteractive) staging mode: first argument only. ---
if /i "%~1"=="--orchestrated" goto orch_main
chcp 65001 >nul
cls
echo  ::::::::  :::::::::  ::::::::::: :::::::::::  ::::::::   ::::::::      :::     :::        :::::::::: :::::::::  
echo :+:    :+: :+:    :+:     :+:         :+:     :+:    :+: :+:    :+:   :+: :+:   :+:        :+:        :+:    :+: 
echo +:+    +:+ +:+    +:+     +:+         +:+     +:+        +:+         +:+   +:+  +:+        +:+        +:+    +:+ 
echo +#+    +:+ +#++:++#+      +#+         +#+     +#++:++#++ +#+        +#++:++#++: +#+        +#++:++#   +#++:++#:  
echo +#+    +#+ +#+            +#+         +#+            +#+ +#+        +#+     +#+ +#+        +#+        +#+    +#+ 
echo #+#    #+# #+#            #+#         #+#     #+#    #+# #+#    #+# #+#     #+# #+#        #+#        #+#    #+# 
echo  ########  ###            ###     ###########  ########   ########  ###     ### ########## ########## ###    ### 
echo.
echo Coping is strong with this one...
echo v3.0-pre1
echo.

del "!! README_EXTRACT ALL FILES TO GAME FOLDER !!.txt" 2>nul

setlocal enabledelayedexpansion

REM --- Language gate: Korean default, [2] English ---
echo.
echo  [1] 한국어 (기본)
echo  [2] English
echo.
set "LANG=ko"
choice /c 12 /n /m "언어를 선택하세요 / Select language [1/2]: "
if errorlevel 2 set "LANG=en"
echo.

REM --- Susemi-next KO identity (banner block) ---
if "%LANG%"=="ko" echo  Susemi-next 한국어 UI 팩 - wilsjo2 v0.8.8 기반
if not "%LANG%"=="ko" echo  Susemi-next UI Language Pack - wilsjo2 v0.8.8 based
if "%LANG%"=="ko" echo  한국어가 기본 언어로 선택되었습니다. [2] English를 고르면 영어로 진행합니다.
if not "%LANG%"=="ko" echo  Korean is selected as the default language. Choose [2] English to proceed in English.
echo.

if exist OptiScaler.sln (
    echo Detected OptiScaler.sln or .git files^^!
    echo.
    echo If .sln or .git files are in the folder, congratz, you have the source code.
	echo Now please try properly downloading OptiScaler.
	echo.
    echo Hint - use the Releases page on GitHub, or RTFM :^)
	echo.
    echo.
	echo P.S. If you somehow have both the OptiScaler.dll and .sln file, then be nice, just delete the .sln file, re-run the BAT setup and hope for the best.
	echo.
    goto end
)

if not exist OptiScaler.dll (
    echo OptiScaler "OptiScaler.dll" file is not found^^!
    set "CE_TEXT=Detected a folder permissions issue most likely. Might have more luck running the BAT as admin."
    call :cEcho Red
    echo.
	echo OR
	echo.
    echo If "OptiScaler.dll" exists, please manually rename to a supported filename ^(e.g. dxgi/winmm.dll^) and you are done^^!
	echo No need to run the setup BAT again after renaming.
	echo.
    echo.
    goto end
)

REM Check if old pre-0.9 additional files exist, along with an existing Opti installation
set "OLD_FILES_FOUND=0"
set "OPTI_DLL_LIST="
if exist nvapi64.dll set "OLD_FILES_FOUND=1"
if exist nvngx.dll set "OLD_FILES_FOUND=1"
if exist OptiScaler.asi set "OLD_FILES_FOUND=1"
if exist "Remove OptiScaler.bat" set "OLD_FILES_FOUND=1"
if exist "Remove_OptiScaler.bat" set "OLD_FILES_FOUND=1"

for %%F in (dxgi.dll winmm.dll d3d12.dll dbghelp.dll version.dll wininet.dll winhttp.dll) do (
    if exist "%%F" (
        set "origname="
        for /f "tokens=*" %%P in ('powershell -NoProfile -Command "(Get-Item '%%F').VersionInfo.OriginalFilename"') do (
            set "origname=%%P"
        )
        if /i "!origname!"=="OptiScaler.dll" (
            set "OLD_FILES_FOUND=1"
            set "OPTI_DLL_LIST=!OPTI_DLL_LIST! %%F"
        )
    )
)

if "!OLD_FILES_FOUND!"=="1" (
    echo WARNING: Possible old OptiScaler file^(s^) detected^^!
    if exist nvapi64.dll echo   - nvapi64.dll
    if exist nvngx.dll echo   - nvngx.dll
    if exist OptiScaler.asi echo   - OptiScaler.asi
	if exist "Remove OptiScaler.bat" echo   - Remove OptiScaler.bat
    if exist "Remove_OptiScaler.bat" echo   - Remove_OptiScaler.bat
    for %%F in (!OPTI_DLL_LIST!) do echo   - %%F ^(original filename: OptiScaler.dll^)
    echo.
    if "%LANG%"=="ko" goto delOld_ko
:delOld_en
    echo These files may conflict with the current version of OptiScaler.
    echo It is recommended to delete them.
    echo.
    set "CE_TEXT=Do you want to delete these files?"
    call :cEcho White
    echo.
	echo [1] Yes
    echo [2] No
    echo.
	set /p "USER_CHOICE=Waiting - "
    goto delOld_cont
:delOld_ko
    echo 다음 파일들이 현재 버전의 OptiScaler와 충돌할 수 있습니다.
    echo 삭제하는 것을 권장합니다.
    echo.
    set "CE_TEXT=이 파일들을 삭제하시겠습니까?"
    call :cEcho White
    echo.
    echo [1] 예
    echo [2] 아니요
    echo.
	set /p "USER_CHOICE=Waiting - "
:delOld_cont
	echo.
    if /i "!USER_CHOICE!"=="1" (
        if exist nvapi64.dll (
            del nvapi64.dll
            set "CE_TEXT=Deleted nvapi64.dll"
            call :cEcho Green
        )
        if exist nvngx.dll (
            del nvngx.dll
            set "CE_TEXT=Deleted nvngx.dll"
            call :cEcho Green
        )
        if exist OptiScaler.asi (
            del OptiScaler.asi
            set "CE_TEXT=Deleted OptiScaler.asi"
            call :cEcho Green
        )
		if exist "Remove OptiScaler.bat" (
            del "Remove OptiScaler.bat"
            set "CE_TEXT=Deleted Remove OptiScaler.bat"
            call :cEcho Green
        )
        if exist "Remove_OptiScaler.bat" (
            del "Remove_OptiScaler.bat"
            set "CE_TEXT=Deleted Remove_OptiScaler.bat"
            call :cEcho Green
        )
        for %%F in (!OPTI_DLL_LIST!) do (
            del "%%F"
            set "CE_TEXT=Deleted %%F"
            call :cEcho Green
        )
        echo Done^^!
    ) else (
        set "CE_TEXT=Skipping deletion. Note that these files may cause issues."
        call :cEcho Yellow
    )
    echo.
)

REM Set paths based on current directory

set "optiScalerFile=.\OptiScaler.dll"
set setupSuccess=false

REM Check if the Engine folder exists
if exist ".\Engine" (
    if "%LANG%"=="ko" goto engine_ko
:engine_en
    echo Found Engine folder. If this is an Unreal Engine game, then please extract Optiscaler to #CODENAME#\Binaries\Win64
	echo Do not extract to the Engine folder^^!
	echo.
	echo Example - \Jedi Survivor\SwGame\Binaries\Win64, \Witchfire\Witchfire\Binaries\Win64
    echo.
    set "CE_TEXT=Continue installation to current folder?"
    call :cEcho White
	echo. 
    echo [1] Yes
    echo [2] No
    echo.
	set /p continueChoice="Waiting - "
    goto engine_cont
:engine_ko
    echo Engine 폴더가 감지되었습니다. 언리얼 엔진 게임이라면 #CODENAME#\Binaries\Win64로 OptiScaler를 풀어 넣으세요.
	echo Engine 폴더에는 풀지 마세요^^!
	echo.
	echo 예 - \Jedi Survivor\SwGame\Binaries\Win64, \Witchfire\Witchfire\Binaries\Win64
    echo.
    set "CE_TEXT=현재 폴더에 설치를 계속하시겠습니까?"
    call :cEcho White
	echo. 
    echo [1] 예
    echo [2] 아니요
    echo.
	set /p continueChoice="Waiting - "
:engine_cont
    set continueChoice=!continueChoice: =!

    if "!continueChoice!"=="1" (
        goto selectFilename
    )

    goto end
)

REM Prompt user to select a filename for OptiScaler
:selectFilename
echo.
if "%LANG%"=="ko" goto selName_ko
:selName_en
echo Choose a filename for OptiScaler (default is dxgi.dll, most compatible):
echo (For Vulkan, use winmm.dll. For XGP/MS Store, winmm/version.dll may be better)
echo.
echo  [1] dxgi.dll
echo  [2] winmm.dll
echo  [3] version.dll
echo  [4] dbghelp.dll
echo  [5] d3d12.dll
echo  [6] wininet.dll
echo  [7] winhttp.dll
echo  [8] OptiScaler.asi
echo.
set /p filenameChoice="Enter 1-8 (or press Enter for default): "
goto selName_cont
:selName_ko
echo OptiScaler 파일 이름을 선택하세요 (기본: dxgi.dll, 호환성이 가장 좋음):
echo (Vulkan은 winmm.dll, XGP/MS Store는 winmm/version.dll이 더 나을 수 있음)
echo.
echo  [1] dxgi.dll
echo  [2] winmm.dll
echo  [3] version.dll
echo  [4] dbghelp.dll
echo  [5] d3d12.dll
echo  [6] wininet.dll
echo  [7] winhttp.dll
echo  [8] OptiScaler.asi
echo.
set /p filenameChoice="1-8을 입력하세요 (기본은 Enter): "
:selName_cont

if "%filenameChoice%"=="" (
    set selectedFilename="dxgi.dll"
) else if "%filenameChoice%"=="1" (
    set selectedFilename="dxgi.dll"
) else if "%filenameChoice%"=="2" (
    set selectedFilename="winmm.dll"
) else if "%filenameChoice%"=="3" (
    set selectedFilename="version.dll"
) else if "%filenameChoice%"=="4" (
    set selectedFilename="dbghelp.dll"
) else if "%filenameChoice%"=="5" (
    set selectedFilename="d3d12.dll"
) else if "%filenameChoice%"=="6" (
    set selectedFilename="wininet.dll"
) else if "%filenameChoice%"=="7" (
    set selectedFilename="winhttp.dll"
) else if "%filenameChoice%"=="8" (
    set selectedFilename="OptiScaler.asi"
) else (
    set "CE_TEXT=Invalid choice. Please select a valid option."
    call :cEcho Red
    echo.
    goto selectFilename
)

if exist %selectedFilename% (
    echo.
    if "%LANG%"=="ko" goto overwrite_ko
:overwrite_en
    set "CE_TEXT=WARNING: %selectedFilename% already exists in the current folder."
    call :cEcho Yellow
    echo.
	set "CE_TEXT=Do you want to overwrite %selectedFilename%?"
	call :cEcho White
	echo.
    echo [1] Yes
    echo [2] No
    echo.
	set /p overwriteChoice="Waiting - "
    goto overwrite_cont
:overwrite_ko
    echo 경고: %selectedFilename%이^(가^) 이미 현재 폴더에 있습니다.
    echo.
	set "CE_TEXT=%selectedFilename%을(를) 덮어쓰시겠습니까?"
	call :cEcho White
	echo.
    echo [1] 예
    echo [2] 아니요
    echo.
	set /p overwriteChoice="Waiting - "
:overwrite_cont
    set overwriteChoice=!overwriteChoice: =!
    
    echo.
    if "!overwriteChoice!"=="1" (
        goto checkWine
    )

    goto selectFilename
)

REM Wine doesn't support powershell
:checkWine
reg query HKEY_CURRENT_USER\Software\Wine\DllOverrides >nul 2>&1
if %errorlevel%==0 (
    echo.
    echo Using wine, skipping over spoofing checks.
    echo If you need, you can disable spoofing by setting Dxgi=false in the config
    echo.
    pause
    goto completeSetup
) 

if exist %windir%\system32\nvapi64.dll (
    echo.
    echo Nvidia driver files detected.
    set isNvidia=true
) else (
    set isNvidia=false
)

REM Query user for GPU type
echo.
set "CE_TEXT=Are you using an Nvidia GPU or AMD/Intel GPU?"
call :cEcho White
echo.
echo [1] AMD/Intel
echo [2] Nvidia
echo.

:gpuPrompt
if "%isNvidia%"=="true" (
    set /p gpuChoice="Enter 1 or 2 (Detected Nvidia): "
) else (
    set /p gpuChoice="Enter 1 or 2 (Detected AMD/Intel): "
)

if "%gpuChoice%"=="1" goto gpuValid
if "%gpuChoice%"=="2" goto gpuValid
set "CE_TEXT=Invalid input. Please enter 1 or 2."
call :cEcho Red
echo.
goto gpuPrompt

:gpuValid

REM Skip spoofing if Nvidia
if "%gpuChoice%"=="2" (
    goto completeSetup
)

REM Query user for DLSS
echo.
if "%LANG%"=="ko" goto dlss_ko
:dlss_en
echo Will you try to use DLSS inputs to replace with FSR/XeSS? (enables Nvidia spoofing, required for DLSS-FG, Reflex-^>AL2)
echo If you want to change the setting later, edit OptiScaler.ini and set Dxgi=false to disable spoofing and reverse.
echo.
echo [1] Yes
echo [2] No
echo.
set /p enablingSpoofing="Enter 1 or 2 (or press Enter for Yes): "
goto dlss_cont
:dlss_ko
echo DLSS 입력을 FSR/XeSS로 대체하시겠습니까? (Nvidia 스푸핑 활성화, DLSS-FG와 Reflex-^>AL2에 필요)
echo 나중에 설정을 바꾸려면 OptiScaler.ini에서 Dxgi=false로 설정해 스푸핑을 해제하세요.
echo.
echo [1] 예
echo [2] 아니요
echo.
set /p enablingSpoofing="1 또는 2를 입력하세요 (기본은 Enter=예): "
:dlss_cont

set configFile=OptiScaler.ini
if "%enablingSpoofing%"=="2" (
    if not exist "%configFile%" (
        set "CE_TEXT=Config file not found: %configFile%"
        call :cEcho Red
        pause
    )

    powershell -Command "(Get-Content '%configFile%') -replace 'Dxgi=auto', 'Dxgi=false' | Set-Content '%configFile%'"
)

REM Decide whether to run OptiPatcher
echo.
if "%gpuChoice%"=="1" (
    echo AMD/Intel GPU detected - running OptiPatcher check.
    goto checkExistingOptiPatcher
)

:checkExistingOptiPatcher
set "foundOptiPatcher="
for %%F in (OptiScaler\plugins\*OptiPatcher*.asi) do (
    set "foundOptiPatcher=%%F"
)

if defined foundOptiPatcher (
    echo.
    if "%LANG%"=="ko" goto redl_ko
:redl_en
    echo OptiPatcher found: !foundOptiPatcher!
    echo If the existing version works properly, might be best to keep it.
	set "CE_TEXT=Do you want to re-download a possibly newer version?"
	call :cEcho White
	echo.
    echo [1] Yes
    echo [2] No
    echo.
	set /p optiRedownload="Waiting - "
    goto redl_cont
:redl_ko
    echo OptiPatcher 발견: !foundOptiPatcher!
    echo 기존 버전이 제대로 작동한다면 그대로 둔 것이 좋을 수 있습니다.
	set "CE_TEXT=더 새로운 버전을 다시 다운로드하시겠습니까?"
	call :cEcho White
	echo.
    echo [1] 예
    echo [2] 아니요
    echo.
	set /p optiRedownload="Waiting - "
:redl_cont
    if /i "!optiRedownload!"=="1" (
        echo.
        echo Deleting !foundOptiPatcher!...
        del "!foundOptiPatcher!"
        goto checkOptiPatcher
    ) else (
        echo.
        echo Keeping existing OptiPatcher - skipping download.
        goto completeSetup
    )
)

REM Not installed - continue to download
goto checkOptiPatcher

:checkOptiPatcher
REM Check connectivity
echo.
set "CE_TEXT=Checking for OptiPatcher compatibility..."
call :cEcho Cyan
echo Press Ctrl+C if this gets stuck to skip to setup completion.

ping -n 1 -w 3000 github.com >nul 2>&1
if %errorlevel% neq 0 (
    set "CE_TEXT=Offline or GitHub blocked. Skipping OptiPatcher check."
    call :cEcho Yellow
    goto completeSetup
)

set "OPTI_MATCH=NO"
for /f "usebackq tokens=*" %%A in (`powershell -Command "& { $rawUrl = 'https://raw.githubusercontent.com/optiscaler/OptiPatcher/main/OptiPatcher/dllmain.cpp'; try { $code = (Invoke-WebRequest -Uri $rawUrl -UseBasicParsing).Content } catch { return 'ERR' }; $supported = @(); $ueMatches = [Regex]::Matches($code, 'CHECK_UE\s*\(\s*([a-zA-Z0-9_]+)\s*\)'); foreach ($m in $ueMatches) { $base = $m.Groups[1].Value; $supported += ($base + '-win64-shipping.exe').ToLower(); $supported += ($base + '-wingdk-shipping.exe').ToLower(); }; $directMatches = [Regex]::Matches($code, 'exeName\s*==\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]'); foreach ($m in $directMatches) { $supported += $m.Groups[1].Value.ToLower(); }; $localFiles = Get-ChildItem *.exe | Select-Object -ExpandProperty Name; foreach ($file in $localFiles) { if ($supported -contains $file.ToLower()) { Write-Output 'YES'; exit; } }; Write-Output 'NO'; }"`) do (
    set "OPTI_MATCH=%%A"
)

if "!OPTI_MATCH!"=="YES" (
    echo.
    if "%LANG%"=="ko" goto dlopt_ko
:dlopt_en
    echo OptiPatcher support detected^^!
    echo An Opti plugin used for unlocking DLSS/DLSS-FG inputs, avoiding spoofing and performance overhead in supported games.
    echo More info available on OptiPatcher Github
    echo.
	set "CE_TEXT=Download OptiPatcher.asi?"
	call :cEcho White
    echo.
	echo [1] Yes
    echo [2] No
    echo.
	set /p downloadOptiPatcher="Waiting - "
    goto dlopt_cont
:dlopt_ko
    echo OptiPatcher 지원이 감지되었습니다^^!
    echo 지원되는 게임에서 DLSS/DLSS-FG 입력을 잠금 해제하고 스푸핑 및 성능 오버헤드를 피하기 위한 Opti 플러그인입니다.
    echo 자세한 내용은 OptiPatcher Github에서 확인하세요.
    echo.
	set "CE_TEXT=OptiPatcher.asi를 다운로드하시겠습니까?"
	call :cEcho White
    echo.
	echo [1] 예
    echo [2] 아니요
    echo.
	set /p downloadOptiPatcher="Waiting - "
:dlopt_cont
    set downloadOptiPatcher=!downloadOptiPatcher: =!
    
    if "!downloadOptiPatcher!"=="1" (
        echo.
        set "CE_TEXT=Preparing plugins folder..."
        call :cEcho Cyan
        if not exist "OptiScaler\plugins" mkdir "OptiScaler\plugins"
        
        set "CE_TEXT=Downloading OptiPatcher..."
        call :cEcho Cyan
        echo Press Ctrl+C if this gets stuck to skip to setup completion.
        echo.
        powershell -Command "Invoke-WebRequest -Uri 'https://github.com/optiscaler/OptiPatcher/releases/download/rolling/OptiPatcher.asi' -OutFile 'OptiScaler\plugins\OptiPatcher.asi'"
        if errorlevel 1 goto completeSetup
        
        if exist "OptiScaler\plugins\OptiPatcher.asi" (
            set "CE_TEXT=OptiPatcher.asi downloaded successfully."
            call :cEcho Green
            echo Enabling ASI loading in OptiScaler.ini...
            if exist "%configFile%" (
                powershell -Command "(Get-Content '%configFile%') -replace 'LoadAsiPlugins=auto', 'LoadAsiPlugins=true' | Set-Content '%configFile%'"
                echo Successfully enabled ASI loading in OptiScaler.ini^^!
            ) else (
                set "CE_TEXT=Warning: OptiScaler.ini not found, could not enable LoadAsiPlugins."
                call :cEcho Yellow
            )
        ) else (
            set "CE_TEXT=Failed to download OptiPatcher.asi."
            call :cEcho Red
        )
     timeout /t 3
    )
)
echo.

goto completeSetup

:completeSetup
REM Rename OptiScaler file
echo.
if "!overwriteChoice!"=="1" (
    set "CE_TEXT=Removing previous %selectedFilename%..."
    call :cEcho Cyan
    del /F %selectedFilename% 
)

set "CE_TEXT=Renaming OptiScaler file to %selectedFilename%..."
call :cEcho Cyan
rename "%optiScalerFile%" %selectedFilename%
if errorlevel 1 (
    echo.
    set "CE_TEXT=ERROR: Failed to rename OptiScaler file to %selectedFilename%. Most likely due to folder permissions issues."
    call :cEcho Red
    echo Please rename OptiScaler.dll manually to %selectedFilename%^^! No need to run setup BAT again after that.
    echo.
    goto end
)

goto create_uninstaller

:create_uninstaller_return

cls
set "CE_TEXT= OptiScaler setup completed successfully..."
call :cEcho Green
echo.
echo   ___                 
echo  (_         '        
echo  /__  /)   /  () (/  
echo          _/      /    
echo.

set setupSuccess=true

REM Neural Rendering is optional; install the model separately as documented in INSTALL-DLSSNR.md.
if "%setupSuccess%"=="true" (
    echo.
    echo Neural Rendering is off by default. See INSTALL-DLSSNR.md for the model runtime
    echo and enable it in the OptiScaler overlay when the ordinary upscaler works.
    echo NR uses OptiScaler, your nvngx_dlssnr.dll, and the installed NVIDIA driver.
    echo No separate NR helper DLL is required or supplied.
)

:end
pause

if "%setupSuccess%"=="true" (
    del "setup_linux.sh"
    del "%~nx0"
)

exit /b

REM --- cEcho: one colored line per screen accent (single Write-Host call) ---
:cEcho
REM %1 = ForegroundColor (Cyan/Green/Yellow/Red/White); text from CE_TEXT; +[char]13 keeps echo-like CRLF
powershell -NoProfile -Command "Write-Host ($env:CE_TEXT + [char]13) -ForegroundColor %1"
exit /b 0

:create_uninstaller
setlocal DisableDelayedExpansion

(
echo @echo off
echo setlocal EnableDelayedExpansion
echo cls
echo echo  ::::::::  :::::::::  ::::::::::: :::::::::::  ::::::::   ::::::::      :::     :::        :::::::::: :::::::::  
echo echo :+:    :+: :+:    :+:     :+:         :+:     :+:    :+: :+:    :+:   :+: :+:   :+:        :+:        :+:    :+: 
echo echo +:+    +:+ +:+    +:+     +:+         +:+     +:+        +:+         +:+   +:+  +:+        +:+        +:+    +:+ 
echo echo +#+    +:+ +#++:++#+      +#+         +#+     +#++:++#++ +#+        +#++:++#++: +#+        +#++:++#   +#++:++#:  
echo echo +#+    +#+ +#+            +#+         +#+            +#+ +#+        +#+     +#+ +#+        +#+        +#+    +#+ 
echo echo #+#    #+# #+#            #+#         #+#     #+#    #+# #+#    #+# #+#     #+# #+#        #+#        #+#    #+# 
echo echo  ########  ###            ###     ###########  ########   ########  ###     ### ########## ########## ###    ### 
echo echo.
echo echo Coping is strong with this one...
echo echo v2.8 - now with OptiPatcher support
echo echo.
echo if "%LANG%"=="ko" echo Susemi-next 한국어 UI 팩 - wilsjo2 v0.8.8 기반
echo if not "%LANG%"=="ko" echo Susemi-next UI Language Pack - wilsjo2 v0.8.8 based
echo if "%LANG%"=="ko" echo 한국어가 기본 언어로 선택되었습니다. [2] English를 고르면 영어로 진행합니다.
echo if not "%LANG%"=="ko" echo Korean is selected as the default language. Choose [2] English to proceed in English.
echo echo.
echo REM Check if OptiScaler installation exists
echo set "OLD_FILES_FOUND=0"
echo set "OPTI_DLL_LIST="
echo if exist OptiScaler.asi set "OLD_FILES_FOUND=1"

echo for %%%%F in ^(dxgi.dll winmm.dll d3d12.dll dbghelp.dll version.dll wininet.dll winhttp.dll^) do ^(
echo     if exist "%%%%F" ^(
echo         set "origname="
echo         for /f "tokens=*" %%%%P in ^('powershell -NoProfile -Command "(Get-Item '%%%%F').VersionInfo.OriginalFilename"'^) do ^(
echo             set "origname=%%%%P"
echo         ^)
echo         if /i "!origname!"=="OptiScaler.dll" ^(
echo             set "OLD_FILES_FOUND=1"
echo             set "OPTI_DLL_LIST=!OPTI_DLL_LIST! %%%%F"
echo         ^)
echo     ^)
echo ^)

echo if "!OLD_FILES_FOUND!"=="1" ^(
echo     if "%LANG%"=="ko" echo 기존 OptiScaler 설치가 감지되었습니다^^^^!
echo     if not "%LANG%"=="ko" echo Existing OptiScaler installation detected^^^^!
echo     if exist OptiScaler.asi echo   - OptiScaler.asi
echo     for %%%%F in ^(!OPTI_DLL_LIST!^) do echo   - %%%%F - original filename: OptiScaler.dll
echo     echo.
echo ^)

echo if "%LANG%"=="ko" echo OptiScaler를 제거하시겠습니까?
echo if not "%LANG%"=="ko" echo Do you want to remove OptiScaler?
echo echo.
echo if "%LANG%"=="ko" echo [1] 예
echo if not "%LANG%"=="ko" echo [1] Yes
echo if "%LANG%"=="ko" echo [2] 아니요
echo if not "%LANG%"=="ko" echo [2] No
echo echo.
echo set /p removeChoice="Waiting - "
echo echo.

echo if "%%removeChoice%%"=="1" ^(
echo     del OptiScaler.log
echo     del OptiScaler.ini
echo     del OptiScaler.asi
echo     for %%%%F in ^(!OPTI_DLL_LIST!^) do ^(del "%%%%F"^)
echo     del /Q Licenses\*
echo     rd Licenses
echo     del /Q OptiScaler\D3D12_Optiscaler\*
echo     rd OptiScaler\D3D12_Optiscaler
echo     del /Q OptiScaler\Streamline\*
echo     rd OptiScaler\Streamline
echo     del /Q OptiScaler\streamline\*
echo     rd OptiScaler\streamline
echo     echo.
echo     if "%LANG%"=="ko" echo OptiPatcher가 있으면 삭제합니다
echo     if not "%LANG%"=="ko" echo Deleting OptiPatcher if present
echo     del /Q OptiScaler\plugins\*
echo     rd OptiScaler\plugins
echo     echo.
echo     del /Q OptiScaler\*
echo     rd OptiScaler
echo     echo.
echo     if "%LANG%"=="ko" echo OptiScaler가 제거되었습니다^^^^! 없는 파일 경고는 무시하세요.
echo     if not "%LANG%"=="ko" echo OptiScaler removed^^^^! Ignore the warnings about missing files.
echo     echo.
echo ^) else ^(
echo     echo.
echo     if "%LANG%"=="ko" echo 작업이 취소되었습니다.
echo     if not "%LANG%"=="ko" echo Operation cancelled.
echo     echo.
echo ^)

echo.
echo pause
echo if "%%removeChoice%%"=="1" ^(
echo     del "%%~nx0"
echo ^)
) > "Remove_OptiScaler.bat"

endlocal
echo.
echo Uninstaller created.
echo.

goto create_uninstaller_return

REM ============================================================
REM Orchestrated (noninteractive) staging mode.
REM Entered only when the first argument is --orchestrated; the legacy
REM interactive flow above is untouched. Operates on a private staging
REM copy only: no prompts, no network, no config edits, no uninstaller
REM generation, no pause and no self-delete. Deletes nothing; the caller
REM must pass a free staging directory as the cwd.
REM Usage: setup_windows.bat --orchestrated <asi|proxy> [--exename <name>]
REM Requires env SUSEMI_ORCH_STAGE=1 and OptiScaler.dll in the cwd.
REM Emits one ASCII machine line (status=...) first, then a human line.
REM ============================================================
:orch_main
setlocal EnableDelayedExpansion

set "ORCH_ROUTE=%~2"
set "ORCH_EXENAME="
if /i "%~3"=="--exename" set "ORCH_EXENAME=%~4"

if /i "!ORCH_ROUTE!"=="asi" goto orch_route_ok
if /i "!ORCH_ROUTE!"=="proxy" goto orch_route_ok
echo status=invalid-invocation reason=bad-route
exit /b 2

:orch_route_ok
REM Tolerate cmd's `set VAR=1 && ...` trailing space; the value must still be exactly 1.
set "ORCH_STAGE=!SUSEMI_ORCH_STAGE: =!"
if not "!ORCH_STAGE!"=="1" (
    echo status=invalid-invocation reason=stage-env-missing
    exit /b 2
)

if not "!ORCH_EXENAME!"=="" (
    set "ORCH_BADNAME="
    if not "!ORCH_EXENAME:\=!"=="!ORCH_EXENAME!" set "ORCH_BADNAME=1"
    if not "!ORCH_EXENAME:/=!"=="!ORCH_EXENAME!" set "ORCH_BADNAME=1"
    if defined ORCH_BADNAME (
        echo status=invalid-invocation reason=bad-exename
        exit /b 2
    )
)

if not exist "OptiScaler.dll" (
    echo status=install-failed reason=missing-optiscaler-dll
    exit /b 1
)

if /i "!ORCH_ROUTE!"=="asi" (
    set "ORCH_TARGET=OptiScaler.asi"
    set "ORCH_REASON=asi"
) else (
    set "ORCH_TARGET=!ORCH_EXENAME!"
    if "!ORCH_TARGET!"=="" set "ORCH_TARGET=dxgi.dll"
    set "ORCH_REASON=proxy"
)

if /i "!ORCH_TARGET!"=="OptiScaler.dll" (
    echo status=install-failed reason=target-equals-source
    exit /b 1
)
if exist "!ORCH_TARGET!" (
    echo status=install-failed reason=target-exists
    exit /b 1
)

rename "OptiScaler.dll" "!ORCH_TARGET!" >nul 2>&1
if errorlevel 1 (
    echo status=install-failed reason=rename-failed
    exit /b 1
)
if not exist "!ORCH_TARGET!" (
    echo status=install-failed reason=verify-target-missing
    exit /b 1
)
if exist "OptiScaler.dll" (
    echo status=install-failed reason=verify-source-remains
    exit /b 1
)

echo status=staged reason=!ORCH_REASON! staged=!ORCH_TARGET!
echo Staged OptiScaler payload as !ORCH_TARGET!.
exit /b 0
