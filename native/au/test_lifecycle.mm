// Synthetic SDK lifecycle fixture: no plug-in loading, Access files, MIDI or USB.
// The SDK caches controller values in its constructor, before setActive; it only
// refreshes on RestoreState when a Controller State key is present. Exercise the
// actual TIReviveAU subclass against those boundaries, including failure paths.
#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cmath>
#include <cstdio>
#include <initializer_list>

namespace Steinberg {
namespace Vst {

using ComponentResult = OSStatus;
struct ComponentInstanceRecord {};
template <class Proc> bool executeOnMainThreadSync(void *, Proc) { return false; }

class AUWrapper
{
public:
    explicit AUWrapper(ComponentInstanceRecord *) {}
    virtual ~AUWrapper() = default;
    virtual ComponentResult Initialize()
    {
        ++initialize_calls;
        if (initialize_result == noErr) controller_value = 1;
        return initialize_result;
    }
    virtual void Cleanup() { ++cleanup_calls; }
    virtual ComponentResult SaveState(CFPropertyListRef *) { ++save_calls; return noErr; }
    virtual ComponentResult RestoreState(CFPropertyListRef data)
    {
        ++restore_calls;
        if (restore_result) return restore_result;
        if (!data || CFGetTypeID(data) != CFDictionaryGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
        auto dict = static_cast<CFDictionaryRef>(data);
        auto bytes = CFDictionaryGetValue(dict, CFSTR("Processor State"));
        if (bytes && CFGetTypeID(bytes) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)bytes) == 1)
            controller_value = CFDataGetBytePtr((CFDataRef)bytes)[0] / 127.0;
        if (CFDictionaryContainsKey(dict, CFSTR("Controller State"))) syncParameterValues();
        return noErr;
    }
    virtual OSStatus GetPropertyInfo(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UInt32 &, bool &)
    {
        ++property_info_calls;
        return noErr;
    }
    virtual ComponentResult GetProperty(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *)
    {
        ++property_calls;
        return noErr;
    }
    virtual ComponentResult SetProperty(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32)
    {
        ++set_property_calls;
        return noErr;
    }
    virtual ComponentResult SetParameter(AudioUnitParameterID, AudioUnitScope, AudioUnitElement,
                                         AudioUnitParameterValue, UInt32)
    {
        ++set_parameter_calls;
        return noErr;
    }
    virtual ComponentResult SetConnection(const AudioUnitConnection &)
    {
        ++connection_calls;
        return noErr;
    }
    virtual ComponentResult Render(AudioUnitRenderActionFlags &, const AudioTimeStamp &, UInt32)
    {
        ++render_calls;
        return noErr;
    }
    void missing_controller() { editController = nullptr; }
    void missing_processor() { audioProcessor = nullptr; }
    int initialize_calls = 0, cleanup_calls = 0, restore_calls = 0, sync_calls = 0;
    int save_calls = 0, property_calls = 0, property_info_calls = 0, set_property_calls = 0;
    int set_parameter_calls = 0, connection_calls = 0, render_calls = 0;
    ComponentResult initialize_result = noErr, restore_result = noErr;
    double controller_value = 0, cached_value = 0;

protected:
    void *GetMutex() { return nullptr; }
    void syncParameterValues() { ++sync_calls; cached_value = controller_value; }
    int processor_token = 1, controller_token = 2;
    void *audioProcessor = &processor_token, *editController = &controller_token;
};

} // namespace Vst
} // namespace Steinberg

#define SMTG_AUWRAPPER_USES_AUSDK
#include "tirevive_au.h"

static int checks = 0, failures = 0;
static void check(bool result, const char *label)
{
    ++checks;
    if (!result) { ++failures; std::fprintf(stderr, "FAIL: %s\n", label); }
}

static CFMutableDictionaryRef preset(bool legacy = false, bool controller = false)
{
    auto p = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const char *keys[] = {kAUPresetVersionKey, kAUPresetSubtypeKey, kAUPresetManufacturerKey};
    const int values[] = {0, 0x56544972, 0x54495276};
    for (int n = 0; n < 3; ++n) {
        auto key = CFStringCreateWithCString(nullptr, keys[n], kCFStringEncodingUTF8);
        auto value = CFNumberCreate(nullptr, kCFNumberIntType, &values[n]);
        CFDictionarySetValue(p, key, value);
        CFRelease(key); CFRelease(value);
    }
    const UInt8 synthetic = 64;
    auto state = CFDataCreate(nullptr, &synthetic, 1);
    CFDictionarySetValue(p, legacy ? CFSTR(kAUPresetDataKey) : CFSTR("Processor State"), state);
    if (controller) CFDictionarySetValue(p, CFSTR("Controller State"), state);
    CFRelease(state);
    return p;
}

