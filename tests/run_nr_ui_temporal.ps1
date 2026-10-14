param(
    [Parameter(Mandatory)][ValidateSet('Cpu', 'Warp', 'Runtime')][string]$Phase,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [ValidateSet('none', 'overlay-before-temporal', 'stale-owner')][string]$Mutation = 'none',
    [switch]$BuildOnly
)
$ErrorActionPreference = 'Stop'
if($Phase -eq 'Runtime') {
    if(-not $BuildOnly -or $Mutation -ne 'none') { throw 'TASK14_EXPLICIT_RUNTIME_ENTRY_REFUSED' }
    & (Join-Path $PSScriptRoot 'nr_ui_temporal/RunRuntime.ps1') -Mode Build -EvidenceRoot $EvidenceRoot
    exit $LASTEXITCODE
}
$repo = Split-Path $PSScriptRoot -Parent
$parent = Join-Path $repo '.omo/evidence/optiscaler-nr-present-addon-options/e1-20261002-01a0fbd1'
if (-not [IO.Path]::IsPathRooted($EvidenceRoot)) { throw 'TASK3_EVIDENCE_ROOT_REFUSED' }
$full = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
$allowed = [IO.Path]::GetFullPath($parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $full.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'TASK3_EVIDENCE_ROOT_REFUSED'
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw 'TASK3_COMPILER_MISSING' }
if (Test-Path -LiteralPath (Join-Path $full 'result.json')) { throw 'TASK3_EVIDENCE_OVERWRITE_REFUSED' }
New-Item -ItemType Directory -Force -Path $full | Out-Null
$gameObs = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(CrimsonDesert.*|obs64|obs32)\.exe$'
} | Select-Object ProcessId, CreationDate, ExecutablePath, CommandLine)
[ordered]@{observedUtc=[DateTimeOffset]::UtcNow.ToString('o');gameObsCount=$gameObs.Count;
    gameObsMatches=$gameObs} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $full 'build-absence.json') -Encoding UTF8
if($gameObs.Count) { throw 'TASK3_NATIVE_GAME_OBS_OCCUPIED_REFUSED' }

