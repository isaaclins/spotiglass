// SpotiglassEQDriver / SpotiglassEQPlugin.cpp
//
// AudioServerPlugIn entry point and `AudioServerPlugInDriverInterface` vtable
// for the Spotiglass EQ virtual output device.
//
// `coreaudiod` loads this bundle, calls `SpotiglassEQDriver_Create` to obtain
// a driver factory, and from there walks an AudioObject hierarchy rooted at
// the plugin:
//
//     Plugin (kAudioPlugInClassID)
//       └── Device "Spotiglass EQ" (kAudioDeviceClassID)
//             ├── Output Stream  (kAudioStreamClassID, output scope only)
//             └── Volume Control (kAudioVolumeControlClassID, optional)
//
// Every AudioObject must implement a long list of CoreAudio "properties"
// (Name, UID, ClassID, BaseClassID, OwningObject, ZeroTimeStamp, ...).
// `AudioObjectPropertyAddress` lookups arrive at this plugin via
// `GetPropertyData` / `SetPropertyData` and are dispatched by ID.
//
// This file provides:
//   1. The `kAudioServerPlugInCreate` function (`SpotiglassEQDriver_Create`)
//      that CoreAudio looks up by bundle Info.plist key
//      `AudioServerPlugIn_FactoryFunctions`.
//   2. The interface vtable.
//   3. A minimal `DoIOOperation` that calls into SpotiglassEQDSP.
//
// The remaining property handlers (Open, Close, AddDevice, RemoveDevice,
// PerformDeviceConfigurationChange, HasProperty, IsPropertySettable,
// GetPropertyDataSize, GetPropertyData, SetPropertyData for the Plugin /
// Device / Stream / Control objects) follow a strict pattern documented in
// Apple's "Audio Server Plug-In Driver Programming Guide" and modelled by
// the BlackHole / BackgroundMusic / NullAudio open-source plugins. They are
// scaffolded here as `TODO(PROP)` stubs — completing them is the remaining
// work before `coreaudiod` will register the device.

#include <CoreAudio/AudioServerPlugIn.h>
#include <pthread.h>

#include "EQCoefficientReader.h"
#include "SpotiglassEQDSP.h"

namespace {

// MARK: - Plugin singleton state
//
// Object IDs are exposed once the property dispatcher (`TODO(PROP)` below)
// is filled in; kept here as ground truth for the AudioObject hierarchy.
[[maybe_unused]] constexpr UInt32 kPluginObjectID = kAudioObjectPlugInObject;
[[maybe_unused]] constexpr UInt32 kDeviceObjectID = 2;
[[maybe_unused]] constexpr UInt32 kOutputStreamObjectID = 3;

// CFString helpers for property handlers (used once the dispatcher lands).
[[maybe_unused]] CFStringRef MakeStaticCFString(const char* s) {
    return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

struct PluginState {
    pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
    AudioServerPlugInHostRef host = nullptr;

    // DSP + IPC are owned by the IO thread but installed by Start/StopIO.
    EQDSPState dsp{};
    EQCoefficientReader* coeffReader = nullptr;
    EQCoefficientFrame lastFrame{};
    Float64 currentSampleRate = 48000.0;
};

PluginState gPlugin;

// MARK: - Forward declarations (vtable members)

HRESULT QueryInterface(void* self, REFIID uuid, LPVOID* outInterface);
ULONG AddRef(void* self);
ULONG Release(void* self);
OSStatus Initialize(AudioServerPlugInDriverRef self, AudioServerPlugInHostRef host);
OSStatus CreateDevice(AudioServerPlugInDriverRef self,
                      CFDictionaryRef description,
                      const AudioServerPlugInClientInfo* clientInfo,
                      AudioObjectID* outDeviceObjectID);
OSStatus DestroyDevice(AudioServerPlugInDriverRef self, AudioObjectID deviceID);
OSStatus AddDeviceClient(AudioServerPlugInDriverRef self,
                         AudioObjectID deviceID,
                         const AudioServerPlugInClientInfo* clientInfo);
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef self,
                            AudioObjectID deviceID,
                            const AudioServerPlugInClientInfo* clientInfo);
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef self,
                                          AudioObjectID deviceID,
                                          UInt64 changeAction,
                                          void* changeInfo);
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef self,
                                        AudioObjectID deviceID,
                                        UInt64 changeAction,
                                        void* changeInfo);