int main()
{
    using Steinberg::Vst::TIReviveAU;
    {
        TIReviveAU au(nullptr);
        check(au.Initialize() == noErr, "initialization succeeds");
        check(au.cached_value == 1, "AU values follow the controller after activation");
    }
    {
        TIReviveAU au(nullptr);
        au.initialize_result = -777;
        check(au.Initialize() == -777 && au.sync_calls == 0, "failed initialization never publishes parameter values");
    }
    for (bool legacy : {false, true}) {
        TIReviveAU au(nullptr);
        auto state = preset(legacy);
        check(au.RestoreState(state) == noErr, legacy ? "legacy preset accepted" : "processor-only preset accepted");
        check(std::fabs(au.cached_value - 64.0 / 127.0) < 1e-12,
              legacy ? "legacy restore refreshes AU values" : "processor-only restore refreshes AU values");
        CFRelease(state);
    }
    {
        TIReviveAU au(nullptr);
        auto state = preset(false, true);
        check(au.RestoreState(state) == noErr && std::fabs(au.cached_value - 64.0 / 127.0) < 1e-12,
              "current controller/processor preset stays compatible");
        CFRelease(state);
    }
    {
        TIReviveAU au(nullptr);
        check(au.RestoreState(nullptr) == kAudioUnitErr_InvalidPropertyValue && au.restore_calls == 0,
              "null preset rejected before SDK");
        check(au.RestoreState(CFSTR("not a preset")) == kAudioUnitErr_InvalidPropertyValue && au.restore_calls == 0,
              "non-dictionary preset rejected before SDK");
    }
    for (auto key : {CFSTR(kAUPresetVersionKey), CFSTR(kAUPresetSubtypeKey), CFSTR(kAUPresetManufacturerKey),
                     CFSTR("Processor State"), CFSTR("Controller State")}) {
        TIReviveAU au(nullptr);
        auto state = preset();
        CFDictionarySetValue(state, key, CFSTR("wrong type"));
        check(au.RestoreState(state) == kAudioUnitErr_InvalidPropertyValue && au.restore_calls == 0,
              "wrong preset field type rejected before SDK");
        CFRelease(state);
    }
    {
        TIReviveAU au(nullptr);
        au.restore_result = -777;
        auto state = preset();
        check(au.RestoreState(state) == -777 && au.sync_calls == 0, "failed restore never publishes values");
        CFRelease(state);
    }
    for (bool processor_missing : {false, true}) {
        TIReviveAU au(nullptr);
        if (processor_missing) au.missing_processor(); else au.missing_controller();
        check(au.Initialize() == kAudioUnitErr_FailedInitialization && au.initialize_calls == 0,
              "unavailable plug-in cannot initialize");
        auto state = preset();
        check(au.RestoreState(state) == kAudioUnitErr_FailedInitialization && au.restore_calls == 0,
              "unavailable plug-in cannot restore a preset");
        CFRelease(state);
        CFPropertyListRef out = nullptr;
        check(au.SaveState(&out) == kAudioUnitErr_FailedInitialization && au.save_calls == 0,
              "unavailable plug-in cannot save a misleading empty preset");
        UInt32 size = 123;
        bool writable = true;
        check(au.GetPropertyInfo(kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, size, writable) ==
                  kAudioUnitErr_FailedInitialization && size == 0 && !writable && au.property_info_calls == 0,
              "unavailable plug-in exposes no Cocoa UI");
        check(au.GetProperty(kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, nullptr) ==
                  kAudioUnitErr_FailedInitialization && au.property_calls == 0,
              "unavailable plug-in property is guarded");
        check(au.SetProperty(kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0, nullptr, 0) ==
                  kAudioUnitErr_FailedInitialization && au.set_property_calls == 0,
              "unavailable plug-in property setter is guarded");
        check(au.SetParameter(153, kAudioUnitScope_Global, 0, 0, 0) == kAudioUnitErr_FailedInitialization &&
                  au.set_parameter_calls == 0, "unavailable plug-in parameter setter is guarded");
        AudioUnitConnection connection = {};
        check(au.SetConnection(connection) == kAudioUnitErr_FailedInitialization && au.connection_calls == 0,
              "unavailable plug-in connection is guarded");
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp stamp = {};
        check(au.Render(flags, stamp, 512) == kAudioUnitErr_FailedInitialization && au.render_calls == 0 &&
                  (flags & kAudioUnitRenderAction_OutputIsSilence), "unavailable plug-in render fails safely");
        au.Cleanup();
        check(au.cleanup_calls == 0, "unavailable plug-in cleanup never enters partial SDK state");
    }
    std::printf("AU lifecycle fixture: %d checks, %d failures; synthetic controller only\n", checks, failures);
    return failures ? 1 : 0;
}
