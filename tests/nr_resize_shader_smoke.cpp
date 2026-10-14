// Execute the shipped shader on WARP; no game, capture or NVIDIA runtime is loaded.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <optional>
#include <string>
#include <concepts>
#include <fstream>
#include <iterator>
#include <map>
#include <array>
#include "../OptiScaler/shaders/output_scaling/precompile/BCUS_Shader.h"
#include "../OptiScaler/shaders/output_scaling/precompile/BCDS_bicubic_Shader.h"
#ifdef NR_RECONSTRUCTION_HEADER
#include NR_RECONSTRUCTION_HEADER
#else
#include "../OptiScaler/shaders/dlssnr/DlssNr_Common.h"
#endif
#ifdef NR_CONFIG_OPTION_HEADER
#include NR_CONFIG_OPTION_HEADER
#endif
#include "../OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h"
#ifdef NR_FILTER_SHADER_HEADER
#include NR_FILTER_SHADER_HEADER
#else
#include "../OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h"
#endif
using Microsoft::WRL::ComPtr;
struct Pixel { float r, g, b, a; };
struct Image { unsigned w, h; std::vector<Pixel> pixels; };
struct IntegrationOperation
{
    unsigned kind, source, model, original, output, keep;
    DlssNrConstants constants;
};
struct IntegrationRecipe
{
    std::array<unsigned,13> header;
    std::vector<IntegrationOperation> operations;
};
std::vector<IntegrationRecipe> readRecipes(const char* path)
{
    std::ifstream file(path,std::ios::binary);
    if(!file.good()) throw std::runtime_error("T9_PIXEL: recipe-missing");
    unsigned magic=0,count=0;
    file.read(reinterpret_cast<char*>(&magic),4); file.read(reinterpret_cast<char*>(&count),4);
    if(magic!=0x39524e || count==0) throw std::runtime_error("T9_PIXEL: recipe-header");
    std::vector<IntegrationRecipe> recipes(count);
    for(auto& recipe:recipes)
    {
        file.read(reinterpret_cast<char*>(recipe.header.data()),13*4);
        recipe.operations.resize(recipe.header[12]);
        for(auto& op:recipe.operations)
        {
            unsigned edges[6] {};
            file.read(reinterpret_cast<char*>(edges),sizeof(edges));
            op.kind=edges[0]; op.source=edges[1]; op.model=edges[2];
            op.original=edges[3]; op.output=edges[4]; op.keep=edges[5];
            file.read(reinterpret_cast<char*>(&op.constants),sizeof(op.constants));
        }
    }
    if(!file.good()) throw std::runtime_error("T9_PIXEL: truncated-recipe");
    return recipes;
}
// Independent double-precision reference: integrate source cells for Area;
// interpolate around destination centres for Bilinear; select centre cells for Nearest.
Image filterReference(const Image& input, unsigned w, unsigned h, unsigned code)
{
    Image result {w,h,std::vector<Pixel>(size_t(w)*h)};
    const bool shrink=w<=input.w && h<=input.h && (w<input.w || h<input.h);
    if(!shrink) code=0;
    for(unsigned y=0;y<h;++y) for(unsigned x=0;x<w;++x)
    {
        const double cx=(x+.5)*input.w/w, cy=(y+.5)*input.h/h;
        const auto centre=input.pixels[std::min(unsigned(cy),input.h-1)*input.w+
                                       std::min(unsigned(cx),input.w-1)];
        double value[4] {};
        auto add=[&](unsigned sx,unsigned sy,double weight)
        {
            const auto p=input.pixels[sy*input.w+sx];
            value[0]+=p.r*weight; value[1]+=p.g*weight;
            value[2]+=p.b*weight; value[3]+=p.a*weight;
        };
        if(code==2) { result.pixels[y*w+x]=centre; continue; }
        if(code==1)
        {
            const double px=std::clamp(cx-.5,0.0,double(input.w-1));
            const double py=std::clamp(cy-.5,0.0,double(input.h-1));
            const unsigned ax=unsigned(px), ay=unsigned(py);
            const unsigned bx=std::min(ax+1,input.w-1), by=std::min(ay+1,input.h-1);
            const double fx=px-ax, fy=py-ay;
            add(ax,ay,(1-fx)*(1-fy)); add(bx,ay,fx*(1-fy));
            add(ax,by,(1-fx)*fy); add(bx,by,fx*fy);
        }
        else
        {
            const double left=double(x)*input.w/w, right=double(x+1)*input.w/w;
            const double top=double(y)*input.h/h, bottom=double(y+1)*input.h/h;
            for(unsigned sy=0;sy<input.h;++sy) for(unsigned sx=0;sx<input.w;++sx)
                add(sx,sy,std::max(0.0,std::min(right,double(sx+1))-std::max(left,double(sx)))*
                    std::max(0.0,std::min(bottom,double(sy+1))-std::max(top,double(sy)))/
                    ((right-left)*(bottom-top)));
            value[3]=centre.a;
        }
        result.pixels[y*w+x]={float(value[0]),float(value[1]),float(value[2]),float(value[3])};
    }
    return result;
}
float halfValue(unsigned short bits)
{
    const unsigned exponent=(bits>>10)&31, mantissa=bits&1023;
    const float value=exponent ? std::ldexp(1.0f+mantissa/1024.0f,int(exponent)-15)
                              : std::ldexp(float(mantissa),-24);
    return bits&32768 ? -value : value;
}
void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("D3D11 call failed"); }
void expect(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
float linear(float v) { return v <= .04045f ? v / 12.92f : std::pow((v + .055f) / 1.055f, 2.4f); }
float srgb(float v) { return v <= .0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - .055f; }
float difference(const Image& a, const Image& b)
{
    float error = 0;
    for (size_t i = 0; i < a.pixels.size(); ++i)
    {
        const auto x = a.pixels[i], y = b.pixels[i];
        expect(std::isfinite(x.r) && std::isfinite(x.g) && std::isfinite(x.b), "Non-finite reconstruction");
        error = std::max({error, std::abs(x.r-y.r), std::abs(x.g-y.g), std::abs(x.b-y.b), std::abs(x.a-y.a)});
    }
    return error;
}
Image modelAnswer(Image image, bool hdr, float gain, float colour)
{
    for (auto& p : image.pixels)
    {
        if (hdr) { p.r=linear(p.r); p.g=linear(p.g); p.b=linear(p.b); }
        float y = .2126f*p.r + .7152f*p.g + .0722f*p.b;
        p.r = gain * (p.r + colour*y); p.b = gain * (p.b - colour*y);
        p.g = (gain*y - .2126f*p.r - .0722f*p.b) / .7152f;
        if (hdr) { p.r=srgb(p.r); p.g=srgb(p.g); p.b=srgb(p.b); }
    }
    return image;
}
// Reuse the active-colour fixture's production copy seam, with the actual shader's pixels,
// not a constant standing in for composition. Both UAV and non-UAV game allocations stay readable.
Image copyBack(const Image& original, const Image& composed, bool uav, bool cropped, bool success)
{
    ComPtr<IDXGIFactory4> factory; check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    ComPtr<IDXGIAdapter> warp; check(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)));
    ComPtr<ID3D12Device> device;
    check(D3D12CreateDevice(warp.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)));
    D3D12_RESOURCE_DESC td {};
    td.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width=original.w+(cropped ? 4 : 0); td.Height=original.h+(cropped ? 2 : 0);
    td.DepthOrArraySize=td.MipLevels=1; td.SampleDesc.Count=1;
    td.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
    const auto active=DlssNr::PreSrColorExtent(td,original.w,original.h);
    expect(active.has_value(),"Task24 active extent rejected");
    auto create=[&](D3D12_RESOURCE_DESC desc,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state)
    {
        D3D12_HEAP_PROPERTIES heap {}; heap.Type=type;
        ComPtr<ID3D12Resource> resource;
        check(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&resource)));
        return resource;
    };
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint {}; UINT64 bytes=0;
    device->GetCopyableFootprints(&td,0,1,0,&footprint,nullptr,nullptr,&bytes);
    auto buffer=[&](bool readback)
    {
        D3D12_RESOURCE_DESC bd {}; bd.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width=bytes;
        bd.Height=1; bd.DepthOrArraySize=bd.MipLevels=1; bd.SampleDesc.Count=1;
        bd.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        return create(bd,readback ? D3D12_HEAP_TYPE_READBACK : D3D12_HEAP_TYPE_UPLOAD,
                      readback ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_GENERIC_READ);
    };
    auto originalUpload=buffer(false), composedUpload=buffer(false), readback=buffer(true);
    const Pixel padding {9,8,7,.125f};
    for(auto* upload : {originalUpload.Get(),composedUpload.Get()})
    {
        char* memory=nullptr; D3D12_RANGE noRead {0,0}; check(upload->Map(0,&noRead,(void**)&memory));
        const auto& image=upload==originalUpload.Get() ? original : composed;
        for(unsigned y=0;y<td.Height;++y) for(unsigned x=0;x<td.Width;++x)
            reinterpret_cast<Pixel*>(memory+y*footprint.Footprint.RowPitch)[x]=
                x<image.w && y<image.h ? image.pixels[y*image.w+x] : padding;
        upload->Unmap(0,nullptr);
    }
    td.Flags=uav ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE;
    auto game=create(td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
    td.Width=original.w; td.Height=original.h; td.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    auto compact=create(td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
    ComPtr<ID3D12CommandQueue> queue; D3D12_COMMAND_QUEUE_DESC q {};
    check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
    ComPtr<ID3D12CommandAllocator> allocator;
    check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
    ComPtr<ID3D12GraphicsCommandList> commands;
    check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)));
    auto transition=[&](ID3D12Resource* resource,D3D12_RESOURCE_STATES from,D3D12_RESOURCE_STATES to)
    {
        D3D12_RESOURCE_BARRIER b {}; b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition.pResource=resource; b.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore=from; b.Transition.StateAfter=to; commands->ResourceBarrier(1,&b);
    };
    auto location=[](ID3D12Resource* resource)
    {
        D3D12_TEXTURE_COPY_LOCATION result {}; result.pResource=resource;
        result.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; return result;
    };
    auto src=location(originalUpload.Get()), dst=location(game.Get());
    src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint=footprint;
    commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    const auto arrival=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    transition(game.Get(),D3D12_RESOURCE_STATE_COPY_DEST,arrival);
    src=location(composedUpload.Get()); src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint=footprint; dst=location(compact.Get());
    const D3D12_BOX box {0,0,0,original.w,original.h,1};
    commands->CopyTextureRegion(&dst,0,0,0,&src,&box);
    transition(compact.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    if(success)
    {
        transition(compact.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        transition(game.Get(),arrival,D3D12_RESOURCE_STATE_COPY_DEST);
        DlssNr::CopyActiveColor(commands.Get(),game.Get(),compact.Get(),*active);
        transition(game.Get(),D3D12_RESOURCE_STATE_COPY_DEST,arrival);
        transition(compact.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    }
    transition(game.Get(),arrival,D3D12_RESOURCE_STATE_COPY_SOURCE);
    src=location(game.Get()); dst=location(readback.Get());
    dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint=footprint;
    commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
    transition(game.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,arrival);
    check(commands->Close());
    ComPtr<ID3D12Fence> fence; check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
    HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr); expect(event!=nullptr,"Task24 fence event");
    // Subscribe before submission; no polling or fixed sleep.
    const auto armed=fence->SetEventOnCompletion(1,event);
    if(FAILED(armed)) { CloseHandle(event); check(armed); }
    ID3D12CommandList* lists[]={commands.Get()}; queue->ExecuteCommandLists(1,lists);
    const auto signalled=queue->Signal(fence.Get(),1);
    if(FAILED(signalled)) { CloseHandle(event); check(signalled); }
    const auto waited=WaitForSingleObject(event,30000); CloseHandle(event);
    expect(waited==WAIT_OBJECT_0,"Task24 copy-back fence timeout");
    char* memory=nullptr; D3D12_RANGE read {0,SIZE_T(bytes)}; check(readback->Map(0,&read,(void**)&memory));
    Image result {original.w,original.h,std::vector<Pixel>(original.pixels.size())};
    bool paddingOk=true;
    for(unsigned y=0;y<footprint.Footprint.Height;++y) for(unsigned x=0;x<footprint.Footprint.Width;++x)
    {
        const auto p=reinterpret_cast<const Pixel*>(memory+y*footprint.Footprint.RowPitch)[x];
        if(x<original.w && y<original.h) result.pixels[y*original.w+x]=p;
        else paddingOk &= p.r==padding.r && p.g==padding.g && p.b==padding.b && p.a==padding.a;
    }
    D3D12_RANGE noWrite {0,0}; readback->Unmap(0,&noWrite);
    expect(paddingOk,"Task24 copy-back overwrote allocation padding");
    return result;
}

void contracts()
{
    unsigned cases=0;
    for(bool before : {false,true}) for(unsigned requested : {0u,1u,2u,3u,4u})
        for(float scale : {.65f,1.0f,1.25f})
    {
        const auto r=DlssNrResolveReconstruction(requested,before,scale!=1,scale);
        const bool privateExpected=!before && (requested==2 || requested==4) && scale!=1 &&
                                   (requested==2 || scale<1);
        expect(r.requested==requested && r.privateEnlargement==privateExpected,"Task24 private eligibility");
        expect(r.effective==(privateExpected ? requested : DlssNrSpatialTransfer(requested)),
               "Task24 effective reconstruction");
        expect(r.compatibilityFallback==(before && (requested==2 || requested==4) && scale!=1 &&
                                          (requested==2 || scale<1)),"Task24 compatibility notice");
        for(bool privateReady : {false,true}) for(bool shaderReady : {false,true})
        {
            unsigned enlarged=0,composed=0;
            const bool ok=DlssNrComposeReconstruction(r,[&](){++enlarged;return privateReady;},
                                                      [&](){++composed;return shaderReady;});
            expect(enlarged==(privateExpected ? 1u : 0u),"Task24 private invoked before SR");
            expect(composed==(!privateExpected || privateReady ? 1u : 0u),"Task24 composition gate");
            expect(ok==((!privateExpected || privateReady) && shaderReady),"Task24 failure swallowed");
            ++cases;
        }
#ifdef NR_CONFIG_OPTION_HEADER
        // The real persistence option supplies save/reload values; resolving a frame must not assign it.
        CustomOptional<uint32_t> option(0);
        option.set_from_config(requested);
        const auto saved=option.value_for_config();
        const auto effective=DlssNrResolveReconstruction(option.value_or_default(),true,scale!=1,scale);
        (void)effective;
        expect(option.value_for_config()==saved,"Task24 request changed during resolution");
        CustomOptional<uint32_t> reloaded(0); reloaded.set_from_config(saved);
        expect(reloaded.value_or_default()==requested,"Task24 persistence lost requested transfer");
        const bool postPrivate=(requested==2 || requested==4) && scale!=1 && (requested==2 || scale<1);
        expect(DlssNrResolveReconstruction(reloaded.value_or_default(),false,scale!=1,scale).privateEnlargement==
               postPrivate,"Task24 post restoration");
#endif
    }
    std::printf("PASS: Task24 %u production decision contracts; persistence option save/reload\n",cases);
}

int main(int argc, char** argv)
try
{
    if(argc==2 && std::string(argv[1])=="--contracts") { contracts(); return 0; }
    const bool filtersOnly=argc==3 && std::string(argv[1])=="--filters";
    const bool integrationOnly=argc==5 && std::string(argv[1])=="--integration";
    if(argc==2 || filtersOnly || integrationOnly)
    {
        std::ifstream file(argv[filtersOnly || integrationOnly ? 2 : 1],std::ios::binary);
        expect(file.good(),"Fresh shader binary missing");
        const std::vector<unsigned char> fresh((std::istreambuf_iterator<char>(file)),{});
        expect(fresh.size()==sizeof(DlssNr_cso) &&
               std::equal(fresh.begin(),fresh.end(),DlssNr_cso),"Shipped shader differs from current fxc output");
        std::puts("PASS: current HLSL fxc output equals shipped shader byte-for-byte");
    }
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> ctx;
    check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, nullptr, 0,
                           D3D11_SDK_VERSION, &device, nullptr, &ctx));
    ComPtr<ID3D11ComputeShader> shader;
    check(device->CreateComputeShader(DlssNr_cso, sizeof(DlssNr_cso), nullptr, &shader));
    ComPtr<ID3D11ComputeShader> osUp,osDown;
    if(integrationOnly)
    {
        check(device->CreateComputeShader(bcus_cso,sizeof(bcus_cso),nullptr,&osUp));
        check(device->CreateComputeShader(bcds_bicubic_cso,sizeof(bcds_bicubic_cso),nullptr,&osDown));
    }
    D3D11_BUFFER_DESC bd {}; bd.ByteWidth=sizeof(DlssNrConstants); bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
    ComPtr<ID3D11Buffer> cb; check(device->CreateBuffer(&bd, nullptr, &cb));
    D3D11_SAMPLER_DESC sd {}; sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP; sd.MaxLOD=D3D11_FLOAT32_MAX;
    ComPtr<ID3D11SamplerState> sampler; check(device->CreateSamplerState(&sd, &sampler));
    auto run = [&](const DlssNrConstants& c, const Image& source, const Image& model, const Image& original,
                   bool fp16=false, unsigned os=0)
    {
        expect(c.Width && c.Height && source.w && source.h,"T8_FILTER: zero-dispatch-rejected");
        ComPtr<ID3D11Texture2D> textures[4], target, keep, staging;
        ComPtr<ID3D11ShaderResourceView> views[4];
        const Image* inputs[] = { &source, &model, &original, &original };
        D3D11_TEXTURE2D_DESC td {}; td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;
        td.Format=DXGI_FORMAT_R32G32B32A32_FLOAT; td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        for (unsigned i=0; i<4; ++i)
        {
            td.Width=inputs[i]->w; td.Height=inputs[i]->h;
            D3D11_SUBRESOURCE_DATA data { inputs[i]->pixels.data(), td.Width*sizeof(Pixel), 0 };
            check(device->CreateTexture2D(&td, &data, &textures[i]));
            check(device->CreateShaderResourceView(textures[i].Get(), nullptr, &views[i]));
        }
        td.Width=c.Width; td.Height=c.Height; td.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        if(fp16) td.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;
        const bool guarded=filtersOnly && !fp16;
        if(guarded) { td.Width+=2; td.Height+=2; }
        std::vector<Pixel> padding(size_t(td.Width)*td.Height,Pixel{9,8,7,.625f});
        D3D11_SUBRESOURCE_DATA sentinel {padding.data(),td.Width*sizeof(Pixel),0};
        check(device->CreateTexture2D(&td, guarded ? &sentinel : nullptr, &target));
        check(device->CreateTexture2D(&td, nullptr, &keep));
        ComPtr<ID3D11UnorderedAccessView> uav, keepUav;
        check(device->CreateUnorderedAccessView(target.Get(), nullptr, &uav));
        check(device->CreateUnorderedAccessView(keep.Get(), nullptr, &keepUav));
        td.Usage=D3D11_USAGE_STAGING; td.BindFlags=0; td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        check(device->CreateTexture2D(&td, nullptr, &staging));
        ID3D11ShaderResourceView* srv[] = {views[0].Get(), views[1].Get(), views[2].Get(), views[3].Get()};
        ID3D11UnorderedAccessView* outputs[] = {uav.Get(), keepUav.Get()};
        auto uploaded=c;
        if(os)
        {
            uploaded={};
            const unsigned sizes[]={source.w,source.h,c.Width,c.Height};
            memcpy(&uploaded,sizes,sizeof(sizes)); // Actual OS Constants: four int32, 256-byte buffer.
        }
        ctx->UpdateSubresource(cb.Get(),0,nullptr,&uploaded,0,0);
        ctx->CSSetShader(os==1 ? osUp.Get() : os==2 ? osDown.Get() : shader.Get(),nullptr,0);
        ctx->CSSetConstantBuffers(0,1,cb.GetAddressOf());
        ctx->CSSetSamplers(0,1,sampler.GetAddressOf()); ctx->CSSetShaderResources(0,4,srv);
        ctx->CSSetUnorderedAccessViews(0,2,outputs,nullptr);
        const unsigned threads=os==1 ? 16u : 8u;
        ctx->Dispatch((c.Width+threads-1)/threads,(c.Height+threads-1)/threads,1);
        ctx->CopyResource(staging.Get(),target.Get()); D3D11_MAPPED_SUBRESOURCE mapped {};
        check(ctx->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
        Image result {c.Width,c.Height,std::vector<Pixel>(size_t(c.Width)*c.Height)};
        for (unsigned y=0; y<c.Height; ++y)
        {
            const auto* row=static_cast<char*>(mapped.pData)+y*mapped.RowPitch;
            if(!fp16) memcpy(result.pixels.data()+y*c.Width,row,c.Width*sizeof(Pixel));
            else for(unsigned x=0;x<c.Width;++x)
            {
                const auto* p=reinterpret_cast<const unsigned short*>(row)+4*x;
                result.pixels[y*c.Width+x]={halfValue(p[0]),halfValue(p[1]),halfValue(p[2]),halfValue(p[3])};
            }
        }
        bool boundsOk=true;
        if(guarded) for(unsigned y=0;y<td.Height;++y) for(unsigned x=0;x<td.Width;++x)
        {
            if(x<c.Width && y<c.Height) continue;
            const auto p=reinterpret_cast<const Pixel*>(static_cast<char*>(mapped.pData)+y*mapped.RowPitch)[x];
            boundsOk &= p.r==9 && p.g==8 && p.b==7 && p.a==.625f;
        }
        expect(boundsOk,"T8_FILTER: dispatch-bounds-sentinel");
        ctx->Unmap(staging.Get(),0); ctx->ClearState(); return result;
    };
    if(integrationOnly)
    {
        const auto candidate=readRecipes(argv[3]),baseline=readRecipes(argv[4]);
        using Key=std::array<unsigned,10>;
        std::map<Key,std::array<Image,2>> oldPixels;
        const auto key=[](const IntegrationRecipe& recipe) {
            Key value {}; std::copy_n(recipe.header.begin()+1,10,value.begin()); return value;
        };
        unsigned pixelCases=0,zeroCases=0,preservedCases=0,downLegCases=0,pairedEditCases=0;
        float worstReference=0,worstZero=0,worstPreservation=0,measuredSuperDelta=0;
        float worstPairedEdit=0,measuredLegacyReplaceDelta=0;
        auto execute=[&](const IntegrationRecipe& recipe,bool fp16,bool verify)
        {
            const auto& h=recipe.header;
            Image original {h[1],h[2],std::vector<Pixel>(size_t(h[1])*h[2])};
            for(unsigned y=0;y<original.h;++y) for(unsigned x=0;x<original.w;++x)
            {
                const float v=x<2 ? .024f : .25f+.05f*float((x+2*y)%7);
                original.pixels[y*original.w+x]={v,.7f*v,.4f*v,float((x+3*y)%5)/4};
            }
            std::map<unsigned,Image> resources {{h[11],original}};
            for(const auto& op:recipe.operations)
            {
                expect(op.constants.SignalEncoding==0,"T9_PIXEL: reserved-signal-zero");
                const auto& source=resources.at(op.source);
                if(op.kind==1)
                {
                    auto answer=h[9]==3 ? modelAnswer(source,h[7]!=0,.85f,.02f) : source;
                    for(auto& p:answer.pixels) p.a=0;
                    resources[op.output]=std::move(answer);
                    continue;
                }
                if(op.kind==4) { resources[op.output]=source; continue; }
                const auto& model=op.model ? resources.at(op.model) : source;
                const auto& base=op.original ? resources.at(op.original) : original;
                if(verify && h[9]==0 && op.kind==0 && op.constants.Mode==DlssNrMode_Resolve &&
                    source.w==model.w && source.h==model.h)
                {
                    bool sameRgb=true;
                    for(size_t i=0;i<source.pixels.size();++i)
                        sameRgb &= source.pixels[i].r==model.pixels[i].r &&
                                   source.pixels[i].g==model.pixels[i].g &&
                                   source.pixels[i].b==model.pixels[i].b;
                    // The successful old supernative down-leg deliberately has
                    // differently resampled pictures. Only a matched model pair
                    // has the zero-artificial-edit contract.
                    const bool successfulDown=(h[3]>h[1] || h[4]>h[2]) && h[10]==0;
                    if(!successfulDown)
                    {
                        expect(sameRgb,"T9_PIXEL: identical-model-reference-rgb");
                        auto debug=op.constants; debug.DebugView=3;
                        const auto residual=run(debug,source,model,base,fp16);
                        Image neutral=residual;
                        for(auto& p:neutral.pixels) p.r=p.g=p.b=linear(.5f)*debug.DebugScale;
                        const float error=difference(residual,neutral);
                        worstPairedEdit=std::max(worstPairedEdit,error);
                        expect(error<=(fp16 ? 2e-3f : 1e-5f),"T9_PIXEL: paired-artificial-edit-zero");
                        ++pairedEditCases;
                    }
                }
                auto result=run(op.constants,source,model,base,fp16,
                                op.kind==2 ? 1u : op.kind==3 ? 2u : 0u);
                if(verify && op.kind==0 && op.constants.Mode==DlssNrMode_Downsample)
                {
                    const float error=difference(result,filterReference(source,result.w,result.h,
                                                                       op.constants.InputFilter));
                    worstReference=std::max(worstReference,error);
                    expect(error<=(fp16 ? 2e-3f : 1e-5f),"T9_PIXEL: independent-minifier-reference");
                }
                resources[op.output]=std::move(result);
                if(op.keep) resources[op.keep]=source;
            }
            auto output=resources.at(h[11]);
            if(verify)
            {
                const bool reduced=h[3]<h[1] || h[4]<h[2];
                const bool super=h[3]>h[1] || h[4]>h[2];
                // ApplyModel off is an exact bypass. Strength zero is also a
                // bypass in composed modes, but existing HDR replace modes
                // deliberately decode the low-resolution model directly.
                // Their final image is not a universal identity expectation.
                const bool replace=h[7]!=0 && (h[8]==2 || h[8]==4);
                if(h[9]==1 || (h[9]==2 && !replace))
                {
                    const float error=difference(output,original); worstZero=std::max(worstZero,error);
                    if(error>(fp16 ? 2e-3f : 1e-6f))
                    {
                        const auto old=oldPixels.find(key(recipe));
                        const float oldDelta=old==oldPixels.end() ? -1 :
                            difference(old->second[fp16 ? 1 : 0],original);
                        const float oldDifference=old==oldPixels.end() ? -1 :
                            difference(output,old->second[fp16 ? 1 : 0]);
                        std::printf("T9_ZERO_DIAGNOSTIC id=%u shape=%ux%u->%ux%u filter=%u transfer=%u hdr=%u "
                            "curve=%u noedit=%u branch=%u format=%s error=%.9g firstOriginal=%.9g "
                            "firstOutput=%.9g oldDelta=%.9g candidateVsOld=%.9g\n",
                            h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8],h[9],
                            h[10],fp16 ? "FP16" : "R32",error,original.pixels[0].r,output.pixels[0].r,
                            oldDelta,oldDifference);
                    }
                    expect(error<=(fp16 ? 2e-3f : 1e-6f),"T9_PIXEL: matched-pair-zero-residual");
                    ++zeroCases;
                }
                if(h[9]==0 && super && h[10]==0)
                { measuredSuperDelta=std::max(measuredSuperDelta,difference(output,original)); ++downLegCases; }
                if(h[9]==0 && reduced && replace)
                    measuredLegacyReplaceDelta=std::max(measuredLegacyReplaceDelta,difference(output,original));
                for(size_t i=0;i<output.pixels.size();++i)
                    expect(output.pixels[i].a==original.pixels[i].a,"T9_PIXEL: original-alpha");
                if(!reduced || h[5]==0)
                {
                    const auto old=oldPixels.find(key(recipe));
                    expect(old!=oldPixels.end(),"T9_PIXEL: old-branch-baseline-missing");
                    const float error=difference(output,old->second[fp16 ? 1 : 0]);
                    worstPreservation=std::max(worstPreservation,error);
                    expect(error==0,"T9_PIXEL: old-area-native-supernative-preservation");
                    ++preservedCases;
                }
                ++pixelCases;
                std::printf("T9_PIXEL id=%u shape=%ux%u->%ux%u filter=%u transfer=%u hdr=%u curve=%u "
                    "noedit=%u branch=%u format=%s\n",h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8],
                    h[9],h[10],fp16 ? "FP16" : "R32");
            }
            return output;
        };
        for(const auto& recipe:baseline)
            for(bool fp16:{false,true}) oldPixels[key(recipe)][fp16 ? 1 : 0]=execute(recipe,fp16,false);
        for(const auto& recipe:candidate)
            for(bool fp16:{false,true}) execute(recipe,fp16,true);
        std::printf("T9_PIXEL_PASS comparisons=%u bypass=%u paired-zero-edit=%u baseline-preserved=%u "
            "successful-downleg=%u maxReference=%.9g maxBypass=%.9g maxPairedEdit=%.9g "
            "maxPreservation=%.9g measuredLegacySuperDelta=%.9g measuredLegacyReplaceDelta=%.9g resources=RAII\n",
            pixelCases,zeroCases,pairedEditCases,preservedCases,downLegCases,worstReference,worstZero,
            worstPairedEdit,worstPreservation,measuredSuperDelta,measuredLegacyReplaceDelta);
        return 0;
    }
    if(filtersOnly)
    {
        unsigned cases=0; float worst32=0,worst16=0;
        for(const auto shape : {std::vector<unsigned>{5,1,2,1}, {1,5,1,2}, {7,5,3,2},
                                {9,7,4,3}, {1,1,1,1}, {5,3,5,3}, {3,2,5,4}, {5,3,2,4}})
        for(unsigned pattern=0;pattern<4;++pattern) for(unsigned code=0;code<3;++code)
        {
            Image input {shape[0],shape[1],std::vector<Pixel>(size_t(shape[0])*shape[1])};
            for(unsigned y=0;y<input.h;++y) for(unsigned x=0;x<input.w;++x)
            {
                const float v=pattern==0 ? .375f : pattern==1 ? (x>=2 ? 1.0f : 0.0f) :
                    pattern==2 ? float(x+2*y)/float(std::max(1u,input.w+2*input.h-3)) :
                    (x==0 || y==0 || x+1==input.w || y+1==input.h ? .875f : .125f);
                input.pixels[y*input.w+x]={v,.25f*v,.5f*v,float((x+3*y)%5)/4};
            }
            DlssNrConstants c {}; c.Mode=DlssNrMode_Downsample; c.Width=shape[2]; c.Height=shape[3];
            DlssNr_Common::SetInputFilter(c,input.w,input.h,code,true);
            const bool eligible=c.Width<=input.w && c.Height<=input.h &&
                (c.Width<input.w || c.Height<input.h);
            expect(c.InputFilter==(eligible ? code : 0u) && c.SignalEncoding==0,
                   "T8_FILTER: production-cbuffer-selection");
            const auto reference=filterReference(input,c.Width,c.Height,code);
            for(bool fp16 : {false,true})
            {
                const auto output=run(c,input,input,input,fp16);
                const float error=difference(output,reference);
                if(fp16) worst16=std::max(worst16,error); else worst32=std::max(worst32,error);
                expect(error<=(fp16 ? 2e-3f : 1e-5f),"T8_FILTER: independent-reference");
                std::printf("T8_PIXEL shape=%ux%u->%ux%u pattern=%u code=%u effective=%u format=%s error=%.9g\n",
                    input.w,input.h,c.Width,c.Height,pattern,code,c.InputFilter,fp16 ? "FP16" : "R32",error);
                ++cases;
            }
            // Analytic five-to-two: Area step [0.2,1], ramp [0.2,0.8];
            // Bilinear step [0,1], ramp [0.1875,0.8125]; Nearest ramp [0.25,0.75].
            if(input.w==5 && input.h==1 && (pattern==1 || pattern==2))
            {
                const float first=pattern==1 ? (code==0 ? .2f : 0.0f) :
                    (code==0 ? .2f : code==1 ? .1875f : .25f);
                const float last=pattern==1 ? 1.0f :
                    (code==0 ? .8f : code==1 ? .8125f : .75f);
                expect(std::abs(reference.pixels[0].r-first)<1e-6f &&
                       std::abs(reference.pixels[1].r-last)<1e-6f,"T8_FILTER: analytic-five-to-two");
            }
            auto legacy=c; legacy.InputFilter=0;
            auto disabled=c;
            DlssNr_Common::SetInputFilter(disabled,input.w,input.h,code,false);
            expect(disabled.InputFilter==0 && difference(run(disabled,input,input,input),
                run(legacy,input,input,input))==0,"T8_FILTER: unsupported-legacy-zero");
            if(!eligible || code==0)
            {
                auto forced=c; forced.InputFilter=code;
                expect(difference(run(forced,input,input,input),run(legacy,input,input,input))==0,
                       "T8_FILTER: copy-enlarge-default-area-equivalence");
            }
            // Final composition alpha is the original, not the filtered/model alpha.
            auto resolve=c; resolve.Mode=DlssNrMode_Resolve; resolve.Width=input.w; resolve.Height=input.h;
            resolve.Passthrough=resolve.ApplyModel=1; resolve.Transfer=0; resolve.WhitePoint=1;
            resolve.TransferStrength=resolve.ColourStrength=1; resolve.MaxRatio=8; resolve.CompareZoom=1;
            const auto proxy=run(c,input,input,input);
            auto model=proxy; for(auto& p:model.pixels) { p.r*=.8f; p.a=0; }
            const auto final=run(resolve,proxy,model,input);
            for(size_t i=0;i<final.pixels.size();++i)
                expect(final.pixels[i].a==input.pixels[i].a,"T8_FILTER: original-final-alpha");
        }
        for(unsigned axis=0;axis<4;++axis)
        {
            DlssNrConstants c {}; c.Width=c.Height=1;
            unsigned sw=2,sh=2;
            if(axis==0) c.Width=0; if(axis==1) c.Height=0;
            if(axis==2) sw=0; if(axis==3) sh=0;
            DlssNr_Common::SetInputFilter(c,sw,sh,2,true);
            expect(c.InputFilter==0,"T8_FILTER: zero-extent-selection");
        }
        DlssNrConstants zero {}; Image one {1,1,{Pixel{1,1,1,1}}}; bool rejected=false;
        try { run(zero,one,one,one); } catch(const std::runtime_error& e) {
            rejected=std::string(e.what())=="T8_FILTER: zero-dispatch-rejected";
        }
        expect(rejected,"T8_FILTER: zero-dispatch-admission");
        std::printf("T8_FILTER_PASS cases=%u maxR32=%.9g maxFP16=%.9g alpha=original resources=RAII\n",
                    cases,worst32,worst16);
        return 0;
    }
    Image original {100,8,std::vector<Pixel>(800)};
    for (unsigned y=0; y<8; ++y) for (unsigned x=0; x<100; ++x)
        original.pixels[y*100+x] = x<51 ? Pixel{.024f,.018f,.012f,.4f} : Pixel{.65f,.36f,.24f,.8f};
    unsigned cases=0; float worst=0, legacyHalo=0;
    for (unsigned hdr : {0u,1u}) for (unsigned curve=0; curve<5; ++curve)
    {
        DlssNrConstants c {}; c.Width=100; c.Height=8; c.Mode=DlssNrMode_Encode;
        c.Passthrough=!hdr; c.WhitePoint=1; c.ReversibleMode=curve; c.MaxRatio=8;
        c.TransferStrength=c.ColourStrength=1; c.ApplyModel=1; c.CompareZoom=1;
        const auto full = run(c,original,original,original);
        for (float gain : {.75f,1.0f,1.15f}) for (float colour : {0.0f,.05f})
        {
            const auto nativeAnswer=modelAnswer(full,hdr!=0,gain,colour);
            c.Mode=DlssNrMode_Resolve; c.Transfer=0;
            const auto reference=run(c,full,nativeAnswer,original);
            for (unsigned percent : {25u,65u,99u,100u,101u})
            {
                auto work=c; work.Width=percent; work.Height=std::max(2u,8*percent/100);
                work.Mode=DlssNrMode_Downsample;
                const auto proxy=run(work,full,full,original);
                const auto answer=modelAnswer(proxy,hdr!=0,gain,colour);
                c.Transfer=3;
                auto reconstructed=run(c,proxy,answer,original);
                if (percent<100)
                {
                    float error=difference(reconstructed,reference); worst=std::max(worst,error);
                    if (error>.0004f) std::printf("hdr=%u curve=%u gain=%g colour=%g scale=%u error=%g\n",hdr,curve,gain,colour,percent,error);
                    expect(error<.0004f,"Separated resize changed a uniform lighting/chroma edit at the hair/skin edge");
                    c.Transfer=1; const auto legacy=run(c,proxy,answer,original);
                    legacyHalo=std::max(legacyHalo,difference(legacy,reference));
                    c.Transfer=3; c.ApplyModel=0;
                    expect(difference(run(c,proxy,answer,original),original)<1e-6f,"Bypass changed the source frame");
                    c.ApplyModel=1;
                    // Carrier encoding and full-size carrier consumption, without proprietary DLSS.
                    work.Mode=DlssNrMode_EncodeResizeField;
                    const auto field=run(work,proxy,answer,original);
                    Image enlarged {100,8,std::vector<Pixel>(800,field.pixels[field.pixels.size()/2])};
                    c.Transfer=4;
                    expect(difference(run(c,field,enlarged,original),reference)<.0005f,"Private carrier reconstruction mismatch");
                    std::fill(enlarged.pixels.begin(),enlarged.pixels.end(),Pixel{2,-1,3,1});
                    expect(difference(run(c,field,enlarged,original),reference)<.0005f,"Private carrier range guard failed");
                }
                else
                {
                    c.Transfer=0;
                    expect(difference(reconstructed,run(c,proxy,answer,original))<1e-6f,"Native/supersampled path changed");
                }
                ++cases;
            }
        }
    }
    expect(legacyHalo>.01f,"Fixture did not reproduce the old resize mismatch");
    DlssNrConstants black {}; black.Mode=DlssNrMode_Resolve; black.Width=100; black.Height=8;
    black.Passthrough=black.ApplyModel=1; black.ReversibleMode=2; black.Transfer=3;
    Image blackFrame {100,8,std::vector<Pixel>(800,Pixel{0,0,0,1})};
    Image blackProxy {25,2,std::vector<Pixel>(50,Pixel{0,0,0,1})};
    Image brightAnswer {25,2,std::vector<Pixel>(50,Pixel{.3f,.2f,.1f,1})};
    expect(difference(run(black,blackProxy,brightAnswer,blackFrame),blackFrame)==0,
           "Relative reconstruction created light at true black");
    std::printf("PASS: %u resize fixtures; max reconstruction error %.7f, old resize mismatch %.7f\n",cases,worst,legacyHalo);
    expect(DlssNrSpatialTransfer(2)==1 && DlssNrSpatialTransfer(4)==3 && DlssNrSpatialTransfer(0)==0,
           "Transfer routing changed");
    unsigned repairCases=0;
    for(unsigned requested : {2u,4u}) for(float scale : {.65f,1.0f,1.25f})
        for(bool uav : {false,true}) for(bool cropped : {false,true})
        for(unsigned outcome : {0u,1u,2u,3u}) // visible, hidden, model failure, shader failure
    {
        Image active {17,9,std::vector<Pixel>(153,Pixel{.2f,.3f,.4f,.625f})};
        DlssNrConstants c {}; c.Width=active.w; c.Height=active.h; c.Mode=DlssNrMode_Encode;
        c.Passthrough=1; c.WhitePoint=1; c.MaxRatio=8; c.TransferStrength=c.ColourStrength=1;
        c.ApplyModel=outcome==1 ? 0u : 1u; c.CompareZoom=1;
        const auto full=run(c,active,active,active);
        auto down=c; down.Mode=DlssNrMode_Downsample;
        down.Width=unsigned(active.w*scale+.5f); down.Height=unsigned(active.h*scale+.5f);
        const auto proxy=run(down,full,full,active);
        const auto answer=modelAnswer(proxy,false,1.15f,.05f);
        const auto reconstruction=DlssNrResolveReconstruction(requested,true,
            down.Width!=active.w || down.Height!=active.h,scale);
        c.Mode=DlssNrMode_Resolve; c.Transfer=DlssNrSpatialTransfer(reconstruction.effective);
        Image composed=active; unsigned privateCalls=0,dispatches=0;
        // Model success is the same outer admission used by Run, not invented neutral model output.
        const bool success=outcome!=2 && DlssNrComposeReconstruction(reconstruction,[&]()
        {
            ++privateCalls;
            return false; // The old before-upscale private function rejects this actual frame.
        },[&]()
        {
            ++dispatches;
            if(outcome==3) return false;
            composed=run(c,proxy,answer,active);
            return true;
        });
        const auto output=copyBack(active,composed,uav,cropped,success);
        if(outcome==0)
        {
            expect(success && dispatches==1 && difference(output,active)>.01f,
                   "TASK24_OUTPUT: valid nonneutral before answer did not reach composition/copy-back");
            expect(difference(output,composed)<1e-6f,"Task24 copy-back lost shader output");
        }
        else
            expect(difference(output,active)<1e-6f,"Task24 hidden/failed output changed original");
        expect(privateCalls==0,"Task24 before path invoked private enlargement");
        expect(success==(outcome<2),"Task24 genuine failure was reported successful");
        for(const auto& p : output.pixels) expect(p.a==.625f,"Task24 alpha changed");
        std::printf("PASS Task24 output requested=%u effective=%u scale=%.2f UAV=%d cropped=%d outcome=%u composed=%d\n",
                    requested,reconstruction.effective,scale,uav,cropped,outcome,success);
        ++repairCases;
    }
    std::printf("PASS: Task24 %u actual shipped-shader/readback/copy-back cases (D3D11 + D3D12 WARP)\n",repairCases);
    return 0;
}
catch (const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
