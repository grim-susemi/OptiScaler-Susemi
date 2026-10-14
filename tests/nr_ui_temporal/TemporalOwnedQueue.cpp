// Actual capture/admission/compositor/wrapper and overlay submission bodies.
// The deterministic history-bearing provider and ImGui marker are fixture inputs.
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_5.h>
#include <d3dcompiler.h>
#include <shared_mutex>
#include <deque>
#include <fstream>
#include <filesystem>
#include <imgui/imgui.h>
#include <imgui/imgui_impl_dx12.h>
#include <d3dx/d3dx12.h>
#include <upscalers/ShaderPipeline_Dx12.h>
#include <dlssnr/DlssNr_Pipeline_Dx12.h>
#include <shaders/dlssnr/DlssNr_ActiveColor.h>

class Shader_Dx12
{
  public:
    static void SetBufferState(ID3D12GraphicsCommandList*,D3D12_RESOURCE_STATES,
                               ID3D12Resource*,D3D12_RESOURCE_STATES*);
};

static void TemporalHistoryRun(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*,
                               D3D12_RESOURCE_STATES, ID3D12CommandQueue*, D3D12_RESOURCE_STATES);
static HRESULT TemporalApplicationPresent(IDXGISwapChain*,UINT,UINT,const DXGI_PRESENT_PARAMETERS*);
static UINT TemporalApplicationIndex(IDXGISwapChain*);
namespace MenuOverlayDx
{
void Present(IDXGISwapChain*,UINT,UINT,const DXGI_PRESENT_PARAMETERS*,IUnknown*,HWND,bool);
}
#define main ExistingAdmissionMain
#include "TemporalCompositionAdapters.inc"
#undef main
#include "TemporalDirectProduction.inc"

static constexpr unsigned NUM_BACK_BUFFERS = 8, SRV_HEAP_SIZE = 64;
static bool _dx11Device = false, _dx12Device = true, _isInited = true;
static bool _showRenderImGuiDebugOnce = true;
static ID3D11Device* g_pd3dDevice = nullptr;
static ID3D12Device* g_pd3dDeviceParam = nullptr;
static ID3D12CommandQueue* g_pd3dCommandQueue = nullptr;
static IUnknown* currentSCCommandQueue = nullptr;
static ID3D12DescriptorHeap* g_pd3dRtvDescHeap = nullptr;
static ID3D12DescriptorHeap* g_pd3dSrvDescHeap = nullptr;
static ID3D12GraphicsCommandList* g_pd3dCommandList = nullptr;
static ID3D12CommandAllocator* g_commandAllocators[NUM_BACK_BUFFERS] {};
static ID3D12Resource* g_mainRenderTargetResource[NUM_BACK_BUFFERS] {};
static D3D12_CPU_DESCRIPTOR_HANDLE g_mainRenderTargetDescriptor[NUM_BACK_BUFFERS] {};
static unsigned markerX = 0, uiDraws = 0;
static bool overlayVisible = true;
static std::ofstream routeTrace;
static uint64_t traceSequence=0,traceApplication=0,traceGeneration=0,traceSerial=0;
static ID3D12Resource* tracePicture=nullptr;
static ID3D12GraphicsCommandList* traceNrCommands=nullptr;
static void TraceGpu(const char* event, const void* object=nullptr, uint64_t value=0)
{
    routeTrace<<"{\"sequence\":"<<++traceSequence<<",\"event\":\""<<event
              <<"\",\"application\":"<<traceApplication<<",\"generation\":"<<traceGeneration
              <<",\"serial\":"<<traceSerial<<",\"applicationTexture\":"
              <<reinterpret_cast<uintptr_t>(tracePicture)<<",\"object\":"
              <<reinterpret_cast<uintptr_t>(object)<<",\"value\":"<<value
              <<",\"nesting\":\"adapter-selected-not-observed-sdk\"}\n";
}
struct ScopedSkipHeapCapture {};
#define LOG_FUNC() ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
static DescriptorHeapAllocator g_pd3dSrvDescHeapAlloc;
namespace MenuOverlayBase
{
bool IsInited() { return true; }
HWND Handle() { return nullptr; }
void Init(HWND, bool) {}
void Shutdown() {}
void Dx11Ready() {}
void Dx12Ready() {}
void HideMenu() {}
void Present() {}
bool RenderMenu()
{
    if (!overlayVisible) return false;
    ImGui::GetIO().DisplaySize=ImVec2(8,8);
    ImGui::GetIO().DeltaTime=1.0f/60.0f;
    ImGui::NewFrame();
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(float(markerX),2),
        ImVec2(float(markerX+2),4), IM_COL32(255,0,255,255));
    ++uiDraws;
    return true;
}
}
namespace MenuOverlayDx
{
void Present(IDXGISwapChain*, UINT, UINT, const DXGI_PRESENT_PARAMETERS*, IUnknown*, HWND, bool);
}
static bool CheckForRealObject(std::string, IUnknown*, IUnknown**) { return false; }
static void CleanupRenderTargetDx11(bool) {}
static void CreateRenderTargetDx11(IDXGISwapChain*) {}
static void RenderImGui_DX11(IDXGISwapChain*) {}
static void CleanupRenderTargetDx12(bool)
{
    for (auto*& resource : g_mainRenderTargetResource) if (resource) { resource->Release(); resource=nullptr; }
}
#include "TemporalOverlayProduction.inc"
#include "TemporalGpuHooks.h"