Boolean HasProperty(AudioServerPlugInDriverRef self,
                    AudioObjectID objectID,
                    pid_t pid,
                    const AudioObjectPropertyAddress* address);
OSStatus IsPropertySettable(AudioServerPlugInDriverRef self,
                            AudioObjectID objectID,
                            pid_t pid,
                            const AudioObjectPropertyAddress* address,
                            Boolean* outIsSettable);
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef self,
                             AudioObjectID objectID,
                             pid_t pid,
                             const AudioObjectPropertyAddress* address,
                             UInt32 qualifierDataSize,
                             const void* qualifierData,
                             UInt32* outDataSize);
OSStatus GetPropertyData(AudioServerPlugInDriverRef self,
                         AudioObjectID objectID,
                         pid_t pid,
                         const AudioObjectPropertyAddress* address,
                         UInt32 qualifierDataSize,
                         const void* qualifierData,
                         UInt32 inDataSize,
                         UInt32* outDataSize,
                         void* outData);
OSStatus SetPropertyData(AudioServerPlugInDriverRef self,
                         AudioObjectID objectID,
                         pid_t pid,
                         const AudioObjectPropertyAddress* address,
                         UInt32 qualifierDataSize,
                         const void* qualifierData,
                         UInt32 inDataSize,
                         const void* inData);
OSStatus StartIO(AudioServerPlugInDriverRef self, AudioObjectID deviceID, UInt32 clientID);
OSStatus StopIO(AudioServerPlugInDriverRef self, AudioObjectID deviceID, UInt32 clientID);
OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef self,
                          AudioObjectID deviceID,
                          UInt32 clientID,
                          Float64* outSampleTime,
                          UInt64* outHostTime,
                          UInt64* outSeed);
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef self,
                           AudioObjectID deviceID,
                           UInt32 clientID,
                           UInt32 operationID,
                           Boolean* outWillDo,
                           Boolean* outWillDoInPlace);
OSStatus BeginIOOperation(AudioServerPlugInDriverRef self,
                          AudioObjectID deviceID,
                          UInt32 clientID,
                          UInt32 operationID,
                          UInt32 ioBufferFrameSize,
                          const AudioServerPlugInIOCycleInfo* ioCycleInfo);
OSStatus DoIOOperation(AudioServerPlugInDriverRef self,
                       AudioObjectID deviceID,
                       AudioObjectID streamID,
                       UInt32 clientID,
                       UInt32 operationID,
                       UInt32 ioBufferFrameSize,
                       const AudioServerPlugInIOCycleInfo* ioCycleInfo,
                       void* ioMainBuffer,
                       void* ioSecondaryBuffer);
OSStatus EndIOOperation(AudioServerPlugInDriverRef self,
                        AudioObjectID deviceID,
                        UInt32 clientID,
                        UInt32 operationID,
                        UInt32 ioBufferFrameSize,
                        const AudioServerPlugInIOCycleInfo* ioCycleInfo);

// MARK: - Interface vtable

AudioServerPlugInDriverInterface gInterface = {
    nullptr,  // _reserved
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation
};

AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;

// MARK: - DoIOOperation (the DSP path)

OSStatus DoIOOperation(AudioServerPlugInDriverRef /*self*/,
                       AudioObjectID /*deviceID*/,
                       AudioObjectID /*streamID*/,
                       UInt32 /*clientID*/,
                       UInt32 operationID,
                       UInt32 ioBufferFrameSize,
                       const AudioServerPlugInIOCycleInfo* /*ioCycleInfo*/,
                       void* ioMainBuffer,
                       void* /*ioSecondaryBuffer*/) {
    // We only act on the "write mix" operation — that's the one where the
    // stereo float buffer is fully mixed and about to be delivered to the
    // (virtual) hardware output.
    if (operationID != kAudioServerPlugInIOOperationWriteMix) return noErr;
    if (!ioMainBuffer || ioBufferFrameSize == 0) return noErr;

    EQCoefficientFrame freshFrame;
    const int snapshotStatus = EQCoefficientReader_Snapshot(
        gPlugin.coeffReader, &freshFrame
    );
    // 0 = success, 1 = torn read (use cached), 2 = no reader
    EQDSP_Apply(
        &gPlugin.dsp,
        snapshotStatus == 0 ? &freshFrame : nullptr,
        static_cast<float*>(ioMainBuffer),
        ioBufferFrameSize
    );
    return noErr;
}