function FunctionText([string]$text, [string]$signature) {
    $at = $text.IndexOf($signature, [StringComparison]::Ordinal)
    if ($at -lt 0) { throw "TASK3_SOURCE_ANCHOR_MISSING=$signature" }
    $open = $text.IndexOf('{', $at)
    $depth = 1; $line = $false; $block = $false; $str = $false; $char = $false
    for ($i = $open + 1; $i -lt $text.Length; ++$i) {
        $c = $text[$i]
        $next = if ($i + 1 -lt $text.Length) { $text[$i + 1] } else { [char]0 }
        if ($line) { if ($c -eq "`n") { $line = $false }; continue }
        if ($block) { if ($c -eq '*' -and $next -eq '/') { $block = $false; ++$i }; continue }
        if ($str) { if ($c -eq '\') { ++$i } elseif ($c -eq '"') { $str = $false }; continue }
        if ($char) { if ($c -eq '\') { ++$i } elseif ($c -eq "'") { $char = $false }; continue }
        if ($c -eq '/' -and $next -eq '/') { $line = $true }
        elseif ($c -eq '/' -and $next -eq '*') { $block = $true }
        elseif ($c -eq '"') { $str = $true }
        elseif ($c -eq "'") { $char = $true }
        elseif ($c -eq '{') { ++$depth }
        elseif ($c -eq '}') {
            --$depth
            if ($depth -eq 0) { return $text.Substring($at, $i - $at + 1) }
        }
    }
    throw "TASK3_SOURCE_BODY_UNTERMINATED=$signature"
}
function ReplaceOnce([string]$text, [string]$from, [string]$to) {
    if (($text.Split(@($from), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw "TASK3_ADAPTER_ANCHOR_DRIFT=$from"
    }
    return $text.Replace($from, $to)
}
function WriteGenerated([string]$name, [string]$text) {
    [IO.File]::WriteAllText((Join-Path $full $name), $text, (New-Object Text.UTF8Encoding($false)))
}

if ($Phase -eq 'Warp') {
    $dx12='OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp'
    $queue='OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp'
    $late='OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp'
    $compose='OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp'
    $state='OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h'
    function Extract([string]$path,[string]$signature) {
        return FunctionText ([IO.File]::ReadAllText((Join-Path $repo $path))) $signature
    }
    function WithoutIncludes([string]$path) {
        return [regex]::Replace([IO.File]::ReadAllText((Join-Path $repo $path)),'(?m)^#include[^\r\n]*','')
    }
    WriteGenerated 'present_late_context.inc' ((Extract $state '    struct LateContext') + ';')
    $production=@(
        (Extract 'OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp' 'DlssNr::InputStates_Dx12 DlssNr::ResolveInputStates_Dx12'),
        (Extract $dx12 'bool DlssNr_Dx12::ProcessSeam'),
        (Extract $dx12 'bool DlssNr_Dx12::ApplyFinished'),
        (Extract $dx12 'bool DlssNr_Dx12::PendingFinishedCapture'),
        (Extract $dx12 'bool DlssNr_Dx12::State::PendingFinishedCapture'),
        (Extract $dx12 'void DlssNr_Dx12::State::CloseFinishedCaptures'),
        (Extract $queue 'auto DlssNr_Dx12::State::FinishedPictureResetCommandList'),
        (Extract $queue 'auto DlssNr_Dx12::State::FinishedPicturePromised'),
        (Extract $queue 'auto DlssNr_Dx12::State::FinishedPictureSubmitted'),
        (WithoutIncludes $late),
        (WithoutIncludes $compose),
        (WithoutIncludes 'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp'),
        'namespace DlssNr {',
        (Extract $dx12 'StreamlinePicture::ConsumerSnapshot CaptureFinishedConsumer'),
        (Extract $dx12 'static DXGI_COLOR_SPACE_TYPE ReadFinishedSpace'),
        (Extract $dx12 'void ApplyToStreamlinePicture'),
        (Extract $dx12 'void SkipFinishedPicture'),
        (Extract $dx12 'void ApplyToFinishedPicture(IDXGISwapChain*'),
        (Extract $dx12 'void FinishedPicturePromise('),
        (Extract $dx12 'void FinishedPictureSubmitted('),
        (Extract $dx12 'bool XeFGPendingCapture('),
        (Extract $dx12 'bool ApplyXeFGPicture('),
        (Extract $dx12 'void XeFGCloseCaptures('),
        '}',
        (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'bool XeFG_Dx12::OwnsFinishedConsumer'),
        (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'bool XeFG_Dx12::ClaimsFinishedConsumer'),
        (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'void XeFG_Dx12::ResetNrHandoff'),
        (Extract 'OptiScaler/framegen/xefg/XeFG_Dx12.cpp' 'void XeFG_Dx12::OwnedNrHandoff'),
        (Extract 'OptiScaler/resource_tracking/ResTrack_dx12.cpp' 'static void STDMETHODCALLTYPE hkNrExecuteCommandLists')
    ) -join "`n"
    WriteGenerated 'present_production.inc' $production
    $streamlineBody=WithoutIncludes 'OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp'
    $adapter=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'nr_present_admission_smoke.cpp'))
    $adapter=ReplaceOnce $adapter `
        'struct InputStates_Dx12 { D3D12_RESOURCE_STATES color, depth, motion, exposure; };' ''
    $adapter=ReplaceOnce $adapter "struct Config`n{" "class Config`n{`n  public:"
    $adapter=ReplaceOnce $adapter '        DlssNr::OutputStatus outputStatus;' `
        "        DlssNr::OutputStatus outputStatus;`n        DlssNr::ModelFacts modelFacts;"
    $adapter=ReplaceOnce $adapter '    Setting<bool> DlssNrEnabled { true },' `
        "    Setting<bool> OverlayMenu { true };`n    Setting<bool> DlssNrEnabled { true },"
    $adapter=ReplaceOnce $adapter '    Setting<bool> OverlayMenu { true };' @'
    Setting<bool> OverlayMenu { true };
    Setting<bool> FGUseMutexForSwapchain, ForceVsync, FGDLSSGUseGamesReflexMarkers, SimulateWaitableObject;
    Setting<unsigned> VsyncInterval;
'@
    $adapter=ReplaceOnce $adapter 'struct Fg' @'
enum class FGOutput { NoFG, DLSSG, XeFG, FSRFG };
enum class FGInput { None, FSRFG, FSRFG30 };
struct Fg
'@
    $adapter=ReplaceOnce $adapter '    bool IsActive() const { return false; }' @'
    bool active=true, paused=false;
    std::function<void()> onPresent;
    struct Lock { int getOwner() { return 0; } void lock(int) {} void unlockThis(int) {} } Mutex;
    bool IsActive() const { return active; }
    void Present() { if(onPresent) onPresent(); }
    unsigned GetInterpolatedFrameCount() const { return 0; }
'@
    $fgDefinition=FunctionText $adapter 'struct Fg'
    $updatedFg=ReplaceOnce $fgDefinition '    bool IsPaused() const { return false; }' `
        '    bool IsPaused() const { return paused; }'
    $adapter=ReplaceOnce $adapter $fgDefinition $updatedFg
    $adapter=ReplaceOnce $adapter 'enum class GameEngineType { Other, Unreal };' `
        'enum class GameEngineType { Other, Unreal, Unity };'
    $adapter=ReplaceOnce $adapter "struct State`n{" @'
struct GpuUpscaler
{
    std::optional<double> ReadUpscalerTime(ID3D11DeviceContext*) { return {}; }
    std::optional<double> ReadUpscalerTime(ID3D12CommandQueue*) { return {}; }
    void ReadDetailedGpuTimes(ID3D11DeviceContext*,int&) {}
    void ReadDetailedGpuTimes(ID3D12CommandQueue*,int&) {}
    API Api() const { return API::DX12; }
    bool IsWithDx12() const { return false; }
    void TickFrozenCheck(unsigned=0) {}
};
struct State
{
'@
    $adapter=ReplaceOnce $adapter '    Fg* currentFG = nullptr;' @'
    Fg* currentFG = nullptr;
    FGOutput activeFgOutput=FGOutput::NoFG;
    FGInput activeFgInput=FGInput::None;
    GpuUpscaler* currentFeature=nullptr;
    ID3D12CommandQueue* currentCommandQueue=nullptr;
    ID3D11Device* currentD3D11Device=nullptr;
    ID3D12Device* currentD3D12Device=nullptr;
    DXGI_SWAP_CHAIN_DESC currentSwapchainDesc {};
    int detailedGpuTimes=0;
    unsigned dlssgDetectedInterpolationCount=0;
    uint64_t fgLastFrame=0;
    double lastFGFrameTime=0,presentFrameTime=0;
    bool SCAllowTearing=false,realExclusiveFullscreen=false,fgPresentIsCalled=false,reflexLimitsFps=true;
    std::mutex frameTimeMutex;
    std::deque<double> upscaleTimes;
'@
    $pluginPresent=FunctionText $adapter '    static HRESULT Present(IDXGISwapChain*'
    $adapter=ReplaceOnce $adapter $pluginPresent @'
    static HRESULT Present(IDXGISwapChain* chain,UINT sync,UINT flags,bool&)
    { ++forwards; return TemporalApplicationPresent(chain,sync,flags,nullptr); }
'@
    $pluginPresent1=FunctionText $adapter '    static HRESULT Present1(IDXGISwapChain*'
    $adapter=ReplaceOnce $adapter $pluginPresent1 @'
    static HRESULT Present1(IDXGISwapChain* chain,UINT sync,UINT flags,
                           const DXGI_PRESENT_PARAMETERS* parameters,bool&)
    { ++forwards; return TemporalApplicationPresent(chain,sync,flags,parameters); }
'@
    $adapter=ReplaceOnce $adapter 'static UINT Index(IDXGISwapChain*, bool& skip) { skip = handled; return 0; }' `
        'static UINT Index(IDXGISwapChain* chain, bool& skip) { skip = handled; return TemporalApplicationIndex(chain); }'
    $adapter=ReplaceOnce $adapter '        unsigned runs = 0;' @'
        ID3D12Resource* buffer=nullptr;
        D3D12_RESOURCE_STATES bufferState=D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
        std::vector<ComPtr<ID3D12Resource>> parkedBuffers;
        ~State() { if(buffer) buffer->Release(); }
        void ParkNrResource(ID3D12Resource*& resource)
        { ComPtr<ID3D12Resource> retained; retained.Attach(resource); parkedBuffers.push_back(retained); resource=nullptr; }
        unsigned runs = 0;
'@
    $adapter=ReplaceOnce $adapter '    std::unique_ptr<State> _state = std::make_unique<State>(*this);' @'
    std::unique_ptr<State> _state = std::make_unique<State>(*this);
    bool _init=true;
    bool IsInit() const { return _init; }
    bool CreateBufferResource(ID3D12Device*,ID3D12Resource*,D3D12_RESOURCE_STATES);
    void SetBufferState(ID3D12GraphicsCommandList*,D3D12_RESOURCE_STATES);
    ID3D12Resource* Buffer();
    bool Dispatch(ID3D12GraphicsCommandList*,ID3D12Resource*,ID3D12Resource*,ID3D12Resource*,
                  ID3D12Resource*,const DlssNrFrameInfo&,ID3D12CommandQueue*);
'@
    $adapter=ReplaceOnce $adapter 'td.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;' `
        'td.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS | D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;'
    $run=FunctionText $adapter '        void Run('
    $replacement=@'
        void Run(ID3D12GraphicsCommandList* cmd, ID3D12Resource* color, ID3D12Resource*,
                 ID3D12Resource*, ID3D12Resource* output, const DlssNrFrameInfo& frame,
                 ID3D12CommandQueue* queue)
        {
            ++runs; nr.successfulDispatches += Config::Instance()->passes;
            TemporalHistoryRun(cmd,color,frame.FinishedPicture ? color : output,
                frame.FinishedPicture ? D3D12_RESOURCE_STATE_PRESENT
                                      : static_cast<D3D12_RESOURCE_STATES>(frame.OutputArrivalState),queue,
                frame.FinishedPicture ? D3D12_RESOURCE_STATE_PRESENT
                                      : static_cast<D3D12_RESOURCE_STATES>(frame.OutputArrivalState));
            outputStatus.evaluated=true;
            outputStatus.composed=Config::Instance()->DlssNrApplyModel.value_or_default();
            outputStatus.copyBack=outputStatus.composed;
            if (!outputStatus.composed)
                outputStatus.state=DlssNr::OutputState::EvaluatedHidden;
        }
'@
    $adapter=ReplaceOnce $adapter $run $replacement
    WriteGenerated 'TemporalCompositionAdapters.inc' $adapter
    $pipeline='OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp'
    WriteGenerated 'TemporalDirectProduction.inc' (@(
        (Extract 'OptiScaler/shaders/Shader_Dx12.cpp' 'void Shader_Dx12::SetBufferState'),
        (Extract $dx12 'bool DlssNr_Dx12::CreateBufferResource'),
        (Extract $dx12 'void DlssNr_Dx12::SetBufferState'),
        (Extract $dx12 'ID3D12Resource* DlssNr_Dx12::Buffer()'),
        (Extract $dx12 'bool DlssNr_Dx12::Dispatch('),
        'namespace {',
        (Extract $pipeline 'bool HasSupportedNrSubrects'),
        (Extract $pipeline 'ID3D12Resource* NrResource'),
        (Extract $pipeline 'void NrBarrier'),
        '}',
        (Extract $pipeline 'bool DlssNr::CanRunBeforeUpscale_Dx12'),
        (Extract $pipeline 'ShaderPass_Dx12 MakeDlssNrPass'),
        (Extract $pipeline 'ID3D12Resource* PrepareDlssNrInput')
    ) -join "`n")
    $localBody=Extract 'OptiScaler/wrapped/wrapped_swapchain.cpp' 'static HRESULT LocalPresent('
    $fgBody=Extract 'OptiScaler/hooks/FG_Hooks.cpp' 'HRESULT FGHooks::FGPresent('
    if($Mutation -eq 'overlay-before-temporal') {
        $ui='MenuOverlayDx::Present(pSwapChain, SyncInterval, Flags, pPresentParameters, pDevice, hWnd, isUWP);'
        $localBody=ReplaceOnce $localBody $ui ''
        $fgBody=ReplaceOnce $fgBody '        if (!xefgOwnedHandoff)' @'
        if (state.activeFgOutput != FGOutput::XeFG)
            MenuOverlayDx::Present(This,SyncInterval,Flags,pPresentParameters,state.currentCommandQueue,nullptr,false);
        if (!xefgOwnedHandoff)
'@
        $streamlineAnchor='        Apply(swapchain, flags, skip);'
        if(($streamlineBody.Split(@($streamlineAnchor),[StringSplitOptions]::None).Count-1)-ne 2) {
            throw 'TASK3_STREAMLINE_MUTATION_ANCHOR_DRIFT'
        }
        $streamlineBody=$streamlineBody.Replace($streamlineAnchor,@'
        if (!skip && !(flags & DXGI_PRESENT_TEST))
            MenuOverlayDx::Present(swapchain,interval,flags,nullptr,State::Instance().currentCommandQueue,nullptr,false);
        Apply(swapchain, flags, skip);
'@)
    }
    if($Mutation -eq 'stale-owner') {
        $fgBody=ReplaceOnce $fgBody 'if (state.isShuttingDown || nonOwnerXeFGPresent)' 'if (state.isShuttingDown)'
    }
    WriteGenerated 'StreamlinePicture.cpp' $streamlineBody
    WriteGenerated 'TemporalLocalPresent.inc' $localBody
    WriteGenerated 'TemporalGpuFGPresent.inc' $fgBody
    $overlay='OptiScaler/menu/menu_overlay_dx.cpp'
    WriteGenerated 'TemporalOverlayProduction.inc' (@(
        (Extract $overlay 'static int GetCorrectDXGIFormat'),
        (Extract $overlay 'static void CreateRenderTargetDx12'),
        (Extract $overlay 'static void RenderImGui_DX12'),
        (Extract $overlay 'void MenuOverlayDx::Present')
    ) -join "`n")
    $sdk=Join-Path $repo 'external/nvngx_dlss_sdk'
    if (-not (Test-Path "$sdk/nvsdk_ngx_params.h")) {
        $sdk='C:/omo-research/optiscaler-hybrid-port-v0.7.1/external/nvngx_dlss_sdk'
    }
    if (-not (Test-Path "$sdk/nvsdk_ngx_params.h")) { throw 'TASK3_EXISTING_NGX_HEADERS_MISSING' }
    $source=Join-Path $PSScriptRoot 'nr_ui_temporal/TemporalOwnedQueue.cpp'
    $exe=Join-Path $full 'temporal.exe'
    $dependencies='C:/omo-research/rw-nr3-0985d/external'
    $freetype=Join-Path $dependencies 'freetype/freetype.lib'
    if (-not (Test-Path -LiteralPath $freetype)) { throw 'TASK3_EXISTING_FREETYPE_MISSING' }
    $archiveHash='74856E22714BF99F2F04E59CFE77D7C85729E5AA3570030B939048115EF528AD'
    if((Get-Item -LiteralPath $freetype).Length -ne 4591050 -or
        (Get-FileHash -LiteralPath $freetype).Hash -ne $archiveHash) {
        throw 'TASK3_ACCEPTED_C_ARCHIVE_DRIFT'
    }
    $dumpbin=(Get-Command dumpbin.exe -ErrorAction Stop).Source
    $directives=(& $dumpbin /directives $freetype | Out-String)
    $directiveExit=$LASTEXITCODE
    if($directiveExit -ne 0 -or $directives -notmatch '/DEFAULTLIB:LIBCMT' -or
        $directives -match '(?i)FAILIFMISMATCH.*RuntimeLibrary') {
        throw 'TASK3_RETAINED_C_ARCHIVE_ABI_REFUSED'
    }
    [ordered]@{path=$freetype;bytes=4591050;sha256=$archiveHash;nativeExit=$directiveExit;
        dumpbin=$dumpbin;dumpbinSha256=(Get-FileHash -LiteralPath $dumpbin).Hash;
        command="$dumpbin /directives $freetype";rawDirectives=$directives;
        runtime='MD_DynamicRelease';preciseIgnoredCDefaultLibrary='LIBCMT';
        reference='tests/nr_addon_host/BuildHost.ps1:87-92 and SourceAudit.ps1:46-71'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$full/native-library-crt.json" -Encoding UTF8
    WriteGenerated 'pch.h' '// Standalone production Localization compilation; no product PCH reuse.'
    $consumedPaths=@(
        $dx12,$queue,$late,$compose,$state,
        'OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp',
        'OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp',
        'OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.h',
        'OptiScaler/upscalers/ShaderPipeline_Dx12.h',
        'OptiScaler/shaders/Shader_Dx12.cpp',
        'OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h',
        'OptiScaler/include/d3dx/d3dx12.h',
        'OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp',
        'OptiScaler/dlssnr/DlssNr_StreamlinePicture.h',
        'OptiScaler/dlssnr/DlssNr_FinishedConsumer.h',
        'OptiScaler/dlssnr/DlssNr_Status.h',
        'OptiScaler/framegen/xefg/XeFG_Dx12.cpp',
        'OptiScaler/resource_tracking/ResTrack_dx12.cpp',
        'OptiScaler/menu/menu_overlay_dx.cpp',
        'OptiScaler/hooks/FG_Hooks.cpp',
        'OptiScaler/wrapped/wrapped_swapchain.cpp',
        'OptiScaler/include/imgui/imgui.cpp',
        'OptiScaler/include/imgui/imgui_draw.cpp',
        'OptiScaler/include/imgui/imgui_tables.cpp',
        'OptiScaler/include/imgui/imgui_widgets.cpp',
        'OptiScaler/include/imgui/imgui_impl_dx12.cpp',
        'OptiScaler/include/imgui/imgui_impl_dx12.h',
        'OptiScaler/include/imgui/misc/freetype/imgui_freetype.cpp',
        'OptiScaler/menu/Localization.cpp',
        'OptiScaler/menu/Localization.h',
        'OptiScaler/menu/locales/ko_catalog.inc',
        'tests/nr_present_admission_smoke.cpp',
        'tests/nr_ui_temporal/TemporalOwnedQueue.cpp',
        'tests/nr_ui_temporal/TemporalGpuHooks.h',
        'tests/run_nr_ui_temporal.ps1'
    )
    $sourcePins=@($consumedPaths | ForEach-Object {
        $path=Join-Path $repo $_
        [ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash}
    })
    $sourcePins += [ordered]@{path=$freetype;sha256=(Get-FileHash -LiteralPath $freetype).Hash}
    $generatedPins=@(
        'present_late_context.inc','present_production.inc','StreamlinePicture.cpp',
        'TemporalCompositionAdapters.inc','TemporalOverlayProduction.inc',
        'TemporalLocalPresent.inc','TemporalGpuFGPresent.inc','TemporalDirectProduction.inc'
    ) | ForEach-Object {
        [ordered]@{file=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $full $_)).Hash}
    }
    $arguments=@('/nologo','/std:c++20','/EHsc','/W4','/MD','/DNOMINMAX',
        "/I$full","/I$sdk","/I$repo/OptiScaler","/I$repo/OptiScaler/include","/I$repo/tests",
        "/I$dependencies/freetype",
        "/Fo$full/","/Fd$full/temporal.pdb","/Fe$exe",'/sourceDependencies',"$full/compiler-inputs.json",
        $source,"$repo/OptiScaler/include/imgui/imgui.cpp","$repo/OptiScaler/include/imgui/imgui_draw.cpp",
        "$repo/OptiScaler/include/imgui/imgui_tables.cpp","$repo/OptiScaler/include/imgui/imgui_widgets.cpp",
        "$repo/OptiScaler/include/imgui/imgui_impl_dx12.cpp",
        "$repo/OptiScaler/include/imgui/misc/freetype/imgui_freetype.cpp",
        "$repo/OptiScaler/menu/Localization.cpp",
        '/link','/NODEFAULTLIB:LIBCMT','/VERBOSE:LIB',
        'd3d12.lib','dxgi.lib','dxguid.lib','d3dcompiler.lib',$freetype)
    $observedArguments=$arguments -join ' '
    if($observedArguments -notmatch '(?:^|\s)/MD(?:\s|$)' -or
        $observedArguments -match '(?i)(?:^|\s)/(?:GL|MT)(?:\s|$)|/FORCE|/IGNORE:2038|/NODEFAULTLIB(?:\s|$)' -or
        $observedArguments -notmatch '(?i)/NODEFAULTLIB:LIBCMT(?:\s|$)' -or
        $observedArguments -notmatch '(?i)/VERBOSE:LIB') {
        throw 'TASK3_GUARDED_C_ARCHIVE_CRT_CONTRACT_REFUSED'
    }
    Write-Host ('TASK3_COMPILE_COMMAND=cl.exe '+($arguments -join ' '))
    & cl.exe @arguments 2>&1 | Tee-Object -Variable compileOutput | Write-Host
    $compileExit=$LASTEXITCODE
    $compileOutput | Set-Content -LiteralPath "$full/compile.log" -Encoding UTF8
    if ($compileExit) { throw "TASK3_WARP_COMPILE_EXIT=$compileExit" }
    foreach($pin in $sourcePins) {
        if ((Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.sha256) { throw 'TASK3_BUILD_SOURCE_DRIFT' }
    }
    [ordered]@{phase=$Phase;mutation=$Mutation;compileExit=$compileExit;exe=$exe;
        exeSha256=(Get-FileHash $exe).Hash;buildOnly=[bool]$BuildOnly;
        sourcePins=$sourcePins;compiledBodyPins=@($generatedPins);
        scope='Current production owned composition/wrapper and overlay bodies; provider/marker fixtures; remaining route/placement qualification is not inferred'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$full/build.json" -Encoding UTF8
    if ($BuildOnly) { Write-Host 'TASK3_WARP_BUILD_COMPLETE'; exit 0 }
    Write-Host "TASK3_RUN_COMMAND=$exe $full/pixels.json"
    & $exe "$full/pixels.json"
    $runExit=$LASTEXITCODE
    Write-Host "TASK3_TEMPORAL_TERMINAL phase=Warp mutation=$Mutation native=$runExit"
    exit $runExit
}

$fgPath = Join-Path $repo 'OptiScaler/hooks/FG_Hooks.cpp'
$wrappedPath = Join-Path $repo 'OptiScaler/wrapped/wrapped_swapchain.cpp'
$templatePath = Join-Path $PSScriptRoot 'fgpresent_owner_routing.cpp'
$menuPath = Join-Path $repo 'OptiScaler/dlssnr/DlssNr_Menu.cpp'
$fg = FunctionText ([IO.File]::ReadAllText($fgPath)) 'HRESULT FGHooks::FGPresent('
$body = $fg.Substring($fg.IndexOf('{') + 1)
$body = $body.Substring(0, $body.LastIndexOf('}'))
$local = FunctionText ([IO.File]::ReadAllText($wrappedPath)) 'static HRESULT LocalPresent('
if ($Mutation -eq 'stale-owner') {
    $body = ReplaceOnce $body 'if (state.isShuttingDown || nonOwnerXeFGPresent)' 'if (state.isShuttingDown)'
}
if ($Mutation -eq 'overlay-before-temporal') {
    $ui = 'MenuOverlayDx::Present(pSwapChain, SyncInterval, Flags, pPresentParameters, pDevice, hWnd, isUWP);'
    $local = ReplaceOnce $local $ui ''
    $local = ReplaceOnce $local 'if (cq && (fg == nullptr || !fg->IsActive() || fg->IsPaused()))' `
        ($ui + "`n        if (cq && (fg == nullptr || !fg->IsActive() || fg->IsPaused()))")
}
$adapter = [IO.File]::ReadAllText($templatePath)
$adapter = ReplaceOnce $adapter '/*__FG_PRESENT_BODY__*/' $body
$adapter = ReplaceOnce $adapter '    NoFG = 0,' "    NoFG = 0,`n    FSRFG,"
$adapter = ReplaceOnce $adapter '    virtual uint64_t FrameCount() = 0;' `
    "    virtual uint64_t FrameCount() = 0;`n    virtual unsigned GetInterpolatedFrameCount() { return 0; }"
$adapter = ReplaceOnce $adapter '    std::optional<double> ReadUpscalerTime(ID3D11DeviceContext*)' @'
    API Api() const { return API::DX12; }
    bool IsWithDx12() const { return false; }
    void TickFrozenCheck(unsigned = 0) {}
    std::optional<double> ReadUpscalerTime(ID3D11DeviceContext*)
'@
$adapter = ReplaceOnce $adapter '    ID3D12CommandQueue* currentCommandQueue = nullptr;' @'
    ID3D12CommandQueue* currentCommandQueue = nullptr;
    API swapchainApi = API::DX12;
    DXGI_SWAP_CHAIN_DESC currentSwapchainDesc {};
    double presentFrameTime = 0;
    std::vector<double> frameTimes;
'@
$adapter = ReplaceOnce $adapter 'inline double MillisecondsNow() { return 0.0; }' `
    'inline double MillisecondsNow() { return fixtureClock; }'
$adapter = ReplaceOnce $adapter 'inline void ApplyToFinishedPicture(IDXGISwapChain*, ID3D12CommandQueue*) { ++genericApplyCount; }' `
    'inline void ApplyToFinishedPicture(IDXGISwapChain*, ID3D12CommandQueue*) { ++genericApplyCount; Record("NR.generic"); }'
$menu = [IO.File]::ReadAllText($menuPath)
$start = $menu.IndexOf('            const auto& state = State::Instance();', [StringComparison]::Ordinal)
$endToken = 'PipelineUi::IntervalSource(state.swapchainApi == API::Vulkan, state.currentFG != nullptr));'
$end = $menu.IndexOf($endToken, $start, [StringComparison]::Ordinal)
if ($start -lt 0 -or $end -lt 0) { throw 'TASK3_TIMING_SELECTION_ANCHOR_DRIFT' }
$selection = $menu.Substring($start, $end + $endToken.Length - $start)
WriteGenerated 'TemporalAdapters.inc' $adapter
WriteGenerated 'TemporalLocalPresent.inc' $local
WriteGenerated 'TemporalTimingSelection.inc' $selection
$source = Join-Path $PSScriptRoot 'nr_ui_temporal/TemporalRoutes.cpp'
$exe = Join-Path $full 'routes.exe'
$arguments = @('/nologo', '/std:c++20', '/EHsc', '/W4', '/MD', '/DNOMINMAX',
    "/I$full", "/Fo$full/routes.obj", "/Fd$full/routes.pdb", "/Fe$exe",
    '/sourceDependencies', "$full/compiler-inputs.json", $source, '/link', 'dxguid.lib')
Write-Host ('TASK3_COMPILE_COMMAND=cl.exe ' + ($arguments -join ' '))
& cl.exe @arguments 2>&1 | Tee-Object -Variable compileOutput | Write-Host
$compileExit = $LASTEXITCODE
$compileOutput | Set-Content -LiteralPath "$full/compile.log" -Encoding UTF8
if ($compileExit -ne 0) { throw "TASK3_COMPILE_EXIT=$compileExit" }
Write-Host "TASK3_RUN_COMMAND=$exe"
$ErrorActionPreference = 'Continue'
& $exe 2>&1 | Tee-Object -Variable runOutput | Write-Host
$runExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$runOutput | Set-Content -LiteralPath "$full/run.log" -Encoding UTF8
$sourcePins = @($fgPath, $wrappedPath, $templatePath, $menuPath, $source, $PSCommandPath) | ForEach-Object {
    [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}
}
[ordered]@{
    phase=$Phase;mutation=$Mutation;compileExit=$compileExit;runExit=$runExit
    exe=$exe;exeSha256=(Get-FileHash -LiteralPath $exe).Hash
    sourcePins=@($sourcePins)
    scope='Actual FGPresent, LocalPresent, existing owner assertions, and exact menu selection fragment; service and COM doubles. No GPU/SDK or supported callback-bypass proof.'
    compiledBodyPins=@(
        [ordered]@{file='TemporalAdapters.inc';sha256=(Get-FileHash "$full/TemporalAdapters.inc").Hash},
        [ordered]@{file='TemporalLocalPresent.inc';sha256=(Get-FileHash "$full/TemporalLocalPresent.inc").Hash},
        [ordered]@{file='TemporalTimingSelection.inc';sha256=(Get-FileHash "$full/TemporalTimingSelection.inc").Hash}
    )
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$full/result.json" -Encoding UTF8
Write-Host "TASK3_TEMPORAL_TERMINAL phase=$Phase mutation=$Mutation native=$runExit"
exit $runExit