struct ObservedQueue final : ID3D12CommandQueue
{
    std::atomic<ULONG> refs {1};
    ComPtr<ID3D12CommandQueue> real;
    explicit ObservedQueue(ID3D12CommandQueue* queue) : real(queue) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override
    {
        if(iid==__uuidof(IUnknown)||iid==__uuidof(ID3D12Object)||iid==__uuidof(ID3D12DeviceChild)||
           iid==__uuidof(ID3D12Pageable)||iid==__uuidof(ID3D12CommandQueue))
        { *out=this;AddRef();return S_OK; }
        *out=nullptr;return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { const auto n=--refs;if(!n)delete this;return n; }
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID g,UINT* n,void* p) override {return real->GetPrivateData(g,n,p);}
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID g,UINT n,const void* p) override {return real->SetPrivateData(g,n,p);}
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID g,const IUnknown* p) override {return real->SetPrivateDataInterface(g,p);}
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR n) override {return real->SetName(n);}
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID iid,void** out) override {return real->GetDevice(iid,out);}
    void STDMETHODCALLTYPE UpdateTileMappings(ID3D12Resource* r,UINT n,const D3D12_TILED_RESOURCE_COORDINATE* c,
        const D3D12_TILE_REGION_SIZE* s,ID3D12Heap* h,UINT m,const D3D12_TILE_RANGE_FLAGS* f,const UINT* o,
        const UINT* z,D3D12_TILE_MAPPING_FLAGS flags) override {real->UpdateTileMappings(r,n,c,s,h,m,f,o,z,flags);}
    void STDMETHODCALLTYPE CopyTileMappings(ID3D12Resource* a,const D3D12_TILED_RESOURCE_COORDINATE* b,
        ID3D12Resource* c,const D3D12_TILED_RESOURCE_COORDINATE* d,const D3D12_TILE_REGION_SIZE* e,
        D3D12_TILE_MAPPING_FLAGS f) override {real->CopyTileMappings(a,b,c,d,e,f);}
    void STDMETHODCALLTYPE ExecuteCommandLists(UINT n,ID3D12CommandList* const* lists) override
    {
        for(UINT i=0;i<n;++i)
        {
            if(lists[i]==g_pd3dCommandList)
            {
                ComPtr<IDXGISwapChain3> chain;
                Check(State::Instance().currentSwapchain->QueryInterface(IID_PPV_ARGS(&chain)));
                const auto index=chain->GetCurrentBackBufferIndex();
                Expect(g_mainRenderTargetResource[index]==tracePicture,"TemporalOverlayTargetMatchesApplication");
                TraceGpu("overlay-target",g_mainRenderTargetResource[index]);
            }
            TraceGpu(lists[i]==g_pd3dCommandList ? "overlay-submit" :
                     lists[i]==traceNrCommands ? "composition-submit" : "source-submit",lists[i],
                     reinterpret_cast<uintptr_t>(real.Get()));
        }
        real->ExecuteCommandLists(n,lists);
    }
    void STDMETHODCALLTYPE SetMarker(UINT a,const void* b,UINT c) override {real->SetMarker(a,b,c);}
    void STDMETHODCALLTYPE BeginEvent(UINT a,const void* b,UINT c) override {real->BeginEvent(a,b,c);}
    void STDMETHODCALLTYPE EndEvent() override {real->EndEvent();}
    HRESULT STDMETHODCALLTYPE Signal(ID3D12Fence* fence,UINT64 value) override
    {TraceGpu("queue-fence-signal",fence,value);return real->Signal(fence,value);}
    HRESULT STDMETHODCALLTYPE Wait(ID3D12Fence* fence,UINT64 value) override
    {TraceGpu("queue-fence-wait",fence,value);return real->Wait(fence,value);}
    HRESULT STDMETHODCALLTYPE GetTimestampFrequency(UINT64* n) override {return real->GetTimestampFrequency(n);}
    HRESULT STDMETHODCALLTYPE GetClockCalibration(UINT64* a,UINT64* b) override {return real->GetClockCalibration(a,b);}
    D3D12_COMMAND_QUEUE_DESC STDMETHODCALLTYPE GetDesc() override {return real->GetDesc();}
};

