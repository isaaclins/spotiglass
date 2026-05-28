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

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#include <atomic>

#include "EQCoefficientReader.h"
#include "EQRouter.h"
#include "SpotiglassEQDSP.h"

namespace {

// MARK: - Plugin singleton state
//
// Object IDs are exposed once the property dispatcher (`TODO(PROP)` below)
// is filled in; kept here as ground truth for the AudioObject hierarchy.
[[maybe_unused]] constexpr UInt32 kPluginObjectID = kAudioObjectPlugInObject;
[[maybe_unused]] constexpr UInt32 kDeviceObjectID = 2;
[[maybe_unused]] constexpr UInt32 kOutputStreamObjectID = 3;
// Master output volume control. Mirrors the EQRouter target device's
// kAudioDevicePropertyVolumeScalar so the macOS menu-bar volume slider is
// usable while Spotiglass EQ is the default output. See ADR-EQ-3.
[[maybe_unused]] constexpr UInt32 kVolumeControlObjectID = 4;

// Volume range exposed by the master control. Matches the typical macOS
// device range so the menu-bar slider's full travel maps to a useful range.
constexpr Float32 kVolumeMinDB = -64.0f;
constexpr Float32 kVolumeMaxDB = 0.0f;

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
    // Whether StartIO has been called and StopIO has not yet been. This is
    // what kAudioDevicePropertyDeviceIsRunning must reflect. Keeping it
    // separate from `coeffReader` (which is null when the publisher file
    // doesn't exist yet) so a missing coefficient file doesn't make
    // coreaudiod think the device is dead and kill the IO thread with
    // kAudioHardwareStoppedError ('stop').
    bool ioRunning = false;
    // Mach absolute-time anchor for `GetZeroTimeStamp`. Set on StartIO so
    // the sample count keeps advancing during playback; without an
    // ever-advancing timeline coreaudiod tears down the IO thread.
    UInt64 ioStartHostTime = 0;
    UInt64 ioStartSeed = 1;

    // Forwards EQ-processed audio out to the real hardware output that was
    // active before the user routed default-output to Spotiglass EQ. Without
    // this, audio routed to our virtual device would have nowhere to go.
    // Lazily opened on StartIO; closed on StopIO. NEVER opens an input
    // IOProc — output-scope only, no microphone path.
    EQRouter* router = nullptr;

    // Last scalar (0..1) the OS / user set on the master volume control.
    // The control mirrors-through to the EQRouter target device's
    // VolumeScalar, but we cache here so reads remain stable while the
    // router is in the middle of a swap (target file change) or null.
    std::atomic<Float32> cachedVolumeScalar{1.0f};

    // Pending write slot drained by the volume mirror worker. SetPropertyData
    // (called from inside coreaudiod servicing the HAL property dispatch)
    // must not call AudioObjectSetPropertyData on the target device inline —
    // doing so re-enters coreaudiod from coreaudiod and the slider goes
    // inert. Instead, SetPropertyData stages the desired scalar here and a
    // detached worker performs the cross-device write off the dispatch path.
    std::atomic<Float32> pendingVolumeWrite{1.0f};
    std::atomic<bool> hasPendingVolumeWrite{false};
};

PluginState gPlugin;

// MARK: - Volume control math + target-device mirroring

/// Clamps a scalar to [0, 1] then converts to dB on a 20·log10 curve, with
/// the result floored at `kVolumeMinDB`. A scalar of 0 reports the floor
/// rather than -inf so HAL clients don't see a denormal.
Float32 ScalarToDB(Float32 scalar) {
    if (scalar <= 0.0f) return kVolumeMinDB;
    if (scalar >= 1.0f) return kVolumeMaxDB;
    const Float32 db = 20.0f * log10f(scalar);
    return db < kVolumeMinDB ? kVolumeMinDB : db;
}

/// Inverse of ScalarToDB; clamps the result to [0, 1].
Float32 DBToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0.0f;
    if (db >= kVolumeMaxDB) return 1.0f;
    const Float32 s = powf(10.0f, db / 20.0f);
    return s < 0.0f ? 0.0f : (s > 1.0f ? 1.0f : s);
}

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
#if defined(SPOTIGLASS_EQ_DEBUG)
    // Periodic diagnostic — every 200 IO cycles (~2s @ 96-frame cycles)
    // dump snapshot status + first band coefficient so we can see whether
    // the driver is actually reading new coefficient frames.
    static UInt32 ioCycleCounter = 0;
    if ((ioCycleCounter++ % 200) == 0) {
        FILE* log = fopen("/tmp/com.isaaclins.spotiglass.eq.router.log", "a");
        if (log) {
            fprintf(log,
                "DoIO[%u]: snapStatus=%d preamp=%.3f band[0..3]=%.4f,%.4f,%.4f,%.4f rate=%u mask=0x%x frames=%u\n",
                ioCycleCounter,
                snapshotStatus,
                (double)freshFrame.preampLinear,
                (double)freshFrame.bandCoeffs[0],
                (double)freshFrame.bandCoeffs[1],
                (double)freshFrame.bandCoeffs[2],
                (double)freshFrame.bandCoeffs[3],
                (unsigned)freshFrame.sampleRateHz,
                (unsigned)freshFrame.enabledMask,
                (unsigned)ioBufferFrameSize);
            fclose(log);
        }
    }