// MARK: - Trivial stubs

HRESULT QueryInterface(void* /*self*/, REFIID uuid, LPVOID* outInterface) {
    if (!outInterface) return E_POINTER;
    *outInterface = &gInterfacePtr;
    return S_OK;
}
ULONG AddRef(void* /*self*/) { return 1; }
ULONG Release(void* /*self*/) { return 1; }

OSStatus Initialize(AudioServerPlugInDriverRef /*self*/, AudioServerPlugInHostRef host) {
    pthread_mutex_lock(&gPlugin.stateLock);
    gPlugin.host = host;
    EQDSP_Reset(&gPlugin.dsp);
    pthread_mutex_unlock(&gPlugin.stateLock);
    return noErr;
}

OSStatus StartIO(AudioServerPlugInDriverRef /*self*/,
                 AudioObjectID /*deviceID*/,
                 UInt32 /*clientID*/) {
    pthread_mutex_lock(&gPlugin.stateLock);
    if (!gPlugin.coeffReader) {
        // Default backing path. Must mirror EQCoefficientPublisher.defaultBackingPath.
        char path[256];
        snprintf(path, sizeof(path),
                 "/tmp/com.isaaclins.spotiglass.eq.coeffs.v1.u%u", getuid());
        gPlugin.coeffReader = EQCoefficientReader_Open(path);
    }
    EQDSP_Reset(&gPlugin.dsp);
    pthread_mutex_unlock(&gPlugin.stateLock);
    return noErr;
}

OSStatus StopIO(AudioServerPlugInDriverRef /*self*/,
                AudioObjectID /*deviceID*/,
                UInt32 /*clientID*/) {
    pthread_mutex_lock(&gPlugin.stateLock);
    if (gPlugin.coeffReader) {
        EQCoefficientReader_Close(gPlugin.coeffReader);
        gPlugin.coeffReader = nullptr;
    }
    pthread_mutex_unlock(&gPlugin.stateLock);
    return noErr;
}

// TODO(PROP): The functions below need full implementations before
// coreaudiod will accept the device. Each is a property-routing dispatcher
// keyed on `address->mSelector` and `objectID`. The reference implementations
// in BlackHole / NullAudio sample (Apple Sample Code) demonstrate the
// patterns; the most important properties to implement are:
//
// Plugin object (kAudioObjectPlugInObject):
//   - kAudioObjectPropertyName, kAudioObjectPropertyManufacturer
//   - kAudioPlugInPropertyDeviceList (return {kDeviceObjectID})
//
// Device object (kDeviceObjectID):
//   - kAudioObjectPropertyName ("Spotiglass EQ")
//   - kAudioDevicePropertyDeviceUID ("com.isaaclins.spotiglass.eqdevice")
//   - kAudioDevicePropertyTransportType (kAudioDeviceTransportTypeVirtual)
//   - kAudioDevicePropertyStreams (return {kOutputStreamObjectID}; OUTPUT scope only)
//   - kAudioDevicePropertyNominalSampleRate (settable; triggers
//     PerformDeviceConfigurationChange to flush DSP state)
//   - kAudioDevicePropertyAvailableNominalSampleRates ({44100, 48000, 96000, 192000})
//   - kAudioDevicePropertyZeroTimeStampPeriod (one buffer)
//   - kAudioDevicePropertyIsHidden = false
//
// Output Stream object (kOutputStreamObjectID):
//   - kAudioStreamPropertyDirection = 0 (output)
//   - kAudioStreamPropertyVirtualFormat: 32-bit float, stereo, native order
//   - kAudioStreamPropertyAvailableVirtualFormats: 44.1/48/96/192 stereo float
//
// Until those land, coreaudiod will reject the plugin during HAL load with a
// kAudioHardwareUnsupportedOperationError. The plugin doesn't crash, it just
// doesn't appear in System Settings → Sound. The DSP path (this file's
// DoIOOperation + SpotiglassEQDSP.c) is independently testable and
// independently correct.

