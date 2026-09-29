#Requires -Version 5.1
<#
.SYNOPSIS
  susemi_stage_helpers.ps1 - private-staging adapter for the approved local Ultimate ASI
  Loader (UAL) pin and the consented official NVIDIA Streamline runtime (plan todo T6).

.DESCRIPTION
  Copies verified payloads into a PRIVATE staging directory only. It never writes into a
  game folder, never runs a game, and never invokes Get-StreamlineRuntime.ps1 -Action remove.

  Actions:
    ual        Stage tools\asi-loader\Ultimate-ASI-Loader-x64.dll (inner pin
               fa266e35...5afd7) from the byte-exact local rc2 ZIP (outer sha
               42bac65f...1cc2a) or from the worktree copy, or - with -Consent network -
               from the official v9.7.4 release URL (Install-PinnedUAL.ps1 -Destination
               into staging, then re-pinned here). No network without -Consent network.
    streamline Stage OptiScaler\streamline from the official NVIDIA-RTX/Streamline release
               ONLY after -Consent network, by running tools/Get-StreamlineRuntime.ps1 as a
               child (120s timeout + kill), then independently re-verifying SOURCES.json,
               every listed sha and the required DLLs. A missing official digest or a
               non-Valid signature is NOT a failure to install: status=staged-unverified
               (documented weaker provenance, exit 0 + explicit warning line) so the
               coordinator can decide. A failed child => exit 1 with its captured reason.
    verify     Re-check every staged file against the pins/manifests.

  Machine line: exactly one "status=<word> reason=<token>" per run. Human text is printed
  bilingually (ko: then en:). Exit: 0 ok, 1 refused/failed, 2 invalid invocation.

  Pin constants mirror tools/Install-PinnedUAL.ps1; that file is NOT modified.
#>

$ErrorActionPreference = 'Stop'

# ---- pins (mirror of tools/Install-PinnedUAL.ps1; do not modify that file) ----
$UalUrl        = 'https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/download/v9.7.4/Ultimate-ASI-Loader_x64.zip'
$UalOuterSha   = '8272d83b2692662098746f2d0ad0e2d85f3c8358ab1d63f75fbe835c2c8135fd'
$UalInnerName  = 'dinput8.dll'
$UalInnerSha   = 'fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7'

# Byte-exact local rc2 ZIP and the UAL member it carries.
$Rc2ZipDefault = 'C:/omo-research/susemi-next-ui-lang/.omo/evidence/susemi-xefg-nr-loadorder-release/20260927/task-22/staging/r5/OptiScaler-NR-v11.2-rc2.zip'
$Rc2ZipSha     = '42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a'
$Rc2UalEntry   = 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'

$StreamlineRequired = @('sl.interposer.dll', 'sl.common.dll', 'nvngx_dlssg.dll')
$ChildTimeoutSec    = 120

$Usage = 'susemi_stage_helpers.ps1 ual -StageDir <dir> [-Source zip|worktree] [-Consent network] [-Rc2Zip <path>] | streamline -StageDir <dir> [-Version <tag>|latest] [-Consent network] | verify -StageDir <dir>'

# ------------------------------------------------------------------ output ----
function Write-Human {
    param([string]$Ko, [string]$En)
    Write-Output ('ko: {0}' -f $Ko)
    Write-Output ('en: {0}' -f $En)
}

function Write-StatusLine {
    param([string]$Status, [string]$Reason, [string]$Ko, [string]$En)
    Write-Output ('status={0} reason={1}' -f $Status, $Reason)
    Write-Human -Ko $Ko -En $En
}

function Fail-Named {
    param([string]$Status, [string]$Reason, [string]$Ko, [string]$En, [int]$Code)
    Write-StatusLine -Status $Status -Reason $Reason -Ko $Ko -En $En
    exit $Code
}