#endif
    EQDSP_Apply(
        &gPlugin.dsp,
        snapshotStatus == 0 ? &freshFrame : nullptr,
        static_cast<float*>(ioMainBuffer),
        ioBufferFrameSize
    );
    // Forward the post-EQ stereo buffer to the previous real default output
    // so the user actually hears the result. EQRouter_Push is lock-free and
    // drops oldest frames if the consumer's IOProc falls behind, so it's
    // safe to call from this realtime callback.
    if (gPlugin.router) {
        EQRouter_Push(
            gPlugin.router,
            static_cast<const float*>(ioMainBuffer),
            ioBufferFrameSize
        );
    }
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

// Watcher thread: every 500ms, reads the forwarding target file and, if the
// UID differs from the router currently in gPlugin.router, opens a new
// router on the new device and atomically swaps. This lets the Settings UI
// switch where EQ'd audio goes (e.g., from speakers to headphones) without
// requiring the user to toggle EQ off and back on.
void* TargetWatcherMain(void* /*unused*/) {
    while (true) {
        struct timespec ts = {0, 500 * 1000 * 1000}; // 500ms
        nanosleep(&ts, nullptr);

        FILE* f = fopen("/tmp/com.isaaclins.spotiglass.eq.target", "r");
        if (!f) continue;
        char new_uid[256] = {0};
        if (!fgets(new_uid, sizeof(new_uid), f)) { fclose(f); continue; }
        fclose(f);
        size_t len = strlen(new_uid);
        while (len > 0 && (new_uid[len - 1] == '\n' || new_uid[len - 1] == '\r')) {
            new_uid[--len] = '\0';
        }
        if (len == 0) continue;

        pthread_mutex_lock(&gPlugin.stateLock);
        EQRouter* current = gPlugin.router;
        const char* current_uid = current ? EQRouter_TargetUID(current) : "";
        bool same = (strcmp(current_uid, new_uid) == 0);
        pthread_mutex_unlock(&gPlugin.stateLock);
        if (same) continue;

        // Target changed. Open a fresh router on the new device, then
        // atomically swap pointers and close the old one. Doing the open
        // BEFORE acquiring the lock keeps the IO-thread `EQRouter_Push`
        // path lock-free; only the pointer swap is briefly serialised.
        EQRouter* opened = EQRouter_Open(new_uid);
        if (!opened) continue;
        pthread_mutex_lock(&gPlugin.stateLock);
        EQRouter* prior = gPlugin.router;
        gPlugin.router = opened;
        pthread_mutex_unlock(&gPlugin.stateLock);
        if (prior) EQRouter_Close(prior);
    }
    return nullptr;
}