OSStatus CreateDevice(AudioServerPlugInDriverRef /*self*/, CFDictionaryRef /*desc*/,
                      const AudioServerPlugInClientInfo* /*c*/, AudioObjectID* /*out*/) {
    return kAudioHardwareUnsupportedOperationError; // virtual devices use static declaration
}
OSStatus DestroyDevice(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus AddDeviceClient(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                         const AudioServerPlugInClientInfo* /*c*/) { return noErr; }
OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                            const AudioServerPlugInClientInfo* /*c*/) { return noErr; }
OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef /*self*/,
                                          AudioObjectID /*deviceID*/, UInt64 changeAction,
                                          void* /*info*/) {
    pthread_mutex_lock(&gPlugin.stateLock);
    gPlugin.currentSampleRate = static_cast<Float64>(changeAction);
    EQDSP_Reset(&gPlugin.dsp); // clear z1/z2 history across rate change
    pthread_mutex_unlock(&gPlugin.stateLock);
    return noErr;
}
OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef /*self*/,
                                        AudioObjectID /*deviceID*/, UInt64 /*action*/,
                                        void* /*info*/) { return noErr; }

Boolean HasProperty(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*objectID*/,
                    pid_t /*pid*/, const AudioObjectPropertyAddress* /*address*/) {
    return false; // TODO(PROP)
}
OSStatus IsPropertySettable(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*objectID*/,
                            pid_t /*pid*/, const AudioObjectPropertyAddress* /*address*/,
                            Boolean* outIsSettable) {
    if (outIsSettable) *outIsSettable = false;
    return kAudioHardwareUnknownPropertyError; // TODO(PROP)
}
OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*objectID*/,
                             pid_t /*pid*/, const AudioObjectPropertyAddress* /*address*/,
                             UInt32 /*qSize*/, const void* /*qData*/, UInt32* outDataSize) {
    if (outDataSize) *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError; // TODO(PROP)
}
OSStatus GetPropertyData(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*objectID*/,
                         pid_t /*pid*/, const AudioObjectPropertyAddress* /*address*/,
                         UInt32 /*qSize*/, const void* /*qData*/, UInt32 /*inSize*/,
                         UInt32* outDataSize, void* /*outData*/) {
    if (outDataSize) *outDataSize = 0;
    return kAudioHardwareUnknownPropertyError; // TODO(PROP)
}
OSStatus SetPropertyData(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*objectID*/,
                         pid_t /*pid*/, const AudioObjectPropertyAddress* /*address*/,
                         UInt32 /*qSize*/, const void* /*qData*/, UInt32 /*inSize*/,
                         const void* /*inData*/) {
    return kAudioHardwareUnknownPropertyError; // TODO(PROP)
}

OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                          UInt32 /*clientID*/, Float64* outSampleTime, UInt64* outHostTime,
                          UInt64* outSeed) {
    if (outSampleTime) *outSampleTime = 0;
    if (outHostTime)   *outHostTime = 0;
    if (outSeed)       *outSeed = 1;
    return noErr;
}
OSStatus WillDoIOOperation(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                           UInt32 /*clientID*/, UInt32 operationID,
                           Boolean* outWillDo, Boolean* outWillDoInPlace) {
    if (outWillDo) *outWillDo = (operationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}
OSStatus BeginIOOperation(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                          UInt32 /*clientID*/, UInt32 /*operationID*/,
                          UInt32 /*ioBufferFrameSize*/,
                          const AudioServerPlugInIOCycleInfo* /*ioCycleInfo*/) { return noErr; }
OSStatus EndIOOperation(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                        UInt32 /*clientID*/, UInt32 /*operationID*/,
                        UInt32 /*ioBufferFrameSize*/,
                        const AudioServerPlugInIOCycleInfo* /*ioCycleInfo*/) { return noErr; }

} // namespace

// MARK: - Factory entry point (exported)

extern "C" {

/// Factory function name registered in Info.plist under
/// `CFPlugInFactories`. Returns a pointer to the
/// AudioServerPlugInDriverInterface vtable.
void* SpotiglassEQDriver_Create(CFAllocatorRef /*allocator*/, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    return &gInterfacePtr;
}

} // extern "C"