struct HistoryProvider
{
    Fixture& fixture;
    ComPtr<ID3D12Resource> input, history;
    ComPtr<ID3D12DescriptorHeap> views, rtv;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pso;
    unsigned calls = 0;
    explicit HistoryProvider(Fixture& f) : fixture(f)
    {
        D3D12_RESOURCE_DESC td=fixture.output->GetDesc();
        td.Flags=D3D12_RESOURCE_FLAG_NONE;
        D3D12_HEAP_PROPERTIES hp {}; hp.Type=D3D12_HEAP_TYPE_DEFAULT;
        for (auto* resource : {std::addressof(input),std::addressof(history)})
            Check(f.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&td,
                D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,nullptr,IID_PPV_ARGS(resource->ReleaseAndGetAddressOf())));
        D3D12_DESCRIPTOR_HEAP_DESC hd {}; hd.NumDescriptors=2;
        hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        Check(f.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&views)));
        auto view=views->GetCPUDescriptorHandleForHeapStart();
        const auto stride=f.device->GetDescriptorHandleIncrementSize(hd.Type);
        D3D12_SHADER_RESOURCE_VIEW_DESC srv {}; srv.Format=td.Format;
        srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; srv.Texture2D.MipLevels=1;
        f.device->CreateShaderResourceView(input.Get(),&srv,view); view.ptr += stride;
        f.device->CreateShaderResourceView(history.Get(),&srv,view);
        hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors=1; hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        Check(f.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)));
        D3D12_DESCRIPTOR_RANGE range {}; range.RangeType=D3D12_DESCRIPTOR_RANGE_TYPE_SRV; range.NumDescriptors=2;
        D3D12_ROOT_PARAMETER parameter {}; parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        parameter.DescriptorTable={1,&range}; parameter.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC rd {}; rd.NumParameters=1; rd.pParameters=&parameter;
        ComPtr<ID3DBlob> signature, error;
        Check(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&signature,&error));
        Check(f.device->CreateRootSignature(0,signature->GetBufferPointer(),signature->GetBufferSize(),IID_PPV_ARGS(&root)));
        const char* shader=R"(
