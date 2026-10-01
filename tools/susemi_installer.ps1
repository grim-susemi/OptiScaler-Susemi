#Requires -Version 5.1
<#
.SYNOPSIS
  susemi_installer.ps1 - one-entry coordinator for the guided installer
  (plan todo T10; diagnose T4, install T7, ReShade-first T8, remove T9).

  All three actions live in this file and its owned children:
    diagnose - read-only inspection: no writes, no network, no process launch.
    install  - %TEMP% staging from pinned shipped payloads (or explicit rc2 ZIP), then the owned
               tools/susemi_transaction.ps1 plan/prepare/apply/verify plus an
               independent post-apply byte check and recover on any failure.
    remove   - journal-driven reverse of a prior install via
               tools/susemi_transaction.ps1 rollback; REQUIRES -Consent yes and
               validates the entire undo group before touching a byte.
  No action changes the console input/output codepage; Korean literals rely on
  this script being UTF-8 with BOM.

.CONTRACT
  No arguments -> one guided session in THIS process: language select
    (Korean default, [2] English) -> game EXE picker (OpenFileDialog with
    paste-path fallback) -> read-only diagnosis screen -> same-process install
    offer -> result screen. Every screen asks one question with numbered
    choices and an Enter default; nothing is installed without an explicit yes,
    and ReShade-first is offered only when eligible. Never requires a second
    launch.
  Argument modes (noninteractive, fixture/suite-driven):
    diagnose -Exe <path> [-Lang ko|en]
    install  -Exe <path> -Consent yes|no [-Route asi|proxy] [-ProxyName <name>]
             [-ReshadeFirst [-IniConsent yes|no] [-ConvertReshade]] [-Lang ...]
    remove   -Exe <path> -Consent yes|no [-Lang ...]
  Exit values: 0 = ready/success/no-op, 1 = refused/failed, 2 = invalid
    invocation (unknown/missing args).
  Output contract: every invocation prints EXACTLY ONE machine-readable
    "status=<word> reason=<token>" line, as its final status. All intermediate
    progress (child-process stdout/stderr, plan/prepare/apply/recover steps) is
    emitted with a "trace| " prefix ("trace! " for child stderr) so it stays
    visible by default yet never matches a "^status=" parser. Byte-preview
    lines keep their "preview| " prefix.
#>

$ErrorActionPreference = 'Stop'

$Messages = @{
  ko = @{
    LangPrompt      = '[1] 한국어 (기본값)'
    LangPrompt2     = '[2] English'
    LangAsk         = '언어를 선택하세요 [1/2, Enter=1]'
    LangChosen      = '언어: {0}'
    ExePickerTitle  = '게임 실행 파일(.exe) 선택'
    NoGuiFallback   = '파일 선택 대화상자를 열 수 없어 경로를 직접 입력받습니다.'
    ExeAsk          = '게임 실행 파일(.exe) 전체 경로를 붙여넣으세요 (취소: 빈 입력)'
    ExeChosen       = '선택한 실행 파일: {0}'
    ExeCancelled    = '실행 파일이 선택되지 않아 종료합니다. 설치하지 않았습니다.'
    AdvisoryAsk     = '이 게임이 GTA V Enhanced입니까? [1] 기타/확실하지 않음 (기본값)  [2] GTA V Enhanced'
    AdvisoryGtavEnhanced = @(
      'GTA V Enhanced 주의사항 (자동 판별이 아니라 사용자가 직접 선택한 경우의 안내입니다):'
      '공식 위키 기준으로 모드 사용 시 BattlEye를 꺼야 하며, 온라인 접속에는 사용하지 마세요.'
      'XeFG 호환성과 보고된 프리즈 원인은 아직 확인되지 않았습니다. 지금은 실패한 FG 경로를 끄고 사용하세요.'
      '확인을 위해 GPU, 정확한 패키지/코어 빌드, FG 입력/출력, 게임 내 FG 토글, HDR/창 모드, 활성화·실패 시점의 OptiScaler.log 구간을 알려주세요.'
      '네이티브 DLSS-FG 존재만으로는 충돌 근거가 아닙니다. README의 제한은 OptiFG+HUDfix에 한정된 내용입니다.'
      'DirectStorageFix는 상위 INI 저장 관련 참고일 뿐이며 자동 적용하거나 프리즈 해결책으로 지정하지 않습니다.'
      '게임 호환성을 보장하지 않습니다.'
    )
    HoldPrompt      = 'Enter를 누르면 창이 닫힙니다.'
    NextActions = @{
      'exe-not-found' = '게임 실행 파일을 다시 선택하세요.'
      'not-x64' = 'x64 게임 실행 파일을 선택하세요.'
      'game-running' = '게임을 종료한 뒤 다시 시도하세요.'
      'ual-config-conflict' = '위에 표시된 로더와 설정 파일을 확인하세요.'
      'reshade-referenced-but-absent' = '설정이 참조하는 ReShade 파일을 준비하세요.'
      'reshade-identity-unverified' = 'ReShade 파일의 출처를 확인하세요.'
      'unsupported-state' = '기존 로더와 모드 설치 상태를 확인하세요.'
      'non-winmm-loader' = '기존 로더를 확인하세요. 자동 변환하지 않습니다.'
      'exe-selection-cancelled' = '설치한 파일이 없습니다.'
      'guided-target-conflict' = '설치 대상 파일과 기존 로더를 확인하세요. 자동 교체하지 않습니다.'
    }
    InstallAsk      = '설치를 진행할까요? [1] 아니요 (기본값)  [2] 예'
    Declined        = '동의하지 않아 설치하지 않았습니다.'
    InstallConsentRequired = '동의(Consent)가 필요합니다. -Consent yes 로 다시 실행하세요.'
    InstallRunning  = '게임 확인 필요: 게임이 실행 중입니다. 게임을 종료한 뒤 다시 설치하세요.'
    InstallConflict = '충돌: 설치를 중단했습니다. 위 이유를 해결한 뒤 다시 시도하세요.'
    PackagePayloadMissing = '패키지 페이로드가 없습니다. 전체 패키지를 새 폴더에 다시 압축 해제한 뒤 설치하세요.'
    PackagePayloadMismatch = '패키지 페이로드를 검증할 수 없습니다. 올바른 패키지를 새 폴더에 다시 압축 해제한 뒤 설치하세요.'
    InstallInstalled = '설치 완료: 페이로드 바이트를 검증했습니다.'
    InstallFailed   = '설치 실패: 변경 사항을 복구했습니다.'
    ReshadeFirstAsk = 'ReShade를 먼저 로드하도록 winmm.ini를 설정할까요? [1] 아니요 (기본값)  [2] 예'
    ReshadeFirstSkip = 'ReShade 우선 설정을 건너뜁니다 (사유: {0}).'
    IniConsentRequired = 'INI 동의가 필요합니다. -IniConsent yes 로 다시 실행하세요.'
    IniCreated      = 'ReShade 우선 설정: winmm.ini 를 새로 만들었습니다.'
    IniExtended     = 'ReShade 우선 설정: winmm.ini 에 키를 추가했습니다 (기존 바이트 보존).'
    IniNoOp         = 'ReShade 우선 설정: 이미 올바르게 설정되어 있어 수정하지 않았습니다 (소유권 주장 없음).'
    IniLaterOverride = 'ReShade 우선 설정이 나중 파일에 의해 덮어써집니다 (파일: {0}, 키: loadextraplugins={1}). 그 파일은 자동으로 수정하지 않습니다.'
    IniUnowned      = 'INI 거부: winmm.ini 가 이 설치 프로그램 소유가 아니므로 수정하지 않습니다. 수동으로 [globalsets] 섹션에 loadextraplugins=ReShade.asi 를 추가하거나, 파일을 백업한 뒤 관리자에게 문의하세요. 설치 프로그램은 소유하지 않은 INI를 편집하지 않습니다.'
    IniKeyPresent   = 'INI 거부: winmm.ini 에 이미 loadextraplugins 키가 있습니다. 기존 키를 자동으로 덮어쓰지 않습니다. 수동으로 값을 확인/수정하세요.'
    ConvertWarn     = 'ReShade 변환: {0} -> ReShade.asi 를 복사로 생성했습니다 (원본 유지). 게임이 두 경로를 모두 로드할 수 있습니다.'
    Usage           = '사용법: diagnose -Exe <path> [-Lang ko|en] | install -Exe <path> -Consent yes|no [-Route asi|proxy] [-ProxyName <name>] [-ReshadeFirst [-IniConsent yes|no] [-ConvertReshade]] [-Lang ...] | remove -Exe <path> -Consent yes|no [-Lang ...]'
    ResultTitle     = '설치 결과'
    ResultOwnerVerify = '게임 내 확인은 소유자만 가능합니다: 게임을 실행해 OptiScaler가 로드되는지 직접 확인하세요.'
    ResultBackup    = '백업 위치: {0}'
    ResultRemoveHow = '제거 방법: Install_OptiScaler_windows.bat remove -Exe "{0}" -Consent yes'
    InstallEta      = '설치는 보통 1~2분 걸립니다. 창을 닫지 마세요.'
    ProgressHeader  = '설치 진행'
    ProgressSuffix  = '(1~2분 소요)'
    StageBusy       = @('패키지 준비 중...', '패키지 구성 중...', '설치 계획 수립 중...', '백업 준비 중...', '파일 적용 중...')
    StageDone       = @('패키지 준비 완료', '패키지 구성 완료', '설치 계획 수립 완료', '백업 준비 완료', '파일 적용 완료')
  }
  en = @{
    LangPrompt      = '[1] 한국어 (Korean, default)'
    LangPrompt2     = '[2] English'
    LangAsk         = 'Select language [1/2, Enter=1]'
    LangChosen      = 'Language: {0}'
    ExePickerTitle  = 'Select the game executable (.exe)'
    NoGuiFallback   = 'File dialog unavailable; pasting the path instead.'
    ExeAsk          = 'Paste the full path of the game .exe (empty input cancels)'
    ExeChosen       = 'Selected executable: {0}'
    ExeCancelled    = 'No executable selected; exiting. Nothing was installed.'
    AdvisoryAsk     = 'Is this game GTA V Enhanced? [1] Other / not sure (default)  [2] GTA V Enhanced'
    AdvisoryGtavEnhanced = @(
      'GTA V Enhanced caution (from your explicit selection, not automatic identification):'
      'Per the official wiki, mod use requires BattlEye disabled; do not use it online.'
      'XeFG compatibility and this reported freeze cause are still unconfirmed. For now, disable the failing FG route.'
      'To help confirm, report GPU, exact package/core build, FG input/output, the in-game FG toggle, HDR/window mode, and the OptiScaler.log section around enabling/failure.'
      'Native DLSS-FG presence alone is not conflict proof. The README limitation is specifically about OptiFG + HUDfix.'
      'DirectStorageFix is only an upstream INI-save note; it is not installed automatically or prescribed as a freeze fix.'
      'No game compatibility is promised.'
    )
    HoldPrompt      = 'Press Enter to close this window.'
    NextActions = @{
      'exe-not-found' = 'Select the game executable again.'
      'not-x64' = 'Select an x64 game executable.'
      'game-running' = 'Close the game and retry.'
      'ual-config-conflict' = 'Inspect the named loader and configuration files.'
      'reshade-referenced-but-absent' = 'Supply the referenced ReShade file.'
      'reshade-identity-unverified' = 'Verify the source of the ReShade file.'
      'unsupported-state' = 'Inspect the existing loader and mod installation.'
      'non-winmm-loader' = 'Inspect the existing loader. It is not converted automatically.'
      'exe-selection-cancelled' = 'Nothing was installed.'
      'guided-target-conflict' = 'Inspect the install targets and existing loaders. They are not replaced automatically.'
    }
    InstallAsk      = 'Proceed with install? [1] No (default)  [2] Yes'
    Declined        = 'Consent not given; nothing was installed.'
    InstallConsentRequired = 'Consent required: re-run with -Consent yes.'
    InstallRunning  = 'Game verification required: the game is running. Close it and install again.'
    InstallConflict = 'Conflict: install stopped. Resolve the reason above and retry.'
    PackagePayloadMissing = 'Package payload missing. Extract the complete package into a new folder and retry.'
    PackagePayloadMismatch = 'Package payload could not be verified. Extract a valid package into a new folder and retry.'
    InstallInstalled = 'Installed: payload bytes verified.'
    InstallFailed   = 'Install failed: changes were recovered.'
    ReshadeFirstAsk = 'Also set winmm.ini so ReShade loads first? [1] No (default)  [2] Yes'
    ReshadeFirstSkip = 'Skipping the ReShade-first setting (reason: {0}).'
    IniConsentRequired = 'INI consent required: re-run with -IniConsent yes.'
    IniCreated      = 'ReShade-first: created winmm.ini.'
    IniExtended     = 'ReShade-first: added the key to winmm.ini (existing bytes preserved).'
    IniNoOp         = 'ReShade-first: already correctly configured; nothing was written and no ownership is claimed.'
    IniLaterOverride = 'ReShade-first is overridden by a later file (file: {0}, key: loadextraplugins={1}). That file is never edited automatically.'
    IniUnowned      = 'INI refused: winmm.ini is not owned by this installer, so it will not be modified. Manually add loadextraplugins=ReShade.asi under [globalsets], or back the file up and ask the owner. The installer never edits an unowned INI.'
    IniKeyPresent   = 'INI refused: winmm.ini already defines loadextraplugins. An existing key is never overwritten automatically; review or change the value by hand.'
    ConvertWarn     = 'ReShade conversion: created ReShade.asi as a COPY of {0} (original kept). The game may load both routes.'
    Usage           = 'Usage: diagnose -Exe <path> [-Lang ko|en] | install -Exe <path> -Consent yes|no [-Route asi|proxy] [-ProxyName <name>] [-ReshadeFirst [-IniConsent yes|no] [-ConvertReshade]] [-Lang ...] | remove -Exe <path> -Consent yes|no [-Lang ...]'
    ResultTitle     = 'Install result'
    ResultOwnerVerify = 'In-game confirmation is owner-only: launch the game and verify OptiScaler loads yourself.'
    ResultBackup    = 'Backup location: {0}'
    ResultRemoveHow = 'To remove: Install_OptiScaler_windows.bat remove -Exe "{0}" -Consent yes'
    InstallEta      = 'Installation usually takes 1-2 minutes. Do not close this window.'
    ProgressHeader  = 'Installing'
    ProgressSuffix  = '(takes 1-2 min)'
    StageBusy       = @('Preparing package...', 'Building package...', 'Planning install...', 'Preparing backup...', 'Applying files...')
    StageDone       = @('Package prepared', 'Package assembled', 'Plan complete', 'Backup prepared', 'Files applied')
  }
}