// Volume mirror worker: every ~150ms, (a) drains a pending write by calling
// AudioObjectSetPropertyData on the EQRouter target's VolumeScalar and
// (b) reads the target's current VolumeScalar so the menu-bar slider tracks
// hardware-side changes (someone hitting F11/F12 on the laptop keyboard,
// another app calling SetVolume). On change, it publishes a
// `PropertiesChanged` so HAL clients refresh their cached read.
//
// This MUST be off the HAL property dispatch path — calling
// AudioObjectSet/GetPropertyData on the target from inside SetPropertyData
// recursively re-enters coreaudiod and the menu-bar slider stays inert.
void* VolumeMirrorMain(void* /*unused*/) {
    Float32 lastObserved = -1.0f;
    while (true) {
        struct timespec ts = {0, 150 * 1000 * 1000}; // 150ms
        nanosleep(&ts, nullptr);

        const AudioObjectID target = EQRouter_TargetDevice(gPlugin.router);
        if (target == kAudioObjectUnknown) continue;

        AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyVolumeScalar,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };

        // 1) Drain a pending write before sampling — otherwise the read
        //    races the write and we'd briefly observe the stale hardware
        //    value, snap the cache back, and flicker the slider.
        if (gPlugin.hasPendingVolumeWrite.exchange(false, std::memory_order_acq_rel)) {
            Float32 want = gPlugin.pendingVolumeWrite.load(std::memory_order_acquire);
            if (want < 0.0f) want = 0.0f;
            if (want > 1.0f) want = 1.0f;
            (void)AudioObjectSetPropertyData(
                target, &addr, 0, nullptr, sizeof(want), &want
            );
        }

        // 2) Sample the target so external volume changes (keyboard F11/F12,
        //    System Settings slider on the target device) reflect on our
        //    virtual device's slider.
        Float32 fresh = 0.0f;
        UInt32 size = sizeof(fresh);
        const OSStatus status = AudioObjectGetPropertyData(
            target, &addr, 0, nullptr, &size, &fresh
        );
        if (status != noErr || size != sizeof(fresh)) continue;
        if (fresh < 0.0f) fresh = 0.0f;
        if (fresh > 1.0f) fresh = 1.0f;

        const Float32 prior = gPlugin.cachedVolumeScalar.load(std::memory_order_acquire);
        if (fabsf(fresh - prior) < 0.0005f) {
            lastObserved = fresh;
            continue;
        }
        gPlugin.cachedVolumeScalar.store(fresh, std::memory_order_release);

        if (gPlugin.host && gPlugin.host->PropertiesChanged && fabsf(fresh - lastObserved) > 0.0005f) {
            const AudioObjectPropertyAddress changed[2] = {
                { kAudioLevelControlPropertyScalarValue,
                  kAudioObjectPropertyScopeGlobal,
                  kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue,
                  kAudioObjectPropertyScopeGlobal,
                  kAudioObjectPropertyElementMain }
            };
            gPlugin.host->PropertiesChanged(
                gPlugin.host, kVolumeControlObjectID, 2, changed
            );
        }
        lastObserved = fresh;
    }
    return nullptr;
}

OSStatus Initialize(AudioServerPlugInDriverRef /*self*/, AudioServerPlugInHostRef host) {
    pthread_mutex_lock(&gPlugin.stateLock);
    gPlugin.host = host;
    EQDSP_Reset(&gPlugin.dsp);
    pthread_mutex_unlock(&gPlugin.stateLock);

    // Start the target-file watcher exactly once per plugin lifetime.
    static pthread_t watcher;
    static bool watcher_started = false;
    if (!watcher_started) {
        if (pthread_create(&watcher, nullptr, TargetWatcherMain, nullptr) == 0) {
            pthread_detach(watcher);
            watcher_started = true;
        }
    }
    // Start the volume-mirror worker. Same one-shot pattern; never joined.
    static pthread_t volume_mirror;
    static bool volume_mirror_started = false;
    if (!volume_mirror_started) {
        if (pthread_create(&volume_mirror, nullptr, VolumeMirrorMain, nullptr) == 0) {
            pthread_detach(volume_mirror);
            volume_mirror_started = true;
        }
    }
    return noErr;
}

