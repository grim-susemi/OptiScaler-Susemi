#pragma once
#include <nvsdk_ngx.h>
#include <string>
#include <unordered_map>
#include <variant>

namespace NrAddonHost
{
// Application-owned argument storage, including WARP which has no NGX provider.
class RuntimeParameters final : public NVSDK_NGX_Parameter
{
    using Value = std::variant<unsigned long long, float, double, unsigned, int, void*>;
    std::unordered_map<std::string, Value> values;
    template<class T> NVSDK_NGX_Result Read(const char* key, T* result) const
    {
        if (!result) return NVSDK_NGX_Result_Fail;
        const auto found = values.find(key);
        if (found == values.end()) return NVSDK_NGX_Result_Fail;
        if constexpr (std::is_pointer_v<T>)
        {
            const auto stored = std::get_if<void*>(&found->second);
            if (!stored) return NVSDK_NGX_Result_Fail;
            *result = static_cast<T>(*stored);
        }
        else
        {
            const auto stored = std::get_if<T>(&found->second);
            if (!stored) return NVSDK_NGX_Result_Fail;
            *result = *stored;
        }
        return NVSDK_NGX_Result_Success;
    }
public:
    void Set(const char* k, unsigned long long v) override { values[k] = v; }
    void Set(const char* k, float v) override { values[k] = v; }
    void Set(const char* k, double v) override { values[k] = v; }
    void Set(const char* k, unsigned v) override { values[k] = v; }
    void Set(const char* k, int v) override { values[k] = v; }
    void Set(const char* k, void* v) override { values[k] = v; }
    void Set(const char* k, ID3D11Resource* v) override { values[k] = static_cast<void*>(v); }
    void Set(const char* k, ID3D12Resource* v) override { values[k] = static_cast<void*>(v); }
    NVSDK_NGX_Result Get(const char* k, unsigned long long* v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, float* v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, double* v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, unsigned* v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, int* v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, void** v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, ID3D11Resource** v) const override { return Read(k, v); }
    NVSDK_NGX_Result Get(const char* k, ID3D12Resource** v) const override { return Read(k, v); }
    void Reset() override { values.clear(); }
};
}