function Write-StatusLine {
  param([string]$Status, [string]$Reason, [string]$Human)
  Write-Output ("status={0} reason={1}" -f $Status, $Reason)
  if (-not [string]::IsNullOrEmpty($Human)) { Write-Output $Human }
}

function Get-LangTable {
  param([string]$Lang)
  $l = 'ko'
  if ($Lang -eq 'en') { $l = 'en' }
  return $Messages[$l]
}

function Test-InteractiveInputAvailable {
  # True only when this process's caller can actually complete the Win32 file
  # dialog. With piped/redirected stdin (a scripted no-arg session) or no usable
  # console UI, ShowDialog cannot be answered and would block the whole session,
  # so the guided flow must use the paste-path prompt instead.
  try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
  try {
    $ui = $Host.UI
    if ($null -eq $ui) { return $false }
    $null = $ui.RawUI
  } catch { return $false }
  return $true
}

function Read-GameExePaste {
  # Paste-path prompt; Read-Host reads the next stdin line, so this works with a
  # real console and with piped stdin alike (same wording as the GUI fallback).
  param($M)
  $p = Read-Host $M.ExeAsk
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  return $p.Trim().Trim('"')
}

function Select-GameExe {
  # Returns @{ path = <string|$null>; notice = <string> }. `notice` is the
  # human explanation shown when the dialog was unavailable (empty when the real
  # dialog ran); the caller prints it, so prompt text never leaks into `path`.
  param($M)
  if (-not (Test-InteractiveInputAvailable)) {
    # Non-interactive stdin: skip the blocking dialog, use the existing paste
    # prompt in this same process. Interactive real-console behavior is unchanged.
    return @{ path = (Read-GameExePaste -M $M); notice = $M.NoGuiFallback }
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Game executable (*.exe)|*.exe|All files (*.*)|*.*'
    $dlg.Title = $M.ExePickerTitle
    $res = $dlg.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return @{ path = $dlg.FileName; notice = '' } }
    return @{ path = $null; notice = '' }
  } catch {
    # No GUI thread (e.g. MTA console) -> paste-path fallback, same process.
    return @{ path = (Read-GameExePaste -M $M); notice = $M.NoGuiFallback }
  }
}

function Get-PeValid {
  # True only for a structurally valid x64 PE image (MZ + e_lfanew -> PE\0\0 + 0x8664).
  param([string]$p)
  try {
    $b = [System.IO.File]::ReadAllBytes($p)
    if ($b.Length -lt 134) { return $false }
    if ([char]$b[0] -ne 'M' -or [char]$b[1] -ne 'Z') { return $false }
    $lfanew = [System.BitConverter]::ToInt32($b, 0x3C)
    if (($lfanew -le 0) -or (($lfanew + 6) -gt $b.Length)) { return $false }
    if ([char]$b[$lfanew] -ne 'P' -or [char]$b[$lfanew+1] -ne 'E' -or [char]$b[$lfanew+2] -ne [char]0 -or [char]$b[$lfanew+3] -ne [char]0) { return $false }
    if ([System.BitConverter]::ToUInt16($b, ($lfanew + 4)) -ne 0x8664) { return $false }
    return $true
  } catch { return $false }
}