OSStatus StartIO(AudioServerPlugInDriverRef /*self*/,
                 AudioObjectID /*deviceID*/,
                 UInt32 /*clientID*/) {
    pthread_mutex_lock(&gPlugin.stateLock);
    if (!gPlugin.coeffReader) {
        // Fixed path (no uid suffix). The Swift host writes from the
        // logged-in user; the driver reads from inside coreaudiod where
        // `getuid()` returns _coreaudiod's uid (202). Sharing one path keeps
        // both sides aligned. Must mirror EQCoefficientPublisher.defaultBackingPath.
        gPlugin.coeffReader = EQCoefficientReader_Open(
            "/tmp/com.isaaclins.spotiglass.eq.coeffs.v1"
        );
#if defined(SPOTIGLASS_EQ_DEBUG)
        FILE* log = fopen("/tmp/com.isaaclins.spotiglass.eq.router.log", "a");
        if (log) {
            fprintf(log, "StartIO: coeffReader_Open(\"%s\") → %p\n",
                    "/tmp/com.isaaclins.spotiglass.eq.coeffs.v1",
                    (void*)gPlugin.coeffReader);
            fclose(log);
        }
#endif
    }
    EQDSP_Reset(&gPlugin.dsp);
    gPlugin.ioRunning = true;
    gPlugin.ioStartHostTime = mach_absolute_time();
    gPlugin.ioStartSeed++;

    // Snapshot whether the router still needs opening, then release the
    // state lock BEFORE the call out (held locks across calls back into
    // coreaudiod deadlock). EQRouter is currently disabled (see below).
    bool need_open_router = (gPlugin.router == nullptr);
    pthread_mutex_unlock(&gPlugin.stateLock);

    if (need_open_router) {
        // Open the router on a detached worker thread so coreaudiod's IO
        // setup for OUR device finishes first. Calling
        // AudioDeviceCreateIOProcID + AudioDeviceStart from inside
        // coreaudiod is supported (it's how the plugin can forward audio to
        // real hardware) but it MUST run on its own thread — inline calls
        // either block our StartIO or interleave badly with the IO thread
        // that's still spinning up.
        pthread_t worker;
        if (pthread_create(&worker, nullptr,
                           [](void*) -> void* {
                               // Brief yield so the EQ device's own IO
                               // thread can finish its first cycle before
                               // we add a peer-device IOProc to the
                               // coreaudiod scheduler. 20ms is plenty.
                               struct timespec ts = {0, 20 * 1000 * 1000}; // 20ms
                               nanosleep(&ts, nullptr);
                               const char* target_path = "/tmp/com.isaaclins.spotiglass.eq.target";
                               FILE* f = fopen(target_path, "r");
                               if (!f) return nullptr;
                               char uid[256] = {0};
                               if (!fgets(uid, sizeof(uid), f)) { fclose(f); return nullptr; }
                               fclose(f);
                               size_t len = strlen(uid);
                               while (len > 0 && (uid[len - 1] == '\n' || uid[len - 1] == '\r')) {
                                   uid[--len] = '\0';
                               }
                               if (len == 0) return nullptr;
                               EQRouter* opened = EQRouter_Open(uid);
                               if (!opened) return nullptr;
                               pthread_mutex_lock(&gPlugin.stateLock);
                               if (!gPlugin.router) {
                                   gPlugin.router = opened;
                                   pthread_mutex_unlock(&gPlugin.stateLock);
                               } else {
                                   pthread_mutex_unlock(&gPlugin.stateLock);
                                   EQRouter_Close(opened);
                               }
                               return nullptr;
                           },
                           nullptr) == 0) {
            pthread_detach(worker);
        }
    }
    return noErr;
}

OSStatus StopIO(AudioServerPlugInDriverRef /*self*/,
                AudioObjectID /*deviceID*/,
                UInt32 /*clientID*/) {
    pthread_mutex_lock(&gPlugin.stateLock);
    gPlugin.ioRunning = false;
    if (gPlugin.coeffReader) {
        EQCoefficientReader_Close(gPlugin.coeffReader);
        gPlugin.coeffReader = nullptr;
    }
    // Intentionally KEEP gPlugin.router open across StopIO so the next
    // StartIO doesn't pay the ~200ms AudioDeviceCreateIOProcID +
    // AudioDeviceStart warmup. Without this, every fresh client (e.g., back-
    // to-back `afplay` calls) triggers a Stop/Start cycle and the first
    // ~200ms of audio is dropped while the router reopens. The router will
    // be torn down for real in DestroyDevice / plugin teardown.
    pthread_mutex_unlock(&gPlugin.stateLock);
    return noErr;
}

// MARK: - Static device shape

// 2 ch, native-endian Float32 interleaved — the format coreaudiod will
// publish to clients as "Spotiglass EQ"'s virtual stream format. Sample rate
// is mutable via SetPropertyData; the constants here are the discrete rates
// kAudioDevicePropertyAvailableNominalSampleRates advertises.
constexpr UInt32 kChannelsPerFrame = 2;
constexpr Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 192000.0 };
constexpr UInt32 kNumSupportedSampleRates =
    sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);

constexpr const char* kPluginNameUTF8 = "Spotiglass EQ Driver";
constexpr const char* kPluginManufacturerUTF8 = "Isaac Lins";
constexpr const char* kDeviceNameUTF8 = "Spotiglass EQ";
constexpr const char* kDeviceUIDUTF8 = "com.isaaclins.spotiglass.eqdevice";
constexpr const char* kModelUIDUTF8 = "com.isaaclins.spotiglass.eqmodel";

static AudioStreamBasicDescription MakeStreamFormat(Float64 sampleRate) {
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
                      | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = sizeof(Float32) * kChannelsPerFrame;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(Float32) * kChannelsPerFrame;
    asbd.mChannelsPerFrame = kChannelsPerFrame;
    asbd.mBitsPerChannel = 32;
    return asbd;
}

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

// MARK: - Property dispatcher

