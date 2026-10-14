#pragma once

// Typed boundary services only. Production Models/Proxy/Encode/Run bodies are
// included unchanged by the runner; these resources record their actual edges.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include "../../OptiScaler/shaders/dlssnr/DlssNr_Common.h"
#include "../../OptiScaler/dlssnr/DlssNr_Options.h"

using UINT = unsigned int;
using DXGI_FORMAT = unsigned;
using D3D12_RESOURCE_STATES = unsigned;
constexpr unsigned D3D12_RESOURCE_STATE_COMMON = 0, D3D12_RESOURCE_STATE_UNORDERED_ACCESS = 1,
    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE = 2, D3D12_RESOURCE_STATE_COPY_SOURCE = 3,
    D3D12_RESOURCE_STATE_COPY_DEST = 4, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS = 1,
    D3D12_RESOURCE_DIMENSION_TEXTURE2D = 2, D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION = 16384,
    D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX = 0, DXGI_FORMAT_R32G32B32A32_FLOAT = 2;
#ifdef NR_SIGNAL_CARRIER
constexpr unsigned D3D12_COMMAND_LIST_TYPE_DIRECT = 0, DXGI_FORMAT_R16G16B16A16_FLOAT = 10,
    DXGI_FORMAT_R32_FLOAT = 11, DXGI_FORMAT_R32G32_FLOAT = 12;
#endif
struct D3D12_RESOURCE_DESC
{
    unsigned long long Width = 0;
    unsigned Height = 0, Format = 1, Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    unsigned short DepthOrArraySize = 1;
    struct { unsigned Count = 1; } SampleDesc;
    unsigned Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
};
struct ID3D12Device {};
// This boundary only compares IUnknown pointers; it does not implement COM.
// A declaration can coexist with the SDK's actual interface definition.
struct IUnknown;
struct ID3D12Resource
{
    inline static unsigned nextId = 0;
    unsigned id = ++nextId;
    D3D12_RESOURCE_DESC desc;
    ID3D12Device* device = nullptr;
    ID3D12Resource(unsigned w = 1, unsigned h = 1) { desc.Width = w; desc.Height = h; }
    D3D12_RESOURCE_DESC GetDesc() const { return desc; }
    int GetDevice(ID3D12Device** out) { *out = device; return device ? 0 : -1; }
};
struct D3D12_TEXTURE_COPY_LOCATION { ID3D12Resource* pResource; unsigned Type; };
struct D3D12_BOX { unsigned left, top, front, right, bottom, back; };
namespace FilterFixture
{
struct Operation
{
    unsigned kind, source, model, original, output, keep;
    DlssNrConstants constants;
};
inline std::vector<Operation> operations;
inline bool upReady = true, downReady = true, dispatchReady = true;
inline void Record(unsigned kind, ID3D12Resource* source, ID3D12Resource* model,
                   ID3D12Resource* original, ID3D12Resource* output, ID3D12Resource* keep,
                   const DlssNrConstants& constants = {})
{
    operations.push_back({kind, source ? source->id : 0, model ? model->id : 0,
        original ? original->id : 0, output ? output->id : 0, keep ? keep->id : 0, constants});
}
inline void Require(bool value, const char* name)
{
    if (!value) throw std::runtime_error(name);
}
}
namespace DlssNr
{
inline constexpr unsigned MaxPassCount = 30, DefaultMaxPassCount = 3;
}
struct ID3D12CommandList {};
struct ID3D12GraphicsCommandList : ID3D12CommandList
{
#ifdef NR_SIGNAL_CARRIER
    unsigned GetType() const { return D3D12_COMMAND_LIST_TYPE_DIRECT; }
#endif
    void CopyResource(ID3D12Resource* dst, ID3D12Resource* src)
    { FilterFixture::Record(4, src, nullptr, nullptr, dst, nullptr); }
    void CopyTextureRegion(const D3D12_TEXTURE_COPY_LOCATION* dst, unsigned, unsigned, unsigned,
                           const D3D12_TEXTURE_COPY_LOCATION* src, const D3D12_BOX*)
    { CopyResource(dst->pResource, src->pResource); }
};
struct ID3D12CommandQueue
{
#ifdef NR_SIGNAL_CARRIER
    struct Desc { unsigned Type = D3D12_COMMAND_LIST_TYPE_DIRECT; };
    Desc GetDesc() const { return {}; }
    ID3D12Device* device = nullptr;
    int GetDevice(ID3D12Device** out) { *out = device; return device ? 0 : -1; }
#endif
};
namespace Microsoft::WRL
{
template<class T> struct ComPtr
{
    T* pointer = nullptr;
    T* Get() const { return pointer; }
    T** operator&() { return &pointer; }
#ifdef NR_SIGNAL_CARRIER
    void Attach(T* p) { pointer=p; }
    T* operator->() const { return pointer; }
    explicit operator bool() const { return pointer!=nullptr; }
    ComPtr& operator=(T* p) { pointer=p; return *this; }
#endif
};
}
#define IID_PPV_ARGS(p) (p)
#define FAILED(value) ((value) < 0)
#define LOG_WARN(...) ((void)0)
enum class API { DX12, DX11, Vulkan };
struct State
{
    API swapchainApi = API::DX12;
    static State& Instance() { static State value; return value; }
};
enum class Scaler : uint32_t { Bicubic, Count };
struct OS_Dx12
{
    bool up;
    OS_Dx12(const char*, ID3D12Device*, bool enlarge, Scaler) : up(enlarge) {}
    bool DispatchResources(ID3D12GraphicsCommandList*, ID3D12Resource* src, ID3D12Resource* dst)
    {
        if (!(up ? FilterFixture::upReady : FilterFixture::downReady)) return false;
        DlssNrConstants sizes {};
        sizes.Width = unsigned(dst->desc.Width); sizes.Height = dst->desc.Height;
        FilterFixture::Record(up ? 2 : 3, src, nullptr, nullptr, dst, nullptr, sizes);
        return true;
    }
};
namespace D3D12Hooks
{
inline bool CanRestoreRootSignature(ID3D12GraphicsCommandList*) { return true; }
}
namespace Util
{
inline std::filesystem::path DllPath() { return {}; }
inline bool CheckForRealObject(const char*, ID3D12GraphicsCommandList*, IUnknown**) { return false; }
#ifdef NR_SIGNAL_CARRIER
inline bool CheckForRealObject(const char*, ID3D12CommandQueue*, IUnknown**) { return false; }
#endif
}
namespace ResTrack_Dx12 { inline void HookLateNrQueue(ID3D12Device*) {} }
struct DlssNrGpuTime
{
    explicit DlssNrGpuTime(ID3D12Device*) {}
    void Start(ID3D12GraphicsCommandList*) {}
    void End(ID3D12GraphicsCommandList*) {}
};