function Initialize-UalProfileReader {
  if ('Susemi.UalProfile' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Susemi {
  public static class UalProfile {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern uint GetPrivateProfileIntW(string section, string key, int fallback, string file);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern uint GetPrivateProfileStringW(string section, string key, string fallback, StringBuilder value, uint size, string file);
    public static uint Integer(string key, uint fallback, string file) {
      return GetPrivateProfileIntW("globalsets", key, unchecked((int)fallback), file);
    }
  }
}
'@ | Out-Null
}

function Get-DiagnosisContext {
  # Real read-only diagnosis (no writes, no network, no game launch). Builds the
  # full identity + effective-config state; Invoke-Diagnose renders it and the
  # ReShade-first gate reuses it. Every status/reason/human string is unchanged.
  param([string]$Exe, [string]$Lang, $M)
  $UILang = 'ko'
  if ($Lang -eq 'en') { $UILang = 'en' }
  $ko = ($UILang -eq 'ko')

  $ctx = @{
    code = 1; status = ''; reason = ''; human = ''; ko = $ko
    exePath = ''; exeDir = ''; exeSha = ''; exeOrig = ''; exeProd = ''
    isX64 = $false; gameRunning = $false
    cands = @(); candFiles = @(); installTargets = $null
    ualNames = @(); optiNames = @(); reshadeNames = @()
    hasLoader = $false; loaderBase = $null; hasOpti = $false; ualAmbiguous = $false
    reshadeExist = $false; reshadeValid = $false; reshadeReferenced = $false
    reshadeIniExists = $false; reshadeDirExists = $false
    effLoadPlugins = '1'; srcLoadPlugins = '(default)'
    effScriptsOnly = '0'; srcScriptsOnly = '(default)'
    effExtra = 'modloader\modloader.asi'; srcExtra = '(default)'
    extraOverridden = $false; extraOverrideFile = ''; extraDefs = @(); configReason = ''
    effList = @(); isReshadeOnly = $false
    proxyNames = @('dxgi.dll','d3d11.dll','d3d12.dll','dinput8.dll','winmm.dll','version.dll','wininet.dll','winhttp.dll','dsound.dll','dbghelp.dll')
  }

  $rawExe = $Exe
  if ([string]::IsNullOrEmpty($rawExe)) { $rawExe = '' }
  else { $rawExe = ([string]$rawExe).Trim().Trim('"') }
  $exePath = $rawExe
  try { $exePath = (Resolve-Path -LiteralPath $rawExe -ErrorAction Stop).Path } catch { $exePath = $rawExe }
  if ([string]::IsNullOrWhiteSpace($rawExe) -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    if ($ko) { $ctx.human = "진단: 실행 파일을 찾을 수 없습니다: $rawExe" } else { $ctx.human = "diagnose: exe not found: $rawExe" }
    $ctx.status = 'missing-input'; $ctx.reason = 'exe-not-found'
    return $ctx
  }
  $ctx.exePath = $exePath

  # 1. PE machine check (e_lfanew at 0x3C -> PE sig + 4, machine is bytes 4-5).
  $isX64 = $false
  try {
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    if ($bytes.Length -gt 0x40) {
      $lfanew = [System.BitConverter]::ToInt32($bytes, 0x3C)
      if (($lfanew -gt 0) -and (($lfanew + 6) -le $bytes.Length)) {
        if ([System.BitConverter]::ToUInt16($bytes, ($lfanew + 4)) -eq 0x8664) { $isX64 = $true }
      }
    }
  } catch { $isX64 = $false }
  $ctx.isX64 = $isX64
  if (-not $isX64) {
    if ($ko) { $ctx.human = "미지원: x64(0x8664) 실행 파일이 아닙니다: $exePath" } else { $ctx.human = "unsupported: not an x64 (0x8664) executable: $exePath" }
    $ctx.status = 'unsupported'; $ctx.reason = 'not-x64'
    return $ctx
  }

  $exeSha = ''
  try { $exeSha = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { $exeSha = '' }
  $ctx.exeSha = $exeSha
  $exeOrig = ''; $exeProd = ''
  try {
    $evi = (Get-Item -LiteralPath $exePath -ErrorAction Stop).VersionInfo
    $exeOrig = [string]$evi.OriginalFilename
    $exeProd = [string]$evi.ProductName
  } catch {}
  $ctx.exeOrig = $exeOrig; $ctx.exeProd = $exeProd

  # 2. Inventory the EXE directory ONLY (*.dll / *.asi, no recursion).
  $exeDir = Split-Path -Parent $exePath
  if ([string]::IsNullOrEmpty($exeDir)) { $exeDir = (Get-Location).Path }
  $ctx.exeDir = $exeDir
  # Enumerating directory entries also sees dangling links; Test-Path alone
  # cannot prove that an install target is genuinely absent.
  try {
    $ctx.installTargets = @(Get-ChildItem -LiteralPath $exeDir -Force -ErrorAction Stop | Where-Object {
      $_.Name -ieq 'winmm.dll' -or $_.Name -ieq 'OptiScaler.asi'
    } | ForEach-Object { @{ name = $_.Name; attributes = $_.Attributes } })
  } catch { $ctx.installTargets = $null }
  $cands = @()
  try { $cands = @(Get-ChildItem -LiteralPath $exeDir -File -ErrorAction Stop | Where-Object { ($_.Extension -ieq '.dll') -or ($_.Extension -ieq '.asi') }) } catch { $cands = @() }
  $ctx.cands = $cands
  $UAL_SHA = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
  $OPT_SHA = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
  $reshadeIniExists = Test-Path -LiteralPath (Join-Path $exeDir 'ReShade.ini')
  $reshadeDirExists = Test-Path -LiteralPath (Join-Path $exeDir 'reshade-shaders')
  $ctx.reshadeIniExists = $reshadeIniExists; $ctx.reshadeDirExists = $reshadeDirExists
  $ualNames = @(); $optiNames = @(); $reshadeNames = @()
  foreach ($f in $cands) {
    $sha = ''
    try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { $sha = '' }
    $orig = ''; $prod = ''
    try {
      $vi = (Get-Item -LiteralPath $f.FullName -ErrorAction Stop).VersionInfo
      $orig = [string]$vi.OriginalFilename
      $prod = [string]$vi.ProductName
    } catch {}
    if (($sha -eq $UAL_SHA) -or ($orig -ieq 'Ultimate-ASI-Loader-x64.dll')) { $ualNames += @($f.Name) }
    elseif (($sha -eq $OPT_SHA) -or ($orig -ieq 'OptiScaler.dll')) { $optiNames += @($f.Name) }
    elseif ($orig -like '*ReShade*' -or $prod -like '*ReShade*') { $reshadeNames += @($f.Name) }
    elseif (((($reshadeIniExists) -or ($reshadeDirExists)) -and ($f.Name -ieq 'ReShade.asi')) -and ($(Get-PeValid $f.FullName))) { $reshadeNames += @($f.Name) }
  }
  $ualAmbiguous = ((@($ualNames | Sort-Object -Unique)).Count -gt 1)
  $hasLoader = ($ualNames.Count -ge 1)
  $hasOpti = ($optiNames.Count -ge 1)
  $loaderBase = $null
  if ($hasLoader) { $loaderBase = [System.IO.Path]::GetFileNameWithoutExtension((@($ualNames | Sort-Object -Unique))[0]) }
  $ctx.ualNames = $ualNames; $ctx.optiNames = $optiNames; $ctx.reshadeNames = $reshadeNames
  $ctx.ualAmbiguous = $ualAmbiguous; $ctx.hasLoader = $hasLoader; $ctx.hasOpti = $hasOpti; $ctx.loaderBase = $loaderBase

  # 3. Effective UAL config (candidates in order, LAST file's value wins).
  $effLoadPlugins = '1'; $srcLoadPlugins = '(default)'
  $effScriptsOnly = '0'; $srcScriptsOnly = '(default)'
  $effExtra = 'modloader\modloader.asi'; $srcExtra = '(default)'
  $extraOverridden = $false; $extraOverrideFile = ''
  $extraDefs = @()
  $candFiles = @()
  if (-not $hasLoader) { $loaderBase = 'winmm' }
  $candFiles = @(
      (Join-Path $exeDir ($loaderBase + '.ini')),
      (Join-Path $exeDir 'global.ini'),
      (Join-Path $exeDir (Join-Path 'scripts' 'global.ini')),
      (Join-Path $exeDir (Join-Path 'plugins' 'global.ini')),
      (Join-Path $exeDir (Join-Path 'update' 'global.ini'))
  )
  $ctx.candFiles = $candFiles
  Initialize-UalProfileReader
  $candIdx = -1
  foreach ($cf in $candFiles) {
    $candIdx++
    # The pinned loader uses MAX_PATH paths/string buffers. Never certify an
    # unsupported path, unreadable file, or ambiguous full buffer as defaults.
    if ($cf.Length -ge 260) { $ctx.configReason = 'ual-config-path-limit'; break }
    try {
      $item = Get-Item -LiteralPath $cf -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] { continue }
    catch { $ctx.configReason = 'ual-config-unreadable'; break }
    try {
      if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsupported config entry' }
      $stream = [IO.File]::Open($cf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $stream.Dispose()
    } catch { $ctx.configReason = 'ual-config-unreadable'; break }
    foreach ($key in @('loadplugins', 'loadfromscriptsonly')) {
      # Two native defaults distinguish a contributing integer from a missing
      # or empty key, even when its value equals the carried default.
      $a = [Susemi.UalProfile]::Integer($key, 0, $cf)
      $b = [Susemi.UalProfile]::Integer($key, 1, $cf)
      if ($key -eq 'loadplugins') {
        $effLoadPlugins = [string][Susemi.UalProfile]::Integer($key, [uint32]$effLoadPlugins, $cf)
        if ($a -eq $b) { $srcLoadPlugins = $cf }
      } else {
        $effScriptsOnly = [string][Susemi.UalProfile]::Integer($key, [uint32]$effScriptsOnly, $cf)
        if ($a -eq $b) { $srcScriptsOnly = $cf }
      }
    }
    $value = New-Object System.Text.StringBuilder 260
    $length = [Susemi.UalProfile]::GetPrivateProfileStringW('globalsets', 'loadextraplugins', $effExtra, $value, 260, $cf)
    if ($length -ge 259) { $ctx.configReason = 'ual-config-string-limit'; break }
    $probeA = New-Object System.Text.StringBuilder 260
    $probeB = New-Object System.Text.StringBuilder 260
    $null = [Susemi.UalProfile]::GetPrivateProfileStringW('globalsets', 'loadextraplugins', '__susemi_missing_a__', $probeA, 260, $cf)
    $null = [Susemi.UalProfile]::GetPrivateProfileStringW('globalsets', 'loadextraplugins', '__susemi_missing_b__', $probeB, 260, $cf)
    if ($probeA.ToString() -eq $probeB.ToString()) {
      $srcExtra = $cf
      $extraDefs += @{ file = $cf; value = $value.ToString(); index = $candIdx }
    }
    $effExtra = $value.ToString()
  }
  $extraOverridden = ($extraDefs.Count -gt 1 -and $effExtra -ne $extraDefs[0].value)
  if ($extraOverridden) { $extraOverrideFile = $srcExtra }
  $ctx.effLoadPlugins = $effLoadPlugins; $ctx.srcLoadPlugins = $srcLoadPlugins
  $ctx.effScriptsOnly = $effScriptsOnly; $ctx.srcScriptsOnly = $srcScriptsOnly
  $ctx.effExtra = $effExtra; $ctx.srcExtra = $srcExtra
  $ctx.extraOverridden = $extraOverridden; $ctx.extraOverrideFile = $extraOverrideFile
  $ctx.extraDefs = $extraDefs
  $entries = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in $effExtra.Split('|')) {
    $clean = $entry.Trim([char[]]" `t`r`n")
    if ($clean.Length -ge 2 -and $clean[0] -eq '"' -and $clean[$clean.Length - 1] -eq '"') { $clean = $clean.Substring(1, $clean.Length - 2) }
    if ($clean -ne '' -and -not $entries.Contains($clean)) { $entries.Add($clean) }
  }
  $effList = @($entries.ToArray())
  $isReshadeOnly = (($effList.Count -eq 1) -and ($effList[0] -ieq 'ReShade.asi'))
  $ctx.effList = $effList; $ctx.isReshadeOnly = $isReshadeOnly

  $reshadeExist = Test-Path -LiteralPath (Join-Path $exeDir 'ReShade.asi')
  $reshadeValid = ($reshadeExist -and ($(Get-PeValid (Join-Path $exeDir 'ReShade.asi'))))
  $reshadeReferenced = ((@($effList | Where-Object { $_ -ieq 'ReShade.asi' })).Count -gt 0)
  $ctx.reshadeExist = $reshadeExist; $ctx.reshadeValid = $reshadeValid; $ctx.reshadeReferenced = $reshadeReferenced

  # Game running check (Path equality with the resolved EXE).
  $gameRunning = $false
  try {
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
      $pp = $null
      try { $pp = $p.Path } catch { continue }
      if (([string]$pp) -ieq $exePath) { $gameRunning = $true; break }
    }
  } catch { $gameRunning = $false }
  $ctx.gameRunning = $gameRunning

  # 4. Decide status.
  $lp = $effLoadPlugins.Trim(); $lso = $effScriptsOnly.Trim()
  if ($gameRunning) {
    if ($ko) { $ctx.human = "게임 확인 필요: 게임이 실행 중입니다 ($exePath). 게임을 종료한 뒤 다시 진단하세요." } else { $ctx.human = "game verification required: the game is running ($exePath). Close it and diagnose again." }
    $ctx.status = 'game-verification-required'; $ctx.reason = 'game-running'
    return $ctx
  }
  if ($ctx.configReason -ne '') {
    $ctx.status = 'conflict'; $ctx.reason = $ctx.configReason
    $ctx.human = 'Static UAL configuration could not be verified: ' + $ctx.configReason
    return $ctx
  }
  if ($hasLoader -and $reshadeValid -and $isReshadeOnly -and ([uint32]$lp -ne 0) -and (([uint32]$lso -eq 0) -or $reshadeReferenced) -and (-not $ualAmbiguous)) {
    if ($ko) { $ctx.human = "준비 완료: ReShade.asi 로드 체인이 정상입니다 (loadextraplugins=$effExtra @ $srcExtra)." } else { $ctx.human = "ready: ReShade.asi load chain is configured (loadextraplugins=$effExtra @ $srcExtra)." }
    $ctx.status = 'ready'; $ctx.reason = 'ready'; $ctx.code = 0
    return $ctx
  }
  $conflictWhy = ''
  if ($ualAmbiguous) {
    if ($ko) { $conflictWhy = "충돌: UAL 로더가 여러 개 식별됨: $(($ualNames | Sort-Object -Unique) -join ', ')" } else { $conflictWhy = "conflict: ambiguous UAL loader: $(($ualNames | Sort-Object -Unique) -join ', ')" }
  } elseif ([uint32]$lp -eq 0) {
    if ($ko) { $conflictWhy = "충돌: $srcLoadPlugins 의 loadplugins=0 (ReShade가 로드되지 않음)" } else { $conflictWhy = "conflict: loadplugins=0 in $srcLoadPlugins (ReShade will not load)" }
  } elseif ($hasLoader -and ([uint32]$lso -ne 0) -and -not $reshadeReferenced -and $effList -notcontains 'OptiScaler.asi') {
    if ($ko) { $conflictWhy = "충돌: $srcScriptsOnly 의 loadfromscriptsonly=1 (ReShade가 로드되지 않음)" } else { $conflictWhy = "conflict: loadfromscriptsonly=1 in $srcScriptsOnly (ReShade will not load)" }
  } elseif ($hasLoader -and $extraOverridden -and (-not $isReshadeOnly)) {
    if ($ko) { $conflictWhy = "충돌: $extraOverrideFile 가 loadextraplugins를 '$effExtra'로 덮어씀 (ReShade.asi 아님)" } else { $conflictWhy = "conflict: $extraOverrideFile overrides loadextraplugins to '$effExtra' (not ReShade.asi)" }
  }
  if ($conflictWhy -ne '') {
    $ctx.status = 'conflict'; $ctx.reason = 'ual-config-conflict'; $ctx.human = $conflictWhy
    return $ctx
  }
  if ($reshadeReferenced -and (-not $reshadeValid)) {
    if (-not $reshadeExist) {
      if ($ko) { $ctx.human = "입력 부족: loadextraplugins가 ReShade.asi를 참조하지만 파일이 없습니다 ($exeDir)." } else { $ctx.human = "missing input: loadextraplugins references ReShade.asi but the file is absent ($exeDir)." }
      $ctx.status = 'missing-input'; $ctx.reason = 'reshade-referenced-but-absent'
    } else {
      if ($ko) { $ctx.human = "입력 부족: loadextraplugins가 ReShade.asi를 참조하지만 PE 검증에 실패했습니다 ($exeDir; not-a-pe)." } else { $ctx.human = "missing input: loadextraplugins references ReShade.asi but PE identity verification failed ($exeDir; not-a-pe)." }
      $ctx.status = 'missing-input'; $ctx.reason = 'reshade-identity-unverified'
    }
    return $ctx
  }
  if ((-not $hasLoader) -and (-not $hasOpti)) {
    if ($ko) { $ctx.human = "입력 부족: UAL 로더/OptiScaler가 식별되지 않았습니다 ($exeDir; *.dll/*.asi $($cands.Count)개)." } else { $ctx.human = "missing input: no UAL loader/OptiScaler identified ($exeDir; $($cands.Count) *.dll/*.asi files)." }
    $ctx.status = 'missing-input'; $ctx.reason = 'no-loader-or-optiscaler'
    return $ctx
  }
  if ($ko) { $ctx.human = "미지원: 현재 폴더 상태에서는 설치할 수 없습니다 (exe=$exeOrig/$exeProd)." } else { $ctx.human = "unsupported: cannot install from the current folder state (exe=$exeOrig/$exeProd)." }
  $ctx.status = 'unsupported'; $ctx.reason = 'unsupported-state'
  return $ctx
}

function Invoke-Diagnose {
  # Render the read-only diagnosis context as exactly one status= line + human text.
  param([string]$Exe, [string]$Lang, $M)
  $ctx = Get-DiagnosisContext -Exe $Exe -Lang $Lang -M $M
  Write-StatusLine -Status $ctx.status -Reason $ctx.reason -Human $ctx.human
  if (@($ctx).Count -gt 0) { return $ctx.code }
}

function Get-BytesSha {
  param([byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function ConvertTo-HexString {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes) { return '' }
  return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-JournalRoot {
  if (-not [string]::IsNullOrEmpty($env:SUSEMI_TX_JOURNAL_ROOT)) { return $env:SUSEMI_TX_JOURNAL_ROOT }
  return (Join-Path $env:LOCALAPPDATA 'susemi-installer\journal')
}

function Get-IniOwnership {
  # Ownership comes ONLY from a prior applied coordinator journal that recorded
  # this exact target. Ownership is granted while the live bytes still match a
  # hash the journal recorded for that file (the bytes we wrote, or the preimage
  # the journal names), so a post-install user edit revokes it.
  param([string]$IniPath, [string]$CurSha)
  $res = @{ owned = $false; journal = ''; how = '' }
  $root = Get-JournalRoot
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $res }
  $target = ''
  try { $target = [System.IO.Path]::GetFullPath($IniPath) } catch { return $res }
  $jfiles = @()
  try { $jfiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) } catch { $jfiles = @() }
  foreach ($jf in $jfiles) {
    $j = $null
    try { $j = ((Get-Content -LiteralPath $jf.FullName -Raw) | ConvertFrom-Json) } catch { continue }
    if ($null -eq $j) { continue }
    if ([string]$j.phase -ne 'applied') { continue }
    if ($null -eq $j.ops) { continue }
    foreach ($op in @($j.ops)) {
      if ($null -eq $op.target) { continue }
      $t = ''
      try { $t = [System.IO.Path]::GetFullPath([string]$op.target) } catch { continue }
      if (-not $t.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { continue }
      if ([string]$op.state -ne 'applied') { continue }
      if ([string]$op.sourceSha -eq $CurSha -and -not [string]::IsNullOrEmpty($CurSha)) { return @{ owned = $true; journal = $jf.FullName; how = 'source-sha-match' } }
      if ([string]$op.beforeSha -eq $CurSha -and -not [string]::IsNullOrEmpty($CurSha)) { return @{ owned = $true; journal = $jf.FullName; how = 'before-sha-match' } }
    }
  }
  return $res
}

function Get-IniInsertPlan {
  # Byte-preserving plan to add `[globalsets] loadextraplugins=ReShade.asi` to an
  # INI. Returns the complete new byte image plus the exact inserted bytes. The
  # only supported encodings are ASCII/UTF-8 (with or without a BOM); UTF-16/32
  # and high-byte bodies without a BOM are refused by name.
  param([string]$IniPath, [bool]$Owned)
  $res = @{ ok = $false; reason = ''; action = ''; newBytes = $null; insertBytes = $null;
            eol = ''; encoding = ''; curSha = ''; exists = $false } 
  $keyLine = 'loadextraplugins=ReShade.asi'
  $exists = Test-Path -LiteralPath $IniPath -PathType Leaf
  $res.exists = $exists
  if (-not $exists) {
    $eol = "`r`n"
    $insert = [System.Text.Encoding]::ASCII.GetBytes('[globalsets]' + $eol + $keyLine + $eol)
    $res.ok = $true; $res.action = 'create'; $res.eol = $eol; $res.encoding = 'none'
    $res.insertBytes = $insert; $res.newBytes = $insert
    return $res
  }
  $bytes = [System.IO.File]::ReadAllBytes($IniPath)
  $res.curSha = Get-BytesSha $bytes
  if (-not $Owned) { $res.reason = 'ini-unowned'; return $res }

  $bomLen = 0; $enc = 'ascii-or-utf8-nobom'
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) { $enc = 'utf32le'; $bomLen = 4 }
  elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) { $enc = 'utf32be'; $bomLen = 4 }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = 'utf16le'; $bomLen = 2 }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = 'utf16be'; $bomLen = 2 }
  elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = 'utf8bom'; $bomLen = 3 }
  $res.encoding = $enc
  if ($enc -eq 'utf16le' -or $enc -eq 'utf16be') { $res.reason = 'ini-encoding-utf16'; return $res }
  if ($enc -eq 'utf32le' -or $enc -eq 'utf32be') { $res.reason = 'ini-encoding-utf32'; return $res }
  if ($enc -eq 'ascii-or-utf8-nobom') {
    $high = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ge 0x80) { $high = $true; break } }
    if ($high) { $res.reason = 'ini-encoding-ambiguous'; return $res }
  }

  $body = @()
  if ($bytes.Length -gt $bomLen) { $body = $bytes[$bomLen..($bytes.Length - 1)] }
  $crlf = $false; $lf = $false
  for ($i = 0; $i -lt $body.Length; $i++) {
    if ($body[$i] -eq 0x0A) { if ($i -gt 0 -and $body[$i - 1] -eq 0x0D) { $crlf = $true } else { $lf = $true } }
  }
  $eol = "`r`n"
  if ($crlf) { $eol = "`r`n" } elseif ($lf) { $eol = "`n" }
  $res.eol = $eol

  # latin1 keeps every byte intact while scanning section headers / keys.
  $text = [System.Text.Encoding]::GetEncoding(28591).GetString($body)
  $lines = @()
  $pos = 0
  while ($true) {
    $nl = $text.IndexOf("`n", $pos)
    if ($nl -lt 0) {
      $lines += @{ text = $text.Substring($pos); end = $text.Length; hasNl = $false }
      break
    }
    $lt = $text.Substring($pos, $nl - $pos)
    if ($lt.EndsWith("`r")) { $lt = $lt.Substring(0, $lt.Length - 1) }
    $lines += @{ text = $lt; end = $nl + 1; hasNl = $true }
    $pos = $nl + 1
  }

  $section = ''
  $keyPresent = $false
  $headerLine = $null
  foreach ($ln in $lines) {
    $t = ([string]$ln.text).Trim()
    if ($t.StartsWith('[') -and $t.EndsWith(']')) {
      $section = $t.Substring(1, $t.Length - 2).Trim()
      if ($section -ieq 'globalsets' -and $null -eq $headerLine) { $headerLine = $ln }
      continue
    }
    if ($section -ieq 'globalsets') {
      $eq = $t.IndexOf('=')
      if ($eq -lt 0) { continue }
      $k = ([string]$t.Substring(0, $eq)).Trim().ToLowerInvariant()
      if ($k -eq 'loadextraplugins') { $keyPresent = $true }
    }
  }
  if ($keyPresent) { $res.reason = 'ini-key-present'; return $res }

  $insertText = ''
  $insertAt = 0
  if ($null -ne $headerLine) {
    $insertAt = [int]$headerLine.end
    if ($headerLine.hasNl) { $insertText = $keyLine + $eol } else { $insertText = $eol + $keyLine + $eol }
  } else {
    $insertAt = $text.Length
    if ($text.Length -eq 0) { $insertText = '[globalsets]' + $eol + $keyLine + $eol }
    elseif ($text.EndsWith("`n")) { $insertText = '[globalsets]' + $eol + $keyLine + $eol }
    else { $insertText = $eol + '[globalsets]' + $eol + $keyLine + $eol }
  }
  $insertBytes = [System.Text.Encoding]::ASCII.GetBytes($insertText)
  $new = New-Object System.Collections.Generic.List[byte]
  for ($i = 0; $i -lt $bomLen; $i++) { $new.Add($bytes[$i]) }
  for ($i = 0; $i -lt $insertAt; $i++) { $new.Add($body[$i]) }
  foreach ($bx in $insertBytes) { $new.Add([byte]$bx) }
  for ($i = $insertAt; $i -lt $body.Length; $i++) { $new.Add($body[$i]) }
  $res.ok = $true; $res.action = 'extend'; $res.insertBytes = $insertBytes; $res.newBytes = $new.ToArray()
  return $res
}

