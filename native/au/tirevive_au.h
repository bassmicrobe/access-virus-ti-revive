// The TI Revive-specific part of Steinberg's AU wrapper. Kept separate so its
// lifecycle can be checked with a synthetic controller, without Access files or USB.
#pragma once

#include <cstdio>

namespace Steinberg {
namespace Vst {

class TIReviveAU : public AUWrapper
{
public:
    TIReviveAU(ComponentInstanceRecord *ci) : AUWrapper(ci) {}

    ComponentResult Initialize() override
    {
        // Keep the post-activation cache update on the same main-thread path as
        // the SDK. Its own main-thread trampoline dispatches this virtual method.
        __block ComponentResult result = noErr;
        if (executeOnMainThreadSync(GetMutex(), ^{ result = this->Initialize(); }))
            return result;
        if (!available()) {
            std::fprintf(stderr, "TI Revive Audio Unit: the wrapped plug-in did not initialize. "
                                 "Check the Access files setup and the plug-in log.\n");
            return kAudioUnitErr_FailedInitialization;
        }
        result = AUWrapper::Initialize();
        if (result == noErr)
            // The SDK cached values before setActive; a new TI Revive instance
            // applies its default project during activation. Publish those values
            // directly to the AU cache, without enqueueing parameter writes.
            syncParameterValues();
        return result == -1 ? kAudioUnitErr_FailedInitialization : result;
    }

    void Cleanup() override
    {
        if (available()) AUWrapper::Cleanup();
    }

    ComponentResult SaveState(CFPropertyListRef *outData) override
    {
        if (!outData) return kAudioUnitErr_InvalidPropertyValue;
        *outData = nullptr;
        return available() ? AUWrapper::SaveState(outData) : kAudioUnitErr_FailedInitialization;
    }

    ComponentResult RestoreState(CFPropertyListRef inData) override
    {
        if (!available()) return kAudioUnitErr_FailedInitialization;
        if (!inData || CFGetTypeID(inData) != CFDictionaryGetTypeID())
            return kAudioUnitErr_InvalidPropertyValue;
        CFDictionaryRef dict = static_cast<CFDictionaryRef>(inData);
        // The SDK expects numbers and NSData and calls their APIs directly. Reject
        // malformed/partial presets before passing any of them to the wrapper.
        if (!number(dict, CFSTR(kAUPresetVersionKey)) || !number(dict, CFSTR(kAUPresetSubtypeKey)) ||
            !number(dict, CFSTR(kAUPresetManufacturerKey)))
            return kAudioUnitErr_InvalidPropertyValue;
        CFStringRef processor = CFSTR("Processor State");
        CFTypeRef state = CFDictionaryGetValue(dict, processor);
        bool legacy = state == nullptr;
        if (legacy) state = CFDictionaryGetValue(dict, CFSTR(kAUPresetDataKey));
        CFTypeRef controller = CFDictionaryGetValue(dict, CFSTR("Controller State"));
        if (!state || CFGetTypeID(state) != CFDataGetTypeID() || CFDataGetLength((CFDataRef)state) == 0 ||
            (controller && CFGetTypeID(controller) != CFDataGetTypeID()))
            return kAudioUnitErr_InvalidPropertyValue;

        ComponentResult result;
        if (legacy) {
            auto copy = CFDictionaryCreateMutableCopy(nullptr, 0, dict);
            if (!copy) return kAudioUnitErr_FailedInitialization;
            CFDictionarySetValue(copy, processor, state);
            result = AUWrapper::RestoreState(copy);
            CFRelease(copy);
        } else {
            result = AUWrapper::RestoreState(inData);
        }
        if (result == noErr && !controller)
            // Combined processor/controllers and legacy AU states need no separate
            // Controller State. The SDK already refreshes when that key exists;
            // avoid traversing every parameter twice for current-format presets.
            syncParameterValues();
        return result;
    }

#ifdef SMTG_AUWRAPPER_USES_AUSDK
    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
                            UInt32 &size, bool &writable) override
#else
    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
                            UInt32 &size, Boolean &writable) override
#endif
    {
        if (!available()) {
            size = 0;
            writable = false;
            return kAudioUnitErr_FailedInitialization;
        }
        return AUWrapper::GetPropertyInfo(id, scope, element, size, writable);
    }

    ComponentResult GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
                                void *data) override
    {
        return available() ? AUWrapper::GetProperty(id, scope, element, data) : kAudioUnitErr_FailedInitialization;
    }

    ComponentResult SetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
                                const void *data, UInt32 size) override
    {
        return available() ? AUWrapper::SetProperty(id, scope, element, data, size) : kAudioUnitErr_FailedInitialization;
    }

    // Keep the SDK's exception-based error propagation rather than strengthening
    // these imported realtime signatures to noexcept. Follow its diagnostic scope.
#ifdef AUSDK_BEGIN_NO_RT_NOEXCEPT_WARNINGS
    AUSDK_BEGIN_NO_RT_NOEXCEPT_WARNINGS
#endif
    ComponentResult SetParameter(AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement element,
                                 AudioUnitParameterValue value, UInt32 offset) override
    {
        return available() ? AUWrapper::SetParameter(id, scope, element, value, offset) : kAudioUnitErr_FailedInitialization;
    }

    ComponentResult SetConnection(const AudioUnitConnection &connection) override
    {
        return available() ? AUWrapper::SetConnection(connection) : kAudioUnitErr_FailedInitialization;
    }

    ComponentResult Render(AudioUnitRenderActionFlags &flags, const AudioTimeStamp &time, UInt32 frames) override
    {
        if (!available()) {
            flags |= kAudioUnitRenderAction_OutputIsSilence;
            return kAudioUnitErr_FailedInitialization;
        }
        return AUWrapper::Render(flags, time, frames);
    }
#ifdef AUSDK_END_NO_RT_NOEXCEPT_WARNINGS
    AUSDK_END_NO_RT_NOEXCEPT_WARNINGS
#endif

private:
    bool available() const { return audioProcessor && editController; }
    static bool number(CFDictionaryRef dict, CFStringRef key)
    {
        auto value = CFDictionaryGetValue(dict, key);
        SInt32 n;
        return value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &n);
    }
};

} // namespace Vst
} // namespace Steinberg