Boolean HasProperty(AudioServerPlugInDriverRef /*self*/, AudioObjectID objectID,
                    pid_t /*pid*/, const AudioObjectPropertyAddress* address) {
    if (!address) return false;
    const AudioObjectPropertySelector s = address->mSelector;

    if (objectID == kPluginObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
            default: return false;
        }
    }
    if (objectID == kDeviceObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyPreferredChannelsForStereo:
                return true;
            default: return false;
        }
    }
    if (objectID == kOutputStreamObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default: return false;
        }
    }
    if (objectID == kVolumeControlObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioObjectPropertyName:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                return true;
            default: return false;
        }
    }
    return false;
}

OSStatus IsPropertySettable(AudioServerPlugInDriverRef self, AudioObjectID objectID,
                            pid_t pid, const AudioObjectPropertyAddress* address,
                            Boolean* outIsSettable) {
    if (!outIsSettable || !address) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(self, objectID, pid, address)) {
        *outIsSettable = false;
        return kAudioHardwareUnknownPropertyError;
    }
    // The only properties Spotiglass exposes as settable are the device
    // nominal sample rate and the stream's virtual/physical format. Everything
    // else is read-only metadata.
    *outIsSettable = false;
    if (objectID == kDeviceObjectID && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outIsSettable = true;
    }
    if (objectID == kOutputStreamObjectID &&
        (address->mSelector == kAudioStreamPropertyVirtualFormat ||
         address->mSelector == kAudioStreamPropertyPhysicalFormat ||
         address->mSelector == kAudioStreamPropertyIsActive)) {
        *outIsSettable = true;
    }
    if (objectID == kVolumeControlObjectID &&
        (address->mSelector == kAudioLevelControlPropertyScalarValue ||
         address->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        *outIsSettable = true;
    }
    return noErr;
}

OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef self, AudioObjectID objectID,
                             pid_t pid, const AudioObjectPropertyAddress* address,
                             UInt32 /*qSize*/, const void* /*qData*/, UInt32* outDataSize) {
    if (!outDataSize || !address) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(self, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;

    const AudioObjectPropertySelector s = address->mSelector;

    if (objectID == kPluginObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:                 *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:                 *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:        *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:            *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice:  *outDataSize = sizeof(AudioObjectID); return noErr;
        }
    }
    if (objectID == kDeviceObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:                                *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:                                *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects:
                // Device owns the output stream + the master volume control.
                *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:                              *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:                         *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyRelatedDevices:                        *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyClockDomain:                           *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive:                         *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning:                       *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:              *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:        *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:                               *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyStreams:
                // Match GetPropertyData's scope filter: input scope reports
                // zero streams so Spotiglass EQ has zero input channels.
                *outDataSize = (address->mScope == kAudioObjectPropertyScopeInput)
                    ? 0 : sizeof(AudioObjectID);
                return noErr;
            case kAudioObjectPropertyControlList:                           *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertySafetyOffset:                          *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate:                     *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = kNumSupportedSampleRates * sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyIsHidden:                              *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:                   *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:            *outDataSize = 2 * sizeof(UInt32); return noErr;
        }
    }
    if (objectID == kOutputStreamObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:                              *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:                              *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:                               *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioStreamPropertyIsActive:                           *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection:                          *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyTerminalType:                       *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel:                    *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:                            *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:                     *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription); return noErr;
        }
    }
    if (objectID == kVolumeControlObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:                                  *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:                                  *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects:                           *outDataSize = 0; return noErr;
            case kAudioObjectPropertyName:                                   *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioControlPropertyScope:                                 *outDataSize = sizeof(AudioObjectPropertyScope); return noErr;
            case kAudioControlPropertyElement:                               *outDataSize = sizeof(AudioObjectPropertyElement); return noErr;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:          *outDataSize = sizeof(Float32); return noErr;
            case kAudioLevelControlPropertyDecibelRange:                     *outDataSize = sizeof(AudioValueRange); return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

OSStatus GetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID objectID,
                         pid_t pid, const AudioObjectPropertyAddress* address,
                         UInt32 /*qSize*/, const void* /*qData*/, UInt32 inSize,
                         UInt32* outDataSize, void* outData) {
    if (!address || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(self, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;
    const AudioObjectPropertySelector s = address->mSelector;

    auto putString = [&](const char* utf8) -> OSStatus {
        if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *static_cast<CFStringRef*>(outData) = MakeStaticCFString(utf8);
        *outDataSize = sizeof(CFStringRef);
        return noErr;
    };
    auto putUInt32 = [&](UInt32 v) -> OSStatus {
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *static_cast<UInt32*>(outData) = v;
        *outDataSize = sizeof(UInt32);
        return noErr;
    };
    auto putClassID = [&](AudioClassID v) -> OSStatus {
        if (inSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
        *static_cast<AudioClassID*>(outData) = v;
        *outDataSize = sizeof(AudioClassID);
        return noErr;
    };
    auto putObjectID = [&](AudioObjectID v) -> OSStatus {
        if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        *static_cast<AudioObjectID*>(outData) = v;
        *outDataSize = sizeof(AudioObjectID);
        return noErr;
    };

    if (objectID == kPluginObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:    return putClassID(kAudioObjectClassID);
            case kAudioObjectPropertyClass:        return putClassID(kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:        return putObjectID(kAudioObjectUnknown);
            case kAudioObjectPropertyName:         return putString(kPluginNameUTF8);
            case kAudioObjectPropertyManufacturer: return putString(kPluginManufacturerUTF8);
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:   return putObjectID(kDeviceObjectID);
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = nullptr;
                // qualifierData carries the UID as CFStringRef.
                // For our single-device plugin, just always return the device if the UID matches.
                *static_cast<AudioObjectID*>(outData) =
                    (uid && CFStringCompare(uid, CFSTR("com.isaaclins.spotiglass.eqdevice"), 0) == kCFCompareEqualTo)
                    ? kDeviceObjectID : kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID);
                return noErr;
            }
            case kAudioPlugInPropertyResourceBundle: return putString("");
        }
    }
    if (objectID == kDeviceObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:    return putClassID(kAudioObjectClassID);
            case kAudioObjectPropertyClass:        return putClassID(kAudioDeviceClassID);
            case kAudioObjectPropertyOwner:        return putObjectID(kPluginObjectID);
            case kAudioObjectPropertyName:         return putString(kDeviceNameUTF8);
            case kAudioObjectPropertyManufacturer: return putString(kPluginManufacturerUTF8);
            case kAudioObjectPropertyOwnedObjects: {
                const UInt32 needed = 2 * sizeof(AudioObjectID);
                if (inSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioObjectID* out = static_cast<AudioObjectID*>(outData);
                out[0] = kOutputStreamObjectID;
                out[1] = kVolumeControlObjectID;
                *outDataSize = needed;
                return noErr;
            }
            case kAudioDevicePropertyDeviceUID:    return putString(kDeviceUIDUTF8);
            case kAudioDevicePropertyModelUID:     return putString(kModelUIDUTF8);
            case kAudioDevicePropertyTransportType: return putUInt32(kAudioDeviceTransportTypeVirtual);
            case kAudioDevicePropertyRelatedDevices: return putObjectID(kDeviceObjectID);
            case kAudioDevicePropertyClockDomain:  return putUInt32(0);
            case kAudioDevicePropertyDeviceIsAlive: return putUInt32(1);
            case kAudioDevicePropertyDeviceIsRunning:
                // 1 between StartIO and StopIO. coreaudiod queries this and
                // tears down the IO thread with `kAudioHardwareStoppedError`
                // if it ever returns 0 while the device should be running.
                return putUInt32(gPlugin.ioRunning ? 1 : 0);
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:       return putUInt32(1);
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return putUInt32(1);
            case kAudioDevicePropertyLatency:                        return putUInt32(0);
            case kAudioDevicePropertyStreams: {
                // CRITICAL: Spotiglass EQ is OUTPUT-ONLY. coreaudiod queries
                // streams with both input and output scopes. If we return a
                // stream for input scope, the device incorrectly appears with
                // "Input Channels: 2" in system_profiler — and worse, that's
                // exactly the audio-recording surface the project policy
                // forbids.
                if (address->mScope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = 0;
                    return noErr;
                }
                return putObjectID(kOutputStreamObjectID);
            }
            case kAudioObjectPropertyControlList:                    return putObjectID(kVolumeControlObjectID);
            case kAudioDevicePropertySafetyOffset:                   return putUInt32(0);
            case kAudioDevicePropertyNominalSampleRate: {
                if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                *static_cast<Float64*>(outData) = gPlugin.currentSampleRate;
                *outDataSize = sizeof(Float64);
                return noErr;
            }
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                const UInt32 needed = kNumSupportedSampleRates * sizeof(AudioValueRange);
                if (inSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioValueRange* out = static_cast<AudioValueRange*>(outData);
                for (UInt32 i = 0; i < kNumSupportedSampleRates; ++i) {
                    out[i].mMinimum = kSupportedSampleRates[i];
                    out[i].mMaximum = kSupportedSampleRates[i];
                }
                *outDataSize = needed;
                return noErr;
            }
            case kAudioDevicePropertyIsHidden:               return putUInt32(0);
            case kAudioDevicePropertyZeroTimeStampPeriod:    return putUInt32(static_cast<UInt32>(gPlugin.currentSampleRate));
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                UInt32* out = static_cast<UInt32*>(outData);
                out[0] = 1; out[1] = 2;
                *outDataSize = 2 * sizeof(UInt32);
                return noErr;
            }
        }
    }
    if (objectID == kOutputStreamObjectID) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: return putClassID(kAudioObjectClassID);
            case kAudioObjectPropertyClass:     return putClassID(kAudioStreamClassID);
            case kAudioObjectPropertyOwner:     return putObjectID(kDeviceObjectID);
            case kAudioObjectPropertyName:      return putString("Spotiglass EQ Output");
            case kAudioStreamPropertyIsActive:  return putUInt32(1);
            case kAudioStreamPropertyDirection: return putUInt32(0); // output
            case kAudioStreamPropertyTerminalType: return putUInt32(kAudioStreamTerminalTypeSpeaker);
            case kAudioStreamPropertyStartingChannel: return putUInt32(1);
            case kAudioStreamPropertyLatency:   return putUInt32(0);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                *static_cast<AudioStreamBasicDescription*>(outData) =
                    MakeStreamFormat(gPlugin.currentSampleRate);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return noErr;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                const UInt32 needed = kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription);
                if (inSize < needed) return kAudioHardwareBadPropertySizeError;
                AudioStreamRangedDescription* out =
                    static_cast<AudioStreamRangedDescription*>(outData);
                for (UInt32 i = 0; i < kNumSupportedSampleRates; ++i) {
                    out[i].mFormat = MakeStreamFormat(kSupportedSampleRates[i]);
                    out[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                    out[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
                }
                *outDataSize = needed;
                return noErr;
            }
        }
    }
    if (objectID == kVolumeControlObjectID) {
        auto putFloat32 = [&](Float32 v) -> OSStatus {
            if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            *static_cast<Float32*>(outData) = v;
            *outDataSize = sizeof(Float32);
            return noErr;
        };
        switch (s) {
            case kAudioObjectPropertyBaseClass:        return putClassID(kAudioLevelControlClassID);
            case kAudioObjectPropertyClass:            return putClassID(kAudioVolumeControlClassID);
            case kAudioObjectPropertyOwner:            return putObjectID(kDeviceObjectID);
            case kAudioObjectPropertyOwnedObjects:     *outDataSize = 0; return noErr;
            case kAudioObjectPropertyName:             return putString("Spotiglass EQ Master Volume");
            case kAudioControlPropertyScope:           return putUInt32(kAudioObjectPropertyScopeOutput);
            case kAudioControlPropertyElement:         return putUInt32(kAudioObjectPropertyElementMain);
            case kAudioLevelControlPropertyScalarValue: {
                // Return the cached scalar. The target device is sampled by
                // the VolumeMirrorMain worker thread, not from inside this
                // dispatcher — calling AudioObjectGetPropertyData on another
                // device here would re-enter coreaudiod from coreaudiod and
                // leave the slider inert (CMD path frozen on the recursive
                // call). Worker keeps `cachedVolumeScalar` fresh.
                const Float32 cached = gPlugin.cachedVolumeScalar.load(std::memory_order_acquire);
                return putFloat32(cached);
            }
            case kAudioLevelControlPropertyDecibelValue: {
                const Float32 cached = gPlugin.cachedVolumeScalar.load(std::memory_order_acquire);
                return putFloat32(ScalarToDB(cached));
            }
            case kAudioLevelControlPropertyDecibelRange: {
                if (inSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                AudioValueRange* r = static_cast<AudioValueRange*>(outData);
                r->mMinimum = kVolumeMinDB;
                r->mMaximum = kVolumeMaxDB;
                *outDataSize = sizeof(AudioValueRange);
                return noErr;
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels: {
                if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32* v = static_cast<Float32*>(outData);
                *v = ScalarToDB(*v);
                *outDataSize = sizeof(Float32);
                return noErr;
            }
            case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
                Float32* v = static_cast<Float32*>(outData);
                *v = DBToScalar(*v);
                *outDataSize = sizeof(Float32);
                return noErr;
            }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

OSStatus SetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID objectID,
                         pid_t pid, const AudioObjectPropertyAddress* address,
                         UInt32 /*qSize*/, const void* /*qData*/, UInt32 inSize,
                         const void* inData) {
    if (!address || !inData) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(self, objectID, pid, address)) return kAudioHardwareUnknownPropertyError;

    if (objectID == kDeviceObjectID && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        const Float64 newRate = *static_cast<const Float64*>(inData);
        // Accept only supported rates.
        bool ok = false;
        for (UInt32 i = 0; i < kNumSupportedSampleRates; ++i) {
            if (newRate == kSupportedSampleRates[i]) { ok = true; break; }
        }
        if (!ok) return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&gPlugin.stateLock);
        gPlugin.currentSampleRate = newRate;
        pthread_mutex_unlock(&gPlugin.stateLock);
        return noErr;
    }
    // Stream format / IsActive: accept but no-op (we only support one format).
    if (objectID == kOutputStreamObjectID) {
        return noErr;
    }
    if (objectID == kVolumeControlObjectID) {
        if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        const Float32 raw = *static_cast<const Float32*>(inData);
        Float32 scalar = 1.0f;
        if (address->mSelector == kAudioLevelControlPropertyScalarValue) {
            scalar = raw;
        } else if (address->mSelector == kAudioLevelControlPropertyDecibelValue) {
            scalar = DBToScalar(raw);
        } else {
            return kAudioHardwareUnsupportedOperationError;
        }
        if (scalar < 0.0f) scalar = 0.0f;
        if (scalar > 1.0f) scalar = 1.0f;
        // Cache locally so subsequent reads remain stable, then hand the
        // write off to VolumeMirrorMain. Calling AudioObjectSetPropertyData
        // on the EQRouter target inline here would recursively re-enter the
        // HAL property dispatcher (coreaudiod calling coreaudiod) and the
        // menu-bar slider would stay inert. The worker thread issues the
        // cross-device write off the dispatch path.
        gPlugin.cachedVolumeScalar.store(scalar, std::memory_order_release);
        gPlugin.pendingVolumeWrite.store(scalar, std::memory_order_release);
        gPlugin.hasPendingVolumeWrite.store(true, std::memory_order_release);
        // Notify HAL clients (menu-bar volume slider, System Settings) that
        // both flavours of the value just changed so the UI redraws.
        if (gPlugin.host && gPlugin.host->PropertiesChanged) {
            const AudioObjectPropertyAddress changed[2] = {
                { kAudioLevelControlPropertyScalarValue,
                  kAudioObjectPropertyScopeGlobal,
                  kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue,
                  kAudioObjectPropertyScopeGlobal,
                  kAudioObjectPropertyElementMain }
            };
            gPlugin.host->PropertiesChanged(
                gPlugin.host, kVolumeControlObjectID, 2, changed
            );
        }
        return noErr;
    }
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef /*self*/, AudioObjectID /*deviceID*/,
                          UInt32 /*clientID*/, Float64* outSampleTime, UInt64* outHostTime,
                          UInt64* outSeed) {
    // coreaudiod uses this to peg the device's sample-domain timeline to
    // the host clock. Returning a static value makes coreaudiod think the
    // device isn't advancing and it tears down the IO thread with
    // `kAudioHardwareStoppedError`. Compute an ever-advancing sample count
    // anchored at StartIO via mach_absolute_time.
    static mach_timebase_info_data_t s_tb = {0, 0};
    if (s_tb.denom == 0) mach_timebase_info(&s_tb);
    const UInt64 now = mach_absolute_time();
    pthread_mutex_lock(&gPlugin.stateLock);
    const UInt64 anchor = gPlugin.ioStartHostTime ? gPlugin.ioStartHostTime : now;
    const UInt64 seed = gPlugin.ioStartSeed;
    const Float64 rate = gPlugin.currentSampleRate;
    pthread_mutex_unlock(&gPlugin.stateLock);
    // Convert (now - anchor) mach ticks to nanoseconds to samples.
    const UInt64 elapsed_ticks = (now >= anchor) ? (now - anchor) : 0;
    const Float64 elapsed_ns = static_cast<Float64>(elapsed_ticks) * s_tb.numer / s_tb.denom;
    const Float64 elapsed_samples = elapsed_ns * rate / 1.0e9;
    if (outSampleTime) *outSampleTime = elapsed_samples;
    if (outHostTime)   *outHostTime = anchor;
    if (outSeed)       *outSeed = seed;
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
///
/// `default` visibility is required so `dlsym` inside the
/// `Core-Audio-Driver-Service.helper` host can locate the symbol; the
/// `extern "C"` block only disables C++ name mangling, not the
/// `-fvisibility=hidden` we pass at compile time.
__attribute__((visibility("default")))
void* SpotiglassEQDriver_Create(CFAllocatorRef /*allocator*/, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    return &gInterfacePtr;
}

} // extern "C"
