// Real hardware/context/model admission only. No service or provider doubles.
#include <windows.h>
#include <sddl.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <nvsdk_ngx.h>
#include <xess_fg/xefg_swapchain_d3d12.h>
#include <xell/xell_d3d12.h>
#include <dlssnr/DlssNr_CompatibilityRuntime.h>
#include <dlssnr/DlssNr_ModelParameters.h>
#include <filesystem>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <vector>
#include <d3dcompiler.h>
#include <exception>
#include <cstring>

using Microsoft::WRL::ComPtr;
static std::mutex logMutex;
static void Check(HRESULT result,const char* operation)
{
    std::printf("TASK14_DX operation=%s result=0x%08X\n",operation,unsigned(result));
    if(FAILED(result)) throw std::runtime_error(operation);
}
template<class T> static T Export(HMODULE module,const char* name)
{
    auto* address=GetProcAddress(module,name);
    if(!address) throw std::runtime_error(name);
    return reinterpret_cast<T>(address);
}
static void SdkLog(const char* message,xefg_swapchain_logging_level_t level,void*)
{
    std::lock_guard lock(logMutex);
    std::printf("TASK14_XEFG_LOG level=%d message=%s\n",int(level),message);
    std::fflush(stdout);
}
static void NVSDK_CONV DriverLog(const char* message,NVSDK_NGX_Logging_Level level,NVSDK_NGX_Feature component)
{
    std::lock_guard lock(logMutex);
    std::printf("TASK14_NGX_LOG level=%d component=%d message=%s\n",int(level),int(component),message);
    std::fflush(stdout);
}
static LRESULT CALLBACK WindowProc(HWND window,UINT message,WPARAM wparam,LPARAM lparam)
{
    return DefWindowProcW(window,message,wparam,lparam);
}
struct Admission
{
    ComPtr<IDXGIFactory6> factory;
    ComPtr<IDXGIAdapter1> adapter;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    ComPtr<IDXGISwapChain3> swapchain;
    HANDLE event=nullptr;
    HWND window=nullptr;
    ATOM windowClass=0;
    HMODULE fgModule=nullptr,llModule=nullptr,driverModule=nullptr;
    xefg_swapchain_handle_t fg=nullptr;
    xell_context_handle_t ll=nullptr;
    NVSDK_NGX_Parameter* parameters=nullptr;
    NVSDK_NGX_Handle* feature=nullptr;
    std::shared_ptr<DlssNr::CompatibilityRuntime> nr;
    decltype(&xefgSwapChainDestroy) destroyFg=nullptr;
    decltype(&xellDestroyContext) destroyLl=nullptr;
    decltype(&NVSDK_NGX_D3D12_DestroyParameters) destroyParameters=nullptr;
    using Shutdown=NVSDK_NGX_Result(*)(ID3D12Device*);
    Shutdown shutdown=nullptr;
    bool driverInitialized=false,closed=false;
    bool gpuPending=false;
    unsigned modulesAcquired=0,modulesClosed=0,windowsCreated=0,windowsClosed=0;
    unsigned contextsCreated=0,contextsClosed=0,parametersCreated=0,parametersClosed=0;
    unsigned featuresCreated=0,featuresClosed=0,eventsCreated=0,eventsClosed=0;
    UINT64 fenceValue=0;
    HMODULE Load(const std::filesystem::path& path)
    {
        HMODULE module=LoadLibraryExW(path.c_str(),nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        std::printf("TASK14_LOAD module=%ls handle=%p error=%lu\n",path.c_str(),module,module?0:GetLastError());
        if(!module) throw std::runtime_error("ExactDllLoad");
        ++modulesAcquired;
        return module;
    }
    void Submit()
    {
        Check(commands->Close(),"CloseAdmissionCommands");
        const auto value=++fenceValue;
        Check(fence->SetEventOnCompletion(value,event),"ArmAdmissionFenceEvent");
        std::printf("TASK14_GPU submit queue=%p commands=%p fence=%p value=%llu event=%p\n",
            queue.Get(),commands.Get(),fence.Get(),value,event);
        ID3D12CommandList* lists[]={commands.Get()};
        gpuPending=true;
        queue->ExecuteCommandLists(1,lists);
        Check(queue->Signal(fence.Get(),value),"SignalAdmissionFence");
        const auto wait=WaitForSingleObject(event,15000);
        std::printf("TASK14_GPU completion wait=%lu completed=%llu required=%llu\n",wait,fence->GetCompletedValue(),value);
        if(wait!=WAIT_OBJECT_0 || fence->GetCompletedValue()<value) throw std::runtime_error("AdmissionFenceTimeout");
        gpuPending=false;
    }
    bool Close()
    {
        if(closed) return true;
        if(gpuPending) {
            std::puts("TASK14_GPU_PENDING_NATIVE_EXIT=124 explicitTeardown=REFUSED");
            std::fflush(stdout);
            ExitProcess(124);
        }
        bool ok=true;
        if(feature) {
            auto result=nr->Release(feature);
            std::printf("TASK14_NR_RELEASE result=0x%08X\n",unsigned(result));
            if(result==NVSDK_NGX_Result_Success) {feature=nullptr;++featuresClosed;} else ok=false;
        }
        nr.reset();
        if(parameters) {
            auto result=destroyParameters(parameters);
            std::printf("TASK14_PARAMETERS_DESTROY result=0x%08X\n",unsigned(result));
            if(result==NVSDK_NGX_Result_Success) {parameters=nullptr;++parametersClosed;} else ok=false;
        }
        swapchain.Reset();
        if(fg) {
            auto result=destroyFg(fg);
            std::printf("TASK14_FG_DESTROY result=%d\n",int(result));
            if(result==XEFG_SWAPCHAIN_RESULT_SUCCESS) {fg=nullptr;++contextsClosed;} else ok=false;
        }
        if(ll) {
            auto result=destroyLl(ll);
            std::printf("TASK14_LL_DESTROY result=%d\n",int(result));
            if(result==XELL_RESULT_SUCCESS) {ll=nullptr;++contextsClosed;} else ok=false;
        }
        if(driverInitialized) {
            auto result=shutdown(device.Get());
            std::printf("TASK14_DRIVER_SHUTDOWN result=0x%08X\n",unsigned(result));
            if(result==NVSDK_NGX_Result_Success) driverInitialized=false; else ok=false;
        }
        commands.Reset();allocator.Reset();fence.Reset();queue.Reset();device.Reset();adapter.Reset();factory.Reset();
        if(window) {
            if(DestroyWindow(window)) {window=nullptr;++windowsClosed;} else ok=false;
        }
        if(windowClass) {
            if(UnregisterClassW(L"OptiScalerTask14Owned",GetModuleHandleW(nullptr))) windowClass=0; else ok=false;
        }
        if(event) {
            if(CloseHandle(event)) {event=nullptr;++eventsClosed;} else ok=false;
        }
        for(auto* module:{&driverModule,&fgModule,&llModule}) if(*module) {
            if(FreeLibrary(*module)) {*module=nullptr;++modulesClosed;} else ok=false;
        }
        const bool zero=modulesAcquired==modulesClosed && contextsCreated==contextsClosed &&
            parametersCreated==parametersClosed && featuresCreated==featuresClosed &&
            windowsCreated==windowsClosed && eventsCreated==eventsClosed && !windowClass && !driverInitialized;
        std::printf("TASK14_NATIVE_CLEANUP modules=%u/%u contexts=%u/%u parameters=%u/%u features=%u/%u windows=%u/%u events=%u/%u remaining=%u\n",
            modulesClosed,modulesAcquired,contextsClosed,contextsCreated,parametersClosed,parametersCreated,
            featuresClosed,featuresCreated,windowsClosed,windowsCreated,eventsClosed,eventsCreated,zero?0u:1u);
        closed=true;
        return ok && zero;
    }
    ~Admission() { if(!closed) Close(); }
};
// Public driver ABI, not CompatibilityRuntime::Module's direct-NR parameter ABI.
using ContainedDriverInit=NVSDK_NGX_Result(NVSDK_CONV*)(unsigned long long,const wchar_t*,
    ID3D12Device*,NVSDK_NGX_Version,const NVSDK_NGX_FeatureCommonInfo*);
static bool ContainedPrimaryToken()
{
    HANDLE token=nullptr;
    LPWSTR sidText=nullptr;
    bool qualified=false,closed=true,freed=true;
    try {
        const BOOL opened=OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token);
        std::printf("TASK14_INIT_TOKEN_OPEN ok=%u error=%lu\n",opened?1u:0u,opened?0:GetLastError());
        if(!opened) throw std::runtime_error("OpenProcessPrimaryToken");
        auto info=[&](TOKEN_INFORMATION_CLASS type) {
            DWORD bytes=0;
            SetLastError(0);
            const BOOL sized=GetTokenInformation(token,type,nullptr,0,&bytes);
            const DWORD sizeError=GetLastError();
            std::printf("TASK14_INIT_TOKEN_SIZE class=%u ok=%u error=%lu bytes=%lu\n",
                unsigned(type),sized?1u:0u,sizeError,bytes);
            if(sized || sizeError!=ERROR_INSUFFICIENT_BUFFER) throw std::runtime_error("PrimaryTokenSize");
            std::vector<BYTE> buffer(bytes);
            const BOOL queried=GetTokenInformation(token,type,buffer.data(),bytes,&bytes);
            std::printf("TASK14_INIT_TOKEN_QUERY class=%u ok=%u error=%lu\n",
                unsigned(type),queried?1u:0u,queried?0:GetLastError());
            if(!queried) throw std::runtime_error("PrimaryTokenQuery");
            return buffer;
        };
        const auto is=info(TokenIsAppContainer),app=info(TokenAppContainerSid),
            caps=info(TokenCapabilities),type=info(TokenType);
        const bool container=*reinterpret_cast<const DWORD*>(is.data())!=0;
        // Runtime LPAC is not a qualification fact; the creator supplies no LPAC policy.
        std::puts("TASK14_INIT_LPAC_QUERY=UNMEASURED creatorLpacPolicy=NONE");
        const auto sid=reinterpret_cast<const TOKEN_APPCONTAINER_INFORMATION*>(app.data())->TokenAppContainer;
        if(sid) {
            const BOOL converted=ConvertSidToStringSidW(sid,&sidText);
            std::printf("TASK14_INIT_SID_TEXT ok=%u error=%lu\n",converted?1u:0u,converted?0:GetLastError());
            if(!converted) throw std::runtime_error("PrimarySidText");
        }
        const auto capabilityCount=reinterpret_cast<const TOKEN_GROUPS*>(caps.data())->GroupCount;
        const auto tokenType=*reinterpret_cast<const TOKEN_TYPE*>(type.data());
        qualified=container && tokenType==TokenPrimary && capabilityCount==0 &&
            sidText && std::wstring(sidText)==
                L"S-1-15-2-1050576210-4101474698-56307613-2706264498-167457550-835605972-784472318";
        std::printf("TASK14_INIT_PRIMARY pid=%lu appContainer=%u lessPrivileged=UNMEASURED type=%u capabilities=%lu sid=%ls qualified=%u\n",
            GetCurrentProcessId(),container?1u:0u,unsigned(tokenType),
            capabilityCount,sidText?sidText:L"",qualified?1u:0u);
    } catch(const std::exception& error) {
        std::printf("TASK14_INIT_TOKEN_REFUSAL operation=%s\n",error.what());
    }
    if(sidText) {
        freed=LocalFree(sidText)==nullptr;
        std::printf("TASK14_INIT_SID_FREE acquired=1 freed=%u\n",freed?1u:0u);
    }
    if(token) {
        closed=CloseHandle(token)!=FALSE;
        std::printf("TASK14_INIT_TOKEN_CLOSE acquired=1 closed=%u error=%lu\n",closed?1u:0u,closed?0:GetLastError());
    }
    return qualified && closed && freed;
}
static bool QualifyOutputContract(const HANDLE* expected);
static int ContainedInitOnly(const wchar_t* data,const wchar_t* driver,const wchar_t* runtimeRoot,bool outputOnly=false,
    const HANDLE* expected=nullptr)
{
    setvbuf(stdout,nullptr,_IONBF,0);
    if(!ContainedPrimaryToken()) {
        std::puts("TASK14_INIT_REFUSAL=PRIMARY_TOKEN_IDENTITY_REJECTED");
        std::puts("TASK14_INIT_TERMINAL native=23 graphicsEntries=0 vendorLoads=0 initCalls=0");
        return 23;
    }
    Admission owned;
    if(outputOnly) {
        bool normalized=true,opened=true;
        const HANDLE handles[]={GetStdHandle(STD_OUTPUT_HANDLE),GetStdHandle(STD_ERROR_HANDLE)};
        const wchar_t* names[]={
            L"\\\\?\\C:\\omo-research\\optiscaler-nr-ui-feedback-wt\\wave2-01a12466\\.omo\\e14-output-only-r4-01a12466\\native-output-r4.stdout.log",
            L"\\\\?\\C:\\omo-research\\optiscaler-nr-ui-feedback-wt\\wave2-01a12466\\.omo\\e14-output-only-r4-01a12466\\native-output-r4.stderr.log"};
        for(unsigned role=0;role<2;++role) {
            for(const DWORD flags:{FILE_NAME_NORMALIZED|VOLUME_NAME_DOS,FILE_NAME_OPENED|VOLUME_NAME_DOS}) {
                wchar_t target[32768]{};
                const DWORD length=GetFinalPathNameByHandleW(handles[role],target,32768,flags);
                const DWORD error=length?0:GetLastError();
                const bool bounded=length>0 && length<32768;
                const std::wstring path=bounded?std::wstring(target,length):std::wstring();
                const bool exact=bounded && path==names[role];
                std::printf("TASK26_OUTPUT role=%s handle=%p flags=%lu length=%lu error=%lu bounded=%u exact=%u target=%ls\n",
                    role==0?"stdout":"stderr",handles[role],flags,length,error,bounded?1u:0u,exact?1u:0u,path.c_str());
                if(flags==FILE_NAME_NORMALIZED) normalized=normalized && exact;
                else opened=opened && exact;
            }
        }
        int result=normalized && opened?0:24;
        std::printf("TASK26_OUTPUT_RESULT normalizedExact=%u openedViable=%u graphicsAuthorized=0\n",normalized?1u:0u,opened?1u:0u);
        if(!normalized || !opened) std::puts("TASK14_INIT_REFUSAL operation=InheritedNonEOutputRefused");
        if(!owned.Close()) result=25;
        std::puts("TASK14_INIT_COM_CLEANUP ownersBeforeClose=0 ownedPointersRemaining=0 observedResetCalls=UNMEASURED sdkInternalCleanup=UNMEASURED");
        std::printf("TASK14_INIT_TERMINAL native=%d graphicsEntries=0 vendorLoads=0 initCalls=0\n",result);
        return result;
    }
    unsigned graphicsEntries=0,vendorLoads=0,initCalls=0,comOwners=0;
    int exit=0;
    try {
        // Parent-created storage only; do not repair access or redirect known folders.
        if(expected) {
            if(!QualifyOutputContract(expected)) throw std::runtime_error("InheritedEOutputContractRefused");
        } else for(auto handle:{GetStdHandle(STD_OUTPUT_HANDLE),GetStdHandle(STD_ERROR_HANDLE)}) {
            wchar_t target[32768]{};
            const DWORD length=GetFinalPathNameByHandleW(handle,target,32768,FILE_NAME_NORMALIZED);
            std::printf("TASK14_INIT_OUTPUT handle=%p target=%ls error=%lu\n",handle,target,length?0:GetLastError());
            const std::wstring prefix=L"\\\\?\\C:\\omo-research\\optiscaler-nr-ui-feedback-wt\\wave2-01a12466\\.omo\\e14-contained-init-r3-01a12466\\";
            const std::wstring path(target);
            if(!length || length>=32768 || path.compare(0,prefix.size(),prefix)!=0 ||
                !(path.ends_with(L".stdout.log") || path.ends_with(L".stderr.log")))
                throw std::runtime_error("InheritedNonEOutputRefused");
        }
        std::puts("TASK14_INIT_BOUNDARY=FIRST_GRAPHICS_ENTRY");
        ++graphicsEntries;
        Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&owned.factory)),"ContainedCreateFactory");
        ++comOwners;
        for(UINT index=0;;++index) {
            const auto result=owned.factory->EnumAdapterByGpuPreference(index,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                IID_PPV_ARGS(&owned.adapter));
            if(result==DXGI_ERROR_NOT_FOUND) break;
            Check(result,"ContainedEnumAdapter");
            ++comOwners;
            DXGI_ADAPTER_DESC1 desc{};
            Check(owned.adapter->GetDesc1(&desc),"ContainedAdapterDescription");
            if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) {
                std::printf("TASK14_INIT_COM_RELEASE role=software-adapter refs=%lu\n",owned.adapter.Reset());
                --comOwners;continue;
            }
            const auto created=D3D12CreateDevice(owned.adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&owned.device));
            std::printf("TASK14_INIT_DEVICE adapter=%ls vendor=0x%04X result=0x%08X\n",
                desc.Description,desc.VendorId,unsigned(created));
            if(FAILED(created)) throw std::runtime_error("ContainedCreateDevice");
            ++comOwners;break;
        }
        if(!owned.device) throw std::runtime_error("ContainedNoHardwareDevice");
        std::puts("TASK14_INIT_BOUNDARY=FIRST_EXPLICIT_VENDOR_LOAD");
        owned.driverModule=owned.Load(driver);++vendorLoads;
        auto symbol=[&](const char* name) {
            SetLastError(0);
            const auto address=GetProcAddress(owned.driverModule,name);
            std::printf("TASK14_INIT_EXPORT name=%s address=%p error=%lu\n",name,address,address?0:GetLastError());
            if(!address) throw std::runtime_error(name);
            return address;
        };
        const auto init=reinterpret_cast<ContainedDriverInit>(symbol("NVSDK_NGX_D3D12_Init_Ext"));
        owned.shutdown=reinterpret_cast<Admission::Shutdown>(symbol("NVSDK_NGX_D3D12_Shutdown1"));
        const wchar_t* paths[]={runtimeRoot};
        NVSDK_NGX_FeatureCommonInfo common{};
        common.PathListInfo.Path=paths;common.PathListInfo.Length=1;
        common.LoggingInfo.LoggingCallback=DriverLog;
        common.LoggingInfo.MinimumLoggingLevel=NVSDK_NGX_LOGGING_LEVEL_ON;
        common.LoggingInfo.DisableOtherLoggingSinks=true;
        std::puts("TASK14_INIT_BOUNDARY=FIRST_PUBLIC_INIT commonInfo=1 callbackOnly=1 internalData=null");
        ++initCalls;
        const auto result=init(0x24480451ull,data,owned.device.Get(),NVSDK_NGX_Version_API,&common);
        owned.driverInitialized=result==NVSDK_NGX_Result_Success;
        std::printf("TASK14_INIT_RESULT ngx=0x%08X dataPath=%ls\n",unsigned(result),data);
        if(!owned.driverInitialized) exit=24;
    } catch(const std::exception& error) {
        std::printf("TASK14_INIT_REFUSAL operation=%s\n",error.what());exit=24;
    }
    // No command queue/work submission/window exists in this mode. Shutdown owns SDK retirement.
    if(!owned.Close()) exit=25;
    std::printf("TASK14_INIT_COM_CLEANUP ownersBeforeClose=%u ownedPointersRemaining=%u observedResetCalls=UNMEASURED sdkInternalCleanup=UNMEASURED\n",
        comOwners,owned.factory || owned.adapter || owned.device?1u:0u);
    std::printf("TASK14_INIT_TERMINAL native=%d graphicsEntries=%u vendorLoads=%u initCalls=%u\n",
        exit,graphicsEntries,vendorLoads,initCalls);
    return exit;
}
static bool QualifyOutputContract(const HANDLE* expected)
{
    const HANDLE actual[]={GetStdHandle(STD_OUTPUT_HANDLE),GetStdHandle(STD_ERROR_HANDLE)};
    const bool pair=actual[0] && actual[0]!=INVALID_HANDLE_VALUE &&
        actual[1] && actual[1]!=INVALID_HANDLE_VALUE && actual[0]!=actual[1] &&
        actual[0]==expected[0] && actual[1]==expected[1];
    bool verified=pair;
    for(unsigned role=0;role<2;++role) {
        std::printf("TASK26_CONTRACT_ROLE role=%s expected=%p actual=%p pairMatched=%u\n",
            role==0?"stdout":"stderr",expected[role],actual[role],pair?1u:0u);
        if(!pair) continue;
        DWORD flags=0;
        const BOOL information=GetHandleInformation(actual[role],&flags);
        const DWORD informationError=information?0:GetLastError();
        SetLastError(ERROR_SUCCESS);
        const DWORD type=GetFileType(actual[role]);
        const DWORD typeError=type==FILE_TYPE_UNKNOWN?GetLastError():0;
        const bool accepted=information && type==FILE_TYPE_DISK;
        std::printf("TASK26_CONTRACT_QUERY role=%s expected=%p actual=%p infoOk=%u infoFlags=%lu infoError=%lu type=%lu typeError=%lu accepted=%u\n",
            role==0?"stdout":"stderr",expected[role],actual[role],information?1u:0u,flags,informationError,type,typeError,accepted?1u:0u);
        verified=verified && accepted;
    }
    std::printf("TASK26_CONTRACT_RESULT pairMatched=%u handlesVerified=%u independentChildPathname=0 graphicsAuthorized=0\n",pair?1u:0u,verified?1u:0u);
    return verified;
}
static int OutputContractOnly(const HANDLE (&expected)[2])
{
    setvbuf(stdout,nullptr,_IONBF,0);
    if(!ContainedPrimaryToken()) {
        std::puts("TASK14_INIT_REFUSAL=PRIMARY_TOKEN_IDENTITY_REJECTED");
        std::puts("TASK14_INIT_TERMINAL native=23 graphicsEntries=0 vendorLoads=0 initCalls=0");
        return 23;
    }
    Admission owned;
    const bool verified=QualifyOutputContract(expected);
    int result=verified?0:24;
    if(!verified) std::puts("TASK14_INIT_REFUSAL operation=InheritedEOutputContractRefused");
    if(!owned.Close()) result=25;
    std::puts("TASK14_INIT_COM_CLEANUP ownersBeforeClose=0 ownedPointersRemaining=0 observedResetCalls=UNMEASURED sdkInternalCleanup=UNMEASURED");
    std::printf("TASK14_INIT_TERMINAL native=%d graphicsEntries=0 vendorLoads=0 initCalls=0\n",result);
    return result;
}
// Real NR owns the history. This fixture only supplies actual GPU scene/guides
// and paints the current UI after Evaluate; it is not a temporal provider.
struct RuntimePair
{
    Admission& owned;
    ComPtr<ID3D12Resource> color,depth,motion,output,before[2],after[2];
    ComPtr<ID3D12DescriptorHeap> rtv,srv;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    unsigned application=0,evaluations=0,callbacks=0,owners=0,resets=0;
    bool recording=false;
    std::exception_ptr failure;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    explicit RuntimePair(Admission& a):owned(a){}
    static void Barrier(ID3D12GraphicsCommandList* cmd,ID3D12Resource* resource,
        D3D12_RESOURCE_STATES from,D3D12_RESOURCE_STATES to)
    {
        D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,from,to};
        cmd->ResourceBarrier(1,&b);
    }
    void Initialize()
    {
        D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;heap.CreationNodeMask=heap.VisibleNodeMask=1;
        auto texture=[&](ComPtr<ID3D12Resource>& target,DXGI_FORMAT format,D3D12_RESOURCE_FLAGS flags,
            D3D12_RESOURCE_STATES state) {
            D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=1280;
            d.Height=720;d.DepthOrArraySize=1;d.MipLevels=1;d.Format=format;d.SampleDesc.Count=1;d.Flags=flags;
            Check(owned.device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,
                IID_PPV_ARGS(&target)),"RuntimeTexture");++owners;
        };
        texture(color,DXGI_FORMAT_R16G16B16A16_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        texture(depth,DXGI_FORMAT_R32_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        texture(motion,DXGI_FORMAT_R16G16_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        texture(output,DXGI_FORMAT_R16G16B16A16_FLOAT,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=4;
        Check(owned.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)),"RuntimeRtvHeap");++owners;
        auto handle=rtv->GetCPUDescriptorHandleForHeapStart();
        for(auto* resource:{color.Get(),depth.Get(),motion.Get()}) {
            owned.device->CreateRenderTargetView(resource,nullptr,handle);
            handle.ptr+=owned.device->GetDescriptorHandleIncrementSize(hd.Type);
        }
        hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;hd.NumDescriptors=1;hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        Check(owned.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&srv)),"RuntimeSrvHeap");++owners;
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};view.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;
        view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Texture2D.MipLevels=1;owned.device->CreateShaderResourceView(output.Get(),&view,srv->GetCPUDescriptorHandleForHeapStart());
        D3D12_DESCRIPTOR_RANGE range{};range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV;range.NumDescriptors=1;
        D3D12_ROOT_PARAMETER parameter{};parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameter.DescriptorTable={1,&range};parameter.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=1;rd.pParameters=&parameter;
        ComPtr<ID3DBlob> signature,error,vs,ps;
        Check(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&signature,&error),"RuntimeRootSerialize");
        Check(owned.device->CreateRootSignature(0,signature->GetBufferPointer(),signature->GetBufferSize(),IID_PPV_ARGS(&root)),"RuntimeRoot");++owners;
        const char* shader=R"(