function Get-ReshadeProxyCandidate {
  # A ReShade proxy DLL is only accepted with PE identity PLUS corroboration
  # (ReShade version metadata, or a ReShade INI/shaders folder with a known
  # proxy name). A random or unknown file is never a conversion candidate.
  param($Ctx)
  $found = @()
  foreach ($f in @($Ctx.cands)) {
    if ($f.Name -ieq 'ReShade.asi') { continue }
    $sha = ''
    try { $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { continue }
    if ($sha -eq $UalSha -or $sha -eq $CoreSha) { continue }
    $orig = ''; $prod = ''
    try {
      $vi = (Get-Item -LiteralPath $f.FullName -ErrorAction Stop).VersionInfo
      $orig = [string]$vi.OriginalFilename; $prod = [string]$vi.ProductName
    } catch {}
    if ($orig -ieq 'Ultimate-ASI-Loader-x64.dll' -or $orig -ieq 'OptiScaler.dll') { continue }
    if (-not (Get-PeValid $f.FullName)) { continue }
    $named = ($Ctx.proxyNames -icontains $f.Name)
    $corro = ($orig -like '*ReShade*') -or ($prod -like '*ReShade*') -or (($Ctx.reshadeIniExists -or $Ctx.reshadeDirExists) -and $named)
    if (-not $corro) { continue }
    $found += @{ name = $f.Name; path = $f.FullName; sha = $sha }
  }
  if ($found.Count -eq 1) { return @{ found = $true; name = $found[0].name; path = $found[0].path; sha = $found[0].sha; ambiguous = $false } }
  if ($found.Count -gt 1) { return @{ found = $false; ambiguous = $true; name = ''; path = ''; sha = '' } }
  return @{ found = $false; ambiguous = $false; name = ''; path = ''; sha = '' }
}

function Test-ReshadeFirstEligible {
  # Eligibility gate for the consented ReShade-first setting. Refusal reasons are
  # named tokens; the caller prints them verbatim. The INI write/ownership
  # decision (create/extend/no-op/refuse) is separate and handled afterwards.
  param($Ctx, [switch]$ConvertReshade)
  $r = @{ eligible = $false; reason = ''; laterOverride = $false; laterFile = ''; laterValue = '';
          goalEffective = $false; convertFound = $false; convertName = ''; convertPath = ''; convertSha = '' }
  if ($Ctx.gameRunning) { $r.reason = 'game-running'; return $r }
  if (-not $Ctx.isX64) { $r.reason = 'not-x64'; return $r }
  if ($Ctx.ualAmbiguous) { $r.reason = 'competing-loaders'; return $r }
  if ($Ctx.hasLoader -and (-not ($Ctx.loaderBase -ieq 'winmm'))) { $r.reason = 'loader-not-winmm'; return $r }
  if ((Test-Path -LiteralPath (Join-Path $Ctx.exeDir 'modloader.asi')) -or (Test-Path -LiteralPath (Join-Path $Ctx.exeDir (Join-Path 'modloader' 'modloader.asi')))) { $r.reason = 'modloader-dependency'; return $r }
  if ($Ctx.configReason -ne '') { $r.reason = $Ctx.configReason; return $r }
  if ([uint32]$Ctx.effLoadPlugins -eq 0) { $r.reason = 'loadplugins-disabled'; return $r }
  if ([uint32]$Ctx.effScriptsOnly -ne 0 -and $Ctx.effList -notcontains 'OptiScaler.asi') { $r.reason = 'scripts-only-enabled'; return $r }

  if ($Ctx.reshadeValid) {
    # identity already present as ReShade.asi
  } elseif ($ConvertReshade) {
    $cc = Get-ReshadeProxyCandidate -Ctx $Ctx
    if ($cc.found) { $r.convertFound = $true; $r.convertName = $cc.name; $r.convertPath = $cc.path; $r.convertSha = $cc.sha }
    elseif ($cc.ambiguous) { $r.reason = 'convert-ambiguous'; return $r }
    else { $r.reason = 'convert-identity-unverified'; return $r }
  } else {
    $r.reason = 'reshade-asi-not-identified'; return $r
  }

  $defs = @($Ctx.extraDefs)
  if ($defs.Count -eq 0) { $r.eligible = $true; return $r }
  $effDef = $defs[$defs.Count - 1]
  $list = @($Ctx.effList)
  if ($list.Count -eq 1 -and $list[0] -ieq 'ReShade.asi') { $r.goalEffective = $true; $r.eligible = $true; return $r }
  if ((@($defs | Where-Object { $_.index -gt 0 }).Count) -gt 0) {
    $later = @($defs | Where-Object { $_.index -gt 0 })[-1]
    $r.laterOverride = $true; $r.laterFile = [string]$later.file; $r.laterValue = [string]$later.value
  }
  $r.eligible = $true
  return $r
}

function Get-LaterOverrideInfo {
  # Post-apply (and pre-apply) re-read helper: does a candidate AFTER the file we
  # would write define loadextraplugins to something other than exactly
  # ReShade.asi? That setting then defeats ours; we name the file+key and never
  # edit it.
  param($Ctx)
  $defs = @($Ctx.extraDefs)
  if ($defs.Count -eq 0) { return @{ present = $false; file = ''; value = '' } }
  $later = @($defs | Where-Object { $_.index -gt 0 })
  if ($later.Count -eq 0) { return @{ present = $false; file = ''; value = '' } }
  $d = $later[-1]
  if (-not $Ctx.isReshadeOnly) {
    return @{ present = $true; file = [string]$d.file; value = [string]$d.value }
  }
  return @{ present = $false; file = ''; value = '' }
}

function Test-PackageSatisfied {
  param([string]$GameDir, [string]$Route, [string]$ProxyName)
  $t = Join-Path $GameDir 'OptiScaler.asi'
  if ($Route -eq 'proxy' -and -not [string]::IsNullOrEmpty($ProxyName)) { $t = Join-Path $GameDir $ProxyName }
  $u = Join-Path $GameDir 'winmm.dll'
  if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { return $false }
  if ((Get-FileSha256 $t) -ne $CoreSha) { return $false }
  if (-not (Test-Path -LiteralPath $u -PathType Leaf)) { return $false }
  if ((Get-FileSha256 $u) -ne $UalSha) { return $false }
  return $true
}

function Test-GuidedInstallEligible {
  # Pure allowlist over a fresh read-only diagnosis. Identity uses the existing
  # content/hash rules only, never the target filename on its own.
  param($Ctx)
  $result = @{ eligible = $false; conflict = $false }
  if (-not $Ctx.isX64 -or $Ctx.gameRunning) { return $result }
  if ($Ctx.configReason -ne '' -or [uint32]$Ctx.effLoadPlugins -eq 0 -or
      ([uint32]$Ctx.effScriptsOnly -ne 0 -and $Ctx.effList -notcontains 'OptiScaler.asi')) {
    $result.conflict = $true; return $result
  }
  if ($null -eq $Ctx.installTargets) { $result.conflict = $true; return $result }
  foreach ($target in @($Ctx.installTargets)) {
    if (($target.attributes -band [IO.FileAttributes]::Directory) -or
        ($target.attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($target.name -ieq 'winmm.dll' -and $Ctx.ualNames -notcontains $target.name) -or
        ($target.name -ieq 'OptiScaler.asi' -and $Ctx.optiNames -notcontains $target.name)) {
      $result.conflict = $true; return $result
    }
  }
  $singleWinmm = (@($Ctx.ualNames).Count -eq 1 -and $Ctx.ualNames[0] -ieq 'winmm.dll')
  if ($Ctx.status -eq 'ready' -and $Ctx.reason -eq 'ready' -and $singleWinmm) {
    $result.eligible = $true
  } elseif ($Ctx.status -eq 'missing-input' -and $Ctx.reason -eq 'no-loader-or-optiscaler' -and
            @($Ctx.installTargets).Count -eq 0 -and @($Ctx.ualNames).Count -eq 0) {
    $result.eligible = $true
  }
  return $result
}

function Invoke-InstallOffer {
  # Same-process continuation after a ready diagnosis; the T7 install body.
  # When the ReShade-first setting is eligible it is offered here explicitly and
  # defaults to off; the INI write still requires its own -IniConsent consent.
  param([string]$Exe, [string]$Lang, $M)
  $ans = Read-Host $M.InstallAsk
  if ($ans -match '^(?i:y|yes|2)$') {
    $rf = $false; $iniConsent = 'no'
    $ctx = Get-DiagnosisContext -Exe $Exe -Lang $Lang -M $M
    $elig = Test-ReshadeFirstEligible -Ctx $ctx
    if ($elig.eligible) {
      $r = Read-Host $M.ReshadeFirstAsk
      if ($r -match '^(?i:y|yes|2)$') { $rf = $true; $iniConsent = 'yes' }
    } else {
      Write-Output ($M.ReshadeFirstSkip -f $elig.reason)
    }
    # Recheck after ALL consent prompts, immediately before the transaction.
    $fresh = Get-DiagnosisContext -Exe $Exe -Lang $Lang -M $M
    $gate = Test-GuidedInstallEligible -Ctx $fresh
    if (-not $gate.eligible) {
      Write-StatusLine -Status 'refused' -Reason 'guided-target-conflict' -Human $M.NextActions['guided-target-conflict']
      return 1
    }
    $code = 1
    Invoke-InstallTransaction -Exe $Exe -Route 'asi' -ProxyName '' -Lang $Lang -M $M -ReshadeFirst:$rf -IniConsent $iniConsent | ForEach-Object {
      if ($_ -is [int]) { $code = [int]$_ } else { Write-Output $_ }
    }
    return $code
  }
  Write-StatusLine -Status 'refused' -Reason 'consent-required' -Human $M.InstallConsentRequired
  return 1
}

function Get-DisplayWidth {
  # Terminal display width: East-Asian wide/fullwidth glyphs count as two cells.
  param([string]$Text)
  $w = 0
  foreach ($ch in ([string]$Text).ToCharArray()) {
    $c = [int][char]$ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
  }
  return $w
}

function Format-GuidedLines {
  # Wrap guided-flow text to display width <= $Width so no screen line overflows a
  # 80-column console. Breaks at spaces and hard-splits a single token (e.g. a long
  # path) that is wider than the whole line.
  param([string]$Text, [int]$Width = 80)
  $res = @()
  $line = ''; $lineW = 0
  foreach ($word in ([string]$Text -split ' ')) {
    if ($word -eq '' -and $line -ne '') { $line += ' '; $lineW += 1; continue }
    $ww = Get-DisplayWidth $word
    while ($ww -gt $Width) {
      $avail = $Width - $lineW - $(if ($line -eq '') { 0 } else { 1 })
      if ($avail -le 0) { $res += $line; $line = ''; $lineW = 0; $avail = $Width }
      $take = ''; $acc = 0
      foreach ($ch in $word.ToCharArray()) {
        $cw = Get-DisplayWidth ([string]$ch)
        if ($acc + $cw -gt $avail) { break }
        $take += $ch; $acc += $cw
      }
      if ($take -eq '') { $res += $line; $line = ''; $lineW = 0; continue }
      if ($line -eq '') { $line = $take; $lineW = $acc } else { $line += ' ' + $take; $lineW += 1 + $acc }
      $res += $line; $line = ''; $lineW = 0
      $word = $word.Substring($take.Length)
      $ww = Get-DisplayWidth $word
    }
    if ($word -eq '') { continue }
    if ($line -eq '') { $line = $word; $lineW = $ww }
    elseif ($lineW + 1 + $ww -le $Width) { $line += ' ' + $word; $lineW += 1 + $ww }
    else { $res += $line; $line = $word; $lineW = $ww }
  }
  if ($line -ne '') { $res += $line }
  if ($res.Count -eq 0) { $res += '' }
  return $res
}

function Write-GuidedResultScreen {
  # Guided-mode result screen: owner-only in-game verification, the backup
  # location and how to remove. Pure text; performs no writes or prompts.
  param([string]$Exe, $M)
  $gameDir = Split-Path -Parent ([string]$Exe)
  $lines = @('')
  $lines += ('== ' + $M.ResultTitle + ' ==')
  $lines += (Format-GuidedLines ([string]$M.ResultOwnerVerify))
  $lines += (Format-GuidedLines ($M.ResultBackup -f (Join-Path $gameDir '.susemi-backup')))
  $lines += (Format-GuidedLines ($M.ResultRemoveHow -f $Exe))
  foreach ($l in $lines) { Write-Output $l }
}

function Invoke-GuidedAdvisory {
  # Presentation-layer guided advisory selector. Rendered after a valid x64
  # diagnosis is shown and before the install offer or terminal result. This is
  # advisory text ONLY: it never authenticates the exe, changes routing/status/
  # exit, writes config, or grants consent. Only the exact answer "2" emits the
  # single machine marker plus one localized caution; Enter/EOF/any other answer
  # is the silent default Other. It is not part of Get-DiagnosisContext and is
  # unreachable from argument modes (they never enter this session).
  param($M)
  $sel = Read-Host $M.AdvisoryAsk
  if ([string]$sel -ne '2') { return }
  Write-Output 'hint| game=gtav-enhanced source=user'
  foreach ($line in @($M.AdvisoryGtavEnhanced)) {
    foreach ($wrapped in (Format-GuidedLines ([string]$line))) { Write-Output $wrapped }
  }
}

function Invoke-InteractiveSession {
  # No-argument entry: language -> EXE picker -> diagnosis screen -> install
  # offer -> result screen, all in this one process. The diagnosis status is
  # rendered as human text (the final status= line belongs to the outcome), so
  # the whole session still prints exactly one machine status line.
  Write-Output $Messages.ko.LangPrompt
  Write-Output $Messages.ko.LangPrompt2
  $sel = Read-Host $Messages.ko.LangAsk
  $lang = 'ko'
  if ($sel -eq '2' -or $sel -eq 'en') { $lang = 'en' }
  $script:GuidedSessionLang = $lang
  $M = Get-LangTable -Lang $lang
  Write-Output ($M.LangChosen -f $lang)
  $pick = Select-GameExe -M $M
  if (-not [string]::IsNullOrEmpty($pick.notice)) { Write-Output $pick.notice }
  $exe = $pick.path
  if ([string]::IsNullOrWhiteSpace($exe)) {
    Write-Output $M.NextActions['exe-selection-cancelled']
    Write-StatusLine -Status 'cancelled' -Reason 'exe-selection-cancelled' -Human $M.ExeCancelled
    return 1
  }
  Write-Output ($M.ExeChosen -f $exe)
  $ctx = Get-DiagnosisContext -Exe $exe -Lang $lang -M $M
  if (-not [string]::IsNullOrEmpty($ctx.human)) {
    foreach ($line in (Format-GuidedLines ([string]$ctx.human))) { Write-Output $line }
  }
  # Advisory selector: after the valid x64 diagnosis is displayed, before the
  # install offer or the terminal result. Presentation only; no gate coupling.
  if ($ctx.isX64) { Invoke-GuidedAdvisory -M $M }
  $gate = Test-GuidedInstallEligible -Ctx $ctx
  if (-not $gate.eligible) {
    if ($gate.conflict) {
      Write-StatusLine -Status 'refused' -Reason 'guided-target-conflict' -Human $M.NextActions['guided-target-conflict']
    } else {
      $nextReason = $ctx.reason
      if ($ctx.hasLoader -and $ctx.loaderBase -ine 'winmm') { $nextReason = 'non-winmm-loader' }
      if ($M.NextActions.ContainsKey($nextReason)) { Write-Output $M.NextActions[$nextReason] }
      Write-StatusLine -Status $ctx.status -Reason $ctx.reason -Human ''
    }
    return 1
  }
  # Safe ready or bare target: continue to the informed-consent install offer.
  $offerCode = 1
  Invoke-InstallOffer -Exe $exe -Lang $lang -M $M | ForEach-Object {
    if ($_ -is [int]) { $offerCode = [int]$_ } else { Write-Output $_ }
  }
  if ($offerCode -eq 0) { Write-GuidedResultScreen -Exe $exe -M $M }
  return $offerCode
}

# ---- T7 (owned): install action -> staged payload + owned transaction ----

$Rc2ZipSha     = '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a'
$CoreEntryName = 'OptiScaler.dll'
$CoreSha       = '0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60'
$UalStagedRel  = 'tools\asi-loader\Ultimate-ASI-Loader-x64.dll'
$UalSha        = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'
$TxTimeoutSec  = 120

function Get-FileSha256 {
  param([string]$Path)
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return '' }
}

function Quote-ProcessArg {
  param([string]$A)
  if ($A -match '[\s"]') { return '"' + ($A -replace '"', '\"') + '"' }
  return $A
}

# Run any child process with a hard timeout + kill and async stdout/stderr drain.
function Invoke-ChildProcess {
  param(
    [string]$FileName,
    [string[]]$ArgList,
    [string]$RawArguments,
    [string]$WorkDir,
    $EnvVars,
    [int]$TimeoutSec = 120
  )
  $res = [ordered]@{ exit = -1; timedOut = $false; stdout = ''; stderr = '' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  if (-not [string]::IsNullOrEmpty($RawArguments)) {
    $psi.Arguments = $RawArguments
  } else {
    $psi.Arguments = (($ArgList | ForEach-Object { Quote-ProcessArg ([string]$_) }) -join ' ')
  }
  if (-not [string]::IsNullOrEmpty($WorkDir)) { $psi.WorkingDirectory = $WorkDir }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  if ($EnvVars) { foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] } }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    $null = $p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      $res.timedOut = $true
      try { $p.Kill() } catch { }
      try { $null = $p.WaitForExit(5000) } catch { }
    }
    try { $null = $p.WaitForExit(5000) } catch { }
    try { $res.exit = [int]$p.ExitCode } catch { $res.exit = -1 }
    try { $res.stdout = [string]$outTask.Result } catch { }
    try { $res.stderr = [string]$errTask.Result } catch { }
  } catch {
    $res.stderr = [string]$_.Exception.Message
  } finally {
    try { $p.Dispose() } catch { }
  }
  return $res
}

