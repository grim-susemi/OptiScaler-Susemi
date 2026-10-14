#include "Services.h"
#include <dlssnr/DlssNr_NgxDiagnostics.h>
#include <iostream>
#include <memory>
#include <fstream>

using namespace DlssNr::MfgDiagnostics;
void Require(bool value, const char* assertion)
{
    if (!value) { std::cout << "ASSERTION_FAILED " << assertion << '\n'; std::exit(41); }
}
#if defined(T19_JOB_DLL)
std::recursive_mutex nrOwnersMutex;
std::atomic_uint nrCaptureOutstanding {0};
struct EntryState {
 std::mutex mutex; unsigned pipelineCaptureRemaining=0;
 struct Late {DlssNr::FinishedIdentity consumer;} late;
};
struct EntryDevice {LUID GetAdapterLuid(){return {17,19};}};
struct DlssNr_Dx12
{
    std::unique_ptr<EntryState> _state=std::make_unique<EntryState>();
    EntryDevice device;
    EntryDevice* _device=&device;
    void DiagnosePipeline(unsigned,ID3D12GraphicsCommandList*,NVSDK_NGX_Parameter*,ID3D12Resource*,uint32_t,bool,bool);
};
// Unchanged, manifest-bound production method; not a copied admission policy.
#include "entry.inc"
std::unique_ptr<DlssNr_Dx12> fixtureOwner;
HANDLE fixtureEntered=nullptr,fixtureRelease=nullptr,fixtureUnloaded=nullptr;
DWORD fixtureEntryThread=0;
void FileGate()
{
    Require(GetCurrentThreadId()!=fixtureEntryThread,"T19_FILE_WORK_OTHER_THREAD");
    SetEvent(fixtureEntered);
    Require(WaitForSingleObject(fixtureRelease,10000)==WAIT_OBJECT_0,"T19_WORKER_RELEASE_EVENT");
}
extern "C" __declspec(dllexport) void Setup(HANDLE entered,HANDLE release,HANDLE unloaded,const wchar_t* root)
{
    fixtureEntered=entered;fixtureRelease=release;fixtureUnloaded=unloaded;
    fixtureEntryThread=GetCurrentThreadId();
    Util::dllPathOverride=std::filesystem::path(root)/"fixture.dll";
    Config::Instance()->FGDLSSGAdaTemporalFix="Ptx";
    Util::onFileVersion=FileGate;
    diagnosticSink=[](const std::string& line){std::cout<<line<<'\n';};
    fixtureOwner=std::make_unique<DlssNr_Dx12>();
}
extern "C" __declspec(dllexport) unsigned Entry(unsigned stage,bool enabled,bool focused,bool control,bool f8,bool f9,
                                               bool busy,bool failSubmit,bool failReference)
{
    Config::Instance()->DlssNrEnabled.value=enabled;
    fixtureForeground=focused;fixtureControl=control;fixtureF8=f8;fixtureF9=f9;
    fixtureSubmitFailure=failSubmit;fixtureReferenceFailure=failReference;
    fixtureOwner->_state->pipelineCaptureRemaining=busy?1:0;
    const auto logs=diagnosticLines.size();
    fixtureOwner->DiagnosePipeline(stage,nullptr,nullptr,nullptr,0,false,false);
    Require(diagnosticLines.size()==logs,"T19_ENTRY_NO_SYNCHRONOUS_LOG");
    Require(fixtureOwner->_state->pipelineCaptureRemaining==(busy?1u:0u),"T19_NO_LEGACY_CAPTURE_ARM");
    return fixtureSubmissions.load();
}
extern "C" __declspec(dllexport) unsigned QueueResult()
{
    return unsigned(DlssNr::NgxDiagnostics::LastMfgQueueResult());
}
extern "C" __declspec(dllexport) void RetireOwner()
{
    fixtureOwner.reset();
    Config::Instance()->FGDLSSGAdaTemporalFix="Retarget";
    Util::dllPathOverride="retired-must-not-be-used";
}
BOOL WINAPI DllMain(HINSTANCE,DWORD reason,LPVOID)
{
    if(reason==DLL_PROCESS_DETACH && fixtureUnloaded)SetEvent(fixtureUnloaded);
    return TRUE;
}
#elif defined(T19_ENTRY_HOST)
unsigned FieldUnsigned(const std::string& json,const char* key)
{
    const auto start=json.find(std::string("\"")+key+"\":");
    Require(start!=std::string::npos,"T19_METADATA_FIELD_AVAILABLE");
    return unsigned(std::stoul(json.substr(start+std::strlen(key)+3)));
}
int main(int argc,char** argv)
{
    if(argc!=4)return 2;
    const std::filesystem::path dll=argv[1],root=argv[2];
    const std::string name=argv[3];
    HANDLE entered=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE release=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE unloaded=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    Require(entered && release && unloaded,"T19_SUBSCRIBE_EVENTS");
    const auto module=LoadLibraryW(dll.c_str());
    Require(module!=nullptr,"T19_OWNED_FIXTURE_DLL_LOAD");
    using SetupFn=void(*)(HANDLE,HANDLE,HANDLE,const wchar_t*);
    using EntryFn=unsigned(*)(unsigned,bool,bool,bool,bool,bool,bool,bool,bool);
    auto setup=reinterpret_cast<SetupFn>(GetProcAddress(module,"Setup"));
    auto entry=reinterpret_cast<EntryFn>(GetProcAddress(module,"Entry"));
    auto queue=reinterpret_cast<unsigned(*)()>(GetProcAddress(module,"QueueResult"));
    auto retire=reinterpret_cast<void(*)()>(GetProcAddress(module,"RetireOwner"));
    Require(setup && entry && queue && retire,"T19_REAL_ENTRY_EXPORTS");
    setup(entered,release,unloaded,root.c_str());
    const bool off=name=="off",unfocused=name=="unfocused",busy=name=="busy",stage=name=="other-stage";
    const bool queueFail=name=="queue-failure",referenceFail=name=="reference-failure";
    unsigned submissions=entry(stage?1:0,!off,!unfocused,true,true,false,busy,queueFail,referenceFail);
    const bool noqueue=off||unfocused||busy||stage||referenceFail;
    if(noqueue)Require(submissions==0,"T19_REJECTED_EDGE_NO_QUEUE");
    else Require(submissions==1,"T19_ACTUAL_ENTRY_ENQUEUE");
    if(queueFail)Require(queue()==unsigned(DlssNr::NgxDiagnostics::MfgQueueResult::SubmissionFailed),
                         "T19_QUEUE_FAILURE_EXPLICIT");
    if(referenceFail)Require(queue()==unsigned(DlssNr::NgxDiagnostics::MfgQueueResult::ModuleReferenceUnavailable),
                             "T19_REFERENCE_FAILURE_EXPLICIT");
    if(!noqueue && !queueFail)
    {
        Require(WaitForSingleObject(entered,10000)==WAIT_OBJECT_0,"T19_EVENT_BEFORE_SUBMISSION");
        // The collector is blocked by an unreleased event, yet the actual entry already returned.
        Require(!std::filesystem::exists(root/"nr-pipeline-captures"),"T19_ENTRY_NONBLOCKING_NO_FILE");
        if(name=="held")Require(entry(0,true,true,true,true,false,false,false,false)==1,"T19_HELD_EDGE_ONCE");
        if(name=="exhausted")
        {
            entry(0,true,true,true,false,false,false,false,false);
            Require(entry(0,true,true,true,false,true,false,false,false)==2,"T19_SECOND_EDGE_ONCE");
            entry(0,true,true,true,false,false,false,false,false);
            Require(entry(0,true,true,true,true,false,false,false,false)==2,"T19_TWO_RUN_BOUND");
        }
        retire();
        Require(FreeLibrary(module),"T19_CALLER_DLL_RELEASE");
        Require(GetModuleHandleW(dll.c_str())!=nullptr,"T19_DLL_PIN_WHILE_WORKER");
        SetEvent(release);
        Require(WaitForSingleObject(unloaded,10000)==WAIT_OBJECT_0,"T19_CALLBACK_RETURN_DLL_RELEASE");
        unsigned files=0;
        for(const auto& file:std::filesystem::recursive_directory_iterator(root))
            if(file.path().filename()=="mfg-preflight.json")
            {
                ++files;
                std::ifstream stream(file.path());
                std::string json((std::istreambuf_iterator<char>(stream)),{});
                Require(FieldUnsigned(json,"workerThread")!=GetCurrentThreadId(),"T19_REAL_COLLECTOR_OTHER_THREAD");
                Require(FieldUnsigned(json,"adapterLuidLow")==17 && FieldUnsigned(json,"adapterLuidHigh")==19,
                        "T19_COPY_ADAPTER_SURVIVES_RETIREMENT");
#if defined(OPTISCALER_RTX40_MFG)
                Require(FieldUnsigned(json,"configuredTemporalMethod")==unsigned(MfgUnlock::TemporalMethod::Ptx),
                        "T19_COPY_CONFIG_SURVIVES_RETIREMENT");
#endif
            }
        Require(files==(name=="exhausted"?2u:1u),"T19_COPIED_REQUEST_SURVIVES_RETIREMENT");
    }
    else
    {
        Require(WaitForSingleObject(entered,0)==WAIT_TIMEOUT,"T19_REJECTED_NO_WORKER");
        retire();Require(FreeLibrary(module),"T19_FAILURE_CALLER_RELEASE");
        Require(WaitForSingleObject(unloaded,10000)==WAIT_OBJECT_0,"T19_QUEUE_FAILURE_RELEASES_DLL");
        Require(!std::filesystem::exists(root/"nr-pipeline-captures"),"T19_REJECTED_NO_FILE");
    }
    CloseHandle(entered);CloseHandle(release);CloseHandle(unloaded);
    std::cout<<"T19_ENTRY_PASS case="<<name<<" entryThread="<<GetCurrentThreadId()<<'\n';
}
#else
int main(int argc, char** argv)
{
    const std::string name = argc > 1 ? argv[1] : "active";
#if !defined(T19_ADAPTER_ONLY)
    if (name == "collector")
    {
        const auto report = DlssNr::NgxDiagnostics::MfgPreflight({});
        Require(report.inputs.optiscaler.loaded && report.inputs.optiscaler.sha256.size() == 64,
                "T19_REAL_LOADED_SELF_HASH");
        Require(!report.inputs.provider.loaded && !report.correctionActivity,
                "T19_REAL_ABSENT_PROVIDER");
        Require(!report.inputs.adapter && !report.inputs.driverStore, "T19_CACHE_ABSENCE_NO_PROBE");
        std::cout << Json(report) << '\n';
        return 0;
    }
#endif
    Inputs input;
    input.provider = { true, L"C:\\fixture\\nvngx_dlssg.dll", std::string(64, 'a'), "310.9.1" };
    input.statusAvailable = true;
    input.status.ModuleFound = true;
    input.status.ModulePath = input.provider.path;
    input.status.SnippetVersion = "310.9.1";
    input.status.AdvertiseMatched = true;
    input.status.ValidateMatched = true;
    input.status.KernelsRewritten = 2;
    input.status.TemporalAttempted = MfgUnlock::TemporalMethod::Ptx;
    input.configured = MfgUnlock::TemporalMethod::Retarget;
    input.configuredAvailable = true;
    input.status.TemporalDetail = "fixture activity only";
    input.status.FlipMetering = "unsupported \"plugin\"\nraw";
    input.status.PluginCeiling = "unknown";
    input.status.FlipRequested = true;
    MfgUnlock::Telemetry telemetry;
    telemetry.optionsSeen = true; telemetry.active = true; telemetry.requested = 2;
    telemetry.sent = 2; telemetry.result = 7;
    telemetry.stateSeen = true; telemetry.presented = 1; telemetry.maxPresented = 3;
    if (name == "absent")
    {
        input.provider = {}; input.status = {}; input.statusAvailable = false;
        telemetry.optionsSeen = false; telemetry.stateSeen = false;
    }
    else if (name == "mismatched") input.provider.path = L"C:\\other\\nvngx_dlssg.dll";
    else if (name == "version-mismatched") input.provider.version = "999.0.1";
    else if (name == "requested-but-not-applied")
    {
        input.status.KernelsRewritten = 0;
        input.status.AdvertiseMatched = false; input.status.ValidateMatched = false;
    }
    else if (name == "unknown-version")
    {
        input.provider.version.clear(); input.status.SnippetVersion.clear();
    }
    else if (name == "ota")
    {
        input.provider.path = L"C:\\ProgramData\\NVIDIA\\NGX\\models\\dlssg\\versions\\1\\files\\abc.bin";
        input.status.ModulePath = input.provider.path;
    }
    else if (name == "unknown-identity")
    {
        input.provider.sha256.clear();
        input.status.ModulePath.clear();
    }
    else if (name == "unread-state") telemetry.stateSeen = false;
    else if (name != "active" && name != "raw-pacing" && name != "plain")
        return 2;
    const auto before = input.status.KernelsRewritten;
    const auto report = Read(input, &telemetry);
    Require(input.status.KernelsRewritten == before && telemetry.sent == 2, "T19_NO_MODE_MUTATION");
#if defined(OPTISCALER_RTX40_MFG)
    Require(report.builtInUnlock, "T19_ACTUAL_MFG_BUILD");
    if (name == "active") Require(report.identityMatched && report.correctionActivity, "T19_ACTIVE_STATUS");
    if (name == "requested-but-not-applied") Require(!report.correctionActivity, "T19_REQUEST_IS_NOT_ACTIVITY");
    if (name == "mismatched" || name == "version-mismatched")
        Require(report.identityMismatch && !report.identityMatched && !report.correctionActivity,
                "T19_MISMATCH_NOT_ACTIVITY");
    if (name == "unknown-version") Require(report.inputs.provider.version.empty() &&
        report.inputs.status.SnippetVersion.empty(), "T19_UNKNOWN_VERSION_RETAINED");
    if (name == "ota") Require(report.providerOta && report.identityMatched, "T19_OTA_IDENTITY");
    if (name == "unknown-identity") Require(!report.identityMatched && !report.correctionActivity,
                                          "T19_UNKNOWN_IDENTITY_NOT_ACTIVITY");
    if (name != "absent") Require(report.optionsSeen && report.requested == 2 && report.sent == 2 &&
        report.result == 7, "T19_RAW_OPTION_RESULT");
    if (name == "unread-state") Require(!report.stateSeen, "T19_UNREAD_STATE_NOT_PRESENTED");
#else
    Require(!report.builtInUnlock && !report.correctionActivity && !report.optionsSeen,
            "T19_PLAIN_NOT_UNLOCK_PROOF");
#endif
    if (name == "absent") Require(!report.identityMatched && !report.correctionActivity &&
        !report.optionsSeen && !report.stateSeen, "T19_ABSENT_EXPLICIT");
    if (name == "raw-pacing") Require(report.inputs.status.FlipMetering == std::string("unsupported \"plugin\"\nraw") &&
        report.inputs.status.FlipRequested && !report.inputs.status.FlipSites, "T19_RAW_PACING_NOT_PATCHED");
    std::cout << Json(report) << '\n';
}
#endif