Texture2D<float4> answer : register(t0);
float4 VS(uint i:SV_VertexID):SV_Position { float2 p=i==0?float2(-1,-1):i==1?float2(-1,3):float2(3,-1); return float4(p,0,1); }
float4 PS(float4 p:SV_Position):SV_Target { return answer.Load(int3(int2(p.xy),0)); }
)";
        Check(D3DCompile(shader,std::strlen(shader),"nr-runtime-output",nullptr,nullptr,"VS","vs_5_0",
            D3DCOMPILE_ENABLE_STRICTNESS,0,&vs,&error),"RuntimeVertexShader");
        Check(D3DCompile(shader,std::strlen(shader),"nr-runtime-output",nullptr,nullptr,"PS","ps_5_0",
            D3DCOMPILE_ENABLE_STRICTNESS,0,&ps,&error),"RuntimePixelShader");
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};pd.pRootSignature=root.Get();
        pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
        pd.SampleMask=UINT_MAX;pd.SampleDesc.Count=1;pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pd.RasterizerState.DepthClipEnable=TRUE;
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.DepthStencilState.DepthEnable=FALSE;pd.DepthStencilState.StencilEnable=FALSE;
        pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pd.NumRenderTargets=1;
        pd.RTVFormats[0]=DXGI_FORMAT_R8G8B8A8_UNORM;
        Check(owned.device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pipeline)),"RuntimeOutputPipeline");++owners;
        ComPtr<ID3D12Resource> backbuffer;Check(owned.swapchain->GetBuffer(0,IID_PPV_ARGS(&backbuffer)),"RuntimeFootprintBuffer");
        const auto desc=backbuffer->GetDesc();UINT64 bytes=0;
        owned.device->GetCopyableFootprints(&desc,0,1,0,&footprint,nullptr,nullptr,&bytes);
        heap.Type=D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC buffer{};buffer.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;buffer.Width=bytes;
        buffer.Height=1;buffer.DepthOrArraySize=1;buffer.MipLevels=1;buffer.SampleDesc.Count=1;buffer.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        for(unsigned frame=0;frame<2;++frame) for(auto* target:{std::addressof(before[frame]),std::addressof(after[frame])}) {
            Check(owned.device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_COPY_DEST,
                nullptr,IID_PPV_ARGS(target->ReleaseAndGetAddressOf())),"RuntimeReadback");++owners;
        }
        std::printf("TASK14_RUNTIME_RESOURCES color=%p depth=%p motion=%p output=%p window=%p chain=%p device=%p queue=%p list=%p fence=%p\n",
            color.Get(),depth.Get(),motion.Get(),output.Get(),owned.window,owned.swapchain.Get(),owned.device.Get(),
            owned.queue.Get(),owned.commands.Get(),owned.fence.Get());
    }
    void Capture(ID3D12Resource* resource,ID3D12Resource* destination)
    {
        Barrier(owned.commands.Get(),resource,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=resource;src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=destination;dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        owned.commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        Barrier(owned.commands.Get(),resource,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
    }
    void Render()
    {
        const uint32_t id=application+1;
        auto marker=Export<decltype(&xellAddMarkerData)>(owned.llModule,"xellAddMarkerData");
        for(auto value:{XELL_SIMULATION_START,XELL_SIMULATION_END,XELL_RENDERSUBMIT_START}) {
            const auto result=marker(owned.ll,id,value);
            std::printf("TASK14_RUNTIME_XELL frame=%u marker=%u result=%d context=%p\n",id,unsigned(value),int(result),owned.ll);
            if(result!=XELL_RESULT_SUCCESS) throw std::runtime_error("RuntimeXellMarker");
        }
        Check(owned.allocator->Reset(),"RuntimeAllocatorReset");
        Check(owned.commands->Reset(owned.allocator.Get(),nullptr),"RuntimeListReset");
        recording=true;
        auto r=rtv->GetCPUDescriptorHandleForHeapStart();
        const float scene[]={0.1f,0.2f,0.3f,1.0f},z[]={0.5f,0,0,0},mv[]={0,0,0,0};
        const float* values[]={scene,z,mv};ID3D12Resource* inputs[]={color.Get(),depth.Get(),motion.Get()};
        for(unsigned i=0;i<3;++i) {
            Barrier(owned.commands.Get(),inputs[i],D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
            owned.commands->ClearRenderTargetView(r,values[i],0,nullptr);
            Barrier(owned.commands.Get(),inputs[i],D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            r.ptr+=owned.device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        }
        auto* p=owned.parameters;
        p->Set("DLSSNR.Color",color.Get());p->Set("DLSSNR.Depth",depth.Get());p->Set("DLSSNR.MVec",motion.Get());p->Set("DLSSNR.Output",output.Get());
        p->Set("DLSSNR.DepthInverted",0u);p->Set("DLSSNR.Reset",application==0?1u:0u);
        p->Set("DLSSNR.MVecScaleX",1.0f);p->Set("DLSSNR.MVecScaleY",1.0f);
        DlssNr::SetModelRegions(p,{1280,720},{{0,0,1280,720},{0,0,1280,720}});
        DlssNr::SetModelTuning(p,DlssNr::ModelSettings{});
        std::printf("TASK14_RUNTIME_EVALUATE_BEGIN application=%u reset=%u feature=%p color=%p output=%p callback=%p queue=%p commands=%p\n",
            id,application==0?1u:0u,owned.feature,color.Get(),output.Get(),this,owned.queue.Get(),owned.commands.Get());
        ++evaluations;
        const auto evaluated=owned.nr->Evaluate(owned.commands.Get(),owned.feature,p);
        std::printf("TASK14_RUNTIME_NR_EVALUATE application=%u result=0x%08X\n",id,unsigned(evaluated));
        if(evaluated!=NVSDK_NGX_Result_Success) {Submit();throw std::runtime_error("RuntimeNrEvaluate");}
        ComPtr<ID3D12Resource> backbuffer;
        Check(owned.swapchain->GetBuffer(owned.swapchain->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&backbuffer)),"RuntimeApplicationBuffer");
        Barrier(owned.commands.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        Barrier(owned.commands.Get(),backbuffer.Get(),D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        owned.device->CreateRenderTargetView(backbuffer.Get(),nullptr,r);owned.commands->OMSetRenderTargets(1,&r,FALSE,nullptr);
        ID3D12DescriptorHeap* heaps[]={srv.Get()};owned.commands->SetDescriptorHeaps(1,heaps);
        owned.commands->SetGraphicsRootSignature(root.Get());owned.commands->SetPipelineState(pipeline.Get());
        owned.commands->SetGraphicsRootDescriptorTable(0,srv->GetGPUDescriptorHandleForHeapStart());
        D3D12_VIEWPORT vp{0,0,1280,720,0,1};D3D12_RECT scissor{0,0,1280,720};
        owned.commands->RSSetViewports(1,&vp);owned.commands->RSSetScissorRects(1,&scissor);
        owned.commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);owned.commands->DrawInstanced(3,1,0,0);
        Capture(backbuffer.Get(),before[application].Get());
        const LONG x=application==0?64:96;const D3D12_RECT ui{x,32,x+8,40};const float magenta[]={1,0,1,1};
        owned.commands->ClearRenderTargetView(r,magenta,1,&ui);
        std::printf("TASK14_RUNTIME_UI_AFTER_NR application=%u x=%ld picture=%p callback=%p generation=1\n",id,x,backbuffer.Get(),this);
        Capture(backbuffer.Get(),after[application].Get());
        Barrier(owned.commands.Get(),output.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        Barrier(owned.commands.Get(),backbuffer.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PRESENT);
        xefg_swapchain_frame_constant_data_t constants{};
        for(unsigned i=0;i<16;i+=5) constants.viewMatrix[i]=constants.projectionMatrix[i]=1.0f;
        constants.motionVectorScaleX=constants.motionVectorScaleY=1.0f;constants.resetHistory=application==0?1u:0u;
        constants.frameRenderTime=16.0f;
        const auto tagged=Export<decltype(&xefgSwapChainTagFrameConstants)>(owned.fgModule,"xefgSwapChainTagFrameConstants")(owned.fg,id,&constants);
        std::printf("TASK14_RUNTIME_FG_CONSTANTS application=%u result=%d\n",id,int(tagged));
        if(tagged!=XEFG_SWAPCHAIN_RESULT_SUCCESS) {Submit();throw std::runtime_error("RuntimeFgConstants");}
        for(auto type:{XEFG_SWAPCHAIN_RES_DEPTH,XEFG_SWAPCHAIN_RES_MOTION_VECTOR}) {
            xefg_swapchain_d3d12_resource_data_t tag{};tag.type=type;tag.validity=XEFG_SWAPCHAIN_RV_ONLY_NOW;
            tag.resourceSize={1280,720};tag.pResource=type==XEFG_SWAPCHAIN_RES_DEPTH?depth.Get():motion.Get();
            tag.incomingState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
            const auto status=Export<decltype(&xefgSwapChainD3D12TagFrameResource)>(owned.fgModule,"xefgSwapChainD3D12TagFrameResource")(owned.fg,owned.commands.Get(),id,&tag);
            std::printf("TASK14_RUNTIME_FG_RESOURCE application=%u type=%u resource=%p result=%d\n",id,unsigned(type),tag.pResource,int(status));
            if(status!=XEFG_SWAPCHAIN_RESULT_SUCCESS) {Submit();throw std::runtime_error("RuntimeFgResource");}
        }
        Submit();
        const auto presentId=Export<decltype(&xefgSwapChainSetPresentId)>(owned.fgModule,"xefgSwapChainSetPresentId")(owned.fg,id);
        if(presentId!=XEFG_SWAPCHAIN_RESULT_SUCCESS) throw std::runtime_error("RuntimePresentId");
        for(auto value:{XELL_RENDERSUBMIT_END,XELL_PRESENT_START}) {
            const auto status=marker(owned.ll,id,value);if(status!=XELL_RESULT_SUCCESS) throw std::runtime_error("RuntimeXellPresentMarker");
        }
        const auto presented=owned.swapchain->Present(0,0);
        std::printf("TASK14_RUNTIME_PRESENT application=%u chain=%p window=%p result=0x%08X\n",id,owned.swapchain.Get(),owned.window,unsigned(presented));
        const auto end=marker(owned.ll,id,XELL_PRESENT_END);
        Check(presented,"RuntimePresent");if(end!=XELL_RESULT_SUCCESS) throw std::runtime_error("RuntimeXellPresentEnd");
        ++application;
    }
    void Submit()
    {
        owned.Submit();
        recording=false;
    }
    uint32_t Pixel(ID3D12Resource* resource,unsigned x,unsigned y)
    {
        void* bytes=nullptr;D3D12_RANGE read{0,SIZE_T(footprint.Footprint.RowPitch)*720};
        Check(resource->Map(0,&read,&bytes),"RuntimeReadbackMap");
        uint32_t value=0;std::memcpy(&value,static_cast<const unsigned char*>(bytes)+footprint.Offset+
            y*footprint.Footprint.RowPitch+x*4,4);D3D12_RANGE written{0,0};resource->Unmap(0,&written);return value;
    }
    bool Inspect()
    {
        const auto first=Pixel(after[0].Get(),65,33),current=Pixel(after[1].Get(),97,33);
        const auto old=Pixel(after[1].Get(),65,33),clean=Pixel(before[1].Get(),65,33);
        const bool clear=first==0xffff00ffu && current==0xffff00ffu && old==clean && old!=0xffff00ffu;
        std::printf("TASK14_RUNTIME_HISTORY_PAIR applications=%u evaluates=%u callbacks=%u firstUi=0x%08X currentUi=0x%08X previousRegion=0x%08X modelRegion=0x%08X currentUiOnly=%u providerDouble=0 productionHookRoute=NOT_PROVED\n",
            application,evaluations,callbacks,first,current,old,clean,clear?1u:0u);
        return clear;
    }
    void Close()
    {
        auto reset=[&](auto& value){if(value){value.Reset();++resets;}};
        reset(color);reset(depth);reset(motion);reset(output);reset(rtv);reset(srv);reset(root);reset(pipeline);
        for(unsigned i=0;i<2;++i){reset(before[i]);reset(after[i]);}
        std::printf("TASK14_RUNTIME_RESOURCE_CLEANUP ownerResets=%u/%u remaining=%u sdkInternalRefs=UNMEASURED\n",resets,owners,owners-resets);
    }
};
static RuntimePair* activeRuntimePair=nullptr;
static LRESULT CALLBACK RuntimeWindowProc(HWND window,UINT message,WPARAM application,LPARAM binding)
{
    if(message==WM_APP+14 && activeRuntimePair && binding==reinterpret_cast<LPARAM>(activeRuntimePair) &&
        window==activeRuntimePair->owned.window && application==activeRuntimePair->application) {
        ++activeRuntimePair->callbacks;
        std::printf("TASK14_RUNTIME_CALLBACK window=%p message=%u application=%llu binding=%p thread=%lu\n",
            window,message,static_cast<unsigned long long>(application),activeRuntimePair,GetCurrentThreadId());
        try {activeRuntimePair->Render();} catch(...) {activeRuntimePair->failure=std::current_exception();}
        return 1;
    }
    return DefWindowProcW(window,message,application,binding);
}
static int ContainedRuntimeOnly(const wchar_t* data,const wchar_t* driver,const wchar_t* nr,
    const wchar_t* fg,const wchar_t* ll,const HANDLE (&expected)[2]);
int wmain(int argc,wchar_t** argv)
{
    bool modeArgument=false;
    for(int i=1;i<argc;++i) if(std::wstring(argv[i]).starts_with(L"--")) modeArgument=true;
    if(modeArgument) {
        if(std::wstring(argv[1])==L"--contained-runtime-r7") {
            bool valid=argc==9;HANDLE expected[2]{};
            if(valid) valid=
                std::wstring(argv[2])==L"C:/omo-research/optiscaler-nr-ui-feedback-wt/wave2-01a12466/.omo/e14-contained-runtime-r7-01a12466/data" &&
                std::wstring(argv[3])==L"C:/Windows/System32/DriverStore/FileRepository/nv_dispi.inf_amd64_da865124972e1f80/_nvngx.dll" &&
                std::wstring(argv[4])==L"D:/SteamLibrary/steamapps/common/The Witcher 3/bin/x64_dx12/nvngx_dlssnr.dll" &&
                std::wstring(argv[5])==L"C:/omo-research/rw-nr3-0985d/external/xess/bin/libxess_fg.dll" &&
                std::wstring(argv[6])==L"C:/omo-research/rw-nr3-0985d/external/xess/bin/libxell.dll";
            if(valid) for(unsigned role=0;role<2;++role) {
                wchar_t* end=nullptr;const auto value=_wcstoui64(argv[role+7],&end,10);
                valid=valid && *end==L'\0' && std::wstring(argv[role+7])==std::to_wstring(value) &&
                    value!=0 && value<static_cast<unsigned long long>(~UINT_PTR(0));
                expected[role]=reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(value));
            }
            if(valid && expected[0]!=expected[1]) return ContainedRuntimeOnly(argv[2],argv[3],argv[4],argv[5],argv[6],expected);
            std::puts("TASK14_INIT_REFUSAL=MALFORMED_OR_MIXED_MODE");
            std::puts("TASK14_INIT_TERMINAL native=90 graphicsEntries=0 vendorLoads=0 initCalls=0");
            return 90;
        }
        const bool sdkOutput=std::wstring(argv[1])==L"--sdk-output-init-r6";
        if(std::wstring(argv[1])==L"--output-contract-r5" || sdkOutput) {
            HANDLE expected[2]{};
            bool valid=argc==(sdkOutput?7:4);
            if(valid && sdkOutput) valid=
                std::wstring(argv[2])==L"C:/omo-research/optiscaler-nr-ui-feedback-wt/wave2-01a12466/.omo/e14-sdk-output-r6-01a12466/data" &&
                std::wstring(argv[3])==L"C:/Windows/System32/DriverStore/FileRepository/nv_dispi.inf_amd64_da865124972e1f80/_nvngx.dll" &&
                std::wstring(argv[4])==L"D:/SteamLibrary/steamapps/common/The Witcher 3/bin/x64_dx12";
            if(valid) for(unsigned role=0;role<2;++role) {
                wchar_t* end=nullptr;
                const wchar_t* argument=argv[role+(sdkOutput?5:2)];
                const unsigned long long value=_wcstoui64(argument,&end,10);
                valid=valid && *end==L'\0' && std::wstring(argument)==std::to_wstring(value) &&
                    value!=0 && value<static_cast<unsigned long long>(~UINT_PTR(0));
                expected[role]=reinterpret_cast<HANDLE>(static_cast<UINT_PTR>(value));
            }
            if(valid && expected[0]!=expected[1]) {
                if(sdkOutput) return ContainedInitOnly(argv[2],argv[3],argv[4],false,expected);
                return OutputContractOnly(expected);
            }
            std::puts("TASK26_CONTRACT_REFUSAL=MALFORMED_EXPECTED_PAIR");
        }
        if(std::wstring(argv[1])==L"--output-only-r4" && argc==2)
            return ContainedInitOnly(nullptr,nullptr,nullptr,true);
        if(argc!=5 || std::wstring(argv[1])!=L"--contained-init-only" ||
            std::wstring(argv[2])!=L"C:/omo-research/optiscaler-nr-ui-feedback-wt/wave2-01a12466/.omo/e14-contained-init-r3-01a12466/data" ||
            std::wstring(argv[3])!=L"C:/Windows/System32/DriverStore/FileRepository/nv_dispi.inf_amd64_da865124972e1f80/_nvngx.dll" ||
            std::wstring(argv[4])!=L"D:/SteamLibrary/steamapps/common/The Witcher 3/bin/x64_dx12") {
            std::puts("TASK14_INIT_REFUSAL=MALFORMED_OR_MIXED_MODE");
            std::puts("TASK14_INIT_TERMINAL native=90 graphicsEntries=0 vendorLoads=0 initCalls=0");
            return 90;
        }
        return ContainedInitOnly(argv[2],argv[3],argv[4]);
    }
    Admission owned;
    int exit=0;
    try {
        if(argc!=6) throw std::runtime_error("UsageOwnedDataDriverNrFgLl");
        const std::filesystem::path dataRoot(argv[1]),driverPath(argv[2]),nrPath(argv[3]),fgPath(argv[4]),llPath(argv[5]);
        if(!dataRoot.is_absolute() || !std::filesystem::is_directory(dataRoot)) throw std::runtime_error("OwnedDataRoot");
        Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&owned.factory)),"CreateOwnedFactory");
        for(UINT index=0;;++index) {
            auto result=owned.factory->EnumAdapterByGpuPreference(index,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                                                                  IID_PPV_ARGS(&owned.adapter));
            if(result==DXGI_ERROR_NOT_FOUND) break;
            Check(result,"EnumOwnedAdapter");
            DXGI_ADAPTER_DESC1 desc{};Check(owned.adapter->GetDesc1(&desc),"OwnedAdapterDescription");
            if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) {owned.adapter.Reset();continue;}
            auto created=D3D12CreateDevice(owned.adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&owned.device));
            std::printf("TASK14_HARDWARE adapter=%ls vendor=0x%04X deviceId=0x%04X luid=%ld:%lu result=0x%08X\n",
                desc.Description,desc.VendorId,desc.DeviceId,desc.AdapterLuid.HighPart,desc.AdapterLuid.LowPart,unsigned(created));
            if(SUCCEEDED(created)) break;
            owned.adapter.Reset();
        }
        if(!owned.device) {
            std::puts("TASK14_QUALIFICATION exactRefusal=NoHardwareD3D12Device historyPair=NOT_ADMITTED fullTask3=NOT_PROVED");
        } else {
            D3D12_COMMAND_QUEUE_DESC q{};
            Check(owned.device->CreateCommandQueue(&q,IID_PPV_ARGS(&owned.queue)),"CreateOwnedQueue");
            Check(owned.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&owned.allocator)),"CreateOwnedAllocator");
            Check(owned.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,owned.allocator.Get(),nullptr,
                                                 IID_PPV_ARGS(&owned.commands)),"CreateOwnedCommandList");
            Check(owned.device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&owned.fence)),"CreateOwnedFence");
            owned.event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
            if(!owned.event) throw std::runtime_error("CreateOwnedFenceEvent");
            ++owned.eventsCreated;
            ComPtr<IUnknown> deviceIdentity,queueIdentity;
            Check(owned.device.As(&deviceIdentity),"CanonicalDeviceIdentity");
            Check(owned.queue.As(&queueIdentity),"CanonicalQueueIdentity");
            std::printf("TASK14_COM device=%p deviceIUnknown=%p queue=%p queueIUnknown=%p wrapper=0\n",
                owned.device.Get(),deviceIdentity.Get(),owned.queue.Get(),queueIdentity.Get());
            deviceIdentity.Reset();queueIdentity.Reset();
            owned.llModule=owned.Load(llPath);owned.fgModule=owned.Load(fgPath);
            owned.destroyLl=Export<decltype(owned.destroyLl)>(owned.llModule,"xellDestroyContext");
            owned.destroyFg=Export<decltype(owned.destroyFg)>(owned.fgModule,"xefgSwapChainDestroy");
            const auto llResult=Export<decltype(&xellD3D12CreateContext)>(owned.llModule,"xellD3D12CreateContext")(owned.device.Get(),&owned.ll);
            if(owned.ll) ++owned.contextsCreated;
            const auto fgResult=Export<decltype(&xefgSwapChainD3D12CreateContext)>(owned.fgModule,"xefgSwapChainD3D12CreateContext")(owned.device.Get(),&owned.fg);
            if(owned.fg) ++owned.contextsCreated;
            std::printf("TASK14_CONTEXT llResult=%d ll=%p fgResult=%d fg=%p\n",int(llResult),owned.ll,int(fgResult),owned.fg);
            bool fgInitialized=false;
            if(fgResult==XEFG_SWAPCHAIN_RESULT_SUCCESS && llResult==XELL_RESULT_SUCCESS) {
                auto logged=Export<decltype(&xefgSwapChainSetLoggingCallback)>(owned.fgModule,"xefgSwapChainSetLoggingCallback")
                    (owned.fg,XEFG_SWAPCHAIN_LOGGING_LEVEL_DEBUG,SdkLog,nullptr);
                auto linked=Export<decltype(&xefgSwapChainSetLatencyReduction)>(owned.fgModule,"xefgSwapChainSetLatencyReduction")(owned.fg,owned.ll);
                std::printf("TASK14_FG_SETUP logging=%d latency=%d\n",int(logged),int(linked));
                if(logged!=XEFG_SWAPCHAIN_RESULT_SUCCESS || linked!=XEFG_SWAPCHAIN_RESULT_SUCCESS) throw std::runtime_error("XeFgSetup");
                WNDCLASSW wc{};wc.lpfnWndProc=WindowProc;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"OptiScalerTask14Owned";
                owned.windowClass=RegisterClassW(&wc);
                if(!owned.windowClass) throw std::runtime_error("RegisterOwnedWindowClass");
                owned.window=CreateWindowExW(WS_EX_NOACTIVATE,wc.lpszClassName,L"Task 14 owned runtime admission",
                    WS_OVERLAPPEDWINDOW,0,0,1280,720,nullptr,nullptr,wc.hInstance,nullptr);
                if(!owned.window) throw std::runtime_error("CreateOwnedWindow");
                ++owned.windowsCreated;
                DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=1280;desc.Height=720;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
                desc.SampleDesc.Count=1;desc.BufferCount=2;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;
                desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
                xefg_swapchain_d3d12_init_params_t params{};params.maxInterpolatedFrames=1;params.uiMode=XEFG_SWAPCHAIN_UI_MODE_AUTO;
                const auto initialized=Export<decltype(&xefgSwapChainD3D12InitFromSwapChainDesc)>(owned.fgModule,"xefgSwapChainD3D12InitFromSwapChainDesc")
                    (owned.fg,owned.window,&desc,nullptr,owned.queue.Get(),owned.factory.Get(),&params);
                std::printf("TASK14_FG_INIT result=%d hwnd=%p queue=%p device=%p\n",int(initialized),owned.window,owned.queue.Get(),owned.device.Get());
                fgInitialized=initialized==XEFG_SWAPCHAIN_RESULT_SUCCESS;
                if(fgInitialized) {
                    const auto acquired=Export<decltype(&xefgSwapChainD3D12GetSwapChainPtr)>(owned.fgModule,"xefgSwapChainD3D12GetSwapChainPtr")
                        (owned.fg,IID_PPV_ARGS(&owned.swapchain));
                    std::printf("TASK14_FG_CHAIN result=%d chain=%p\n",int(acquired),owned.swapchain.Get());
                    if(acquired!=XEFG_SWAPCHAIN_RESULT_SUCCESS) throw std::runtime_error("AcquireSdkSwapchain");
                }
            }
            owned.driverModule=owned.Load(driverPath);
            using DriverInit=NVSDK_NGX_Result(*)(unsigned long long,const wchar_t*,ID3D12Device*,NVSDK_NGX_Version,const NVSDK_NGX_FeatureCommonInfo*);
            auto init=Export<DriverInit>(owned.driverModule,"NVSDK_NGX_D3D12_Init_Ext");
            auto allocate=Export<decltype(&NVSDK_NGX_D3D12_GetCapabilityParameters)>(owned.driverModule,"NVSDK_NGX_D3D12_GetCapabilityParameters");
            owned.destroyParameters=Export<decltype(owned.destroyParameters)>(owned.driverModule,"NVSDK_NGX_D3D12_DestroyParameters");
            owned.shutdown=Export<Admission::Shutdown>(owned.driverModule,"NVSDK_NGX_D3D12_Shutdown1");
            auto wrongModule=DlssNr::CompatibilityRuntime::Open(llPath,owned.device.Get(),allocate,owned.destroyParameters,dataRoot);
            std::printf("TASK14_CONTROL missingNrExports refused=%u candidate=%ls\n",wrongModule?0u:1u,llPath.c_str());
            if(wrongModule) throw std::runtime_error("MissingExportsControlAccepted");
            const auto runtimeRoot=nrPath.parent_path().wstring();const wchar_t* paths[]={runtimeRoot.c_str()};
            NVSDK_NGX_FeatureCommonInfo common{};common.PathListInfo.Path=paths;common.PathListInfo.Length=1;
            common.LoggingInfo.LoggingCallback=DriverLog;common.LoggingInfo.MinimumLoggingLevel=NVSDK_NGX_LOGGING_LEVEL_ON;
            common.LoggingInfo.DisableOtherLoggingSinks=true;
            const auto driverResult=init(0x24480451ull,dataRoot.c_str(),owned.device.Get(),NVSDK_NGX_Version_API,&common);
            owned.driverInitialized=driverResult==NVSDK_NGX_Result_Success;
            std::printf("TASK14_DRIVER_INIT result=0x%08X dataPath=%ls\n",unsigned(driverResult),dataRoot.c_str());
            if(owned.driverInitialized) {
                owned.nr=DlssNr::CompatibilityRuntime::Open(nrPath,owned.device.Get(),allocate,owned.destroyParameters,dataRoot);
                std::printf("TASK14_NR_OPEN admitted=%u\n",owned.nr?1u:0u);
                if(owned.nr) {
                    const auto allocated=allocate(&owned.parameters);
                    if(owned.parameters) ++owned.parametersCreated;
                    std::printf("TASK14_PARAMETERS result=0x%08X pointer=%p\n",unsigned(allocated),owned.parameters);
                    if(allocated!=NVSDK_NGX_Result_Success || !owned.parameters) throw std::runtime_error("AllocateRealParameters");
                    owned.parameters->Set("DLSSNR.Enabled",1u);owned.parameters->Set("DLSSNR.Width",1280u);owned.parameters->Set("DLSSNR.Height",720u);
                    owned.parameters->Set("CreationNodeMask",1u);owned.parameters->Set("VisibilityNodeMask",1u);
                    owned.parameters->Set("DLSSNR.Hint.Render.Preset",0u);owned.parameters->Set("DLSSNR.UICorrection",1u);
                    DlssNr::SetModelTuning(owned.parameters,DlssNr::ModelSettings{});
                    const auto created=owned.nr->Create(owned.commands.Get(),owned.parameters,&owned.feature);
                    if(owned.feature) ++owned.featuresCreated;
                    std::printf("TASK14_NR_CREATE result=0x%08X feature=%p id=%u\n",unsigned(created),owned.feature,owned.feature?owned.feature->Id:0);
                    owned.Submit();
                    if(created==NVSDK_NGX_Result_Success && owned.feature && fgInitialized)
                        std::puts("TASK14_QUALIFICATION creation=ADMITTED historyPair=NEXT_STAGE_REQUIRED fullTask3=NOT_PROVED");
                    else
                        std::puts("TASK14_QUALIFICATION creation=REFUSED historyPair=NOT_ADMITTED fullTask3=NOT_PROVED");
                } else
                    std::puts("TASK14_QUALIFICATION exactRefusal=CompatibilityRuntimeOpen historyPair=NOT_ADMITTED fullTask3=NOT_PROVED");
            } else
                std::puts("TASK14_QUALIFICATION exactRefusal=DriverInit historyPair=NOT_ADMITTED fullTask3=NOT_PROVED");
        }
    } catch(const std::exception& error) {
        std::printf("TASK14_FAILURE=%s win32=%lu\n",error.what(),GetLastError());exit=1;
    }
    if(!owned.Close()) exit=1;
    std::printf("TASK14_CREATION_TERMINAL native=%d\n",exit);
    return exit;
}
static int ContainedRuntimeOnly(const wchar_t* data,const wchar_t* driver,const wchar_t* nrPathText,
    const wchar_t* fgPathText,const wchar_t* llPathText,const HANDLE (&expected)[2])
{
    setvbuf(stdout,nullptr,_IONBF,0);
    if(!ContainedPrimaryToken()) {
        std::puts("TASK14_INIT_REFUSAL=PRIMARY_TOKEN_IDENTITY_REJECTED");
        std::puts("TASK14_INIT_TERMINAL native=23 graphicsEntries=0 vendorLoads=0 initCalls=0");
        return 23;
    }
    if(!QualifyOutputContract(expected)) {
        std::puts("TASK14_RUNTIME_REFUSAL=InheritedEOutputContractRefused");
        std::puts("TASK14_INIT_TERMINAL native=24 graphicsEntries=0 vendorLoads=0 initCalls=0");
        return 24;
    }
    Admission owned;RuntimePair pair(owned);int runtimeExit=0;
    try {
        const std::filesystem::path dataRoot(data),driverPath(driver),nrPath(nrPathText),fgPath(fgPathText),llPath(llPathText);
        std::puts("TASK14_RUNTIME_BOUNDARY=FIRST_GRAPHICS_ENTRY qualifiedPrimaryAndOutput=1");
        Check(CreateDXGIFactory2(0,IID_PPV_ARGS(&owned.factory)),"CreateOwnedFactory");
        for(UINT index=0;;++index) {
            auto result=owned.factory->EnumAdapterByGpuPreference(index,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                                                                  IID_PPV_ARGS(&owned.adapter));
            if(result==DXGI_ERROR_NOT_FOUND) break;
            Check(result,"EnumOwnedAdapter");
            DXGI_ADAPTER_DESC1 desc{};Check(owned.adapter->GetDesc1(&desc),"OwnedAdapterDescription");
            if(desc.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) {owned.adapter.Reset();continue;}
            auto created=D3D12CreateDevice(owned.adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&owned.device));
            std::printf("TASK14_HARDWARE adapter=%ls vendor=0x%04X deviceId=0x%04X luid=%ld:%lu result=0x%08X\n",
                desc.Description,desc.VendorId,desc.DeviceId,desc.AdapterLuid.HighPart,desc.AdapterLuid.LowPart,unsigned(created));
            if(SUCCEEDED(created)) break;
            owned.adapter.Reset();
        }
        if(!owned.device) {
            throw std::runtime_error("NoHardwareD3D12Device");
        } else {
            D3D12_COMMAND_QUEUE_DESC q{};
            Check(owned.device->CreateCommandQueue(&q,IID_PPV_ARGS(&owned.queue)),"CreateOwnedQueue");
            Check(owned.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&owned.allocator)),"CreateOwnedAllocator");
            Check(owned.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,owned.allocator.Get(),nullptr,
                                                 IID_PPV_ARGS(&owned.commands)),"CreateOwnedCommandList");
            Check(owned.device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&owned.fence)),"CreateOwnedFence");
            owned.event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
            if(!owned.event) throw std::runtime_error("CreateOwnedFenceEvent");
            ++owned.eventsCreated;
            ComPtr<IUnknown> deviceIdentity,queueIdentity;
            Check(owned.device.As(&deviceIdentity),"CanonicalDeviceIdentity");
            Check(owned.queue.As(&queueIdentity),"CanonicalQueueIdentity");
            std::printf("TASK14_COM device=%p deviceIUnknown=%p queue=%p queueIUnknown=%p wrapper=0\n",
                owned.device.Get(),deviceIdentity.Get(),owned.queue.Get(),queueIdentity.Get());
            deviceIdentity.Reset();queueIdentity.Reset();
            owned.llModule=owned.Load(llPath);owned.fgModule=owned.Load(fgPath);
            owned.destroyLl=Export<decltype(owned.destroyLl)>(owned.llModule,"xellDestroyContext");
            owned.destroyFg=Export<decltype(owned.destroyFg)>(owned.fgModule,"xefgSwapChainDestroy");
            const auto llResult=Export<decltype(&xellD3D12CreateContext)>(owned.llModule,"xellD3D12CreateContext")(owned.device.Get(),&owned.ll);
            if(owned.ll) ++owned.contextsCreated;
            const auto fgResult=Export<decltype(&xefgSwapChainD3D12CreateContext)>(owned.fgModule,"xefgSwapChainD3D12CreateContext")(owned.device.Get(),&owned.fg);
            if(owned.fg) ++owned.contextsCreated;
            std::printf("TASK14_CONTEXT llResult=%d ll=%p fgResult=%d fg=%p\n",int(llResult),owned.ll,int(fgResult),owned.fg);
            bool fgInitialized=false;
            if(fgResult!=XEFG_SWAPCHAIN_RESULT_SUCCESS || llResult!=XELL_RESULT_SUCCESS || !owned.fg || !owned.ll) throw std::runtime_error("RuntimeContextCreate");
            if(fgResult==XEFG_SWAPCHAIN_RESULT_SUCCESS && llResult==XELL_RESULT_SUCCESS) {
                auto logged=Export<decltype(&xefgSwapChainSetLoggingCallback)>(owned.fgModule,"xefgSwapChainSetLoggingCallback")
                    (owned.fg,XEFG_SWAPCHAIN_LOGGING_LEVEL_DEBUG,SdkLog,nullptr);
                auto linked=Export<decltype(&xefgSwapChainSetLatencyReduction)>(owned.fgModule,"xefgSwapChainSetLatencyReduction")(owned.fg,owned.ll);
                std::printf("TASK14_FG_SETUP logging=%d latency=%d\n",int(logged),int(linked));
                if(logged!=XEFG_SWAPCHAIN_RESULT_SUCCESS || linked!=XEFG_SWAPCHAIN_RESULT_SUCCESS) throw std::runtime_error("XeFgSetup");
                WNDCLASSW wc{};wc.lpfnWndProc=RuntimeWindowProc;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"OptiScalerTask14Owned";
                owned.windowClass=RegisterClassW(&wc);
                if(!owned.windowClass) throw std::runtime_error("RegisterOwnedWindowClass");
                owned.window=CreateWindowExW(WS_EX_NOACTIVATE,wc.lpszClassName,L"Task 14 owned runtime admission",
                    WS_OVERLAPPEDWINDOW,0,0,1280,720,nullptr,nullptr,wc.hInstance,nullptr);
                if(!owned.window) throw std::runtime_error("CreateOwnedWindow");
                ++owned.windowsCreated;
                DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=1280;desc.Height=720;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
                desc.SampleDesc.Count=1;desc.BufferCount=2;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;
                desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
                xefg_swapchain_d3d12_init_params_t params{};params.maxInterpolatedFrames=1;params.uiMode=XEFG_SWAPCHAIN_UI_MODE_AUTO;
                const auto initialized=Export<decltype(&xefgSwapChainD3D12InitFromSwapChainDesc)>(owned.fgModule,"xefgSwapChainD3D12InitFromSwapChainDesc")
                    (owned.fg,owned.window,&desc,nullptr,owned.queue.Get(),owned.factory.Get(),&params);
                std::printf("TASK14_FG_INIT result=%d hwnd=%p queue=%p device=%p\n",int(initialized),owned.window,owned.queue.Get(),owned.device.Get());
                fgInitialized=initialized==XEFG_SWAPCHAIN_RESULT_SUCCESS;
                if(!fgInitialized) throw std::runtime_error("RuntimeFgInit");
                if(fgInitialized) {
                    const auto acquired=Export<decltype(&xefgSwapChainD3D12GetSwapChainPtr)>(owned.fgModule,"xefgSwapChainD3D12GetSwapChainPtr")
                        (owned.fg,IID_PPV_ARGS(&owned.swapchain));
                    std::printf("TASK14_FG_CHAIN result=%d chain=%p\n",int(acquired),owned.swapchain.Get());
                    if(acquired!=XEFG_SWAPCHAIN_RESULT_SUCCESS) throw std::runtime_error("AcquireSdkSwapchain");
                }
            }

            owned.driverModule=owned.Load(driverPath);
            auto init=Export<ContainedDriverInit>(owned.driverModule,"NVSDK_NGX_D3D12_Init_Ext");
            auto allocate=Export<decltype(&NVSDK_NGX_D3D12_GetCapabilityParameters)>(owned.driverModule,"NVSDK_NGX_D3D12_GetCapabilityParameters");
            owned.destroyParameters=Export<decltype(owned.destroyParameters)>(owned.driverModule,"NVSDK_NGX_D3D12_DestroyParameters");
            owned.shutdown=Export<Admission::Shutdown>(owned.driverModule,"NVSDK_NGX_D3D12_Shutdown1");
            const auto runtimeRoot=nrPath.parent_path().wstring();const wchar_t* paths[]={runtimeRoot.c_str()};
            NVSDK_NGX_FeatureCommonInfo common{};common.PathListInfo.Path=paths;common.PathListInfo.Length=1;
            common.LoggingInfo.LoggingCallback=DriverLog;common.LoggingInfo.MinimumLoggingLevel=NVSDK_NGX_LOGGING_LEVEL_ON;
            common.LoggingInfo.DisableOtherLoggingSinks=true;
            const auto initialized=init(0x24480451ull,dataRoot.c_str(),owned.device.Get(),NVSDK_NGX_Version_API,&common);
            owned.driverInitialized=initialized==NVSDK_NGX_Result_Success;
            std::printf("TASK14_RUNTIME_DRIVER_INIT result=0x%08X publicCommonInfo=1 callback=%p internalData=null\n",unsigned(initialized),reinterpret_cast<void*>(DriverLog));
            if(!owned.driverInitialized) throw std::runtime_error("RuntimePublicDriverInit");
            owned.nr=DlssNr::CompatibilityRuntime::Open(nrPath,owned.device.Get(),allocate,owned.destroyParameters,dataRoot);
            std::printf("TASK14_RUNTIME_NR_OPEN admitted=%u directNrCapabilitiesAbi=1 callerCorrection=PRODUCTION\n",owned.nr?1u:0u);
            if(!owned.nr) throw std::runtime_error("RuntimeCompatibilityOpen");
            const auto allocated=allocate(&owned.parameters);if(owned.parameters) ++owned.parametersCreated;
            std::printf("TASK14_RUNTIME_PARAMETERS result=0x%08X pointer=%p\n",unsigned(allocated),owned.parameters);
            if(allocated!=NVSDK_NGX_Result_Success || !owned.parameters) throw std::runtime_error("RuntimeParameters");
            auto* p=owned.parameters;
            p->Set("DLSSNR.Enabled",1u);p->Set("DLSSNR.Width",1280u);p->Set("DLSSNR.Height",720u);
            p->Set("CreationNodeMask",1u);p->Set("VisibilityNodeMask",1u);
            p->Set("DLSSNR.Hint.Render.Preset",0u);p->Set("DLSSNR.UICorrection",1u);
            for(const char* name:{"DLSSNR.ControlMask","DLSSNR.UI","DLSSNR.UIAlpha","DLSSNR.Backbuffer"}) p->Set(name,static_cast<ID3D12Resource*>(nullptr));
            for(const char* name:{"DLSSNR.UISubrectBaseX","DLSSNR.UISubrectBaseY","DLSSNR.UISubrectWidth","DLSSNR.UISubrectHeight",
                "DLSSNR.UIAlphaSubrectBaseX","DLSSNR.UIAlphaSubrectBaseY","DLSSNR.UIAlphaSubrectWidth","DLSSNR.UIAlphaSubrectHeight",
                "DLSSNR.BackbufferSubrectBaseX","DLSSNR.BackbufferSubrectBaseY","DLSSNR.BackbufferSubrectWidth","DLSSNR.BackbufferSubrectHeight"}) p->Set(name,0u);
            DlssNr::SetModelTuning(p,DlssNr::ModelSettings{});
            const auto created=owned.nr->Create(owned.commands.Get(),p,&owned.feature);if(owned.feature) ++owned.featuresCreated;
            std::printf("TASK14_RUNTIME_NR_CREATE result=0x%08X feature=%p id=%u\n",unsigned(created),owned.feature,owned.feature?owned.feature->Id:0);
            owned.Submit();
            if(created!=NVSDK_NGX_Result_Success || !owned.feature) throw std::runtime_error("RuntimeNrModelCreate");
            pair.Initialize();activeRuntimePair=&pair;
            for(unsigned application=0;application<2;++application) {
                const auto dispatched=SendMessageW(owned.window,WM_APP+14,application,reinterpret_cast<LPARAM>(&pair));
                if(pair.failure) std::rethrow_exception(pair.failure);
                if(dispatched!=1 || pair.application!=application+1) throw std::runtime_error("RuntimeApplicationCallback");
            }
            if(!pair.Inspect()) throw std::runtime_error("RuntimeHistoryPairPixels");
            std::puts("TASK14_RUNTIME_QUALIFICATION contextModel=ADMITTED historyPair=OBSERVED productionHookRoute=NOT_PROVED fullTask3=NOT_PROVED");
        }
    } catch(const std::exception& error) {
        std::printf("TASK14_RUNTIME_REFUSAL earliest=%s win32=%lu applications=%u evaluates=%u\n",error.what(),GetLastError(),pair.application,pair.evaluations);runtimeExit=24;
    }
    activeRuntimePair=nullptr;
    if(pair.recording && !owned.gpuPending) owned.commands.Reset();
    if(!owned.Close()) runtimeExit=25;
    pair.Close();
    std::printf("TASK14_RUNTIME_TERMINAL native=%d applications=%u callbacks=%u evaluates=%u positiveRuntimeAcceptance=0\n",runtimeExit,pair.application,pair.callbacks,pair.evaluations);
    return runtimeExit;
}