Texture2D<float4> currentScene : register(t0);
Texture2D<float4> previousInput : register(t1);
float4 VS(uint vertex : SV_VertexID) : SV_Position {
    float2 p = vertex == 0 ? float2(-1,-1) : vertex == 1 ? float2(-1,3) : float2(3,-1);
    return float4(p,0,1);
}
float4 PS(float4 position : SV_Position) : SV_Target {
    int3 pixel=int3(int2(position.xy),0);
    return 0.5*currentScene.Load(pixel)+0.5*previousInput.Load(pixel);
})";
        ComPtr<ID3DBlob> vs, ps;
        Check(D3DCompile(shader,std::strlen(shader),"history-fixture",nullptr,nullptr,"VS","vs_5_0",0,0,&vs,&error));
        Check(D3DCompile(shader,std::strlen(shader),"history-fixture",nullptr,nullptr,"PS","ps_5_0",0,0,&ps,&error));
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd {};
        pd.pRootSignature=root.Get(); pd.VS={vs->GetBufferPointer(),vs->GetBufferSize()};
        pd.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
        pd.SampleMask=UINT_MAX; pd.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode=D3D12_CULL_MODE_NONE; pd.RasterizerState.DepthClipEnable=TRUE;
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.DepthStencilState.DepthEnable=FALSE; pd.DepthStencilState.StencilEnable=FALSE;
        pd.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets=1; pd.RTVFormats[0]=td.Format; pd.SampleDesc.Count=1;
        Check(f.device->CreateGraphicsPipelineState(&pd,IID_PPV_ARGS(&pso)));
    }
    void Run(ID3D12GraphicsCommandList* cmd, ID3D12Resource* color, ID3D12Resource* output,
             D3D12_RESOURCE_STATES arrival, D3D12_RESOURCE_STATES inputArrival)
    {
        auto& state=*fixture.owner._state;
        traceNrCommands=cmd;
        TraceGpu("nr-input-copy-record",color,reinterpret_cast<uintptr_t>(input.Get()));
        state.Barrier(cmd,color,inputArrival,D3D12_RESOURCE_STATE_COPY_SOURCE);
        state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        cmd->CopyResource(input.Get(),color);
        state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        state.Barrier(cmd,color,D3D12_RESOURCE_STATE_COPY_SOURCE,inputArrival);
        if (calls==0)
        {
            state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
            state.Barrier(cmd,history.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
            cmd->CopyResource(history.Get(),input.Get());
            state.Barrier(cmd,history.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        }
        if (Config::Instance()->DlssNrApplyModel.value_or_default())
        {
            state.Barrier(cmd,output,arrival,D3D12_RESOURCE_STATE_RENDER_TARGET);
            auto handle=rtv->GetCPUDescriptorHandleForHeapStart();
            fixture.device->CreateRenderTargetView(output,nullptr,handle);
            cmd->OMSetRenderTargets(1,&handle,FALSE,nullptr);
            ID3D12DescriptorHeap* heaps[]={views.Get()}; cmd->SetDescriptorHeaps(1,heaps);
            cmd->SetGraphicsRootSignature(root.Get()); cmd->SetPipelineState(pso.Get());
            cmd->SetGraphicsRootDescriptorTable(0,views->GetGPUDescriptorHandleForHeapStart());
            D3D12_VIEWPORT vp {0,0,8,8,0,1}; D3D12_RECT scissor {0,0,8,8};
            cmd->RSSetViewports(1,&vp); cmd->RSSetScissorRects(1,&scissor);
            cmd->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST); cmd->DrawInstanced(3,1,0,0);
            state.Barrier(cmd,output,D3D12_RESOURCE_STATE_RENDER_TARGET,arrival);
        }
        else if(output!=color)
        {
            state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
            state.Barrier(cmd,output,arrival,D3D12_RESOURCE_STATE_COPY_DEST);
            cmd->CopyResource(output,input.Get());
            state.Barrier(cmd,output,D3D12_RESOURCE_STATE_COPY_DEST,arrival);
            state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        }
        state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_SOURCE);
        state.Barrier(cmd,history.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        cmd->CopyResource(history.Get(),input.Get());
        TraceGpu("nr-history-update-record",history.Get(),reinterpret_cast<uintptr_t>(input.Get()));
        state.Barrier(cmd,history.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        state.Barrier(cmd,input.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        ++calls;
    }
};
static HistoryProvider* provider=nullptr;
static void TemporalHistoryRun(ID3D12GraphicsCommandList* cmd, ID3D12Resource* color, ID3D12Resource* output,
                               D3D12_RESOURCE_STATES arrival, ID3D12CommandQueue* queue,
                               D3D12_RESOURCE_STATES inputArrival)
{
    Expect(provider && queue==provider->fixture.queue.Get(),"TemporalOwnedRenderQueue");
    provider->Run(cmd,color,output,arrival,inputArrival);
}

static std::array<unsigned char,256> ReadPixels(Fixture& f, ID3D12Resource* texture,
                                               D3D12_RESOURCE_STATES arrival)
{
    const auto td=texture->GetDesc(); D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {}; UINT64 bytes=0;
    f.device->GetCopyableFootprints(&td,0,1,0,&fp,nullptr,nullptr,&bytes);
    D3D12_RESOURCE_DESC bd {}; bd.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width=bytes; bd.Height=1;
    bd.DepthOrArraySize=bd.MipLevels=1; bd.SampleDesc.Count=1; bd.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    D3D12_HEAP_PROPERTIES hp {}; hp.Type=D3D12_HEAP_TYPE_READBACK;
    ComPtr<ID3D12Resource> readback;
    Check(f.device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&bd,D3D12_RESOURCE_STATE_COPY_DEST,
        nullptr,IID_PPV_ARGS(&readback)));
    ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
    Check(f.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
    Check(f.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));
    f.owner._state->Barrier(cmd.Get(),texture,arrival,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION from {},to {};
    from.pResource=texture; from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    to.pResource=readback.Get(); to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; to.PlacedFootprint=fp;
    cmd->CopyTextureRegion(&to,0,0,0,&from,nullptr);
    f.owner._state->Barrier(cmd.Get(),texture,D3D12_RESOURCE_STATE_COPY_SOURCE,arrival);
    Check(cmd->Close()); ID3D12CommandList* lists[]={cmd.Get()}; f.queue->ExecuteCommandLists(1,lists); f.Drain();
    unsigned char* data=nullptr; Check(readback->Map(0,nullptr,reinterpret_cast<void**>(&data)));
    std::array<unsigned char,256> pixels {};
    for(unsigned y=0;y<8;++y) std::memcpy(pixels.data()+y*32,data+fp.Offset+y*fp.Footprint.RowPitch,32);
    readback->Unmap(0,nullptr); return pixels;
}
static void PaintScene(Fixture& f, ID3D12Resource* texture, D3D12_RESOURCE_STATES arrival, unsigned frame)
{
    ComPtr<ID3D12DescriptorHeap> heap; D3D12_DESCRIPTOR_HEAP_DESC hd {};
    hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors=1;
    Check(f.device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&heap)));
    auto rtv=heap->GetCPUDescriptorHandleForHeapStart(); f.device->CreateRenderTargetView(texture,nullptr,rtv);
    ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
    Check(f.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
    Check(f.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));
    f.owner._state->Barrier(cmd.Get(),texture,arrival,D3D12_RESOURCE_STATE_RENDER_TARGET);
    const float color[]={0.15f+float(frame%4)*0.02f,0.3f,0.4f,1};
    cmd->ClearRenderTargetView(rtv,color,0,nullptr);
    f.owner._state->Barrier(cmd.Get(),texture,D3D12_RESOURCE_STATE_RENDER_TARGET,arrival);
    Check(cmd->Close()); ID3D12CommandList* lists[]={cmd.Get()}; f.queue->ExecuteCommandLists(1,lists); f.Drain();
}
static void DirectPipeline(Fixture& f,ID3D12Resource* picture,bool beforeUpscale,uint64_t application)
{
    ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> cmd;
    Check(f.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
    Check(f.device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));
    f.params.Set(NVSDK_NGX_Parameter_Color,f.output.Get());
    ID3D12Resource* result=nullptr;
    D3D12_RESOURCE_STATES resultState=D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    if(beforeUpscale)
    {
        f.owner._state->Barrier(cmd.Get(),f.output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                               D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        result=PrepareDlssNrInput(f.owner,f.device.Get(),cmd.Get(),&f.params,0,f.queue.Get(),false,false,application);
        Expect(result!=nullptr,"TemporalActualBeforePipeline");
        f.owner._state->Barrier(cmd.Get(),f.output.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                               D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        resultState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    }
    else
    {
        ShaderPipeline_Dx12 pipeline;
        pipeline.push_back(MakeDlssNrPass(f.owner,f.device.Get(),cmd.Get(),&f.params,false,0,
                                         f.queue.Get(),false,false,application));
        auto* upstreamOutput=SetupShaderPipeline(pipeline,f.output.Get());
        Expect(upstreamOutput==f.owner.Buffer(),"TemporalActualUpscaledPipeline");
        f.owner._state->Barrier(cmd.Get(),f.output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        f.owner._state->Barrier(cmd.Get(),upstreamOutput,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_DEST);
        cmd->CopyResource(upstreamOutput,f.output.Get());
        f.owner._state->Barrier(cmd.Get(),f.output.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        f.owner._state->Barrier(cmd.Get(),upstreamOutput,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        Expect(DispatchShaderPipeline(pipeline),"TemporalActualUpscaledDispatch");
        result=f.output.Get();
    }
    TraceGpu("direct-output-to-application-record",result,reinterpret_cast<uintptr_t>(picture));
    f.owner._state->Barrier(cmd.Get(),result,resultState,D3D12_RESOURCE_STATE_COPY_SOURCE);
    f.owner._state->Barrier(cmd.Get(),picture,D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_DEST);
    DlssNr::CopyActiveColor(cmd.Get(),picture,result,{8,8});
    f.owner._state->Barrier(cmd.Get(),result,D3D12_RESOURCE_STATE_COPY_SOURCE,resultState);
    f.owner._state->Barrier(cmd.Get(),picture,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PRESENT);
    Check(cmd->Close()); f.allocators.push_back(allocator); f.producers.push_back(cmd);
    ID3D12CommandList* lists[]={cmd.Get()}; f.queue->ExecuteCommandLists(1,lists);
}
static void ShutdownOverlay(Fixture& f)
{
    f.Drain(); ImGui_ImplDX12_Shutdown(); ImGui::DestroyContext();
    g_pd3dSrvDescHeapAlloc.Destroy();
    CleanupRenderTargetDx12(true);
    if(g_pd3dCommandList) {g_pd3dCommandList->Release();g_pd3dCommandList=nullptr;}
    for(auto*& allocator:g_commandAllocators) if(allocator){allocator->Release();allocator=nullptr;}
    if(g_pd3dRtvDescHeap){g_pd3dRtvDescHeap->Release();g_pd3dRtvDescHeap=nullptr;}
    if(g_pd3dSrvDescHeap){g_pd3dSrvDescHeap->Release();g_pd3dSrvDescHeap=nullptr;}
    currentSCCommandQueue=nullptr; g_pd3dDeviceParam=nullptr; g_pd3dCommandQueue=nullptr;
}

int main(int argc,char** argv) try
{
    const bool fixedScene=argc==3 && std::strcmp(argv[2],"--fixed-scene")==0;
    const bool directPlacements=argc==3 && std::strcmp(argv[2],"--direct-placements")==0;
    Expect(argc==2 || fixedScene || directPlacements,"TemporalEvidenceArgument");
    std::ofstream evidence(argv[1]); Expect(bool(evidence),"TemporalEvidenceOpen");
    routeTrace.open(std::filesystem::path(argv[1]).parent_path()/"route-trace.jsonl");
    Expect(bool(routeTrace),"TemporalRouteTraceOpen");
    evidence<<"{\"scope\":\"actual owned compositor and Streamline wrapper; actual DX12 overlay submission;"
              " deterministic history provider and upstream identity copy; no NVIDIA SDK generation or private upscaler qualification\","
              "\"frames\":120,\"cases\":[";
    bool first=true;
    for(unsigned placement=directPlacements?0u:2u;placement<(directPlacements?2u:3u);++placement)
    for(unsigned route=0;route<2;++route) for(unsigned control=0;control<4;++control)
    {
        if(fixedScene && control!=1) continue;
        Fixture f;
        ComPtr<ID3D12CommandQueue> retainedQueue=f.queue;
        f.queue.Reset();
        f.queue.Attach(new ObservedQueue(retainedQueue.Get()));
        Check(f.chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey,f.queue.Get()));
        HistoryProvider history(f); provider=&history;
        Config::Instance()->DlssNrEnabled.stored=control!=3;
        Config::Instance()->DlssNrApplyModel.stored=control!=2;
        Config::Instance()->DlssNrFinishedPicture.stored=placement==2;
        Config::Instance()->DlssNrRunBeforeSr.stored=placement==0;
        Config::Instance()->DlssNrDeferredDlss.stored=false;
        Config::Instance()->DlssNrResidualAcrossRr.stored=false;
        overlayVisible=control!=1; uiDraws=0;
        ImGui::CreateContext(); ImGui::GetIO().IniFilename=nullptr;
        g_pd3dDeviceParam=f.device.Get(); currentSCCommandQueue=f.queue.Get(); _isInited=true; _dx12Device=true;
        RenderImGui_DX12(f.chain.Get()); f.Drain();
        RenderImGui_DX12(f.chain.Get()); f.Drain();
        Fg feature; feature.application=1;
        XeFG_Dx12 xefg;
        State::Instance().currentFG=&feature;
        State::Instance().currentFGSwapchain=f.chain.Get();
        State::Instance().currentCommandQueue=f.queue.Get();
        State::Instance().activeFgOutput=route ? FGOutput::XeFG : FGOutput::DLSSG;
        FGHooks::o_FGSCPresent=OwnedOriginal;
        FGHooks::o_FGSCPresent1=OwnedOriginal1;
        actualOriginalCalls=0;
        if(route)
        {
            State::Instance().currentFG=&feature; State::Instance().currentFGSwapchain=f.chain.Get();
            xefg._swapChain=f.chain.Get(); xefg._gameCommandQueue=f.queue.Get(); xefg.ResetNrHandoff();
            DlssNr::PublishFinishedConsumer(DlssNr::FinishedConsumer::XeFGAvailable);
            if(placement==2) feature.onPresent=[&]{ xefg.OwnedNrHandoff(); };
        }
        else
            Check(f.chain->SetPrivateDataInterface(DlssNr::StreamlinePicture::renderQueueKey,nullptr));
        ComPtr<ID3D12Resource> picture;
        unsigned previous=0, previousLeaks=0, inputLeaks=0, originalBefore=Plugin::forwards;
        for(unsigned frame=0;frame<120;++frame)
        {
            feature.application=frame+1; xefg._lastDispatchedFrame=frame+1; markerX=(frame%3)*2;
            Check(f.chain->GetBuffer(TemporalApplicationIndex(f.chain.Get()),IID_PPV_ARGS(&picture)));
            tracePicture=picture.Get();traceApplication=frame+1;traceSerial=0;traceNrCommands=nullptr;
            traceGeneration=DlssNr::StreamlinePicture::Consumer(f.chain.Get()).identity.generation;
            TraceGpu("application-texture-acquired",f.queue.Get());
            PaintScene(f,picture.Get(),D3D12_RESOURCE_STATE_PRESENT,fixedScene ? 0 : frame);
            const auto before=history.calls;
            if(control!=3 && placement!=2)
            {
                PaintScene(f,f.output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,frame);
                DirectPipeline(f,picture.Get(),placement==0,frame+1);
            }
            if(control!=3 && placement==2)
            {
                TraceGpu("capture-recording",f.queue.Get());
                f.Capture(true,nullptr,true,frame+1);
                for(const auto& slot:f.owner._state->late.slots)
                    if(slot.identity.application==frame+1 && slot.serial>traceSerial) traceSerial=slot.serial;
                TraceGpu("capture-enqueued",f.queue.Get());
            }
            const auto draws=uiDraws;
            HRESULT presentResult;
            DXGI_PRESENT_PARAMETERS parameters {};
            if(route)
            {
                bool skipped=false;
                presentResult=frame%2 ? f.present1(f.chain.Get(),0,0,&parameters,skipped)
                                      : f.present(f.chain.Get(),0,0,skipped);
            }
            else
                presentResult=FGHooks::FGPresent(f.chain.Get(),0,0,frame%2 ? &parameters : nullptr);
            Expect(presentResult==originalResult,"TemporalOriginalHRESULTPreserved");
            TraceGpu("original-present-return",f.chain.Get(),static_cast<uint32_t>(presentResult));
            f.Drain();
            TraceGpu("coupled-graph-complete",f.queue.Get());
            if(control!=3)
            {
                Expect(history.calls==before+1,"TemporalCurrentApplicationOnly");
                auto input=ReadPixels(f,history.input.Get(),D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                for(unsigned pixel=0;pixel<64;++pixel)
                    if(input[pixel*4]>200 && input[pixel*4+2]>200) ++inputLeaks;
            }
            Expect(uiDraws==draws+(overlayVisible?1:0),"TemporalAcceptedSurfaceDrawOnce");
            auto pixels=ReadPixels(f,picture.Get(),D3D12_RESOURCE_STATE_PRESENT);
            if(overlayVisible)
            {
                const auto at=(2*8+markerX)*4;
                Expect(pixels[at]>240 && pixels[at+1]<10 && pixels[at+2]>240,"TemporalCurrentMarkerVisible");
            }
            if(frame>0 && overlayVisible)
            {
                const auto at=(2*8+previous)*4;
                if(pixels[at]>100 && pixels[at+2]>150) ++previousLeaks;
            }
            previous=markerX;
        }
        Expect(inputLeaks==0,"TemporalInputExcludesOverlay");
        Expect(previousLeaks==0,"PreviousMarkerPositionClean");
        Expect(actualOriginalCalls==120,"TemporalOriginalCallbackOnce");
        if(route) Expect(Plugin::forwards==originalBefore+120,"TemporalStreamlineCallbackOnce");
        if(!first)evidence<<","; first=false;
        evidence<<"{\"route\":\""<<(route?"Streamline-XeFG-owned":"DLSS-owned")<<"\",\"control\":"<<control
                <<",\"placement\":\""<<(placement==0?"Before":placement==1?"Upscaled":"Present")<<"\""
                <<",\"frames\":120,\"providerCalls\":"<<history.calls<<",\"uiDraws\":"<<uiDraws
                <<",\"inputLeaks\":"<<inputLeaks<<",\"previousMarkerLeaks\":"<<previousLeaks<<"}";
        ShutdownOverlay(f); provider=nullptr;
        std::printf("TASK3_WARP_CASE placement=%u route=%u control=%u frames=120 inputLeaks=%u previousLeaks=%u\n",
            placement,route,control,inputLeaks,previousLeaks);
    }
    evidence<<"],\"fixedSceneAndGuides\":"<<(fixedScene?"true":"false")
            <<",\"nvidia\":\"NOT_RUN\",\"directBeforeUpscaled\":"<<(directPlacements?"true":"false")
            <<",\"privateSeparateEdit\":\"NOT_QUALIFIED\"}";
    std::puts("TASK3_WARP_BOUNDED_COMPLETE full_task3=NOT_PROVED");
    return 0;
}
catch(const std::exception& error)
{
    std::printf("TASK3_WARP_FAILURE=%s\n",error.what()); return 1;
}