function Invalid-Invocation {
    param([string]$Reason, [string]$Detail = '')
    $ko = ("잘못된 호출: {0} {1} | {2}" -f $Reason, $Detail, $Usage)
    $en = ("invalid invocation: {0} {1} | {2}" -f $Reason, $Detail, $Usage)
    Write-StatusLine -Status 'invalid-invocation' -Reason $Reason -Ko $ko -En $en
    exit 2
}

# ------------------------------------------------------------------ helpers ---
function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StageRoot {
    param([string]$StageDir)
    if ([string]::IsNullOrWhiteSpace($StageDir)) { Invalid-Invocation -Reason 'missing-stagedir' }
    try { return [IO.Path]::GetFullPath($StageDir) }
    catch { Invalid-Invocation -Reason 'bad-stagedir' -Detail $StageDir }
}

# Resolve a staging-relative target and refuse any path that escapes the stage root.
function Get-StageTarget {
    param([string]$StageRoot, [string]$Relative)
    $sr = [IO.Path]::GetFullPath($StageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $t = [IO.Path]::GetFullPath((Join-Path $sr $Relative))
    $prefix = $sr + [IO.Path]::DirectorySeparatorChar
    if (-not ($t.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        Fail-Named 'refused' 'stage-path-escape' `
            ("스테이징 루트 밖으로 벗어나는 경로는 거부합니다: {0}" -f $t) `
            ("refusing a target that escapes the staging root: {0}" -f $t) 1
    }
    return $t
}

function Get-HostExe {
    try { return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    $p = Join-Path $PSHOME 'powershell.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return 'powershell.exe'
}

function Quote-Arg {
    param([string]$A)
    if ($A -match '[\s"]') { return '"' + ($A -replace '"', '\"') + '"' }
    return $A
}

# Run a sibling PowerShell script as a CHILD process with a hard timeout + kill.
# Uses System.Diagnostics.Process (not Start-Process -PassThru): in this Windows PowerShell
# 5.1 environment Start-Process -PassThru returns an EMPTY .ExitCode, which would misreport
# a successful child as a failure. stdout/stderr are drained asynchronously to avoid deadlock.
function Invoke-ChildScript {
    param([string]$ScriptPath, [string[]]$ChildArgs, [int]$TimeoutSec = 120)
    $res = [ordered]@{ exit = -1; timedOut = $false; stdout = ''; stderr = '' }
    $exe = Get-HostExe
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ChildArgs
    $argStr = (($all | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
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

# Uses Write-Host on purpose: this function is called inside value-returning functions, so it
# must never add strings to the pipeline (Write-Output would corrupt $r / $v captures).
function Write-ChildOutput {
    param($Res)
    Write-Host ('child: exit={0} timedOut={1}' -f $Res.exit, $Res.timedOut)
    if ($Res.stdout) { foreach ($ln in ($Res.stdout.TrimEnd() -split "`r?`n")) { Write-Host ('child| ' + $ln) } }
    if ($Res.stderr) { foreach ($ln in ($Res.stderr.TrimEnd() -split "`r?`n")) { Write-Host ('child! ' + $ln) } }
}

# --------------------------------------------------------------- UAL sources --
# Each source function returns @{ ok; reason; ko; en } and stages the target on success.

function Copy-UalFromRc2Zip {
    param([string]$ZipPath, [string]$Target)
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        return @{ ok = $false; reason = 'rc2-zip-absent'
            ko = ("로컬 rc2 ZIP을 찾을 수 없습니다: {0} (다른 경로는 -Rc2Zip, 또는 공식 다운로드는 -Consent network)" -f $ZipPath)
            en = ("local rc2 ZIP not found: {0} (pass -Rc2Zip <path>, or allow the official download with -Consent network)" -f $ZipPath) }
    }
    $zsha = Get-Sha256 $ZipPath
    if ($zsha -ne $Rc2ZipSha) {
        return @{ ok = $false; reason = 'rc2-zip-sha-mismatch'
            ko = ("rc2 ZIP 해시 불일치: 관측 {0}, 기대 {1}. 추출/스테이징 전에 거부합니다." -f $zsha, $Rc2ZipSha)
            en = ("rc2 ZIP sha mismatch: observed {0}, expected {1}. Refusing before extract/stage." -f $zsha, $Rc2ZipSha) }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $Rc2UalEntry } | Select-Object -First 1
            if (-not $entry) {
                return @{ ok = $false; reason = 'rc2-ual-entry-missing'
                    ko = ("rc2 ZIP 안에 UAL 항목이 없습니다: {0}" -f $Rc2UalEntry)
                    en = ("rc2 ZIP has no UAL entry: {0}" -f $Rc2UalEntry) }
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
        } finally { $zip.Dispose() }
        $isha = Get-Sha256 $tmp
        if ($isha -ne $UalInnerSha) {
            return @{ ok = $false; reason = 'rc2-ual-entry-sha-mismatch'
                ko = ("rc2 ZIP 안 UAL 해시 불일치: 관측 {0}, 기대 {1}. 스테이징하지 않습니다." -f $isha, $UalInnerSha)
                en = ("rc2 ZIP UAL sha mismatch: observed {0}, expected {1}. Not staged." -f $isha, $UalInnerSha) }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
        Copy-Item -LiteralPath $tmp -Destination $Target -Force
        $post = Get-Sha256 $Target
        if ($post -ne $UalInnerSha) {
            return @{ ok = $false; reason = 'ual-stage-verify-failed'
                ko = ("스테이징 후 UAL 해시 재검증 실패: {0}" -f $post)
                en = ("staged UAL failed post-copy verification: {0}" -f $post) }
        }
        return @{ ok = $true; reason = 'ual-staged-zip'
            ko = ("rc2 ZIP({0})에서 검증된 UAL을 스테이징했습니다." -f $Rc2ZipSha.Substring(0, 12))
            en = ("staged verified UAL from the rc2 ZIP ({0}...)" -f $Rc2ZipSha.Substring(0, 12)) }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Copy-UalFromWorktree {
    param([string]$Target)
    $root = Split-Path -Parent $PSScriptRoot
    $src = Join-Path $root 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        return @{ ok = $false; reason = 'worktree-source-absent'
            ko = ("워크트리 UAL 사본이 없습니다: {0} (이 파일은 gitignore 대상입니다). -Source zip 또는 -Consent network를 사용하세요." -f $src)
            en = ("worktree UAL copy is absent: {0} (this file is gitignored). Use -Source zip or -Consent network." -f $src) }
    }
    $sha = Get-Sha256 $src
    if ($sha -ne $UalInnerSha) {
        return @{ ok = $false; reason = 'worktree-source-pin-mismatch'
            ko = ("워크트리 UAL 해시가 핀과 다릅니다: 관측 {0}, 기대 {1}. 복사하지 않습니다." -f $sha, $UalInnerSha)
            en = ("worktree UAL sha differs from the pin: observed {0}, expected {1}. Not copied." -f $sha, $UalInnerSha) }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    Copy-Item -LiteralPath $src -Destination $Target -Force
    $post = Get-Sha256 $Target
    if ($post -ne $UalInnerSha) {
        return @{ ok = $false; reason = 'ual-stage-verify-failed'
            ko = ("스테이징 후 UAL 해시 재검증 실패: {0}" -f $post)
            en = ("staged UAL failed post-copy verification: {0}" -f $post) }
    }
    return @{ ok = $true; reason = 'ual-staged-worktree'
        ko = '핀과 일치하는 워크트리 UAL 사본을 스테이징했습니다.'
        en = 'staged the worktree UAL copy that matches the pin.' }
}

function Invoke-UalNetwork {
    param([string]$Target)
    $script = Join-Path $PSScriptRoot 'Install-PinnedUAL.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        return @{ ok = $false; reason = 'install-pinnedual-missing'
            ko = ("핀 UAL 페처를 찾을 수 없습니다: {0}" -f $script)
            en = ("pinned UAL fetcher not found: {0}" -f $script) }
    }
    $r = Invoke-ChildScript -ScriptPath $script -ChildArgs @('-Destination', $Target) -TimeoutSec $ChildTimeoutSec
    Write-ChildOutput -Res $r
    if ($r.timedOut) {
        return @{ ok = $false; reason = 'ual-network-timeout'
            ko = ("공식 UAL 페처가 {0}초 안에 끝나지 않아 중단했습니다." -f $ChildTimeoutSec)
            en = ("the official UAL fetcher did not finish within {0}s; killed." -f $ChildTimeoutSec) }
    }
    if ($r.exit -ne 0) {
        return @{ ok = $false; reason = 'ual-network-fetch-failed'
            ko = ("공식 UAL 페처가 종료 코드 {0}로 실패했습니다." -f $r.exit)
            en = ("the official UAL fetcher failed with exit {0}." -f $r.exit) }
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        return @{ ok = $false; reason = 'ual-network-no-output'
            ko = '공식 UAL 페처가 종료 코드 0을 반환했지만 스테이징 파일이 없습니다.'
            en = 'the official UAL fetcher returned exit 0 but produced no staged file.' }
    }
    # Re-implemented pin check: independent of the child's own verification.
    $sha = Get-Sha256 $Target
    if ($sha -ne $UalInnerSha) {
        return @{ ok = $false; reason = 'ual-network-pin-mismatch'
            ko = ("공식 UAL 스테이징 파일 해시 불일치: 관측 {0}, 기대 {1}. 거부합니다." -f $sha, $UalInnerSha)
            en = ("official UAL staged file sha mismatch: observed {0}, expected {1}. Refusing." -f $sha, $UalInnerSha) }
    }
    return @{ ok = $true; reason = 'ual-staged-network'
        ko = '공식 v9.7.4 릴리스에서 이중 검증된 UAL을 스테이징했습니다.'
        en = 'staged the double-verified UAL from the official v9.7.4 release.' }
}

# --------------------------------------------------------------------- UAL ----
function Invoke-StageUal {
    param([string]$StageDir, [string]$Source, [string]$Consent, [string]$Rc2Zip)
    $root = Get-StageRoot $StageDir
    $target = Get-StageTarget $root 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
    $zipPath = if ($Rc2Zip -ne '') { $Rc2Zip } else { $Rc2ZipDefault }
    $consentTag = 'none'
    if ($Consent -ne '') { $consentTag = $Consent }
    Write-Output ('helper: action=ual stage={0} source={1} consent={2} rc2zip={3}' -f $root, $Source, $consentTag, $zipPath)

    $r = $null
    if ($Source -eq 'worktree') {
        $r = Copy-UalFromWorktree -Target $target
    } else {
        $r = Copy-UalFromRc2Zip -ZipPath $zipPath -Target $target
    }

    if ($r.ok) {
        Write-FinalUalOk -Target $target -Reason $r.reason -Ko $r.ko -En $r.en
    }

    # Local source unavailable: a PIN MISMATCH is a tamper signal -> refuse outright.
    if ($r.reason -like '*mismatch*') {
        Fail-Named 'refused' $r.reason $r.ko $r.en 1
    }

    # Absent local source: network only with explicit consent.
    if ($Consent -eq 'network') {
        Write-Output ('helper: consent-check action=ual-network network=granted child-spawn=allowed')
        $n = Invoke-UalNetwork -Target $target
        if ($n.ok) { Write-FinalUalOk -Target $target -Reason $n.reason -Ko $n.ko -En $n.en }
        Fail-Named 'failed' $n.reason $n.ko $n.en 1
    }
    Write-Output ('helper: consent-check action=ual-network network=not-granted child-spawn=blocked')
    Fail-Named 'refused' $r.reason $r.ko $r.en 1
}

function Write-FinalUalOk {
    param([string]$Target, [string]$Reason, [string]$Ko, [string]$En)
    Write-StatusLine -Status 'staged' -Reason $Reason -Ko $Ko -En $En
    $sha = Get-Sha256 $Target
    Write-Human -Ko ("스테이징 파일: {0} sha256={1}" -f $Target, $sha) -En ("staged file: {0} sha256={1}" -f $Target, $sha)
    exit 0
}

# -------------------------------------------------------------- Streamline ----
# Returns @{ ok; unverified; reason; ko; en; warnings = @() } - ok=$false is a hard failure.
function Test-StreamlineStage {
    param([string]$Dest, [string]$ChildOutput)
    $manifestPath = Join-Path $Dest 'SOURCES.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return @{ ok = $false; unverified = $false; reason = 'streamline-manifest-missing'; warnings = @()
            ko = ("Streamline 매니페스트가 없습니다: {0}" -f $manifestPath)
            en = ("Streamline manifest is missing: {0}" -f $manifestPath) }
    }
    try { $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch {
        return @{ ok = $false; unverified = $false; reason = 'streamline-manifest-unreadable'; warnings = @()
            ko = ("Streamline 매니페스트를 읽을 수 없습니다: {0}" -f $manifestPath)
            en = ("Streamline manifest is unreadable: {0}" -f $manifestPath) }
    }
    $names = @()
    if ($null -ne $m.files) { $names = @($m.files.PSObject.Properties.Name) }
    if ($names.Count -eq 0) {
        return @{ ok = $false; unverified = $false; reason = 'streamline-manifest-empty'; warnings = @()
            ko = 'Streamline 매니페스트에 파일 목록이 없습니다.'
            en = 'Streamline manifest lists no files.' }
    }
    $bad = @()
    foreach ($n in $names) {
        $p = Join-Path $Dest $n
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $bad += $n; continue }
        if ((Get-Sha256 $p) -ne ([string]$m.files.$n.sha256)) { $bad += $n }
    }
    if ($bad.Count -gt 0) {
        return @{ ok = $false; unverified = $false; reason = 'streamline-file-hash-mismatch'; warnings = @()
            ko = ("Streamline 파일 해시가 매니페스트와 다릅니다: {0}" -f ($bad -join ', '))
            en = ("Streamline file sha differs from the manifest: {0}" -f ($bad -join ', ')) }
    }
    $missingRequired = @($StreamlineRequired | Where-Object { $names -notcontains $_ })
    $badSig = @($names | Where-Object { ([string]$m.files.$_.signature) -ne 'Valid' })
    $missingDigest = ($ChildOutput -match 'did not expose an asset digest')
    $warnings = @()
    if ($missingRequired.Count -gt 0) { $warnings += ('missing required DLL(s): ' + ($missingRequired -join ', ')) }
    if ($badSig.Count -gt 0) { $warnings += ('non-Valid signature: ' + ($badSig -join ', ')) }
    if ($missingDigest) { $warnings += 'release did not expose an official asset digest' }
    if ($warnings.Count -gt 0) {
        $reason = if ($missingRequired.Count -gt 0) { 'missing-required-dll' }
                  elseif ($badSig.Count -gt 0) { 'signature-unverified' }
                  else { 'release-digest-unavailable' }
        return @{ ok = $true; unverified = $true; reason = $reason; warnings = $warnings
            ko = ('Streamline을 스테이징했으나 약한 출처 표시입니다({0}): {1}' -f $reason, ($warnings -join '; '))
            en = ('Streamline staged with weaker provenance ({0}): {1}' -f $reason, ($warnings -join '; ')) }
    }
    return @{ ok = $true; unverified = $false; reason = 'streamline-staged-verified'; warnings = @()
        ko = ('SOURCES.json의 모든 파일 해시가 일치하고 필수 DLL이 있습니다: {0}' -f $Dest)
        en = ('every SOURCES.json file sha matches and the required DLLs are present: {0}' -f $Dest) }
}

function Invoke-StageStreamline {
    param([string]$StageDir, [string]$Version, [string]$Consent)
    $root = Get-StageRoot $StageDir
    $dest = Get-StageTarget $root 'OptiScaler/streamline'
    $consentTag = 'none'
    if ($Consent -ne '') { $consentTag = $Consent }
    Write-Output ('helper: action=streamline stage={0} dest={1} version={2} consent={3}' -f $root, $dest, $Version, $consentTag)

    if ($Consent -ne 'network') {
        Write-Output ('helper: consent-check action=streamline network=not-granted child-spawn=blocked')
        Fail-Named 'refused' 'network-consent-required' `
            'Streamline 다운로드는 명시적 동의가 필요합니다. -Consent network 없이는 네트워크를 호출하지 않았고 자식 프로세스도 만들지 않았습니다.' `
            'Streamline download requires explicit consent; without -Consent network no network call was made and no child process was spawned.' 1
    }
    Write-Output ('helper: consent-check action=streamline network=granted child-spawn=allowed')

    $child = Join-Path $PSScriptRoot 'Get-StreamlineRuntime.ps1'
    if (-not (Test-Path -LiteralPath $child -PathType Leaf)) {
        Fail-Named 'failed' 'streamline-helper-missing' `
            ("Streamline 페처를 찾을 수 없습니다: {0}" -f $child) ("Streamline fetcher not found: {0}" -f $child) 1
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($Version) -or ($Version -eq 'latest')) {
        $childArgs = @('-Action', 'latest', '-Destination', $dest)
    } else {
        $childArgs = @('-Action', 'version', '-Version', $Version, '-Destination', $dest)
    }
    $r = Invoke-ChildScript -ScriptPath $child -ChildArgs $childArgs -TimeoutSec $ChildTimeoutSec
    Write-ChildOutput -Res $r
    if ($r.timedOut) {
        Fail-Named 'failed' 'streamline-child-timeout' `
            ("Streamline 페처가 {0}초 안에 끝나지 않아 중단했습니다." -f $ChildTimeoutSec) `
            ("the Streamline fetcher did not finish within {0}s; killed." -f $ChildTimeoutSec) 1
    }
    if ($r.exit -ne 0) {
        Fail-Named 'failed' 'streamline-child-failed' `
            ("Streamline 페처가 종료 코드 {0}로 실패했습니다." -f $r.exit) `
            ("the Streamline fetcher failed with exit {0}." -f $r.exit) 1
    }
    $v = Test-StreamlineStage -Dest $dest -ChildOutput ($r.stdout + "`n" + $r.stderr)
    if (-not $v.ok) { Fail-Named 'failed' $v.reason $v.ko $v.en 1 }
    if ($v.unverified) {
        foreach ($w in $v.warnings) { Write-Output ('WARNING: ' + $w) }
        Write-StatusLine -Status 'staged-unverified' -Reason $v.reason -Ko $v.ko -En $v.en
        exit 0
    }
    Write-StatusLine -Status 'staged' -Reason $v.reason -Ko $v.ko -En $v.en
    exit 0
}

# ------------------------------------------------------------------ verify ----
function Invoke-Verify {
    param([string]$StageDir)
    $root = Get-StageRoot $StageDir
    $root = [IO.Path]::GetFullPath($root)
    Write-Output ('helper: action=verify stage={0}' -f $root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Fail-Named 'missing-input' 'nothing-staged' `
            ("스테이징 폴더가 없습니다(확인할 파일 없음): {0}" -f $root) `
            ("staging folder does not exist (nothing to verify): {0}" -f $root) 1
    }
    $ualTarget = Get-StageTarget $root 'tools/asi-loader/Ultimate-ASI-Loader-x64.dll'
    $slManifest = Get-StageTarget $root 'OptiScaler/streamline/SOURCES.json'
    $ualPresent = Test-Path -LiteralPath $ualTarget -PathType Leaf
    $slPresent = Test-Path -LiteralPath $slManifest -PathType Leaf
    if ((-not $ualPresent) -and (-not $slPresent)) {
        Fail-Named 'missing-input' 'nothing-staged' `
            ("스테이징 폴더에 확인할 파일이 없습니다: {0}" -f $root) `
            ("no staged files to verify in: {0}" -f $root) 1
    }

    $problems = @()
    $notes = @()
    if ($ualPresent) {
        $sha = Get-Sha256 $ualTarget
        if ($sha -eq $UalInnerSha) { Write-Output ('verify| ual ok sha256=' + $sha) }
        else { $problems += 'ual-pin-mismatch'; Write-Output ('verify| ual MISMATCH sha256={0} expected={1}' -f $sha, $UalInnerSha) }
    } else { $notes += 'ual-not-staged' }

    if ($slPresent) {
        $v = Test-StreamlineStage -Dest (Split-Path -Parent $slManifest) -ChildOutput ''
        if (-not $v.ok) { $problems += $v.reason; Write-Output ('verify| streamline FAIL reason=' + $v.reason) }
        elseif ($v.unverified) { $notes += $v.reason; Write-Output ('verify| streamline unverified reason=' + $v.reason) }
        else { Write-Output 'verify| streamline ok' }
    } else { $notes += 'streamline-not-staged' }

    if ($problems.Count -gt 0) {
        Fail-Named 'failed' $problems[0] `
            ("스테이징 재검증 실패: {0}" -f ($problems -join ', ')) `
            ("staged re-verification failed: {0}" -f ($problems -join ', ')) 1
    }
    if ($notes.Count -gt 0) {
        Write-StatusLine -Status 'verified' -Reason 'staged-with-notes' `
            ("스테이징 확인 완료(참고: {0})" -f ($notes -join ', ')) `
            ("staged check complete (notes: {0})" -f ($notes -join ', '))
    } else {
        Write-StatusLine -Status 'verified' -Reason 'all-pins-match' `
            '모든 스테이징 파일이 핀/매니페스트와 일치합니다.' 'all staged files match their pins/manifests.'
    }
    exit 0
}

# -------------------------------------------------------------------- parse ---
$argv = @($args)
$action = ''
$stageDir = ''
$source = 'zip'
$version = 'latest'
$consent = ''
$rc2zip = ''

$i = 0
if (($argv.Count -gt 0) -and (-not ([string]$argv[0]).StartsWith('-'))) {
    $action = ([string]$argv[0]).ToLowerInvariant()
    $i = 1
}
while ($i -lt $argv.Count) {
    $key = ([string]$argv[$i]).ToLowerInvariant()
    $needsValue = @('-action', '-stagedir', '-source', '-version', '-consent', '-rc2zip') -contains $key
    if (-not $needsValue) { Invalid-Invocation -Reason 'unknown-argument' -Detail ([string]$argv[$i]) }
    if (($i + 1) -ge $argv.Count) { Invalid-Invocation -Reason 'missing-value' -Detail ([string]$argv[$i]) }
    $val = [string]$argv[$i + 1]
    switch ($key) {
        '-action'   { $action = $val.ToLowerInvariant() }
        '-stagedir' { $stageDir = $val }
        '-source'   { $source = $val.ToLowerInvariant() }
        '-version'  { $version = $val }
        '-consent'  { $consent = $val.ToLowerInvariant() }
        '-rc2zip'   { $rc2zip = $val }
    }
    $i += 2
}

if ([string]::IsNullOrWhiteSpace($action)) { Invalid-Invocation -Reason 'missing-action' }
if ($action -notin @('ual', 'streamline', 'verify')) { Invalid-Invocation -Reason 'unknown-action' -Detail $action }
if ([string]::IsNullOrWhiteSpace($stageDir)) { Invalid-Invocation -Reason 'missing-stagedir' }
if ($source -notin @('zip', 'worktree')) { Invalid-Invocation -Reason 'bad-source' -Detail $source }
if ($consent -notin @('', 'network')) { Invalid-Invocation -Reason 'bad-consent' -Detail $consent }

switch ($action) {
    'ual'        { Invoke-StageUal -StageDir $stageDir -Source $source -Consent $consent -Rc2Zip $rc2zip }
    'streamline' { Invoke-StageStreamline -StageDir $stageDir -Version $version -Consent $consent }
    'verify'     { Invoke-Verify -StageDir $stageDir }
}
