#include <pch.h>
#include "ForbiddenStartup.h"
#include <menu/menu_overlay_base.h>
#include <imgui/imgui_impl_uwp.h>
#include <fsr4/FSR4ModelSelection.h>
#include <framegen/nvngx/Nvngx_FG.h>
#include <hooks/Streamline_Hooks.h>
#include <hooks/Reflex_Hooks.h>
#include <hooks/Xell_Hooks.h>
#include <nvapi/fakenvapi.h>

// No provider, latency integration or live profile inventory exists in this
// UI-only owner. Value queries must not call the production lazy initializers.
int Nvngx_FG::getMaxFakeFramesCount() { return 0; }
bool Nvngx_FG::isDx12Available() { return false; }
bool Nvngx_FG::isVulkanAvailable() { return false; }
feature_version Nvngx_FG::version() { return {}; }
feature_version Nvngx_FG::extraVersion() { return {}; }
void Nvngx_FG::setDebugView(bool) { NrAddonHost::ForbidProviderStartup(); }
void Nvngx_FG::setInterpolatedOnly(bool) { NrAddonHost::ForbidProviderStartup(); }
void StreamlineHooks::updateDlssgOptions() { NrAddonHost::ForbidProviderStartup(); }
bool fakenvapi::isLowLatencyActive() { return false; }
LowLatencyMode fakenvapi::getCurrentMode() { return LowLatencyMode::None; }
bool fakenvapi::isUsingAsMainNvapi() { return false; }
uint8_t ReflexHooks::dlssgFrameCountToGenerate() { return 0; }
bool ReflexHooks::isReflexHooked() { return false; }
bool ReflexHooks::updateTimingData() { return false; }
bool ReflexHooks::gameIsSendingMarkers() { return false; }
std::optional<TimingEntry> ReflexHooks::timingData[TimingType::TimingTypeCOUNT] {};
bool XellHooks::canLimit() { return false; }

PFN_createModel2 FSR4ModelSelection::o_createModelSDK2 = nullptr;
PFN_createModel2 FSR4ModelSelection::o_createModelDriver2 = nullptr;

bool ImGui_ImplUwp_Init(void*) { NrAddonHost::ForbidMenuStartup(); }
void ImGui_ImplUwp_NewFrame(ImVec2) { NrAddonHost::ForbidMenuStartup(); }
void ImGui_ImplUwp_Shutdown() { NrAddonHost::ForbidMenuStartup(); }
void ImGui_BindUwpKeyUp(PFN_KeyUp) { NrAddonHost::ForbidMenuStartup(); }

HWND MenuOverlayBase::Handle() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::Dx11Ready() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::Dx12Ready() { NrAddonHost::ForbidMenuStartup(); }
bool MenuOverlayBase::IsInited() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::Init(HWND, bool) { NrAddonHost::ForbidMenuStartup(); }
bool MenuOverlayBase::RenderMenu() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::Shutdown() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::HideMenu() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::Present() { NrAddonHost::ForbidMenuStartup(); }
void MenuOverlayBase::ApplyThemeStyle() { NrAddonHost::ForbidMenuStartup(); }
bool Config::SaveIni(std::filesystem::path) { NrAddonHost::ForbidConfigSave(); }
bool Config::SaveProfile(const std::wstring&) { NrAddonHost::ForbidConfigSave(); }
bool Config::LoadProfile(const std::wstring&) { NrAddonHost::ForbidConfigSave(); }
std::vector<std::string> Config::ListProfiles() { return {}; }
