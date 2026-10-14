#pragma once
#include "../nr_diagnostics/Adapter.h"
#include <framegen/dlssg/MfgUnlockStatus.h>
#include <atomic>
#include <memory>
namespace MfgUnlock
{
inline Status fixtureStatus;
inline Telemetry fixtureTelemetry;
inline Status LastStatus() { return fixtureStatus; }
inline TemporalMethod ConfiguredTemporalMethod() { return ResolveTemporalMethod(Config::Instance()->FGDLSSGAdaTemporalFix); }
inline const Telemetry& GetTelemetry() { return fixtureTelemetry; }
}
#if defined(T19_JOB_DLL)
inline bool fixtureForeground=true, fixtureControl=false, fixtureF8=false, fixtureF9=false;
inline bool fixtureSubmitFailure=false, fixtureReferenceFailure=false;
inline std::atomic_uint fixtureSubmissions {0}, fixtureDeferredReleases {0};
extern HANDLE fixtureEntered,fixtureRelease;
void Require(bool,const char*);
struct FixtureDispatch {PTP_SIMPLE_CALLBACK callback;void* context;};
inline void CALLBACK FixtureDispatchWorker(PTP_CALLBACK_INSTANCE instance,void* context)
{
 std::unique_ptr<FixtureDispatch> request(static_cast<FixtureDispatch*>(context));
 SetEvent(fixtureEntered);
 Require(WaitForSingleObject(fixtureRelease,10000)==WAIT_OBJECT_0,"T19_WORKER_START_EVENT");
 auto callback=request->callback;auto argument=request->context;
 request.reset();
 callback(instance,argument);
}
inline HWND FixtureForegroundWindow(){return reinterpret_cast<HWND>(1);}
inline DWORD FixtureForegroundProcess(HWND,DWORD* process) {
 *process=GetCurrentProcessId()+(fixtureForeground?0:1);return 1;
}
inline SHORT FixtureKey(int key) {
 bool down=key==VK_CONTROL?fixtureControl:key==VK_F8?fixtureF8:key==VK_F9?fixtureF9:false;
 return down?SHORT(-32768):SHORT(0);
}
inline void FixtureTime(SYSTEMTIME* time){*time={};time->wYear=2026;time->wMonth=10;time->wDay=3;}
inline BOOL FixtureSubmit(PTP_SIMPLE_CALLBACK callback,void* context,PTP_CALLBACK_ENVIRON environment) {
 ++fixtureSubmissions;
 if(fixtureSubmitFailure)return FALSE;
 auto request=std::make_unique<FixtureDispatch>(FixtureDispatch{callback,context});
 if(!::TrySubmitThreadpoolCallback(FixtureDispatchWorker,request.get(),environment))return FALSE;
 request.release();return TRUE;
}
inline BOOL FixtureModuleReference(DWORD flags,LPCWSTR name,HMODULE* module) {
 if(fixtureReferenceFailure && (flags&GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS)){*module=nullptr;return FALSE;}
 return ::GetModuleHandleExW(flags,name,module);
}
inline void FixtureDeferredRelease(PTP_CALLBACK_INSTANCE instance,HMODULE module) {
 ++fixtureDeferredReleases;::FreeLibraryWhenCallbackReturns(instance,module);
}
#define GetForegroundWindow FixtureForegroundWindow
#define GetWindowThreadProcessId FixtureForegroundProcess
#define GetAsyncKeyState FixtureKey
#define GetLocalTime FixtureTime
#define TrySubmitThreadpoolCallback FixtureSubmit
#define GetModuleHandleExW FixtureModuleReference
#define FreeLibraryWhenCallbackReturns FixtureDeferredRelease
#endif