function Get-PsExe {
  $ps = Join-Path $PSHOME 'powershell.exe'
  if (Test-Path -LiteralPath $ps -PathType Leaf) { return $ps }
  return 'powershell.exe'
}

function Invoke-PsChild {
  param([string]$ScriptPath, [string[]]$ChildArgs, [int]$TimeoutSec = 120)
  $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ChildArgs
  return (Invoke-ChildProcess -FileName (Get-PsExe) -ArgList $all -WorkDir '' -EnvVars $null -TimeoutSec $TimeoutSec)
}

function Write-TxOutput {
  param($Res)
  Write-Output ('trace| exit={0} timedOut={1}' -f $Res.exit, $Res.timedOut)
  if ($Res.stdout) { foreach ($ln in ($Res.stdout.TrimEnd() -split "`r?`n")) { Write-Output ('trace| ' + $ln) } }
  if ($Res.stderr) { foreach ($ln in ($Res.stderr.TrimEnd() -split "`r?`n")) { Write-Output ('trace! ' + $ln) } }
}

function Get-MachineStatus {
  param([string]$Text)
  $st = ''; $rs = ''
  foreach ($ln in ([string]$Text -split "`r?`n")) {
    if ($ln -match '^status=(\S+)\s+reason=(\S+)') { $st = $Matches[1]; $rs = $Matches[2]; break }
  }
  return @{ status = $st; reason = $rs }
}

# Capture Invoke-Diagnose output without re-emitting its status= line (the
# coordinator must print exactly one machine line per run).
function Get-DiagnoseOutcome {
  param([string]$Exe, [string]$Lang, $M)
  $code = 1; $status = ''; $reason = ''
  Invoke-Diagnose -Exe $Exe -Lang $Lang -M $M | ForEach-Object {
    if ($_ -is [int]) { $code = [int]$_ }
    else {
      $line = [string]$_
      if ($line -match '^status=(\S+)\s+reason=(\S+)') { $status = $Matches[1]; $reason = $Matches[2] }
    }
  }
  return @{ code = $code; status = $status; reason = $reason }
}

function Expand-ZipMember {
  param([string]$ZipPath, [string]$EntryName, [string]$Destination)
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
  try {
    $entry = @($zip.Entries | Where-Object { $_.FullName -eq $EntryName })[0]
    if (-not $entry) { return $false }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Destination, $true)
    return $true
  } finally {
    $zip.Dispose()
  }
}

# ---- T20 (owned): hybrid B+A install progress (in-place bar + step counter) ----
# Console-only by design: the in-place bar is written with Write-Host (host stream),
# never Write-Output, so the machine-readable "status=" stream and every fixture
# suite stay byte-clean. When stdout is redirected or detached (log capture, CI,
# piped runs) there is no console to overwrite in place, so plain "trace| " lines
# are emitted instead and the bar is never drawn. PS 5.1 only: plain Write-Host
# carriage-return overwrite, no Write-Progress.
$script:ProgressBarShown = $false
$script:ProgressBarPad = 120

function Test-InstallProgressConsole {
  # True only when a real console can be overwritten in place and the host UI is
  # usable. Redirected/detached stdout -> $false (fall back to trace| lines).
  try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
  try {
    if ($null -eq $Host.UI) { return $false }
    $null = $Host.UI.RawUI
  } catch { return $false }
  return $true
}

function Test-SessionHoldEligible {
  # Pure hold-eligibility for the no-arg guided epilogue. True only for a guided
  # session whose caller has a real console on BOTH sides: input (stdin not
  # redirected plus a usable host UI, via Test-InteractiveInputAvailable) and
  # output (stdout not redirected plus a usable host UI, via
  # Test-InstallProgressConsole). The parameters exist so the truth table is
  # provable without a live console; the production caller passes only -Guided
  # and the defaults probe this process. No environment override, no test switch.
  param(
    [switch]$Guided,
    [bool]$InputAvailable = (Test-InteractiveInputAvailable),
    [bool]$OutputAvailable = (Test-InstallProgressConsole)
  )
  if (-not $Guided) { return $false }
  if (-not $InputAvailable) { return $false }
  if (-not $OutputAvailable) { return $false }
  return $true
}

function Invoke-SessionHold {
  # One localized close line and exactly one Read-Host. EOF (piped or closed
  # stdin) and any host error end the session normally; the caller's captured
  # exit code is untouched. Deliberately no finally and no Ctrl+C re-wait: an
  # interrupt ends the session exactly as it did before this epilogue.
  param($M)
  Write-Output $M.HoldPrompt
  try { $null = Read-Host } catch { }
  return
}

function Format-InstallProgressLine {
  # Pure renderer: stage n/5 shows its baseline percent (20*n), a 10-cell bar
  # (filled = percent/10) and the shared suffix.
  param([int]$Stage, [int]$Total, [string]$Busy, $M)
  if ($Total -le 0) { $Total = 5 }
  $pct = [int](($Stage * 100) / $Total)
  $cells = 10
  $filled = [int][math]::Round($pct / (100 / $cells))
  if ($filled -lt 0) { $filled = 0 }
  if ($filled -gt $cells) { $filled = $cells }
  $bar = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * ($cells - $filled))
  return ('{0} [{1}/{2}] {3} {4} {5}% {6}' -f $M.ProgressHeader, $Stage, $Total, $Busy, $bar, $pct, $M.ProgressSuffix)
}

function Clear-InstallProgressBar {
  # Erase the active in-place line so normal output starts on a clean line.
  if (-not $script:ProgressBarShown) { return }
  Write-Host ("`r" + (' ' * $script:ProgressBarPad) + "`r") -NoNewline
  $script:ProgressBarShown = $false
}

function Write-InstallProgress {
  # Complete=$false: persistent in-place bar for the stage now starting.
  # Complete=$true : the stage finished; one transcript line with a check mark.
  param([int]$Stage, [int]$Total, [bool]$Complete, $M)
  $idx = $Stage - 1
  if (-not (Test-InstallProgressConsole)) {
    if ($Complete) { Write-Output ('trace| [{0}/{1}] ok {2}' -f $Stage, $Total, $M.StageDone[$idx]) }
    else { Write-Output ('trace| [{0}/{1}] {2}' -f $Stage, $Total, $M.StageBusy[$idx]) }
    return
  }
  if ($Complete) {
    Clear-InstallProgressBar
    Write-Host ('[{0}/{1}] {2} {3}' -f $Stage, $Total, [string][char]0x2713, $M.StageDone[$idx])
    return
  }
  $line = Format-InstallProgressLine -Stage $Stage -Total $Total -Busy $M.StageBusy[$idx] -M $M
  if ($script:ProgressBarShown) { Write-Host ("`r" + (' ' * $script:ProgressBarPad) + "`r") -NoNewline }
  Write-Host ("`r" + $line.PadRight(60)) -NoNewline
  $script:ProgressBarShown = $true
}

function Write-InstallExpectation {
  # One-line "this takes a minute" notice before the five stages begin.
  param($M)
  if (Test-InstallProgressConsole) { Write-Host $M.InstallEta }
  else { Write-Output ('trace| ' + $M.InstallEta) }
}

