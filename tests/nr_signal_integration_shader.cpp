#include "pch.h"
// Standalone WARP fixture. Reuse data parsing and spatial references, not the prior entry point.
#define main NrPriorMain
#include "nr_resize_shader_smoke.cpp"
#undef main
#define main NrActivePriorMain
#define check T12ActiveCheck
#define expect T12ActiveExpect
#define run T12ActivePriorRun
#include "nr_active_color_smoke.cpp"
#undef run
#undef expect
#undef check
#undef main
#include <cstdint>
#include <cstring>
#include <limits>
#include <set>
#include "../OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.h"

namespace
{
static_assert(sizeof(DlssNrConstants) == 256);
static_assert(offsetof(DlssNrConstants, SignalEncoding) == 244);
unsigned long long t11Checks = 0;
unsigned t11Recipes = 0, t11Legacy = 0, t11Bypass = 0, t11Carriers = 0;
double t11Max[2] {}, t11BypassMax[2] {}, t11LegacyMax[2] {};

void T11(bool condition, const char* name)
{
    ++t11Checks;
    if (!condition) throw std::runtime_error(name);
}
void Hr(HRESULT result)
{
    if (FAILED(result))
    {
        std::printf("T11_D3D_HRESULT value=0x%08lx\n", static_cast<unsigned long>(result));
        T11(false, "T11_D3D_BOUNDARY");
    }
}
void Near(const Image& actual, const Image& expected, bool fp16, const char* name,
          double tolerance = -1)
{
    T11(actual.w == expected.w && actual.h == expected.h &&
        actual.pixels.size() == expected.pixels.size(), "T11_REFERENCE_EXTENT");
    double error = 0;
    for (size_t i = 0; i < actual.pixels.size(); ++i)
    {
        const auto a = actual.pixels[i], b = expected.pixels[i];
        const float av[] {a.r,a.g,a.b,a.a}, bv[] {b.r,b.g,b.b,b.a};
        for (unsigned channel = 0; channel < 4; ++channel)
        {
            T11(std::isfinite(av[channel]) && std::isfinite(bv[channel]), "T11_FINITE_PIXELS");
            error = std::max(error, std::abs(double(av[channel]) - bv[channel]));
        }
    }
    t11Max[fp16] = std::max(t11Max[fp16], error);
    const double limit = tolerance >= 0 ? tolerance : fp16 ? 2e-3 : 1e-5;
    if (error > limit)
        std::printf("%s format=%s error=%.17g limit=%.17g\n", name, fp16 ? "FP16" : "R32", error, limit);
    T11(error <= limit, name);
}
void Exact(const Image& actual, const Image& expected, const char* name)
{
    T11(actual.w == expected.w && actual.h == expected.h &&
        actual.pixels.size() == expected.pixels.size(), "T11_EXACT_EXTENT");
    T11(std::memcmp(actual.pixels.data(), expected.pixels.data(),
                    actual.pixels.size()*sizeof(Pixel)) == 0, name);
}
std::vector<unsigned char> Blob(const char* path)
{
    std::ifstream file(path, std::ios::binary);
    T11(file.good(), "T11_BYTECODE_MISSING");
    std::vector<unsigned char> result((std::istreambuf_iterator<char>(file)), {});
    T11(!result.empty(), "T11_BYTECODE_EMPTY");
    return result;
}
std::vector<IntegrationRecipe> Recipes(const char* path)
{
    try { return readRecipes(path); }
    catch (const std::exception& error)
    {
        std::printf("T11_RECIPE_INPUT detail=%s\n", error.what());
        throw std::runtime_error("T11_RECIPE_FORMAT");
    }
}

// These equations do not include or call dlssnr_signal.hlsli or its native adapter.
// ST2084 is evaluated in binary64 with exp/log rather than the shader's float pow.
double Bound(double value, unsigned code)
{
    if (std::isnan(value) || (code != 0 && !std::isfinite(value))) return 0;
    return std::clamp(value, 0.0, 1.0);
}
double Encode(double value, unsigned code, bool passthrough)
{
    if (passthrough) return value;
    value = Bound(value, code);
    if (code == 2) return value;
    if (code != 3)
        return value < .0031308 ? value*12.92 : 1.055*std::exp(std::log(value)/2.4)-.055;
    const double p = value == 0 ? 0 : std::exp(std::log(value/100.0)*(2610.0/16384.0));
    return std::exp(std::log((3424.0/4096.0+(2413.0/128.0)*p) /
                             (1+(2392.0/128.0)*p))*(2523.0/32.0));
}
double Decode(double value, unsigned code, bool passthrough)
{
    if (passthrough) return value;
    value = Bound(value, code);
    if (code == 2) return value;
    if (code != 3)
        return value < .04045 ? value/12.92 : std::exp(2.4*std::log((value+.055)/1.055));
    if (value == 0) return 0;
    const double p = std::exp(std::log(value)*(32.0/2523.0));
    const double n = std::max(p-3424.0/4096.0, 0.0);
    return n == 0 ? 0 : std::min(1.0, 100*std::exp(std::log(n /
                                (2413.0/128.0-(2392.0/128.0)*p))*(16384.0/2610.0)));
}
using Rgb = std::array<double,3>;
double Luma(const Rgb& v) { return .2126*v[0]+.7152*v[1]+.0722*v[2]; }
Rgb RgbOf(Pixel p) { return {p.r,p.g,p.b}; }
Rgb Decoded(Pixel p, unsigned code, bool pass)
{
    return {Decode(p.r,code,pass),Decode(p.g,code,pass),Decode(p.b,code,pass)};
}
Pixel PixelOf(const Rgb& rgb, float alpha)
{
    return {float(rgb[0]),float(rgb[1]),float(rgb[2]),alpha};
}
Rgb Mapped(Pixel p, const DlssNrConstants& c)
{
    auto v = RgbOf(p);
    for (auto& channel : v) channel = std::max(0.0, channel);
    if (c.Passthrough) return v;
    for (auto& channel : v) channel /= std::max(double(c.WhitePoint), 1e-4);
    const double peak = std::max({v[0],v[1],v[2]});
    if (c.ReversibleMode == 0)
    {
        const double y = Luma(v);
        if (y > .75)
        {
            const double factor = (.75+.25*(1-std::exp(-(y-.75)/.25)))/y;
            for (auto& channel : v) channel *= factor;
        }
        const double m = std::max({v[0],v[1],v[2]});
        if (m > 1) for (auto& channel : v) channel /= m;
    }
    else if (peak > 1e-6)
    {
        double mapped = peak/std::sqrt(peak*peak+1);
        if (c.ReversibleMode >= 3)
        {
            const double e = (peak-.75)/.25;
            mapped = peak <= .75 ? peak : .75+.25*e/std::sqrt(e*e+1);
        }
        for (auto& channel : v) channel *= mapped/peak;
    }
    return v;
}
Pixel Sample(const Image& image, double u, double v, bool hardwareSampling=false)
{
    // D3D11.3 7.18.5/3.2.4: WARP SampleLevel addresses use eight fractional bits.
    // Manual Load/frac resize-field interpolation does not cross that sampler boundary.
    const auto coordinate = [hardwareSampling](double uv, unsigned extent) {
        double texel = hardwareSampling ? double(float(uv)*float(extent)) : uv*extent;
        if (hardwareSampling) texel = std::nearbyint(texel*256.0)/256.0;
        return std::clamp(texel-.5,0.0,double(extent-1));
    };
    const double px = coordinate(u,image.w), py = coordinate(v,image.h);
    const unsigned x = unsigned(px), y = unsigned(py);
    const unsigned bx = std::min(x+1,image.w-1), by = std::min(y+1,image.h-1);
    const double fx = px-x, fy = py-y;
    const Pixel taps[] {image.pixels[y*image.w+x], image.pixels[y*image.w+bx],
                        image.pixels[by*image.w+x], image.pixels[by*image.w+bx]};
    const double weights[] {(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy};
    double result[4] {};
    for (unsigned i=0;i<4;++i)
    {
        result[0]+=taps[i].r*weights[i]; result[1]+=taps[i].g*weights[i];
        result[2]+=taps[i].b*weights[i]; result[3]+=taps[i].a*weights[i];
    }
    return {float(result[0]),float(result[1]),float(result[2]),float(result[3])};
}
Image Model(Image image, unsigned code, bool pass, bool edited)
{
    for (auto& p : image.pixels)
    {
        if (edited)
        {
            auto v = Decoded(p,code,pass);
            const double y = Luma(v), r = .85*(v[0]+.02*y), b = .85*(v[2]-.02*y);
            const double g = (.85*y-.2126*r-.0722*b)/.7152;
            p = {float(Encode(r,code,pass)),float(Encode(g,code,pass)),
                 float(Encode(b,code,pass)),0};
        }
        else p.a = 0;
    }
    return image;
}
Rgb FieldAt(const Image& source, const Image& model, unsigned x, unsigned y,
            unsigned code, bool pass)
{
    const auto s = Decoded(source.pixels[y*source.w+x],code,pass);
    const auto m = Decoded(model.pixels[y*model.w+x],code,pass);
    double sy = Luma(s), my = Luma(m);
    if (sy < 1.0/1024)
    {
        sy = my = 0;
        for (int dy=-1;dy<=1;++dy) for (int dx=-1;dx<=1;++dx)
        {
            const unsigned qx = unsigned(std::clamp(int(x)+dx,0,int(source.w)-1));
            const unsigned qy = unsigned(std::clamp(int(y)+dy,0,int(source.h)-1));
            sy += Luma(Decoded(source.pixels[qy*source.w+qx],code,pass));
            my += Luma(Decoded(model.pixels[qy*model.w+qx],code,pass));
        }
    }
    const double ls = Luma(s), lm = Luma(m);
    return {(my-sy)/std::max(sy,1.0/1024),
            (lm>1e-6 ? m[0]/lm : 1)-(ls>1e-6 ? s[0]/ls : 1),
            (lm>1e-6 ? m[2]/lm : 1)-(ls>1e-6 ? s[2]/ls : 1)};
}
Image CarrierReference(const Image& source, const Image& model,
                       const DlssNrConstants& c)
{
    Image result {source.w,source.h,std::vector<Pixel>(source.pixels.size())};
    for (unsigned y=0;y<source.h;++y) for (unsigned x=0;x<source.w;++x)
    {
        const size_t i = y*source.w+x;
        Rgb d {};
        if (c.Mode == DlssNrMode_EncodeResizeField)
            d = FieldAt(source,model,x,y,c.SignalEncoding,c.Passthrough!=0);
        else
        {
            const auto s = Decoded(source.pixels[i],c.SignalEncoding,c.Passthrough!=0);
            const auto m = Decoded(model.pixels[i],c.SignalEncoding,c.Passthrough!=0);
            for (unsigned k=0;k<3;++k) d[k] = m[k]-s[k];
        }
        const double scale = c.Mode == DlssNrMode_EncodeResizeField ? 1 : 1.0/64;
        for (auto& channel : d) channel = .5+.5*channel/(scale+std::abs(channel));
        result.pixels[i] = PixelOf(d,1);
    }
    return result;
}

// This boundary owns all D3D objects and staging maps; no prior fixture main is called.
class Warp
{
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11ComputeShader> up,down;
public:
    Warp()
    {
        Hr(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,
                            D3D11_SDK_VERSION,&device,nullptr,&context));
        D3D11_BUFFER_DESC bd {};
        bd.ByteWidth=256; bd.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        Hr(device->CreateBuffer(&bd,nullptr,&constants));
        D3D11_SAMPLER_DESC sd {};
        sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.MaxLOD=D3D11_FLOAT32_MAX;
        Hr(device->CreateSamplerState(&sd,&sampler));
        Hr(device->CreateComputeShader(bcus_cso,sizeof(bcus_cso),nullptr,&up));
        Hr(device->CreateComputeShader(bcds_bicubic_cso,sizeof(bcds_bicubic_cso),nullptr,&down));
    }
    ComPtr<ID3D11ComputeShader> Shader(const std::vector<unsigned char>& bytes)
    {
        ComPtr<ID3D11ComputeShader> result;
        Hr(device->CreateComputeShader(bytes.data(),bytes.size(),nullptr,&result));
        return result;
    }
    std::array<Image,2> Run(ID3D11ComputeShader* shader, const DlssNrConstants& c,
                           const Image& source, const Image& model, const Image& original,
                           bool fp16, unsigned kind=0)
    {
        T11(c.Width && c.Height && source.w && source.h &&
            model.w && model.h && original.w && original.h, "T11_DISPATCH_EXTENT");
        ComPtr<ID3D11Texture2D> inputs[4], targets[2], staging;
        ComPtr<ID3D11ShaderResourceView> views[4];
        ComPtr<ID3D11UnorderedAccessView> outputs[2];
        D3D11_TEXTURE2D_DESC td {};
        td.MipLevels=td.ArraySize=td.SampleDesc.Count=1;
        td.Format=DXGI_FORMAT_R32G32B32A32_FLOAT; td.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        const Image* images[] {&source,&model,&original,&original};
        for (unsigned i=0;i<4;++i)
        {
            td.Width=images[i]->w; td.Height=images[i]->h;
            D3D11_SUBRESOURCE_DATA data {images[i]->pixels.data(),td.Width*sizeof(Pixel),0};
            Hr(device->CreateTexture2D(&td,&data,&inputs[i]));
            Hr(device->CreateShaderResourceView(inputs[i].Get(),nullptr,&views[i]));
        }
        td.Width=c.Width; td.Height=c.Height; td.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        td.Format=fp16 ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R32G32B32A32_FLOAT;
        for (unsigned i=0;i<2;++i)
        {
            Hr(device->CreateTexture2D(&td,nullptr,&targets[i]));
            Hr(device->CreateUnorderedAccessView(targets[i].Get(),nullptr,&outputs[i]));
        }
        td.Usage=D3D11_USAGE_STAGING; td.BindFlags=0; td.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        Hr(device->CreateTexture2D(&td,nullptr,&staging));
        auto uploaded=c;
        if (kind==2 || kind==3)
        {
            uploaded={};
            const unsigned sizes[] {source.w,source.h,c.Width,c.Height};
            std::memcpy(&uploaded,sizes,sizeof(sizes));
        }
        context->UpdateSubresource(constants.Get(),0,nullptr,&uploaded,0,0);
        context->CSSetShader(kind==2 ? up.Get() : kind==3 ? down.Get() : shader,nullptr,0);
        context->CSSetConstantBuffers(0,1,constants.GetAddressOf());
        context->CSSetSamplers(0,1,sampler.GetAddressOf());
        ID3D11ShaderResourceView* srv[] {views[0].Get(),views[1].Get(),views[2].Get(),views[3].Get()};
        ID3D11UnorderedAccessView* uav[] {outputs[0].Get(),outputs[1].Get()};
        context->CSSetShaderResources(0,4,srv);
        context->CSSetUnorderedAccessViews(0,2,uav,nullptr);
        const unsigned threads=kind==2 ? 16u : 8u;
        context->Dispatch((c.Width+threads-1)/threads,(c.Height+threads-1)/threads,1);
        context->ClearState();
        std::array<Image,2> result;
        // u1 is defined only by NR encode; do not read uninitialised auxiliary output.
        const unsigned count=kind==0 && c.Mode==DlssNrMode_Encode ? 2 : 1;
        for (unsigned i=0;i<count;++i)
        {
            result[i]={c.Width,c.Height,std::vector<Pixel>(size_t(c.Width)*c.Height)};
            context->CopyResource(staging.Get(),targets[i].Get());
            D3D11_MAPPED_SUBRESOURCE mapped {};
            Hr(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
            for (unsigned y=0;y<c.Height;++y)
            {
                const char* row=static_cast<const char*>(mapped.pData)+y*mapped.RowPitch;
                if (!fp16) std::memcpy(result[i].pixels.data()+y*c.Width,row,c.Width*sizeof(Pixel));
                else for (unsigned x=0;x<c.Width;++x)
                {
                    const auto* p=reinterpret_cast<const unsigned short*>(row)+4*x;
                    result[i].pixels[y*c.Width+x]={halfValue(p[0]),halfValue(p[1]),halfValue(p[2]),halfValue(p[3])};
                }
            }
            context->Unmap(staging.Get(),0);
        }
        return result;
    }
};

unsigned Signal(const IntegrationRecipe& recipe)
{
    std::optional<unsigned> code;
    bool encode=false,resolve=false;
    for (const auto& op : recipe.operations)
    {
        T11(op.kind<=4, "T11_RESOURCE_OPERATION_KIND");
        if (op.kind!=0) continue;
        if (op.constants.Mode==DlssNrMode_Encode || op.constants.Mode==DlssNrMode_Resolve)
        {
            T11(op.constants.SignalEncoding<=3, "T11_CAPTURED_SIGNAL_CODE");
            if (code) T11(*code==op.constants.SignalEncoding, "T11_ENCODE_RESOLVE_DOMAIN_MATCH");
            code=op.constants.SignalEncoding;
            encode |= op.constants.Mode==DlssNrMode_Encode;
            resolve |= op.constants.Mode==DlssNrMode_Resolve;
        }
    }
    T11(code.has_value() && encode && resolve, "T11_CAPTURED_PAIRED_CONSTANTS");
    for (const auto& op : recipe.operations)
        if (op.kind==0 && (op.constants.Mode==9 || op.constants.Mode==12))
            T11(op.constants.SignalEncoding==*code, "T11_CAPTURED_CARRIER_DOMAIN_MATCH");
    return *code;
}
using RecipeKey=std::array<unsigned,10>;
RecipeKey Key(const IntegrationRecipe& recipe)
{
    RecipeKey key {};
    std::copy_n(recipe.header.begin()+1,10,key.begin());
    return key;
}
void Matrix(const std::vector<IntegrationRecipe>& recipes,
            const std::vector<IntegrationRecipe>& accepted)
{
    using Cell=std::array<unsigned,9>;
    std::map<Cell,unsigned> cells;
    std::set<RecipeKey> acceptedKeys;
    for (const auto& recipe : accepted) acceptedKeys.insert(Key(recipe));
    unsigned bound=0;
    for (const auto& recipe : recipes)
    {
        const auto& h=recipe.header;
        T11(h[12]==recipe.operations.size() && h[12]!=0, "T11_CAPTURED_OPERATION_COUNT");
        T11(h[5]<=2, "T11_HEADER5_INPUT_FILTER");
        const unsigned scale=h[3]<h[1] || h[4]<h[2] ? 0 :
                             h[3]>h[1] || h[4]>h[2] ? 2 : 1;
        const double factor=scale==0 ? .65 : scale==2 ? 1.25 : 1;
        T11(std::abs(double(h[3])-h[1]*factor)<=1 &&
            std::abs(double(h[4])-h[2]*factor)<=1, "T11_CAPTURED_SCALE_ROUNDING");
        unsigned shape=3;
        if (h[1]==7 && h[2]==5) shape=0;
        if (h[1]==5 && h[2]==1) shape=1;
        if (h[1]==1 && h[2]==5) shape=2;
        T11(shape!=3, "T11_CAPTURED_ORIGINAL_SHAPE");
        const unsigned signal=Signal(recipe);
        T11(h[7]!=0 || signal==0, "T11_SDR_EFFECTIVE_LEGACY");
        ++cells[{signal,h[7],scale,h[5],h[6],h[8],h[9],shape,h[10]}];
        if (signal==0 && acceptedKeys.contains(Key(recipe))) ++bound;
    }
    for (unsigned code=0;code<4;++code) for (unsigned hdr=0;hdr<2;++hdr)
    for (unsigned scale=0;scale<3;++scale) for (unsigned filter=0;filter<3;++filter)
    for (unsigned transfer : {0u,1u,3u}) for (unsigned curve : {0u,2u,4u})
    for (unsigned edit : {0u,1u,3u}) for (unsigned shape=0;shape<3;++shape)
    {
        // Requested SDR codes are deliberately unobservable in the byte format: all four
        // producer loop entries must carry effective Legacy in their actual constants.
        if (!hdr && code!=0) continue;
        const unsigned repetitions=hdr ? 1 : 4;
        T11(cells[{code,hdr,scale,filter,transfer,curve,edit,shape,0}]>=repetitions,
            "T11_CURRENT_RECIPE_MATRIX");
        if (scale==2)
            T11(cells[{code,hdr,scale,filter,transfer,curve,edit,shape,1}]>=repetitions,
                "T11_SUPERNATIVE_FALLBACK_MATRIX");
    }
    T11(bound!=0, "T11_ACCEPTED_TASK9_KEYS_BOUND");
    std::printf("T11_RECIPE_BINDING current=%zu accepted=%zu boundLegacyKeys=%u cells=%zu\n",
                recipes.size(),accepted.size(),bound,cells.size());
}
Image Original(const IntegrationRecipe& recipe)
{
    const auto& h=recipe.header;
    Image result {h[1],h[2],std::vector<Pixel>(size_t(h[1])*h[2])};
    for (unsigned y=0;y<result.h;++y) for (unsigned x=0;x<result.w;++x)
    {
        const float v=x<2 ? .024f : .25f+.05f*float((x+2*y)%7);
        result.pixels[y*result.w+x]={v,.7f*v,.4f*v,float((x+3*y)%5)/4};
    }
    return result;
}
Image DebugReference(const Image& source, const Image& model, const Image& original,
                     const DlssNrConstants& c)
{
    Image result {c.Width,c.Height,std::vector<Pixel>(size_t(c.Width)*c.Height)};
    Image field {source.w,source.h,std::vector<Pixel>(source.pixels.size())};
    const bool resizedField=c.DebugView==3 && c.Transfer==3 &&
                           (source.w<c.Width || source.h<c.Height);
    if (resizedField)
        for (unsigned y=0;y<source.h;++y) for (unsigned x=0;x<source.w;++x)
            field.pixels[y*source.w+x]=PixelOf(FieldAt(source,model,x,y,c.SignalEncoding,c.Passthrough!=0),1);
    for (unsigned y=0;y<c.Height;++y) for (unsigned x=0;x<c.Width;++x)
    {
        const double u=(x+.5)/c.Width, v=(y+.5)/c.Height;
        auto s=Decoded(Sample(source,u,v,true),c.SignalEncoding,c.Passthrough!=0);
        auto m=Decoded(Sample(model,u,v,true),c.SignalEncoding,c.Passthrough!=0);
        if (resizedField)
        {
            s=Mapped(original.pixels[y*original.w+x],c);
            if (c.Passthrough) for (auto& channel:s) channel=Bound(channel,0);
            const auto f=RgbOf(Sample(field,u,v));
            const double sy=Luma(s), target=std::max(0.0,sy*(1+f[0]));
            const double r=(f[1]+(sy>1e-6 ? s[0]/sy : 1))*target;
            const double b=(f[2]+(sy>1e-6 ? s[2]/sy : 1))*target;
            m={r,(target-.2126*r-.0722*b)/.7152,b};
            const double light=Bound(Luma(m),0);
            double amount=1;
            for (double channel:m)
            {
                const double d=channel-light;
                if (d>0) amount=std::min(amount,(1-light)/d);
                if (d<0) amount=std::min(amount,-light/d);
            }
            for (auto& channel:m) channel=Bound(light+Bound(amount,0)*(channel-light),0);
        }
        Rgb rgb=c.DebugView==1 ? s : m;
        if (c.DebugView==3)
            for (unsigned k=0;k<3;++k) rgb[k]=Decode(Bound(.5+20*(m[k]-s[k]),0),0,false);
        for (auto& channel:rgb) channel*=c.DebugScale;
        result.pixels[y*c.Width+x]=PixelOf(rgb,original.pixels[y*original.w+x].a);
    }
    return result;
}
Image Execute(Warp& warp, ID3D11ComputeShader* shader, const IntegrationRecipe& recipe,
              bool fp16, bool verify, ID3D11ComputeShader* diagnosticBaseline=nullptr)
{
    const auto& h=recipe.header;
    const unsigned code=Signal(recipe);
    const auto original=Original(recipe);
    std::map<unsigned,Image> resources {{h[11],original}};
    for (const auto& op : recipe.operations)
    {
        T11(resources.contains(op.source), "T11_RESOURCE_SOURCE_EDGE");
        const Image source=resources.at(op.source);
        if (op.kind==1)
        {
            resources[op.output]=Model(source,code,h[7]==0,h[9]==3);
            continue;
        }
        if (op.kind==4) { resources[op.output]=source; continue; }
        T11(!op.model || resources.contains(op.model), "T11_RESOURCE_MODEL_EDGE");
        T11(!op.original || resources.contains(op.original), "T11_RESOURCE_ORIGINAL_EDGE");
        const Image model=op.model ? resources.at(op.model) : source;
        const Image base=op.original ? resources.at(op.original) : original;
        const auto result=warp.Run(shader,op.constants,source,model,base,fp16,op.kind);
        if (verify && op.kind==0)
        {
            const auto& c=op.constants;
            if (c.Mode==DlssNrMode_Encode)
            {
                Image reference=result[0];
                for (size_t i=0;i<reference.pixels.size();++i)
                {
                    auto rgb=Mapped(source.pixels[i],c);
                    for (auto& channel:rgb) channel=Encode(channel,c.SignalEncoding,c.Passthrough!=0);
                    reference.pixels[i]=PixelOf(rgb,c.Passthrough || !c.ReversibleMode ? source.pixels[i].a : 1);
                }
                Near(result[0],reference,fp16,"T11_SIGNAL_DOMAIN_MISMATCH_ENCODE");
                Near(result[1],source,fp16,"T11_ACTUAL_KEEP_ORIGINAL");
            }
            if (c.Mode==DlssNrMode_Downsample)
                Near(result[0],filterReference(source,c.Width,c.Height,c.InputFilter),fp16,
                     "T11_INDEPENDENT_INPUT_FILTER");
            if (c.Mode==DlssNrMode_Resolve && c.ApplyModel!=0)
            {
                bool sameRgb=source.w==model.w && source.h==model.h;
                if (sameRgb) for (size_t i=0;i<source.pixels.size();++i)
                    sameRgb &= source.pixels[i].r==model.pixels[i].r &&
                               source.pixels[i].g==model.pixels[i].g &&
                               source.pixels[i].b==model.pixels[i].b;
                const bool successfulSuper=(h[3]>h[1] || h[4]>h[2]) && h[10]==0;
                if (h[9]==0 && !successfulSuper)
                    T11(sameRgb,"T11_IDENTICAL_PAIRED_MODEL_RGB");
                for (unsigned view : {1u,2u,3u})
                {
                    auto debug=c; debug.DebugView=view;
                    const auto actual=warp.Run(shader,debug,source,model,base,fp16)[0];
                    const auto debugReference=DebugReference(source,model,base,debug);
                    if (difference(actual,debugReference)>(fp16 ? 2e-3f : 1e-5f))
                        for (size_t pixel=0;pixel<actual.pixels.size();++pixel)
                        {
                            const auto a=actual.pixels[pixel],e=debugReference.pixels[pixel];
                            if (std::max({std::abs(a.r-e.r),std::abs(a.g-e.g),std::abs(a.b-e.b)})>(fp16 ? 2e-3f : 1e-5f))
                            {
                                std::printf("T11_GRAPH_VECTOR id=%u code=%u hdr=%u transfer=%u curve=%u view=%u pixel=%zu source=%ux%u target=%ux%u format=%s actual=%.9g,%.9g,%.9g expected=%.9g,%.9g,%.9g\n",
                                    h[0],code,h[7],c.Transfer,c.ReversibleMode,view,pixel,source.w,source.h,c.Width,c.Height,
                                    fp16 ? "FP16" : "R32",a.r,a.g,a.b,e.r,e.g,e.b);
                                if (diagnosticBaseline)
                                {
                                    const auto prior=warp.Run(diagnosticBaseline,debug,source,model,base,fp16)[0];
                                    const auto p=prior.pixels[pixel];
                                    std::printf("T11_GRAPH_ACCEPTED_LEGACY actual=%.9g,%.9g,%.9g currentDifference=%.9g passthrough=%u filter=%u\n",
                                        p.r,p.g,p.b,difference(prior,actual),debug.Passthrough,debug.InputFilter);
                                    for (size_t input=0;input<source.pixels.size();++input)
                                        std::printf("T11_GRAPH_SOURCE pixel=%zu rgb=%.9g,%.9g,%.9g\n",
                                            input,source.pixels[input].r,source.pixels[input].g,source.pixels[input].b);
                                }
                                break;
                            }
                        }
                    Near(actual,debugReference,fp16,
                         view==1 ? "T11_ACTUAL_PROXY_DECODE" : view==2 ?
                         "T11_ACTUAL_MODEL_DECODE" : "T11_EDITAT_RECONSTRUCTION_RESIDUAL");
                    if (view==3 && sameRgb)
                    {
                        Image neutral=actual;
                        const float grey=float(Decode(.5,0,false)*debug.DebugScale);
                        for (auto& p:neutral.pixels) p.r=p.g=p.b=grey;
                        Near(actual,neutral,fp16,"T11_EDITAT_RECONSTRUCTION_NEUTRAL_DEBUG3");
                    }
                }
                // Carriers are evaluated at the paired model's working dimensions, not the game dimensions.
                if (source.w==model.w && source.h==model.h)
                {
                    for (unsigned mode : {9u,12u})
                    {
                        auto carrier=c; carrier.Mode=mode; carrier.Width=source.w; carrier.Height=source.h;
                        const auto actual=warp.Run(shader,carrier,source,model,base,fp16)[0];
                        const auto expectedCarrier=CarrierReference(source,model,carrier);
                        if (difference(actual,expectedCarrier)>(fp16 ? 2e-3 : 1e-5))
                        {
                            std::printf("T11_CARRIER_VECTOR id=%u code=%u hdr=%u transfer=%u curve=%u mode=%u source=%ux%u format=%s error=%.9g\n",
                                h[0],carrier.SignalEncoding,h[7],carrier.Transfer,carrier.ReversibleMode,mode,source.w,source.h,fp16 ? "FP16" : "R32",difference(actual,expectedCarrier));
                            Image prior;
                            if (diagnosticBaseline) prior=warp.Run(diagnosticBaseline,carrier,source,model,base,fp16)[0];
                            auto decodedConstants=c;
                            decodedConstants.Width=source.w; decodedConstants.Height=source.h;
                            decodedConstants.DebugView=1;
                            const auto decodedSource=warp.Run(shader,decodedConstants,source,model,base,false)[0];
                            decodedConstants.DebugView=2;
                            const auto decodedModel=warp.Run(shader,decodedConstants,source,model,base,false)[0];
                            for (size_t pixel=0;pixel<actual.pixels.size();++pixel)
                            {
                                const auto a=actual.pixels[pixel],e=expectedCarrier.pixels[pixel],s=source.pixels[pixel],m=model.pixels[pixel];
                                std::printf("T11_CARRIER_INPUT pixel=%zu source=%.9g,%.9g,%.9g model=%.9g,%.9g,%.9g actual=%.9g,%.9g,%.9g expected=%.9g,%.9g,%.9g\n",
                                    pixel,s.r,s.g,s.b,m.r,m.g,m.b,a.r,a.g,a.b,e.r,e.g,e.b);
                                const auto ds=decodedSource.pixels[pixel],dm=decodedModel.pixels[pixel];
                                const auto rs=Decoded(s,carrier.SignalEncoding,carrier.Passthrough!=0),rm=Decoded(m,carrier.SignalEncoding,carrier.Passthrough!=0);
                                std::printf("T11_CARRIER_DECODE pixel=%zu actualSource=%.9g,%.9g,%.9g referenceSource=%.12g,%.12g,%.12g actualModel=%.9g,%.9g,%.9g referenceModel=%.12g,%.12g,%.12g\n",
                                    pixel,ds.r,ds.g,ds.b,rs[0],rs[1],rs[2],dm.r,dm.g,dm.b,rm[0],rm[1],rm[2]);
                                if (diagnosticBaseline)
                                {
                                    const auto p=prior.pixels[pixel];
                                    std::printf("T11_CARRIER_BASELINE pixel=%zu actual=%.9g,%.9g,%.9g\n",pixel,p.r,p.g,p.b);
                                }
                            }
                        }
                        Near(actual,expectedCarrier,fp16,
                             mode==9 ? "T11_PROXY_RESIDUAL_WORKING_REFERENCE" : "T11_RESIZE_FIELD_WORKING_REFERENCE");
                        if (sameRgb)
                        {
                            Image neutral=actual;
                            for (auto& p:neutral.pixels) p={.5f,.5f,.5f,1};
                            Near(actual,neutral,fp16,mode==9 ? "T11_PROXY_RESIDUAL_NEUTRAL" :
                                 "T11_RESIZE_FIELD_NEUTRAL");
                        }
                        ++t11Carriers;
                    }
                }
            }
        }
        resources[op.output]=result[0];
        if (op.keep)
        {
            T11(op.kind==0 && op.constants.Mode==DlssNrMode_Encode, "T11_KEEP_EDGE_IS_ENCODE_UAV");
            resources[op.keep]=result[1];
        }
    }
    T11(resources.contains(h[11]), "T11_FINAL_RESOURCE_EDGE");
    const auto output=resources.at(h[11]);
    if (verify)
    {
        T11(output.w==original.w && output.h==original.h, "T11_FINAL_ORIGINAL_EXTENT");
        for (size_t i=0;i<output.pixels.size();++i)
            T11(std::memcmp(&output.pixels[i].a,&original.pixels[i].a,sizeof(float))==0,
                "T11_FINAL_ORIGINAL_ALPHA_EXACT");
        const bool replace=h[7]!=0 && (h[8]==2 || h[8]==4);
        if (h[9]==1 || (h[9]==2 && !replace))
        {
            Near(output,original,fp16,"T11_EXISTING_BYPASS",fp16 ? 2e-3 : 1e-6);
            t11BypassMax[fp16]=std::max(t11BypassMax[fp16],double(difference(output,original)));
            ++t11Bypass;
        }
        ++t11Recipes;
    }
    return output;
}

void GuardExclusions(Warp& warp, ID3D11ComputeShader* shader, ID3D11ComputeShader* preGuard)
{
    const char* cases[] {"Legacy","SDR","NonNative","ResidualCarrier","ResizeField",
        "PrivateField","NeutwoReplace","HybridReplace","ProxyDebug","ModelDebug",
        "EditDebug","NonNeutral","ColourBoost","SkinMask","Compare"};
    unsigned measured=0;
    for (unsigned code=1;code<4;++code) for (bool fp16 : {false,true})
    for (unsigned which=0;which<std::size(cases);++which)
    {
        Image original {2,2,std::vector<Pixel>(4,Pixel{8,6,2,.5f})};
        DlssNrConstants c {};
        c.Width=c.Height=2; c.WhitePoint=1; c.ApplyModel=1; c.MaxRatio=4;
        c.DebugScale=1; c.SignalEncoding=which==0 ? 0 : code;
        c.TransferStrength=1; c.ReversibleMode=3;
        if (which==1) c.Passthrough=1;
        if (which==2) c.Width=c.Height=1;
        if (which>=3 && which<=5) c.Transfer=which-1;
        if (which==6) c.ReversibleMode=2;
        if (which==7) c.ReversibleMode=4;
        if (which>=8 && which<=10) c.DebugView=which-7;
        if (which==12) c.ColourStrength=2;
        if (which==13) { c.SkinProtection=1; c.ShowSkinMask=1; }
        if (which==14) { c.CompareMode=2; c.CompareSplit=.5f; }
        const unsigned targetW=c.Width,targetH=c.Height;
        c.Mode=DlssNrMode_Encode;
        const auto proxy=warp.Run(preGuard,c,original,original,original,fp16)[0];
        auto model=Model(proxy,c.SignalEncoding,c.Passthrough!=0,which==11);
        if (which>=3 && which<=5) for (auto& p:model.pixels) p={.5f,.5f,.5f,0};
        c.Width=original.w; c.Height=original.h; c.Mode=DlssNrMode_Resolve;
        T11(which!=2 || targetW!=c.Width || targetH!=c.Height,"T11_GUARD_NONNATIVE_INPUT");
        const auto actual=warp.Run(shader,c,proxy,model,original,fp16)[0];
        const auto prior=warp.Run(preGuard,c,proxy,model,original,fp16)[0];
        Exact(actual,prior,"T11_NATIVE_NEUTRAL_GUARD_EXCLUDED_PATH_EXACT");
        std::printf("T11_GUARD_EXCLUSION case=%s code=%u format=%s exact=1\n",
            cases[which],c.SignalEncoding,fp16 ? "FP16" : "R32");
        ++measured;
    }
    std::printf("T11_GUARD_EXCLUSION_PASS cases=%u\n",measured);
}

void Vectors(Warp& warp, ID3D11ComputeShader* shader, ID3D11ComputeShader* acceptedLegacy)
{
    const float inf=std::numeric_limits<float>::infinity();
    const std::array<float,15> values {0,.0001f,.001f,.01f,.18f,.5f,1,-2,1.2f,2,100,
                                     -inf,inf,std::numeric_limits<float>::quiet_NaN(),1.9920601f};
    for (unsigned code=0;code<4;++code) for (bool fp16 : {false,true})
    {
        // Encode inputs are finite game vectors; malformed MODEL values enter the decode boundary below.
        Image original {7,1,std::vector<Pixel>(7)};
        for (unsigned i=0;i<7;++i) original.pixels[i]={values[i],values[i],values[i],float(i%5)/4};
        DlssNrConstants c {};
        c.Width=7; c.Height=1; c.WhitePoint=1; c.ApplyModel=1;
        c.MaxRatio=4; c.DebugScale=1; c.SignalEncoding=code; c.Mode=DlssNrMode_Encode;
        const auto encoded=warp.Run(shader,c,original,original,original,fp16)[0];
        auto expected=original;
        for (auto& p:expected.pixels)
        {
            auto rgb=Mapped(p,c);
            for (auto& channel:rgb) channel=Encode(channel,code,false);
            p=PixelOf(rgb,p.a);
        }
        Near(encoded,expected,fp16,"T11_SIGNAL_DOMAIN_MISMATCH_ENCODE");
        if (code==0) continue;
        for (float value:values)
        {
            // A constant texture prevents undefined NaN interpolation from obscuring integer classification.
            // The optimized shader still performs its actual SampleLevel and asuint classification.
            Image malformed {1,1,{{value,value,value,0}}};
            Image base {1,1,{{.25f,.25f,.25f,.75f}}};
            c.Mode=DlssNrMode_Resolve; c.Width=c.Height=1; c.DebugView=2;
            const auto actual=warp.Run(shader,c,base,malformed,base,fp16)[0];
            const float decoded=float(Decode(value,code,false));
            Image reference {1,1,{{decoded,decoded,decoded,.75f}}};
            if (difference(actual,reference)>(fp16 ? 2e-3f : 1e-5f))
                std::printf("T11_DECODE_VECTOR code=%u input=%.9g format=%s actual=%.9g expected=%.9g\n",
                    code,value,fp16 ? "FP16" : "R32",actual.pixels[0].r,decoded);
            Near(actual,reference,fp16,"T11_O3_MODEL_INTEGER_CLASSIFICATION");
            // The actual interpass clamp reads Load, so its integer guard is
            // also tested without sampler handling of exceptional values.
            c.Mode=DlssNrMode_ClampProxy;
            const auto clamped=warp.Run(shader,c,malformed,malformed,base,fp16)[0];
            const float bounded=float(Bound(value,code));
            Image clampReference {1,1,{{bounded,bounded,bounded,0}}};
            Near(clamped,clampReference,fp16,"T11_O3_INTERPASS_INTEGER_CLASSIFICATION");
        }
    }
    // Qualified native composed subset only: replacements and successful super legs are not raw HDR identities.
    for (unsigned code=0;code<4;++code) for (unsigned curve : {0u,1u,3u})
    for (float value : {.125f,2.0f,8.0f}) for (bool fp16 : {false,true})
    {
        Image original {1,1,{{value,value,value,.5f}}};
        DlssNrConstants c {};
        c.Width=c.Height=1; c.WhitePoint=1; c.ApplyModel=1; c.MaxRatio=4;
        c.DebugScale=1; c.SignalEncoding=code; c.ReversibleMode=curve;
        c.TransferStrength=1; c.ColourStrength=0; c.Mode=DlssNrMode_Encode;
        const auto proxy=warp.Run(shader,c,original,original,original,fp16)[0];
        c.Mode=DlssNrMode_Resolve;
        const auto composed=warp.Run(shader,c,proxy,Model(proxy,code,false,false),original,fp16)[0];
        if (difference(composed,original)>(fp16 ? 2e-3f : 1e-5f))
        {
            std::printf("T11_HEADROOM_VECTOR code=%u curve=%u input=%.9g format=%s proxy=%.9g actual=%.9g expected=%.9g\n",
                code,curve,value,fp16 ? "FP16" : "R32",proxy.pixels[0].r,composed.pixels[0].r,original.pixels[0].r);
            if (code==0)
            {
                auto oldConstants=c;
                oldConstants.Mode=DlssNrMode_Encode;
                const auto oldProxy=warp.Run(acceptedLegacy,oldConstants,original,original,original,fp16)[0];
                oldConstants.Mode=DlssNrMode_Resolve;
                const auto oldOutput=warp.Run(acceptedLegacy,oldConstants,oldProxy,Model(oldProxy,0,false,false),original,fp16)[0];
                std::printf("T11_HEADROOM_ACCEPTED_LEGACY proxy=%.9g actual=%.9g rawError=%.9g currentDifference=%.9g\n",
                    oldProxy.pixels[0].r,oldOutput.pixels[0].r,difference(oldOutput,original),difference(oldOutput,composed));
            }
        }
        auto debugConstants=c;
        debugConstants.DebugView=3;
        const auto residual=warp.Run(shader,debugConstants,proxy,Model(proxy,code,false,false),original,fp16)[0];
        const float grey=float(Decode(.5,0,false));
        Image neutral {1,1,{{grey,grey,grey,.5f}}};
        Near(residual,neutral,fp16,"T11_HEADROOM_ACTUAL_MATCHED_PAIR_NEUTRAL");
        if (code==0)
        {
            auto oldConstants=c;
            oldConstants.Mode=DlssNrMode_Encode;
            const auto oldProxy=warp.Run(acceptedLegacy,oldConstants,original,original,original,fp16)[0];
            oldConstants.Mode=DlssNrMode_Resolve;
            const auto oldOutput=warp.Run(acceptedLegacy,oldConstants,oldProxy,Model(oldProxy,0,false,false),original,fp16)[0];
            Exact(composed,oldOutput,"T11_HEADROOM_LEGACY_ACCEPTED_EXACT");
        }
        else
        {
            Near(composed,original,fp16,"T11_COMPOSED_NEUTRAL_HEADROOM_RESTORATION");
        }
        T11(value<=1 || composed.pixels[0].r>1,"T11_HEADROOM_RETAINED_ABOVE_PROXY_RANGE");
        T11(composed.pixels[0].a==original.pixels[0].a,"T11_HEADROOM_ALPHA_EXACT");
    }
}
}

void T12Compare(std::ofstream& capture, unsigned id, const char* phase,
                const Image& actual, const Image& expected, bool fp16, const char* assertion,
                double tolerance=-1)
{
    const double limit=tolerance>=0 ? tolerance : fp16 ? 2e-3 : 1e-5;
    T11(actual.w==expected.w && actual.h==expected.h && actual.pixels.size()==expected.pixels.size(),
        "T12_CAPTURE_REFERENCE_EXTENT");
    for (size_t i=0;i<actual.pixels.size();++i)
    {
        const auto a=actual.pixels[i],e=expected.pixels[i];
        capture<<id<<','<<phase<<','<<i<<','<<a.r<<','<<a.g<<','<<a.b<<','<<a.a
               <<','<<e.r<<','<<e.g<<','<<e.b<<','<<e.a<<','<<limit<<'\n';
    }
    capture.flush();
    Near(actual,expected,fp16,assertion,tolerance);
}
Image T12Image(unsigned pattern,bool hdr)
{
    Image image {7,5,std::vector<Pixel>(35)};
    for (unsigned y=0;y<5;++y) for (unsigned x=0;x<7;++x)
    {
        const float peak=hdr ? 2.0f : 1.0f;
        float v=pattern==0 ? 0 : pattern==1 ? peak :
                pattern==4 ? (x<3 ? .015625f : peak) : peak*float(x+7*y)/34;
        image.pixels[y*7+x]={v,v,v,float((x+3*y)%5)/4};
        if (pattern==3) image.pixels[y*7+x]={peak*float(x%3)/2,
            peak*float((x+y)%5)/4,peak*float(y%3)/2,float((x+3*y)%5)/4};
    }
    return image;
}
void T12Matrix(Warp& warp,ID3D11ComputeShader* shader,ID3D11ComputeShader* legacy,const char* path)
{
    std::ofstream capture(path);
    T11(capture.good(),"T12_CAPTURE_OPEN");
    capture.precision(17);
    capture<<"case,phase,pixel,actualR,actualG,actualB,actualA,expectedR,expectedG,expectedB,expectedA,limit\n";
    unsigned id=0;
    for (bool hdr : {false,true}) for (unsigned code=0;code<(hdr ? 4u : 1u);++code)
    for (unsigned curve=0;curve<(hdr ? 5u : 1u);++curve) for (unsigned pattern=0;pattern<5;++pattern)
    for (unsigned spatial=0;spatial<4;++spatial) for (bool fp16 : {false,true})
    {
        const auto original=T12Image(pattern,hdr);
        DlssNrConstants c {};
        c.Width=7;c.Height=5;c.Mode=DlssNrMode_Encode;c.WhitePoint=1;c.ApplyModel=1;
        c.SignalEncoding=code;c.Passthrough=!hdr;c.ReversibleMode=curve;
        c.TransferStrength=1;c.MaxRatio=4;c.DebugScale=1;c.ColourStrength=0;
        auto proxy=warp.Run(shader,c,original,original,original,fp16)[0];
        auto expected=original;
        for (auto& p:expected.pixels)
        {
            auto rgb=Mapped(p,c);
            for (auto& channel:rgb) channel=Encode(channel,code,!hdr);
            p=PixelOf(rgb,!hdr || !curve ? p.a : 1);
        }
        T12Compare(capture,id,"encode",proxy,expected,fp16,"T12_INDEPENDENT_SIGNAL_ENCODE");
        if (spatial)
        {
            c.Mode=DlssNrMode_Downsample;c.Width=5;c.Height=3;c.InputFilter=spatial-1;
            const auto filtered=warp.Run(shader,c,proxy,proxy,original,fp16)[0];
            T12Compare(capture,id,"filter",filtered,filterReference(proxy,5,3,c.InputFilter),
                       fp16,"T12_INDEPENDENT_FILTER");
            proxy=filtered;
        }
        const auto model=Model(proxy,code,!hdr,false);
        c.Mode=DlssNrMode_Resolve;c.Width=7;c.Height=5;
        for (unsigned view : {1u,2u,3u})
        {
            c.DebugView=view;
            const auto debug=warp.Run(shader,c,proxy,model,original,fp16)[0];
            T12Compare(capture,id,view==1 ? "proxy" : view==2 ? "model" : "residual",
                debug,DebugReference(proxy,model,original,c),fp16,"T12_INDEPENDENT_PAIRED_DECODE");
        }
        c.DebugView=0;
        const auto output=warp.Run(shader,c,proxy,model,original,fp16)[0];
        for (size_t i=0;i<output.pixels.size();++i)
        {
            const auto p=output.pixels[i];
            capture<<id<<",final-observation,"<<i<<','<<p.r<<','<<p.g<<','<<p.b<<','<<p.a
                   <<",,,,"<<original.pixels[i].a<<",0\n";
            T11(std::isfinite(p.r)&&std::isfinite(p.g)&&std::isfinite(p.b),"T12_FINAL_FINITE");
            T11(p.a==original.pixels[i].a,"T12_ORIGINAL_ALPHA_EXACT");
        }
        if (code==0)
        {
            auto lc=c;lc.Mode=DlssNrMode_Encode;
            auto prior=warp.Run(legacy,lc,original,original,original,fp16)[0];
            if (spatial)
            {
                lc.Mode=DlssNrMode_Downsample;lc.Width=5;lc.Height=3;
                prior=warp.Run(legacy,lc,prior,prior,original,fp16)[0];
            }
            lc.Mode=DlssNrMode_Resolve;lc.Width=7;lc.Height=5;
            const auto old=warp.Run(legacy,lc,prior,Model(prior,0,!hdr,false),original,fp16)[0];
            T12Compare(capture,id,"legacy-final",output,old,fp16,"T12_LEGACY_REFERENCE");
            Exact(output,old,"T12_LEGACY_NOEDIT_ACCEPTED_EXACT");
        }
        else if (!spatial && curve!=2 && curve!=4)
            T12Compare(capture,id,"native-final",output,original,fp16,"T12_NATIVE_NOEDIT_HEADROOM");
        if (hdr && pattern==1)
            T11(output.pixels[17].r>1,"T12_HDR_HEADROOM_RETAINED");
        std::printf("T12_PIXEL case=%u pattern=%u hdr=%u requested=%u effective=%u map=%u spatial=%s filter=%u format=%s alphaExact=1 finite=1\n",
            id,pattern,hdr,code,code,curve,spatial ? "shrink" : "native",c.InputFilter,fp16 ? "FP16" : "R32");
        ++id;
    }
    T11(capture.good(),"T12_CAPTURE_COMPLETE");
    std::printf("T12_MATRIX_PASS cases=%u assertions=%llu maxR32=%.17g maxFP16=%.17g resources=RAII\n",
        id,t11Checks,t11Max[0],t11Max[1]);
}

class T12FinishedWarp
{
    struct Event
    {
        HANDLE handle=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        ~Event() { if (handle) CloseHandle(handle); }
    } event;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12DescriptorHeap> heap;
    std::vector<ComPtr<ID3D12Resource>> pins;
    UINT64 watermark=0;
    bool submitted=false;
public:
    T12FinishedWarp()
    {
        ComPtr<IDXGIFactory4> factory;ComPtr<IDXGIAdapter> adapter;
        Hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));Hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        Hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
        D3D12_COMMAND_QUEUE_DESC q {};Hr(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
        Hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
        T11(event.handle!=nullptr,"T12_D12_EVENT");
        D3D12_DESCRIPTOR_RANGE ranges[] {
            {D3D12_DESCRIPTOR_RANGE_TYPE_SRV,4,0,0,0},
            {D3D12_DESCRIPTOR_RANGE_TYPE_UAV,1,0,0,4},
            {D3D12_DESCRIPTOR_RANGE_TYPE_CBV,1,0,0,5}};
        D3D12_ROOT_PARAMETER param {};param.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        param.DescriptorTable={3,ranges};
        D3D12_ROOT_SIGNATURE_DESC rd {};rd.NumParameters=1;rd.pParameters=&param;
        ComPtr<ID3DBlob> bytes,error;
        Hr(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&bytes,&error));
        Hr(device->CreateRootSignature(0,bytes->GetBufferPointer(),bytes->GetBufferSize(),IID_PPV_ARGS(&root)));
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd {};pd.pRootSignature=root.Get();
        pd.CS={dlssnr_finished_color_cso,sizeof(dlssnr_finished_color_cso)};
        Hr(device->CreateComputePipelineState(&pd,IID_PPV_ARGS(&pipeline)));
        std::puts("T12_FINISHED_SHIPPED_DXIL_D12_PSO PASS");
    }
    Image Run(const DlssNrConstants& c,const Image& source,const Image& original)
    {
        T11(source.w==c.Width&&source.h==c.Height&&original.w==c.Width&&original.h==c.Height,
            "T12_D12_TRANSPORT_EXTENT");
        Hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
        Hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),pipeline.Get(),IID_PPV_ARGS(&commands)));
        D3D12_DESCRIPTOR_HEAP_DESC hd {};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        hd.NumDescriptors=6;hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        Hr(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&heap)));
        auto cpu=heap->GetCPUDescriptorHandleForHeapStart();
        const auto step=device->GetDescriptorHandleIncrementSize(hd.Type);
        auto td=texture(c.Width,c.Height,true);td.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp {};UINT64 size=0;
        device->GetCopyableFootprints(&td,0,1,0,&fp,nullptr,nullptr,&size);
        for (const Image* image : {&source,&source,&original,&original})
        {
            auto input=create(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
            auto upload=buffer(device.Get(),size,false);
            char* data=nullptr;D3D12_RANGE noRead {0,0};
            Hr(upload->Map(0,&noRead,reinterpret_cast<void**>(&data)));
            for (unsigned y=0;y<c.Height;++y)
                std::memcpy(data+fp.Offset+y*fp.Footprint.RowPitch,image->pixels.data()+y*c.Width,c.Width*sizeof(Pixel));
            upload->Unmap(0,nullptr);
            auto from=location(upload.Get()),to=location(input.Get());
            from.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;from.PlacedFootprint=fp;
            commands->CopyTextureRegion(&to,0,0,0,&from,nullptr);
            barrier(commands.Get(),input.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            D3D12_SHADER_RESOURCE_VIEW_DESC srv {};srv.Format=td.Format;srv.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
            srv.Texture2D.MipLevels=1;srv.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            device->CreateShaderResourceView(input.Get(),&srv,cpu);cpu.ptr+=step;
            pins.push_back(input);pins.push_back(upload);
        }
        auto target=create(device.Get(),td,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        device->CreateUnorderedAccessView(target.Get(),nullptr,nullptr,cpu);cpu.ptr+=step;
        auto cb=buffer(device.Get(),256,false);
        void* values=nullptr;Hr(cb->Map(0,nullptr,&values));std::memcpy(values,&c,256);cb->Unmap(0,nullptr);
        D3D12_CONSTANT_BUFFER_VIEW_DESC cbv {cb->GetGPUVirtualAddress(),256};
        device->CreateConstantBufferView(&cbv,cpu);
        ID3D12DescriptorHeap* tables[] {heap.Get()};commands->SetDescriptorHeaps(1,tables);
        commands->SetComputeRootSignature(root.Get());commands->SetComputeRootDescriptorTable(0,heap->GetGPUDescriptorHandleForHeapStart());
        commands->Dispatch((c.Width+7)/8,(c.Height+7)/8,1);
        barrier(commands.Get(),target.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        auto readback=buffer(device.Get(),size,true);
        auto from=location(target.Get()),to=location(readback.Get());
        to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=fp;
        commands->CopyTextureRegion(&to,0,0,0,&from,nullptr);
        pins.push_back(target);pins.push_back(cb);pins.push_back(readback);
        Hr(commands->Close());++watermark;Hr(fence->SetEventOnCompletion(watermark,event.handle));
        ID3D12CommandList* lists[] {commands.Get()};submitted=true;
        queue->ExecuteCommandLists(1,lists);Hr(queue->Signal(fence.Get(),watermark));
        T11(WaitForSingleObject(event.handle,5000)==WAIT_OBJECT_0,"T12_D12_COMPLETION_TIMEOUT");
        submitted=false;
        Image result {c.Width,c.Height,std::vector<Pixel>(size_t(c.Width)*c.Height)};
        char* data=nullptr;Hr(readback->Map(0,nullptr,reinterpret_cast<void**>(&data)));
        for (unsigned y=0;y<c.Height;++y)
            std::memcpy(result.pixels.data()+y*c.Width,data+fp.Offset+y*fp.Footprint.RowPitch,c.Width*sizeof(Pixel));
        readback->Unmap(0,nullptr);pins.clear();commands.Reset();allocator.Reset();heap.Reset();
        return result;
    }
    ~T12FinishedWarp()
    {
        if (submitted)
        {
            const UINT64 tail=++watermark;
            if (FAILED(fence->SetEventOnCompletion(tail,event.handle))||FAILED(queue->Signal(fence.Get(),tail))||
                WaitForSingleObject(event.handle,5000)!=WAIT_OBJECT_0) std::terminate();
        }
        std::puts("T12_D12_RESOURCE_CLOSURE queueComplete=1 pinsReleased=1 eventRAII=1");
    }
};

double T12ExternalPQ(double units)
{
    const double p=units<=0 ? 0 : std::pow(std::clamp(units/125.0,0.0,1.0),2610.0/16384.0);
    return std::pow((3424.0/4096.0+(2413.0/128.0)*p)/(1+(2392.0/128.0)*p),2523.0/32.0);
}
float T12StoredHalfReference(float value)
{
    T11(std::isfinite(value) && value>=0 && value<=65504 &&
        (value==0 || value>=std::ldexp(1.0f,-14)),"T12_HALF_REFERENCE_DOMAIN");
    if (value==0) return value;
    int exponent=0;
    std::frexp(double(value),&exponent);
    const double step=std::ldexp(1.0,exponent-11);
    return float(std::floor(double(value)/step)*step);
}
void T12Transport(Warp& warp,ID3D11ComputeShader* shader,ID3D11ComputeShader* legacy,const char* path,
                  bool resume=false)
{
    std::ofstream capture(path);capture.precision(17);T11(capture.good(),"T12_TRANSPORT_CAPTURE");
    capture<<"case,phase,pixel,actualR,actualG,actualB,actualA,expectedR,expectedG,expectedB,expectedA,limit\n";
    T12FinishedWarp finished;
    const double anchors[] {0,1,12.5,125};
    Image pq {4,1,std::vector<Pixel>(4)},reference=pq;
    for (unsigned i=0;i<4;++i)
    {
        const float code=i ? float(T12ExternalPQ(anchors[i])) : 0;
        pq.pixels[i]={code,code,code,float(i+1)/4};
        reference.pixels[i]={float(anchors[i]),float(anchors[i]),float(anchors[i]),float(i+1)/4};
    }
    DlssNrConstants fc {};fc.Width=4;fc.Height=1;
    const auto decoded=finished.Run(fc,pq,pq);
    if (!resume)
    {
        T12Compare(capture,0,"external-decode-80nit",decoded,reference,false,"T12_EXTERNAL_PQ_ANCHORS",.005);
        for (unsigned i=0;i<4;++i) T11(decoded.pixels[i].a==pq.pixels[i].a,"T12_EXTERNAL_DECODE_ALPHA_EXACT");
    }
    else
    {
        for (unsigned i=0;i<4;++i)
        {
            const auto p=decoded.pixels[i];
            capture<<0<<",external-decode-resource-prep-observation,"<<i<<','<<p.r<<','<<p.g<<','<<p.b<<','<<p.a
                   <<",,,,"<<pq.pixels[i].a<<",0\n";
        }
        std::puts("T12_EXTERNAL_DECODE_RESOURCE_PREP reusedAnchorProof=1 newAnchorAssertions=0");
    }
    unsigned id=1,executedConnected=0;
    for (unsigned code=0;code<4;++code) for (unsigned curve : {0u,1u,3u})
    for (bool fp16 : {false,true})
    {
        if (resume && id<8) { ++id;continue; }
        DlssNrConstants c {};
        c.Width=4;c.Height=1;c.WhitePoint=1;c.ApplyModel=1;c.SignalEncoding=code;
        c.ReversibleMode=curve;c.TransferStrength=1;c.MaxRatio=4;c.DebugScale=1;
        c.Mode=DlssNrMode_Encode;
        const auto proxy=warp.Run(shader,c,decoded,decoded,decoded,fp16)[0];
        c.Mode=DlssNrMode_Resolve;
        const auto composed=warp.Run(shader,c,proxy,Model(proxy,code,false,false),decoded,fp16)[0];
        if (code)
        {
            auto storedOriginal=decoded;
            if (fp16) for (auto& p:storedOriginal.pixels)
            {
                p.r=T12StoredHalfReference(p.r);p.g=T12StoredHalfReference(p.g);p.b=T12StoredHalfReference(p.b);
            }
            T12Compare(capture,id,"connected-native-nr",composed,storedOriginal,fp16,"T12_CONNECTED_NR_HEADROOM");
        }
        else
        {
            auto lc=c;lc.Mode=DlssNrMode_Encode;
            const auto lp=warp.Run(legacy,lc,decoded,decoded,decoded,fp16)[0];
            lc.Mode=DlssNrMode_Resolve;
            const auto prior=warp.Run(legacy,lc,lp,Model(lp,0,false,false),decoded,fp16)[0];
            T12Compare(capture,id,"connected-legacy",composed,prior,fp16,"T12_CONNECTED_LEGACY_REFERENCE");
            Exact(composed,prior,"T12_CONNECTED_LEGACY_EXACT");
        }
        fc.Mode=1;
        const auto encoded=finished.Run(fc,composed,pq);
        auto expected=pq;
        for (unsigned i=0;i<4;++i)
        {
            const auto p=composed.pixels[i];
            const double r=.6274039*p.r+.3292830*p.g+.0433131*p.b;
            const double g=.0690973*p.r+.9195404*p.g+.0113623*p.b;
            const double b=.0163914*p.r+.0880133*p.g+.8955953*p.b;
            expected.pixels[i]={float(T12ExternalPQ(r)),float(T12ExternalPQ(g)),float(T12ExternalPQ(b)),pq.pixels[i].a};
            T11(composed.pixels[i].a==decoded.pixels[i].a&&encoded.pixels[i].a==pq.pixels[i].a,
                "T12_CONNECTED_ORIGINAL_ALPHA_EXACT");
            T11(std::isfinite(composed.pixels[i].r)&&std::isfinite(encoded.pixels[i].r),"T12_CONNECTED_FINITE");
        }
        T12Compare(capture,id,"external-encode-80nit",encoded,expected,false,"T12_EXTERNAL_TRANSPORT_ENCODE",.0002);
        T11(composed.pixels[2].r>1&&composed.pixels[3].r>1,"T12_CONNECTED_HDR_HEADROOM");
        if (code) T12Compare(capture,id,"connected-pq-roundtrip",encoded,pq,false,"T12_CONNECTED_PQ_ROUNDTRIP",.0002);
        std::printf("T12_TRANSPORT case=%u effective=%u map=%u nrFormat=%s anchors=0/80/1000/10000 alphaExact=1\n",
            id,code,curve,fp16 ? "FP16" : "R32");
        ++id;++executedConnected;
    }
    const float local100=float(T12ExternalPQ(1.25));
    Image calibration {1,1,{{local100,local100,local100,.5f}}};
    DlssNrConstants c {};c.Width=c.Height=1;c.ApplyModel=1;c.WhitePoint=1;
    c.Mode=DlssNrMode_Resolve;c.SignalEncoding=3;c.DebugView=2;c.DebugScale=1;
    const auto local=warp.Run(shader,c,calibration,calibration,calibration,false)[0];
    Image localExpected {1,1,{{1,1,1,.5f}}};
    T12Compare(capture,id,"local-pq-100nit",local,localExpected,false,"T12_LOCAL_PQ_100_NIT");
    fc.Mode=0;fc.Width=fc.Height=1;
    const auto external=finished.Run(fc,calibration,calibration);
    Image externalExpected {1,1,{{1.25f,1.25f,1.25f,.5f}}};
    T12Compare(capture,id,"external-pq-80nit",external,externalExpected,false,"T12_EXTERNAL_PQ_80_NIT",.005);
const float alphaEdges[] {0,std::ldexp(1.0f,-24),std::ldexp(1.0f,-14),.99951171875f,1,1.0009765625f};
    Image alphaPq {6,1,std::vector<Pixel>(6)};
    for (unsigned i=0;i<6;++i) alphaPq.pixels[i]={pq.pixels[1].r,pq.pixels[1].g,pq.pixels[1].b,alphaEdges[i]};
    fc.Mode=0;fc.Width=6;fc.Height=1;
    const auto alphaDecoded=finished.Run(fc,alphaPq,alphaPq);
    unsigned alphaCases=0;
    for (unsigned code=0;code<4;++code) for (unsigned curve=0;curve<5;++curve)
    for (bool fp16 : {false,true})
    {
        DlssNrConstants ac {};ac.Width=6;ac.Height=1;ac.WhitePoint=1;ac.ApplyModel=1;
        ac.SignalEncoding=code;ac.ReversibleMode=curve;ac.TransferStrength=1;ac.MaxRatio=4;
        ac.Mode=DlssNrMode_Encode;
        const auto ap=warp.Run(shader,ac,alphaDecoded,alphaDecoded,alphaDecoded,fp16)[0];
        const auto answer=Model(ap,code,false,false);
        unsigned differentAlpha=0;
        for (unsigned i=0;i<6;++i) differentAlpha+=answer.pixels[i].a!=alphaEdges[i];
        T11(differentAlpha==5,"T12_MODEL_ALPHA_INDEPENDENT_FROM_ORIGINAL");
        ac.Mode=DlssNrMode_Resolve;
        const auto composed=warp.Run(shader,ac,ap,answer,alphaDecoded,fp16)[0];
        fc.Mode=1;
        const auto final=finished.Run(fc,composed,alphaPq);
        auto expected=alphaPq;
        for (unsigned i=0;i<6;++i)
        {
            const auto p=composed.pixels[i];
            const double r=.6274039*p.r+.3292830*p.g+.0433131*p.b;
            const double g=.0690973*p.r+.9195404*p.g+.0113623*p.b;
            const double b=.0163914*p.r+.0880133*p.g+.8955953*p.b;
            expected.pixels[i]={float(T12ExternalPQ(r)),float(T12ExternalPQ(g)),float(T12ExternalPQ(b)),alphaEdges[i]};
            T11(std::memcmp(&alphaDecoded.pixels[i].a,&alphaEdges[i],4)==0&&
                std::memcmp(&composed.pixels[i].a,&alphaEdges[i],4)==0&&
                std::memcmp(&final.pixels[i].a,&alphaEdges[i],4)==0,"T12_ALPHA_EDGE_BITWISE");
            capture<<id<<",alpha-nr-observation,"<<i<<','<<p.r<<','<<p.g<<','<<p.b<<','<<p.a
                   <<",,,,"<<alphaEdges[i]<<",0\n";
        }
        T12Compare(capture,id,"alpha-transport",final,expected,false,"T12_ALPHA_EXTERNAL_TRANSPORT",.0002);
        std::printf("T12_ALPHA case=%u effective=%u map=%u nrFormat=%s vectorCount=6 bitwise=1 modelAlphaDifferent=5\n",
            id,code,curve,fp16 ? "FP16" : "R32");
        ++id;++alphaCases;
    }
    T11(alphaCases==40&&capture.good(),"T12_ALPHA_CAPTURE_COMPLETE");
    T11(executedConnected==(resume ? 17u : 24u),"T12_CONNECTED_CASE_COVERAGE");
    if (resume)
        std::puts("T12_TRANSPORT_RESUME_PASS executedConnectedCases=17 reusedConnectedCases=7 alphaCases=40 reusedExternalAnchors=4 local100nit=1 external80nit=1 resources=RAII");
    else
        std::puts("T12_TRANSPORT_PASS connectedCases=24 alphaCases=40 externalAnchors=4 local100nit=1 external80nit=1 resources=RAII");
}

int main(int argc, char** argv)
try
{
    if (argc==6 && (std::string(argv[1])=="--task12" || std::string(argv[1])=="--task12-transport" ||
                   std::string(argv[1])=="--task12-transport-resume"))
    {
        const auto fresh=Blob(argv[2]);
        T11(fresh.size()==sizeof(DlssNr_cso) && std::equal(fresh.begin(),fresh.end(),DlssNr_cso),
            "T12_INSTALLED_FRESH_BYTECODE_EXACT");
        Warp warp;
        if (std::string(argv[5])!="-") T11(Blob(argv[5])!=fresh,"T12_ACTUAL_MUTANT_DIFFERS");
        const auto current=warp.Shader(std::string(argv[5])=="-" ? fresh : Blob(argv[5]));
        const auto legacy=warp.Shader(Blob(argv[3]));
        if (std::string(argv[1])=="--task12-transport" || std::string(argv[1])=="--task12-transport-resume")
            T12Transport(warp,current.Get(),legacy.Get(),argv[4],std::string(argv[1])=="--task12-transport-resume");
        else T12Matrix(warp,current.Get(),legacy.Get(),argv[4]);
        return 0;
    }
    T11(argc==6 || argc==7,
        "T11_CLI: fresh.cso current-recipes.bin legacy.cso accepted-task9-recipes.bin pre-guard.cso [mutant.cso]");
    const auto fresh=Blob(argv[1]), legacyBytes=Blob(argv[3]);
    // This gate runs before device creation and before every possible dispatch, including mutant mode.
    T11(fresh.size()==sizeof(DlssNr_cso) &&
        std::equal(fresh.begin(),fresh.end(),DlssNr_cso), "T11_INSTALLED_FRESH_BYTECODE_EXACT");
    std::puts("T11_INSTALLED_FRESH_BYTECODE_EXACT PASS");
    const auto current=Recipes(argv[2]), accepted=Recipes(argv[4]);
    Matrix(current,accepted);
    Warp warp;
    const auto installed=warp.Shader(fresh), legacy=warp.Shader(legacyBytes);
    const auto preGuard=warp.Shader(Blob(argv[5]));
    if (argc==7 && std::string(argv[6])=="--diagnose-scope")
    {
        Vectors(warp,installed.Get(),legacy.Get());
        GuardExclusions(warp,installed.Get(),preGuard.Get());
        std::puts("T11_SCOPE_DIAGNOSTIC_PASS vectors=72 exclusions=90");
        return 0;
    }
    if (argc==7 && std::string(argv[6]).starts_with("--diagnose-graph"))
    {
        const std::string option=argv[6];
        const auto separator=option.find('=');
        const unsigned recipe=separator==std::string::npos ? 0 : unsigned(std::stoul(option.substr(separator+1)));
        const auto output=Execute(warp,installed.Get(),current.at(recipe),false,true,
                Signal(current.at(recipe))==0 ? legacy.Get() : preGuard.Get());
        const auto comma=option.find(',');
        if (comma!=std::string::npos)
        {
            const auto comparison=warp.Shader(Blob(option.substr(comma+1).c_str()));
            const auto oldOutput=Execute(warp,legacy.Get(),current.at(recipe),false,false);
            const auto preQ7=Execute(warp,comparison.Get(),current.at(recipe),false,false);
            for (const auto& op:current.at(recipe).operations)
            {
                const auto* words=reinterpret_cast<const unsigned char*>(&op.constants);
                std::printf("T11_EXACT_DISPATCH kind=%u source=%u model=%u original=%u output=%u keep=%u constants=",op.kind,op.source,op.model,op.original,op.output,op.keep);
                for (size_t byte=0;byte<sizeof(op.constants);++byte) std::printf("%02x",words[byte]);
                std::puts("");
            }
            for (size_t pixel=0;pixel<output.pixels.size();++pixel)
            {
                const auto* a=reinterpret_cast<const unsigned char*>(&output.pixels[pixel]);
                const auto* b=reinterpret_cast<const unsigned char*>(&oldOutput.pixels[pixel]);
                const auto* c=reinterpret_cast<const unsigned char*>(&preQ7.pixels[pixel]);
                if (std::memcmp(a,b,sizeof(Pixel))!=0)
                {
                    std::printf("T11_LEGACY_EXACT_VECTOR recipe=%u pixel=%zu current=",recipe,pixel);
                    for (size_t byte=0;byte<sizeof(Pixel);++byte) std::printf("%02x",a[byte]);
                    std::printf(" accepted=");
                    for (size_t byte=0;byte<sizeof(Pixel);++byte) std::printf("%02x",b[byte]);
                    std::printf(" preQ7=");
                    for (size_t byte=0;byte<sizeof(Pixel);++byte) std::printf("%02x",c[byte]);
                    std::puts("");
                }
            }
            Exact(output,oldOutput,"T11_LEGACY_CURRENT_GRAPH_EXACT");
        }
        std::printf("T11_GRAPH_DIAGNOSTIC_PASS recipe=%u format=R32\n",recipe);
        return 0;
    }
    ComPtr<ID3D11ComputeShader> tested=installed;
    const bool graphOnly=argc==7 && std::string(argv[6])=="--graph-only";
    if (argc==7 && !graphOnly)
    {
        const auto mutant=Blob(argv[6]);
        T11(mutant!=fresh,"T11_MUTANT_DERIVED_BYTES_DIFFER");
        // The caller-supplied derived blob itself creates this shader. No installed-byte parity
        // assertion is applied to it; all mathematical and graph assertions below remain active.
        tested=warp.Shader(mutant);
        std::printf("T11_MUTANT_BYTECODE_BOUND bytes=%zu path=%s\n",mutant.size(),argv[6]);
    }
    if (!graphOnly)
    {
        Vectors(warp,tested.Get(),legacy.Get());
        GuardExclusions(warp,tested.Get(),preGuard.Get());
    }
    else std::puts("T11_GRAPH_ONLY_SCOPE_REUSED externally-bound vectors=72 exclusions=90");
    for (const auto& recipe:current) for (bool fp16 : {false,true})
    {
        const unsigned code=Signal(recipe);
        const auto actual=Execute(warp,tested.Get(),recipe,fp16,true);
        if (code==0 || recipe.header[7]==0)
        {
            // Reuse the current captured graph and actual constants; never replay an old suite.
            // SDR is also qualified for exact baseline comparison because its effective codec is bypassed.
            const auto prior=Execute(warp,legacy.Get(),recipe,fp16,false);
            if (code==0) Exact(actual,prior,"T11_LEGACY_CURRENT_GRAPH_EXACT");
            if (recipe.header[7]==0) Exact(actual,prior,"T11_SDR_PASSTHROUGH_EXACT");
            ++t11Legacy;
        }
        std::printf("T11_PIXEL id=%u signal=%u hdr=%u filter=%u transfer=%u curve=%u edit=%u "
                    "branch=%u shape=%ux%u->%ux%u format=%s\n",
                    recipe.header[0],code,recipe.header[7],recipe.header[5],recipe.header[6],
                    recipe.header[8],recipe.header[9],recipe.header[10],recipe.header[1],recipe.header[2],
                    recipe.header[3],recipe.header[4],fp16 ? "FP16" : "R32");
    }
    std::printf("T11_SIGNAL_PASS assertions=%llu recipes=%u exactBaseline=%u bypass=%u carriers=%u "
                "maxR32=%.17g maxFP16=%.17g bypassMaxR32=%.17g bypassMaxFP16=%.17g "
                "legacyMaxR32=%.17g legacyMaxFP16=%.17g resources=RAII\n",
                t11Checks,t11Recipes,t11Legacy,t11Bypass,t11Carriers,t11Max[0],t11Max[1],
                t11BypassMax[0],t11BypassMax[1],t11LegacyMax[0],t11LegacyMax[1]);
    return 0;
}
catch (const std::exception& error)
{
    std::printf("T11_SIGNAL_FAIL assertions=%llu recipes=%u maxR32=%.17g maxFP16=%.17g reason=%s\n",
                t11Checks,t11Recipes,t11Max[0],t11Max[1],error.what());
    return 1;
}
