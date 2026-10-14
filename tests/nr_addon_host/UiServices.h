#pragma once

#include <Config.h>
#include <dlssnr/DlssNr_Status.h>
#include <filesystem>
#include <string_view>

namespace NrAddonHost
{
enum class Fixture
{
    Before4,
    Before2,
    Post4,
    Post2,
    NoRuntime,
    Failure,
    FilterHdr,
    FilterSdr,
    FilterNative,
    FilterSupernative,
    FilterUnsupported,
    MissingCurrentContext
};

bool ParseFixture(std::wstring_view name, Fixture& fixture);
const char* FixtureName(Fixture fixture);
void RunUiContracts(const std::filesystem::path& fixtureRoot);
void RunPlacementContracts(const std::filesystem::path& fixtureRoot);
void RunOptionsContracts(const std::filesystem::path& fixtureRoot);
void RunStartupContracts();

// Only value services. This owner never creates a provider, capture or processing device.
class UiServices
{
  public:
    explicit UiServices(const std::filesystem::path& fixtureRoot);
    ~UiServices();
    void Select(Fixture fixture);
    void Publish();
    Config* Configuration() { return &config; }
    Fixture Selected() const { return selected; }

  private:
    Config config;
    Fixture selected = Fixture::Before4;
};
} // namespace NrAddonHost