# T7 install body: precheck -> stage (%TEMP%, offline) -> plan/prepare/apply -> verify.
# Every failure path restores via the transaction's own recover and reports honestly.
function Invoke-InstallTransaction {
  param([string]$Exe, [string]$Route, [string]$ProxyName, [string]$Lang, $M, [switch]$ReshadeFirst, [string]$IniConsent, [switch]$ConvertReshade)

  if ([string]::IsNullOrEmpty($Route)) { $Route = 'asi' }
  $Route = ([string]$Route).ToLowerInvariant()
  if ($Route -notin @('asi', 'proxy')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-route' -Human ("Route must be asi|proxy, got '{0}'." -f $Route)
    return 2
  }
  if ([string]::IsNullOrEmpty($ProxyName)) { $ProxyName = 'dxgi.dll' }
  if ($Route -eq 'proxy') {
    if (($ProxyName -match '[\\/]') -or ($ProxyName -eq '.') -or ($ProxyName -eq '..')) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-proxyname' -Human ("ProxyName must be a bare file name, got '{0}'." -f $ProxyName)
      return 2
    }
  }

  # Path-escape refusal on the raw -Exe value (a '..' segment is never a game exe).
  $rawExe = ([string]$Exe).Trim().Trim('"')
  if (@($rawExe -split '[\\/]') -contains '..') {
    Write-StatusLine -Status 'refused' -Reason 'path-escape' -Human ("Refusing an -Exe path with a '..' traversal segment: {0}" -f $rawExe)
    return 1
  }

  # Read-only precheck reuses Invoke-Diagnose. Only a running game, a blocking
  # conflict, or an unusable exe stop the install; a bare game folder proceeds.
  $diag = Get-DiagnoseOutcome -Exe $rawExe -Lang $Lang -M $M
  if ($diag.status -eq 'game-verification-required') {
    Write-StatusLine -Status 'game-verification-required' -Reason 'game-running' -Human $M.InstallRunning
    return 1
  }
  if ($diag.status -eq 'conflict' -and -not $ReshadeFirst) {
    Write-StatusLine -Status 'refused' -Reason $diag.reason -Human $M.InstallConflict
    return 1
  }
  if ($diag.status -eq 'missing-input' -and $diag.reason -eq 'exe-not-found') {
    Write-StatusLine -Status 'refused' -Reason 'exe-not-found' -Human ("install: exe not found: {0}" -f $rawExe)
    return 1
  }
  if ($diag.status -eq 'unsupported' -and $diag.reason -eq 'not-x64') {
    Write-StatusLine -Status 'unsupported' -Reason 'not-x64' -Human ("install: not an x64 (0x8664) executable: {0}" -f $rawExe)
    return 1
  }

  $resolved = ''
  try { $resolved = (Resolve-Path -LiteralPath $rawExe -ErrorAction Stop).Path } catch { $resolved = '' }
  if ([string]::IsNullOrEmpty($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Write-StatusLine -Status 'refused' -Reason 'exe-not-found' -Human ("install: exe not found: {0}" -f $rawExe)
    return 1
  }
  $gameDir = Split-Path -Parent $resolved
  # Fresh prospective winmm configuration after consent, including bare folders.
  # No staging, target writes or journal creation may precede this gate.
  $configCtx = Get-DiagnosisContext -Exe $resolved -Lang $Lang -M $M
  $configReason = $configCtx.configReason
  if ([uint32]$configCtx.effLoadPlugins -eq 0) { $configReason = 'loadplugins-disabled' }
  elseif ([uint32]$configCtx.effScriptsOnly -ne 0 -and $configCtx.effList -notcontains 'OptiScaler.asi') { $configReason = 'scripts-only-enabled' }
  if ($configReason -ne '') {
    Write-StatusLine -Status 'refused' -Reason $configReason -Human ('Static UAL configuration prevents this install; nothing was written: ' + $configReason)
    return 1
  }

  # ---- T8: ReShade-first eligibility + INI ownership/preview + conversion.
  # Every decision below happens BEFORE any mutation, so a refusal here leaves
  # the game directory byte-identical (zero writes).
  $rfIniPath = Join-Path $gameDir 'winmm.ini'
  $rfIniAction = 'none'; $rfIniPlan = $null; $rfIniOwned = $false
  $rfConvertSrc = ''; $rfConvertName = ''; $rfConvertSha = ''
  $rfLaterPre = @{ present = $false; file = ''; value = '' }
  $rfFinalStatus = 'installed'; $rfFinalReason = 'ok'; $rfFinalHuman = ''
  if ($ReshadeFirst) {
    if ($Route -ne 'asi') {
      Write-StatusLine -Status 'refused' -Reason 'reshade-first-needs-asi-route' -Human 'ReShade-first setup requires the ASI route (winmm.dll).'
      return 1
    }
    if ($IniConsent -ne 'yes') {
      Write-StatusLine -Status 'refused' -Reason 'ini-consent-required' -Human $M.IniConsentRequired
      return 1
    }
    $rfCtx = Get-DiagnosisContext -Exe $rawExe -Lang $Lang -M $M
    $rfElig = Test-ReshadeFirstEligible -Ctx $rfCtx -ConvertReshade:$ConvertReshade
    if (-not $rfElig.eligible) {
      Write-StatusLine -Status 'refused' -Reason $rfElig.reason -Human ("ReShade-first is not eligible here (reason: {0}); nothing was written." -f $rfElig.reason)
      return 1
    }
    if ($rfElig.convertFound) {
      $rfConvertSrc = $rfElig.convertPath; $rfConvertName = $rfElig.convertName; $rfConvertSha = $rfElig.convertSha
    }
    $rfLaterPre = Get-LaterOverrideInfo -Ctx $rfCtx
    $rfCurSha = ''
    if (Test-Path -LiteralPath $rfIniPath -PathType Leaf) { $rfCurSha = (Get-FileSha256 $rfIniPath) }
    $rfOwn = Get-IniOwnership -IniPath $rfIniPath -CurSha $rfCurSha
    $rfIniOwned = [bool]$rfOwn.owned
    if ($rfElig.goalEffective -and -not $rfLaterPre.present) {
      $rfIniAction = 'noop'
    } elseif ($rfLaterPre.present) {
      # A later candidate already defeats the key. Never edit that file, and do
      # not write a key we know is overridden; the warning is reported below.
      $rfIniAction = 'skip-later-override'
    } else {
      $rfIniPlan = Get-IniInsertPlan -IniPath $rfIniPath -Owned $rfIniOwned
      if (-not $rfIniPlan.ok) {
        $human = ''
        if ($rfIniPlan.reason -eq 'ini-unowned') { $human = $M.IniUnowned }
        elseif ($rfIniPlan.reason -eq 'ini-key-present') { $human = $M.IniKeyPresent }
        else { $human = ("ReShade-first: cannot write winmm.ini (reason: {0})." -f $rfIniPlan.reason) }
        Write-StatusLine -Status 'refused' -Reason $rfIniPlan.reason -Human $human
        return 1
      }
      $rfIniAction = $rfIniPlan.action
      # Exact preview before the transaction (file, current-bytes sha, insert).
      Write-Output ('preview| ini=' + $rfIniPath)
      if ([string]::IsNullOrEmpty($rfIniPlan.curSha)) { Write-Output 'preview| ini-sha-before=(absent)' }
      else { Write-Output ('preview| ini-sha-before=' + $rfIniPlan.curSha) }
      Write-Output ('preview| ini-op=' + $rfIniPlan.action)
      Write-Output ('preview| ini-encoding=' + $rfIniPlan.encoding)
      if ($rfIniPlan.eol -eq "`r`n") { Write-Output 'preview| ini-eol=CRLF' } else { Write-Output 'preview| ini-eol=LF' }
      Write-Output ('preview| ini-insert-hex=' + (ConvertTo-HexString $rfIniPlan.insertBytes))
      Write-Output ('preview| ini-insert-ascii=' + ([System.Text.Encoding]::ASCII.GetString($rfIniPlan.insertBytes).Replace("`r", '\r').Replace("`n", '\n')))
    }
    if ($rfConvertSrc -ne '') {
      Write-Output ('preview| convert=' + $rfConvertName + '->ReShade.asi mode=copy sha=' + $rfConvertSha)
      Write-Output ($M.ConvertWarn -f $rfConvertName)
    }
    # Nothing to install and nothing to write: report honestly without touching a byte.
    if (($rfIniAction -eq 'noop' -or $rfIniAction -eq 'skip-later-override') -and (Test-PackageSatisfied -GameDir $gameDir -Route $Route -ProxyName $ProxyName)) {
      if ($rfIniAction -eq 'skip-later-override') {
        Write-Output ('reshade-first=later-override file=' + $rfLaterPre.file + ' key=loadextraplugins value=' + $rfLaterPre.value)
        Write-StatusLine -Status 'installed-with-warning' -Reason 'later-override' -Human ($M.IniLaterOverride -f $rfLaterPre.file, $rfLaterPre.value)
      } else {
        Write-Output ('reshade-first=no-op reason=already-configured ini=' + $rfIniPath + ' owned=' + $rfIniOwned)
        Write-StatusLine -Status 'no-op' -Reason 'already-configured' -Human $M.IniNoOp
      }
      return 0
    }
  }

  $zipPath = $env:SUSEMI_RC2_ZIP
  $directorySource = [string]::IsNullOrEmpty($zipPath)
  $packageRoot = Split-Path -Parent $PSScriptRoot
  if ($directorySource) {
    Write-Output ('trace| source=directory root=' + $packageRoot)
    $packageCore = Join-Path $packageRoot $CoreEntryName
    $packageUal = Join-Path $packageRoot $UalStagedRel
    foreach ($payload in @($packageCore, $packageUal)) {
      if (-not (Test-Path -LiteralPath $payload)) {
        Write-StatusLine -Status 'refused' -Reason 'package-payload-missing' -Human $M.PackagePayloadMissing
        return 1
      }
    }
    if ((Get-FileSha256 $packageCore) -ne $CoreSha -or (Get-FileSha256 $packageUal) -ne $UalSha) {
      Write-StatusLine -Status 'refused' -Reason 'package-payload-sha-mismatch' -Human $M.PackagePayloadMismatch
      return 1
    }
  } else {
    Write-Output ('trace| source=zip path=' + $zipPath)
  }

  $stageDir = Join-Path $env:TEMP ('susemi-inst-stage-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
  $journalPath = ''
  try {
    $coreDll = Join-Path $stageDir 'OptiScaler.dll'
    $ualStaged = Join-Path $stageDir $UalStagedRel
    if ($directorySource) {
      try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $ualStaged) -Force | Out-Null
        Copy-Item -LiteralPath $packageCore -Destination $coreDll
        Copy-Item -LiteralPath $packageUal -Destination $ualStaged
      } catch {
        Write-StatusLine -Status 'refused' -Reason 'package-payload-sha-mismatch' -Human $M.PackagePayloadMismatch
        return 1
      }
      if ((Get-FileSha256 $coreDll) -ne $CoreSha -or (Get-FileSha256 $ualStaged) -ne $UalSha) {
        Write-StatusLine -Status 'refused' -Reason 'package-payload-sha-mismatch' -Human $M.PackagePayloadMismatch
        return 1
      }
      Write-InstallExpectation -M $M
      Write-InstallProgress -Stage 1 -Total 5 -Complete:$true -M $M
    } else {
    # (1) byte-exact local rc2 ZIP, offline only.
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
      Write-StatusLine -Status 'refused' -Reason 'rc2-zip-absent' -Human ("local rc2 ZIP not found: {0}" -f $zipPath)
      return 1
    }
    if ((Get-FileSha256 $zipPath) -ne $Rc2ZipSha) {
      Write-StatusLine -Status 'refused' -Reason 'rc2-zip-sha-mismatch' -Human 'local rc2 ZIP sha256 does not match the pin; refusing before extract.'
      return 1
    }

    # (2) extract + verify the OptiScaler core.
    $coreDll = Join-Path $stageDir 'OptiScaler.dll'
    if (-not (Expand-ZipMember -ZipPath $zipPath -EntryName $CoreEntryName -Destination $coreDll)) {
      Write-StatusLine -Status 'refused' -Reason 'rc2-core-entry-missing' -Human ("rc2 ZIP has no entry: {0}" -f $CoreEntryName)
      return 1
    }
    if ((Get-FileSha256 $coreDll) -ne $CoreSha) {
      Write-StatusLine -Status 'refused' -Reason 'core-sha-mismatch' -Human 'extracted OptiScaler core sha256 does not match the pin.'
      return 1
    }

    # (3) stage UAL with the approved helper (zip source, its own pin checks; re-verified here).
    Write-InstallExpectation -M $M
    Write-InstallProgress -Stage 1 -Total 5 -Complete:$false -M $M
    $helper = Join-Path $PSScriptRoot 'susemi_stage_helpers.ps1'
    $helperRes = Invoke-PsChild -ScriptPath $helper -ChildArgs @('ual', '-StageDir', $stageDir, '-Source', 'zip', '-Rc2Zip', $zipPath) -TimeoutSec $TxTimeoutSec
    Clear-InstallProgressBar
    Write-TxOutput -Res $helperRes
    Write-InstallProgress -Stage 1 -Total 5 -Complete:$true -M $M
    $ualStaged = Join-Path $stageDir $UalStagedRel
    if ($helperRes.timedOut) {
      Write-StatusLine -Status 'failed' -Reason 'ual-stage-timeout' -Human 'UAL staging helper timed out and was killed.'
      return 1
    }
    if ($helperRes.exit -ne 0 -or -not (Test-Path -LiteralPath $ualStaged -PathType Leaf)) {
      Write-StatusLine -Status 'refused' -Reason 'ual-stage-failed' -Human 'UAL staging helper did not produce the pinned loader.'
      return 1
    }
    if ((Get-FileSha256 $ualStaged) -ne $UalSha) {
      Write-StatusLine -Status 'refused' -Reason 'ual-sha-mismatch' -Human 'staged UAL sha256 does not match the pin.'
      return 1
    }

    }
    Write-Output ('trace| staged-core-sha=' + (Get-FileSha256 $coreDll) + ' staged-ual-sha=' + (Get-FileSha256 $ualStaged))

    # (4) place the core under its owned final name via the T5 orchestrated staging path.
    $bat = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup_windows.bat'
    $inner = '"' + $bat + '" --orchestrated ' + $Route
    if ($Route -eq 'proxy') { $inner += ' --exename ' + $ProxyName }
    $cmd = $env:ComSpec
    if ([string]::IsNullOrEmpty($cmd)) { $cmd = 'cmd.exe' }
    Write-InstallProgress -Stage 2 -Total 5 -Complete:$false -M $M
    $orchRes = Invoke-ChildProcess -FileName $cmd -RawArguments ('/d /c "' + $inner + '"') -WorkDir $stageDir -EnvVars @{ 'SUSEMI_ORCH_STAGE' = '1' } -TimeoutSec $TxTimeoutSec
    Clear-InstallProgressBar
    Write-TxOutput -Res $orchRes
    Write-InstallProgress -Stage 2 -Total 5 -Complete:$true -M $M
    $stagedTarget = if ($Route -eq 'asi') { Join-Path $stageDir 'OptiScaler.asi' } else { Join-Path $stageDir $ProxyName }
    if ($orchRes.timedOut) {
      Write-StatusLine -Status 'failed' -Reason 'stage-timeout' -Human 'setup_windows.bat --orchestrated timed out and was killed.'
      return 1
    }
    if ($orchRes.exit -ne 0 -or -not (Test-Path -LiteralPath $stagedTarget -PathType Leaf)) {
      Write-StatusLine -Status 'refused' -Reason 'stage-rename-failed' -Human 'setup_windows.bat --orchestrated did not produce the staged payload.'
      return 1
    }
    if ((Get-FileSha256 $stagedTarget) -ne $CoreSha) {
      Write-StatusLine -Status 'refused' -Reason 'stage-payload-sha-mismatch' -Human 'staged payload sha256 does not match the pinned core.'
      return 1
    }

    # (4b) extra owned ops, journaled LAST: the verified ReShade -> ReShade.asi
    # COPY first, then the byte-preserving winmm.ini extend/create. Both are plain
    # create/replace ops, so the existing prepare/apply/recover/rollback cover them.
    $extraOps = @()
    if ($rfConvertSrc -ne '') {
      $convStage = Join-Path $stageDir 'ReShade.asi'
      Copy-Item -LiteralPath $rfConvertSrc -Destination $convStage -Force -ErrorAction Stop
      if ((Get-FileSha256 $convStage) -ne $rfConvertSha) {
        Write-StatusLine -Status 'refused' -Reason 'convert-stage-sha-mismatch' -Human 'staged ReShade.asi copy sha256 mismatch.'
        return 1
      }
      $extraOps += @{ target = (Join-Path $gameDir 'ReShade.asi'); source = $convStage }
    }
    if ($rfIniAction -eq 'create' -or $rfIniAction -eq 'extend') {
      $iniStage = Join-Path $stageDir 'winmm.ini'
      [System.IO.File]::WriteAllBytes($iniStage, $rfIniPlan.newBytes)
      $extraOps += @{ target = $rfIniPath; source = $iniStage }
    }
    $extraJsonPath = ''
    if ($extraOps.Count -gt 0) {
      $extraJsonPath = Join-Path $stageDir 'extra-ops.json'
      $extraJsonText = '[' + ((@($extraOps) | ForEach-Object { $_ | ConvertTo-Json -Depth 4 -Compress }) -join ',') + ']'
      [System.IO.File]::WriteAllText($extraJsonPath, $extraJsonText, (New-Object System.Text.UTF8Encoding($false)))
    }

    # (5) owned transaction: plan -> prepare -> apply, each a bounded child process.
    $txArgs = @('plan', '-GameDir', $gameDir, '-StagedDir', $stageDir, '-Route', $Route, '-IncludeUal', '-StagedUalPath', $ualStaged)
    if ($Route -eq 'proxy') { $txArgs += @('-ProxyName', $ProxyName) }
    if ($extraJsonPath -ne '') { $txArgs += @('-ExtraJson', $extraJsonPath) }
    # Optional test/ops isolation: an explicit journal root beats the LOCALAPPDATA default.
    if (-not [string]::IsNullOrEmpty($env:SUSEMI_TX_JOURNAL_ROOT)) { $txArgs += @('-JournalRoot', $env:SUSEMI_TX_JOURNAL_ROOT) }
    Write-InstallProgress -Stage 3 -Total 5 -Complete:$false -M $M
    $planRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs $txArgs -TimeoutSec $TxTimeoutSec
    Clear-InstallProgressBar
    Write-TxOutput -Res $planRes
    Write-InstallProgress -Stage 3 -Total 5 -Complete:$true -M $M
    if ($planRes.timedOut) {
      Write-StatusLine -Status 'failed' -Reason 'transaction-timeout' -Human 'transaction plan timed out and was killed.'
      return 1
    }
    $planSt = Get-MachineStatus -Text $planRes.stdout
    if ($planRes.exit -ne 0 -or $planSt.status -ne 'planned') {
      $pr = $planSt.reason; if ([string]::IsNullOrEmpty($pr)) { $pr = 'plan-failed' }
      Write-StatusLine -Status 'refused' -Reason $pr -Human 'install: transaction plan refused; nothing was written.'
      return 1
    }
    if ($planRes.stdout -match 'journal=([^\r\n]+)') { $journalPath = $Matches[1].Trim() }
    if ([string]::IsNullOrEmpty($journalPath) -or -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
      Write-StatusLine -Status 'failed' -Reason 'journal-path-missing' -Human 'install: plan reported success but no journal path was produced.'
      return 1
    }

    Write-InstallProgress -Stage 4 -Total 5 -Complete:$false -M $M
    $prepRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs @('prepare', '-Journal', $journalPath) -TimeoutSec $TxTimeoutSec
    Clear-InstallProgressBar
    Write-TxOutput -Res $prepRes
    Write-InstallProgress -Stage 4 -Total 5 -Complete:$true -M $M
    if ($prepRes.timedOut -or $prepRes.exit -ne 0) {
      $recRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs @('recover', '-Journal', $journalPath) -TimeoutSec $TxTimeoutSec
      Write-TxOutput -Res $recRes
      $ps2 = Get-MachineStatus -Text $prepRes.stdout
      $pr2 = $ps2.reason; if ([string]::IsNullOrEmpty($pr2)) { $pr2 = 'prepare-failed' }
      if ($prepRes.timedOut) { $pr2 = 'transaction-timeout' }
      Write-StatusLine -Status 'failed' -Reason $pr2 -Human ("{0} journal={1}" -f $M.InstallFailed, $journalPath)
      return 1
    }

    Write-InstallProgress -Stage 5 -Total 5 -Complete:$false -M $M
    $appRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs @('apply', '-Journal', $journalPath) -TimeoutSec $TxTimeoutSec
    Clear-InstallProgressBar
    Write-TxOutput -Res $appRes
    Write-InstallProgress -Stage 5 -Total 5 -Complete:$true -M $M
    if ($appRes.timedOut -or $appRes.exit -ne 0) {
      $recRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs @('recover', '-Journal', $journalPath) -TimeoutSec $TxTimeoutSec
      Write-TxOutput -Res $recRes
      $as2 = Get-MachineStatus -Text $appRes.stdout
      $ar2 = $as2.reason; if ([string]::IsNullOrEmpty($ar2)) { $ar2 = 'apply-failed' }
      if ($appRes.timedOut) { $ar2 = 'transaction-timeout' }
      Write-StatusLine -Status 'failed' -Reason $ar2 -Human ("{0} journal={1}" -f $M.InstallFailed, $journalPath)
      return 1
    }

    # (6) independent post-apply verification of live bytes + journal state.
    $targetOpti = if ($Route -eq 'asi') { Join-Path $gameDir 'OptiScaler.asi' } else { Join-Path $gameDir $ProxyName }
    $targetUal = Join-Path $gameDir 'winmm.dll'
    $okOpti = (Test-Path -LiteralPath $targetOpti -PathType Leaf) -and ((Get-FileSha256 $targetOpti) -eq $CoreSha)
    $okUal = (Test-Path -LiteralPath $targetUal -PathType Leaf) -and ((Get-FileSha256 $targetUal) -eq $UalSha)
    $jPhase = ''; $jTx = ''
    try {
      $j = (Get-Content -LiteralPath $journalPath -Raw) | ConvertFrom-Json
      $jPhase = [string]$j.phase
      $jTx = [string]$j.txid
    } catch { }
    $okConv = $true; $okConvSrc = $true; $okIni = $true; $rfNewSha = ''
    if ($rfConvertSrc -ne '') {
      $convTarget = Join-Path $gameDir 'ReShade.asi'
      $okConv = (Test-Path -LiteralPath $convTarget -PathType Leaf) -and ((Get-FileSha256 $convTarget) -eq $rfConvertSha)
      $okConvSrc = ((Get-FileSha256 $rfConvertSrc) -eq $rfConvertSha)
    }
    if ($rfIniAction -eq 'create' -or $rfIniAction -eq 'extend') {
      $rfNewSha = Get-BytesSha $rfIniPlan.newBytes
      $okIni = (Test-Path -LiteralPath $rfIniPath -PathType Leaf) -and ((Get-FileSha256 $rfIniPath) -eq $rfNewSha)
    }
    if (-not ($okOpti -and $okUal -and ($jPhase -eq 'applied') -and $okConv -and $okConvSrc -and $okIni)) {
      $recRes = Invoke-PsChild -ScriptPath (Join-Path $PSScriptRoot 'susemi_transaction.ps1') -ChildArgs @('recover', '-Journal', $journalPath) -TimeoutSec $TxTimeoutSec
      Write-TxOutput -Res $recRes
      Write-StatusLine -Status 'failed' -Reason 'verify-failed' -Human ("install verification failed (opti={0} ual={1} conv={2} ini={3} phase={4}); journal={5}" -f $okOpti, $okUal, $okConv, $okIni, $jPhase, $journalPath)
      return 1
    }

    if ($rfConvertSrc -ne '') {
      Write-Output ('reshade-first=converted src=' + $rfConvertName + ' dst=ReShade.asi mode=copy sha=' + $rfConvertSha)
    }
    if ($rfIniAction -eq 'create') {
      Write-Output ('reshade-first=ini-created winmm.ini sha=' + $rfNewSha + ' insert=' + (ConvertTo-HexString $rfIniPlan.insertBytes))
    } elseif ($rfIniAction -eq 'extend') {
      Write-Output ('reshade-first=ini-extended winmm.ini sha=' + $rfNewSha + ' insert=' + (ConvertTo-HexString $rfIniPlan.insertBytes))
    } elseif ($rfIniAction -eq 'noop') {
      Write-Output 'reshade-first=no-op reason=already-configured'
    }

    $postCtx = Get-DiagnosisContext -Exe $rawExe -Lang $Lang -M $M
    Write-Output ('static-config| loadplugins=' + $postCtx.effLoadPlugins + ' source=' + $postCtx.srcLoadPlugins + ' scripts-only=' + $postCtx.effScriptsOnly + ' extra-source=' + $postCtx.srcExtra)
    Write-Output 'game-runtime=unverified'
    if ($postCtx.configReason -ne '' -or [uint32]$postCtx.effLoadPlugins -eq 0 -or
        ([uint32]$postCtx.effScriptsOnly -ne 0 -and $postCtx.effList -notcontains 'OptiScaler.asi')) {
      $rfFinalStatus = 'installed-with-warning'; $rfFinalReason = 'ual-config-changed'
      $rfFinalHuman = 'Installed bytes verified; static UAL configuration changed or could not be verified. Game runtime remains unverified.'
    }
    if ($ReshadeFirst) {
      # Re-read all five candidates AFTER apply: a later global.ini may defeat the
      # key. Name the file+key and never edit that file.
      $laterPost = Get-LaterOverrideInfo -Ctx $postCtx
      $goalOk = ($postCtx.effList.Count -eq 1 -and $postCtx.effList[0] -ieq 'ReShade.asi')
      Write-Output ('reshade-first=post-diagnosis status=' + $postCtx.status + ' reason=' + $postCtx.reason + ' eff-extra=' + $postCtx.effExtra)
      if ($rfLaterPre.present) {
        $rfFinalStatus = 'installed-with-warning'; $rfFinalReason = 'later-override'
        $rfFinalHuman = ($M.IniLaterOverride -f $rfLaterPre.file, $rfLaterPre.value)
      } elseif ($laterPost.present) {
        $rfFinalStatus = 'installed-with-warning'; $rfFinalReason = 'later-override'
        $rfFinalHuman = ($M.IniLaterOverride -f $laterPost.file, $laterPost.value)
      } elseif (-not $goalOk) {
        $rfFinalStatus = 'installed-with-warning'; $rfFinalReason = 'reshade-first-not-effective'
        $rfFinalHuman = "ReShade-first is installed but the effective loadextraplugins is '$($postCtx.effExtra)' at $($postCtx.srcExtra)."
      }
    }

    $installedHuman = ("{0} optiscaler={1} ual=winmm.dll txid={2} journal={3}" -f $M.InstallInstalled, (Split-Path -Leaf $targetOpti), $jTx, $journalPath)
    if ($rfFinalStatus -eq 'installed') {
      Write-StatusLine -Status 'installed' -Reason 'ok' -Human $installedHuman
    } else {
      Write-StatusLine -Status $rfFinalStatus -Reason $rfFinalReason -Human ($rfFinalHuman + ' ' + $installedHuman)
    }
    return 0
  } finally {
    Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---- T9 (owned): remove action -> journal-based reverse of install ----
function Invoke-RemoveTransaction {
  param([string]$Exe, [string]$Lang, $M)

  # 0. Resolve EXE dir (reuse existing resolution patterns in this file).
  $rawExe = ([string]$Exe).Trim().Trim('"')
  if (@($rawExe -split '[\\/]') -contains '..') {
    $h = if ($lang -eq 'en') { 'Refusing an -Exe path with a ".." traversal segment: {0}' -f $rawExe }
         else      { 'Refusing an -Exe path with a ".." segment: {0}' -f $rawExe }
    Write-StatusLine -Status 'refused' -Reason 'path-escape' -Human $h
    return 1
  }

  $resolved = ''
  try { $resolved = (Resolve-Path -LiteralPath $rawExe -ErrorAction Stop).Path } catch { $resolved = '' }
  if ([string]::IsNullOrEmpty($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    $h = if ($lang -eq 'en') { ('No executable found: {0}' -f $rawExe) }
         else                 { ('실행 파일을 찾을 수 없습니다: {0}' -f $rawExe) }
    Write-StatusLine -Status 'missing-input' -Reason 'exe-not-found' -Human $h
    return 1
  }
  $gameDir = Split-Path -Parent $resolved
  $ko = (-not [string]::IsNullOrEmpty($lang)) -and ($lang -ne 'en')

  # 1. Find newest journal matching this GameDir with phase applied or recovered.
  $journalRoot = Get-JournalRoot
  if (-not (Test-Path -LiteralPath $journalRoot -PathType Container)) {
    $h = if ($ko) { '해당 게임 폴더에 설치 기록이 없습니다.' }
         else     { 'No install record found for this game directory.' }
    Write-StatusLine -Status 'missing-input' -Reason 'no-install-record' -Human $h
    return 1
  }

  $jfiles = @(Get-ChildItem -LiteralPath $journalRoot -File -Filter '*.json' -ErrorAction SilentlyContinue) |
            Sort-Object Name -Descending
  if ($jfiles.Count -eq 0) {
    $h = if ($ko) { '해당 게임 폴더에 설치 기록이 없습니다.' }
         else     { 'No install record found for this game directory.' }
    Write-StatusLine -Status 'missing-input' -Reason 'no-install-record' -Human $h
    return 1
  }

  $matchedJournal = $null
  foreach ($jf in $jfiles) {
    $j = $null
    try { $j = ((Get-Content -LiteralPath $jf.FullName -Raw) | ConvertFrom-Json) } catch { continue }
    if ($null -eq $j) { continue }
    $ph = [string]$j.phase
    if ($ph -notin @('applied', 'recovered')) { continue }
    $jd = ''; $gd = ''
    try { $jd = [System.IO.Path]::GetFullPath([string]$j.game_dir) } catch { continue }
    try { $gd = [System.IO.Path]::GetFullPath($gameDir)              } catch { continue }
    if ($jd.Equals($gd, [StringComparison]::OrdinalIgnoreCase)) {
      $matchedJournal = @{ path = $jf.FullName; data = $j }
      break
    }
  }

  if ($null -eq $matchedJournal) {
    $h = if ($ko) { '해당 게임 폴더에 설치 기록이 없습니다.' }
         else     { 'No install record found for this game directory.' }
    Write-StatusLine -Status 'missing-input' -Reason 'no-install-record' -Human $h
    return 1
  }

  $journalPath = $matchedJournal.path
  $journalData = $matchedJournal.data

  # 2. Idempotence: phase=recovered -> already removed.
  if ($journalData.phase -eq 'recovered') {
    # Check if files reappeared after removal.
    $filesReappeared = $false
    foreach ($op in @($journalData.ops)) {
      if ($op.op -eq 'create' -and (Test-Path -LiteralPath $op.target)) {
        $filesReappeared = $true; break
      }
      if ($op.op -eq 'replace' -and (Test-Path -LiteralPath $op.target)) {
        $ts = Get-FileSha256 $op.target
        if ($ts -ne $op.beforeSha) { $filesReappeared = $true; break }
      }
    }
    if ($filesReappeared) {
      $h = if ($ko) { '제거 후 대상 파일이 다시 나타났습니다. 삭제를 거부합니다.' }
           else     { 'Target files reappeared after removal; refusing to delete.' }
      Write-StatusLine -Status 'refused' -Reason 'reinstalled-since-removal' -Human $h
      return 1
    }
    $h = if ($ko) { '이미 제거되었습니다. 작업이 없습니다.' }
         else     { 'Already removed; nothing to do.' }
    Write-StatusLine -Status 'no-op' -Reason 'already-removed' -Human $h
    return 0
  }

  # 3. Consent: -Consent yes required (caller validates, but enforce here too).
  #    The argument-mode handler ensures consent=yes before reaching here.
  #    No-op enforcement is handled by the handler, not inside this function.

  # 4. Full-group prevalidation BEFORE any mutation.
  $valid = $true; $failReason = ''; $failDetail = ''

  # schema_version must be known.
  $sv = $null; try { $sv = [int]$journalData.schema_version } catch {}
  if ($sv -ne 1) { $valid = $false; $failReason = 'journal-unknown'; $failDetail = 'unknown schema_version' }

  if ($valid) {
    $base = [System.IO.Path]::GetFullPath($gameDir).TrimEnd('\\').TrimEnd('/')
    foreach ($op in @($journalData.ops)) {
      $tgt = [string]$op.target
      $full = ''; try { $full = [System.IO.Path]::GetFullPath($tgt) } catch { $valid=$false; $failReason='path-escape'; $failDetail=$tgt; break }
      if ($full -ne $base -and $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) {
        # target is inside GameDir prefix → ok
      } elseif ($full -ne $base) {
        $valid = $false; $failReason = 'path-escape'; $failDetail = $tgt; break
      }

      if ($op.op -eq 'create') {
        # sha == sourceSha (deletable) or absent (skip OK)
        if (Test-Path -LiteralPath $op.target) {
          $cs = Get-FileSha256 $op.target
          if ($cs -ne $op.sourceSha) { $valid=$false; $failReason='target-changed'; $failDetail=$tgt; break }
        }
      } elseif ($op.op -eq 'replace') {
        # rc1-era dangerous shape: hash-like field present but backup path empty/missing.
        if ([string]::IsNullOrEmpty($op.backupPath)) {
          $valid=$false; $failReason='backup-missing'; $failDetail=$tgt; break
        }
        # Backup must exist AND its sha == before.sha.
        if (-not (Test-Path -LiteralPath $op.backupPath)) {
          $valid=$false; $failReason='backup-missing'; $failDetail=$op.backupPath; break
        }
        $bsha = Get-FileSha256 $op.backupPath
        if ($bsha -ne $op.beforeSha) {
          $valid=$false; $failReason='backup-tampered'; $failDetail=$op.backupPath; break
        }
        # Current target sha == staged sha (restorable) OR == before.sha (already restored, skip).
        if (Test-Path -LiteralPath $op.target) {
          $tsha = Get-FileSha256 $op.target
          if ($tsha -ne $op.sourceSha -and $tsha -ne $op.beforeSha) {
            $valid=$false; $failReason='target-changed'; $failDetail=$tgt; break
          }
        }
      }
    }
  }

  if (-not $valid) {
    $h = if ($ko) { ('거부 ({0}: {1}). 변경 사항이 없습니다.' -f $failReason,$failDetail) }
         else     { ('Refused ({0}: {1}). Nothing was changed.' -f $failReason,$failDetail) }
    Write-StatusLine -Status 'refused' -Reason $failReason -Human $h
    return 1
  }

  # 5. Execute rollback via child-process transaction engine.
  $psExe  = Get-PsExe
  $script = Join-Path $PSScriptRoot 'susemi_transaction.ps1'
  $allArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'rollback','-Journal',$journalPath)
  $envVars = @{ SUSEMI_TX_JOURNAL_ROOT = $journalRoot }

  $txRes = Invoke-ChildProcess -FileName $psExe -ArgList $allArgs -WorkDir '' -EnvVars $envVars -TimeoutSec $TxTimeoutSec
  Write-TxOutput -Res $txRes

  if ($txRes.timedOut) {
    $h = if ($ko) { ('롤백이 {0}초 안에 끝나지 않아 중단했습니다.' -f $TxTimeoutSec) }
         else     { ('Rollback timed out after {0}s; killed.' -f $TxTimeoutSec) }
    Write-StatusLine -Status 'failed' -Reason 'transaction-timeout' -Human $h
    return 1
  }
  if ($txRes.exit -ne 0) {
    $h = if ($ko) { ('롤백 실패(종료코드={0}); 로그가 변경되지 않았습니다.' -f $txRes.exit) }
         else     { ('Rollback failed (exit={0}); journal unchanged.' -f $txRes.exit) }
    Write-StatusLine -Status 'failed' -Reason 'rollback-failed' -Human $h
    return 1
  }

  # 6. Post-verify: replace ops target sha==before.sha; create ops target absent.
  $postJ = $null
  try { $postJ = ((Get-Content -LiteralPath $journalPath -Raw) | ConvertFrom-Json) } catch {}
  $pOk = $true
  if ($null -eq $postJ) { $pOk = $false }
  if ($pOk) {
    foreach ($op in @($postJ.ops)) {
      if ($op.op -eq 'create') {
        if (Test-Path -LiteralPath $op.target) { $pOk=$false; break }
      } elseif ($op.op -eq 'replace') {
        if (Test-Path -LiteralPath $op.target) {
          $tsha = Get-FileSha256 $op.target
          if ($tsha -ne $op.beforeSha) { $pOk=$false; break }
        }
      }
    }
  }
  if (-not $pOk) {
    $h = if ($ko) { ('사후 검증 실패; 파일 상태가 깨끗하지 않을 수 있습니다. journal={0}' -f $journalPath) }
         else     { ('Post-verification failed; files may be unclean. journal={0}' -f $journalPath) }
    Write-StatusLine -Status 'failed' -Reason 'post-verify-failed' -Human $h
    return 1
  }

  # 7. Success.
  $opCount   = @($journalData.ops).Count
  $txid      = ''; try { $txid = [string]$postJ.txid } catch {}
  if ([string]::IsNullOrEmpty($txid)) { try { $txid = [string]$journalData.txid } catch {} }

  Write-Output "journal=$journalPath"
  if ($txid -ne '') { Write-Output "txid=$txid" }
  $h = if ($ko) { ('{0}개의 작업을 성공적으로 제거했습니다.' -f $opCount) }
       else     { ('Removed {0} operation(s) successfully.' -f $opCount) }
  Write-StatusLine -Status 'removed' -Reason "opcount-$opCount" -Human $h
  return 0
}

# ---- argument-mode entry (manual parse: unknown/missing args must exit 2) ----
$argv = @($args)
if ($argv.Count -eq 0) {
  # Merge the session's output: `exit (Invoke-InteractiveSession)` would capture
  # every prompt and swallow it, so the no-arg console session would print nothing.
  $sessionCode = 1
  Invoke-InteractiveSession | ForEach-Object {
    if ($_ -is [int]) { $sessionCode = [int]$_ } else { Write-Output $_ }
  }
  # Guided epilogue: only for a real console on both streams; one Enter hold so
  # the result stays readable. Piped/EOF/argument runs never hold, and the exit
  # code captured above is preserved.
  if (Test-SessionHoldEligible -Guided) {
    Invoke-SessionHold -M (Get-LangTable -Lang $script:GuidedSessionLang)
  }
  exit $sessionCode
}

$action = ([string]$argv[0]).ToLowerInvariant()
if ($action -notin @('diagnose', 'install', 'remove')) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'unknown-action' `
    -Human ("unknown action: {0} | {1}" -f $argv[0], $Messages.ko.Usage)
  exit 2
}

$exe = $null
$lang = 'ko'
$consent = $null
$sawConsent = $false
$route = $null
$sawRoute = $false
$proxyName = $null
$sawProxyName = $false
$reshadeFirst = $false
$iniConsent = 'no'
$sawIniConsent = $false
$convertReshade = $false
$i = 1
while ($i -lt $argv.Count) {
  $key = ([string]$argv[$i]).ToLowerInvariant()
  if ($key -eq '-reshadefirst') { $reshadeFirst = $true; $i++; continue }
  if ($key -eq '-convertreshade') { $convertReshade = $true; $i++; continue }
  if ($key -eq '-exe' -or $key -eq '-lang' -or $key -eq '-consent' -or $key -eq '-route' -or $key -eq '-proxyname' -or $key -eq '-iniconsent') {
    if (($i + 1) -ge $argv.Count) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' `
        -Human ("missing value for {0} | {1}" -f $argv[$i], $Messages.ko.Usage)
      exit 2
    }
    $val = [string]$argv[$i + 1]
    if ([string]::IsNullOrEmpty($val) -or $val.StartsWith('-')) {
      Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-value' `
        -Human ("missing value for {0} | {1}" -f $argv[$i], $Messages.ko.Usage)
      exit 2
    }
    if ($key -eq '-exe') { $exe = $val }
    elseif ($key -eq '-lang') { $lang = $val.ToLowerInvariant() }
    elseif ($key -eq '-consent') { $consent = $val.ToLowerInvariant(); $sawConsent = $true }
    elseif ($key -eq '-route') { $route = $val.ToLowerInvariant(); $sawRoute = $true }
    elseif ($key -eq '-iniconsent') { $iniConsent = $val.ToLowerInvariant(); $sawIniConsent = $true }
    else { $proxyName = $val; $sawProxyName = $true }
    $i += 2
  } else {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unknown-argument' `
      -Human ("unknown argument: {0} | {1}" -f $argv[$i], $Messages.ko.Usage)
    exit 2
  }
}

