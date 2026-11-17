$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path ([IO.Path]::GetTempPath()) ('nr-finished-extent-' + [guid]::NewGuid())
Write-Host "NR_FINISHED_EXTENT_ARTIFACTS=$out"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$source = Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp" -Raw
$header = Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_FinishedPicture.h" -Raw
$signature = 'bool DlssNr_Dx12::State::AdmitFinishedCapture('
$start = $source.IndexOf($signature, [StringComparison]::Ordinal)
if ($start -lt 0) { throw 'Admission signature missing' }
$first = $source.IndexOf('{', $start)
$depth = 0
$end = -1
for ($i = $first; $i -lt $source.Length; ++$i) {
    if ($source[$i] -eq '{') { ++$depth }
    if ($source[$i] -eq '}') { --$depth }
    if (!$depth) { $end = $i + 1; break }
}
if ($end -lt 0) { throw 'Admission body unterminated' }
$admission = $source.Substring($start, $end - $start)
$applyStart = $source.IndexOf('    auto finishedFrame = slot.frame;', [StringComparison]::Ordinal)
$applyEnd = $source.IndexOf('    const bool holdFinished', $applyStart, [StringComparison]::Ordinal)
if ($applyStart -lt 0 -or $applyEnd -lt 0) { throw 'Actual apply-preparation block missing' }
$apply = $source.Substring($applyStart, $applyEnd - $applyStart)
$state = Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h" -Raw
$member = [regex]::Match($state, '(?m)^\s*DlssNr::FinishedLag1 lag;').Value.Trim()
if (!$member) { throw 'Production LateContext lag member missing' }
$late = (Get-Content -LiteralPath "$repo/OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp" -Raw).Replace("`r`n","`n")
$cancelStart = $late.IndexOf('auto DlssNr_Dx12::State::LateContext::Cancel()')
$cancelEnd = $late.IndexOf('auto DlssNr_Dx12::State::LateContext::Clone(', $cancelStart)
$cancel = $late.Substring($cancelStart, $cancelEnd - $cancelStart)
$resetStart = $late.IndexOf('    frame.Reset = gameReset != 0;')
$resetEnd = $late.IndexOf('    params->Get(NVSDK_NGX_Parameter_FrameTimeDeltaInMsec', $resetStart)
$captureReset = $late.Substring($resetStart, $resetEnd - $resetStart)
$frameUse = '        auto frame = finishedFrame;'
if (($source.Split(@($frameUse), [StringSplitOptions]::None).Count - 1) -ne 1) { throw 'Actual Run frame selection missing' }
$variants = @(
    @{ tag='green'; from=''; to=''; marker='' },
    @{ tag='seed-old-size'; from='const bool resized = width != captured.OutputWidth || height != captured.OutputHeight;';
       to='const bool resized = width != captured.OutputWidth || height != captured.OutputHeight; if (resized) return std::nullopt;'; marker='BF_EXTENT_ADMISSION' },
    @{ tag='seed-mv'; from='prepared.MvScaleX *= float(width) / captured.OutputWidth;';
       to='prepared.MvScaleX *= 1.0f;'; marker='BF_EXTENT_MV_SCALE' },
    @{ tag='seed-fake-size'; from='auto prepared = captured;';
       to='auto prepared = captured; prepared.OutputWidth = width; prepared.OutputHeight = height;'; marker='BF_EXTENT_SOURCE_METADATA' },
    @{ tag='seed-aspect'; from='uint64_t(width) * captured.OutputHeight != uint64_t(height) * captured.OutputWidth';
       to='false'; marker='BF_EXTENT_ASPECT_REFUSAL' },
    @{ tag='seed-apply'; from='finishedFrame = *prepared;'; to='finishedFrame = slot.frame;'; marker='BF_EXTENT_MV_SCALE' },
    @{ tag='seed-frame-use'; from='auto frame = finishedFrame;'; to='auto frame = slot.frame;'; marker='BF_EXTENT_MV_SCALE' },
    @{ tag='seed-bounds'; from='(!wanted.width || region.width == wanted.width)'; to='true'; marker='BF_EXTENT_MOTION_BOUNDS' },
    @{ tag='seed-global'; from='DlssNr::FinishedLag1 lag;'; to='inline static DlssNr::FinishedLag1 lag;'; marker='NR_LAG_OWNER_ISOLATION' },
    @{ tag='seed-cancel'; from='    lag.Reset();'; to='    (void)lag;'; marker='NR_LAG_CANCEL' },
    @{ tag='seed-capture-reset'; from='if (frame.Reset)'; to='if (false)'; marker='NR_LAG_CAPTURE_RESET' }
)
foreach ($variant in $variants) {
    $dir = Join-Path $out $variant.tag
    New-Item -ItemType Directory -Path "$dir/shaders/dlssnr" -Force | Out-Null
    $h = $header; $a = $apply; $f = $frameUse
    $m = $member; $c = $cancel; $r = $captureReset
    if ($variant.tag -ne 'green') {
        if ($variant.tag -eq 'seed-apply') { $text = $a }
        elseif ($variant.tag -eq 'seed-frame-use') { $text = $f }
        elseif ($variant.tag -eq 'seed-global') { $text = $m }
        elseif ($variant.tag -eq 'seed-cancel') { $text = $c }
        elseif ($variant.tag -eq 'seed-capture-reset') { $text = $r }
        else { $text = $h }
        if (($text.Split(@($variant.from), [StringSplitOptions]::None).Count - 1) -ne 1) { throw "Seed anchor drift: $($variant.tag)" }
        $text = $text.Replace($variant.from, $variant.to)
        if ($variant.tag -eq 'seed-apply') { $a = $text }
        elseif ($variant.tag -eq 'seed-frame-use') { $f = $text }
        elseif ($variant.tag -eq 'seed-global') { $m = $text }
        elseif ($variant.tag -eq 'seed-cancel') { $c = $text }
        elseif ($variant.tag -eq 'seed-capture-reset') { $r = $text }
        else { $h = $text }
    }
    Set-Content -LiteralPath "$dir/shaders/dlssnr/DlssNr_FinishedPicture.h" -Value $h -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_admission.inc" -Value $admission -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_apply_prepare.inc" -Value $a -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_apply_frame.inc" -Value $f -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_lag_member.inc" -Value $m -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_cancel.inc" -Value $c -Encoding ascii
    Set-Content -LiteralPath "$dir/finished_capture_reset.inc" -Value $r -Encoding ascii
    $exe = "$dir/extent.exe"
    # Keep the project's /W4 smoke policy: Common.h intentionally pads its
    # alignas(256) ABI constant buffer (existing C4324, retained in the raw log).
    & cl.exe /nologo /std:c++20 /EHsc /W4 /DNOMINMAX "/I$dir" "/I$repo/OptiScaler" `
        "/I$repo/OptiScaler/shaders/dlssnr" "/Fo$dir/" "/Fe$exe" "$PSScriptRoot/nr_finished_extent_smoke.cpp" `
        2>&1 | Tee-Object -FilePath "$dir/compile.log" | Write-Host
    if ($LASTEXITCODE) { throw "Extent compile failed: $($variant.tag)" }
    & $exe 2>&1 | Tee-Object -FilePath "$dir/output.log" | Write-Host
    $code = $LASTEXITCODE
    Write-Host "BF_EXTENT_TEST tag=$($variant.tag) exit=$code"
    if ($variant.tag -eq 'green' -and $code) { throw 'Positive extent regression failed' }
    if ($variant.tag -ne 'green' -and (!$code -or (Get-Content -LiteralPath "$dir/output.log" -Raw) -notmatch $variant.marker)) {
        throw "Seed did not fail as intended: $($variant.tag)"
    }
}
Write-Host 'BF_EXTENT_RESULT exit=0 positive=passed mutations=10/10 gpu=false'
exit 0
