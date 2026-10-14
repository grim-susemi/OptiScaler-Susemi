#pragma once
// Services around the extracted production hook bodies; all GPU work remains owned.
using IFGFeature = Fg;
static constexpr API DX11 = API::DX11, DX12 = API::DX12;
namespace Util
{
double MillisecondsNow() { static double now=100; return now+=16; }
void GetDeviceRemovedReason(ID3D11Device*) { throw std::runtime_error("UnexpectedDeviceRemoval"); }
void GetDeviceRemovedReason(ID3D12Device*) { throw std::runtime_error("UnexpectedDeviceRemoval"); }
}
namespace sl
{
struct FrameToken {};
enum class Result { eOk, eErrorReflexAPI };
enum class PCLMarker { ePresentStart, ePresentEnd };
}
namespace ReflexHooks
{
bool gameIsSendingMarkers() { return false; }
void update(bool,bool) {}
}
namespace StreamlineProxy
{
using Marker = void(*)(sl::PCLMarker,sl::FrameToken&);
using Token = sl::Result(*)(sl::FrameToken*&,const uint32_t*);
using Sleep = void(*)(sl::FrameToken&);
Marker PCLSetMarker() { return nullptr; }
Token GetNewFrameToken() { return nullptr; }
Sleep ReflexSleep() { return nullptr; }
}
namespace Hudfix_Dx12 { void PresentStart() {} void PresentEnd() {} }
namespace ResTrack_Dx12 { void ClearPossibleHudless() {} }
namespace D3D12Hooks { void HookDevice(ID3D12Device*) {} }
namespace IdentifyGpu
{
struct Info { bool usesDxvk=false; };
Info getPrimaryGpu() { return {}; }
}
namespace XellHooks { bool canLimit() { return false; } void update() {} }
namespace FrameLimit { void sleep(bool) { throw std::runtime_error("UnexpectedFrameLimiter"); } }
namespace Dx11wDx12Sync
{
std::shared_mutex& PresentResizeMutex() { static std::shared_mutex mutex; return mutex; }
}
using xefg_swapchain_handle_t=void*;
struct xefg_swapchain_present_status_t
{
    int isFrameGenEnabled=0;
    unsigned frameGenResult=0,framesPresented=0;
};
static constexpr int XEFG_SWAPCHAIN_RESULT_SUCCESS=0;
namespace XeFGProxy
{
using Status=int(*)(xefg_swapchain_handle_t,xefg_swapchain_present_status_t*);
Status GetLastPresentStatus() { return nullptr; }
}
void ffxPresentCallback() {}
namespace FSR3FG { void ffxPresentCallback() {} }
namespace fakenvapi { void reportFGPresent(IDXGISwapChain*,bool,bool) {} }
namespace DlssNr
{
void ApplyToFinishedPictureDx11(IDXGISwapChain*) { throw std::runtime_error("UnexpectedDx11Route"); }
}
namespace WrappedGpu
{
static uint64_t _frameCounter=0;
static double _lastFrameTime=0;
static bool _dx11Device=false,_dx12Device=false;
#include "TemporalLocalPresent.inc"
}
using PresentFn=HRESULT(__stdcall*)(IDXGISwapChain*,UINT,UINT);
using Present1Fn=HRESULT(__stdcall*)(IDXGISwapChain1*,UINT,UINT,const DXGI_PRESENT_PARAMETERS*);
namespace FGHooks
{
static UINT _lastPresentFlags=0;
static double _lastFGFrameTime=0;
static std::shared_mutex _resizeMutex;
static HANDLE _semaphore=nullptr;
static PresentFn o_FGSCPresent=nullptr;
static Present1Fn o_FGSCPresent1=nullptr;
uint64_t XeFGHandoffSequence() { return records; }
bool XeFGHandoffSince(uint64_t,uint64_t&,uint64_t&,void*&) { return false; }
HRESULT FGPresent(IDXGISwapChain*,UINT,UINT,const DXGI_PRESENT_PARAMETERS*);
}
#include "TemporalGpuFGPresent.inc"
static unsigned actualOriginalCalls=0;
static HRESULT originalResult=S_OK;
static HRESULT __stdcall OwnedOriginal(IDXGISwapChain* chain,UINT sync,UINT flags)
{
    ++actualOriginalCalls;
    originalResult=WrappedGpu::LocalPresent(chain,sync,flags,nullptr,
        State::Instance().currentCommandQueue,nullptr,false);
    return originalResult;
}
static HRESULT __stdcall OwnedOriginal1(IDXGISwapChain1* chain,UINT sync,UINT flags,
                                        const DXGI_PRESENT_PARAMETERS* parameters)
{
    ++actualOriginalCalls;
    originalResult=WrappedGpu::LocalPresent(chain,sync,flags,parameters,
        State::Instance().currentCommandQueue,nullptr,false);
    return originalResult;
}
static HRESULT TemporalApplicationPresent(IDXGISwapChain* chain,UINT sync,UINT flags,
                                          const DXGI_PRESENT_PARAMETERS* parameters)
{
    return FGHooks::FGPresent(chain,sync,flags,parameters);
}
static UINT TemporalApplicationIndex(IDXGISwapChain* chain)
{
    ComPtr<IDXGISwapChain3> current; Check(chain->QueryInterface(IID_PPV_ARGS(&current)));
    return current->GetCurrentBackBufferIndex();
}