if ([string]::IsNullOrWhiteSpace($exe)) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-exe' -Human $Messages.ko.Usage
  exit 2
}
if ($lang -notin @('ko', 'en')) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-lang' `
    -Human ("Lang must be ko|en | {0}" -f $Messages.ko.Usage)
  exit 2
}
if ($action -eq 'install') {
  if (-not $sawConsent) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-consent' -Human $Messages.ko.Usage
    exit 2
  }
  if ($consent -notin @('yes', 'no')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-consent' `
      -Human ("Consent must be yes|no | {0}" -f $Messages.ko.Usage)
    exit 2
  }
} elseif ($action -eq 'remove') {
  if (-not $sawConsent) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'missing-consent' -Human $Messages.ko.Usage
    exit 2
  }
  if ($consent -notin @('yes', 'no')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-consent' `
      -Human ("Consent must be yes|no | {0}" -f $Messages.ko.Usage)
    exit 2
  }
}
elseif ($sawConsent) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-consent' -Human $Messages.ko.Usage
  exit 2
}

if ($action -eq 'install' -and $sawIniConsent) {
  if ($iniConsent -notin @('yes', 'no')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-iniconsent' `
      -Human ("IniConsent must be yes|no | {0}" -f $Messages.ko.Usage)
    exit 2
  }
  if (-not $reshadeFirst) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-iniconsent' -Human $Messages.ko.Usage
    exit 2
  }
}
if ($action -eq 'install' -and $convertReshade -and (-not $reshadeFirst)) {
  Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-convertreshade' -Human $Messages.ko.Usage
  exit 2
}
if ($action -ne 'install') {
  if ($reshadeFirst -or $sawIniConsent -or $convertReshade) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-reshadefirst' -Human $Messages.ko.Usage
    exit 2
  }
}

if ($action -ne 'install') {
  if ($sawRoute) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-route' -Human $Messages.ko.Usage
    exit 2
  }
  if ($sawProxyName) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'unexpected-proxyname' -Human $Messages.ko.Usage
    exit 2
  }
} else {
  if ($sawRoute -and ($route -notin @('asi', 'proxy'))) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-route' `
      -Human ("Route must be asi|proxy | {0}" -f $Messages.ko.Usage)
    exit 2
  }
  if ($sawProxyName -and ($proxyName -match '[\\/]')) {
    Write-StatusLine -Status 'invalid-invocation' -Reason 'bad-proxyname' `
      -Human ("ProxyName must be a bare file name | {0}" -f $Messages.ko.Usage)
    exit 2
  }
}

$M = Get-LangTable -Lang $lang
switch ($action) {
  'diagnose' {
    $diagCode = 1
    Invoke-Diagnose -Exe $exe -Lang $lang -M $M | ForEach-Object {
      if ($_ -is [int]) { $diagCode = $_ } else { Write-Output $_ }
    }
    exit $diagCode
  }
  'install' {
    if ($consent -eq 'no') {
      Write-StatusLine -Status 'refused' -Reason 'consent-required' -Human $M.InstallConsentRequired
      exit 1
    }
    if ($reshadeFirst -and $iniConsent -ne 'yes') {
      Write-StatusLine -Status 'refused' -Reason 'ini-consent-required' -Human $M.IniConsentRequired
      exit 1
    }
    $installCode = 1
    Invoke-InstallTransaction -Exe $exe -Route $route -ProxyName $proxyName -Lang $lang -M $M -ReshadeFirst:$reshadeFirst -IniConsent $iniConsent -ConvertReshade:$convertReshade | ForEach-Object {
      if ($_ -is [int]) { $installCode = [int]$_ } else { Write-Output $_ }
    }
    exit $installCode
  }
  'remove' {
    if ($consent -ne 'yes') {
      Write-StatusLine -Status 'refused' -Reason 'consent-required' -Human $M.InstallConsentRequired
      exit 1
    }
    $removeCode = 1
    Invoke-RemoveTransaction -Exe $exe -Lang $lang -M $M | ForEach-Object {
      if ($_ -is [int]) { $removeCode = [int]$_ } else { Write-Output $_ }
    }
    exit $removeCode
  }
}
