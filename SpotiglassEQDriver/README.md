# SpotiglassEQDriver

CoreAudio AudioServerPlugIn that registers "Spotiglass EQ" as a virtual
output device and applies a 10-band biquad cascade in its IO callback.

## What's in this directory

| File | Role |
|---|---|
| `EQCoefficientFrame.h` | Binary layout of the shared-memory channel. Mirrors `Spotiglass/Playback/EQCoefficients.swift`. |
| `EQCoefficientReader.{h,c}` | Real-time-safe seqlock reader. Read from inside `DoIOOperation`. |
| `SpotiglassEQDSP.{h,c}` | Transposed direct-form-II biquad cascade. Hand-written so it auto-vectorises and stays free of allocations / locks. |
| `SpotiglassEQPlugin.cpp` | `AudioServerPlugInDriverInterface` vtable + factory function. Property handlers are scaffolded (`TODO(PROP)`) so the file maps to the structure each one must follow. |
| `Info.plist` | Standard `AudioServerPlugIn` plist with the factory UUID and the `kAudioServerPlugInTypeUUID` binding. |

## Building the `.driver` bundle

This directory ships the *source code* for the plugin. To actually produce a
loadable `SpotiglassEQDriver.driver` bundle, an Xcode target needs to be
added to `Spotiglass.xcodeproj` with these settings (not yet done; tracked
in docs/equalizer.md "Known limitations"):

1. **Product**: Bundle (extension `.driver`)
2. **Bundle Type**: `BNDL`
3. **Embed In**: Spotiglass app (`Contents/Library/Audio/Plug-Ins/HAL/`)
4. **Link**: `CoreAudio.framework`, `CoreFoundation.framework`,
   `AudioToolbox.framework`
5. **Code Signing**: A valid Developer ID. Ad-hoc / Sign-to-Run-Locally is
   not enough — `coreaudiod` on macOS 26 refuses to load plugins that don't
   carry a proper signature. See `docs/equalizer.md` → Known limitations.

Until those steps are completed, the Swift side (`EqualizerHALPluginController`,
`EQCoefficientPublisher`, `AudioEqualizerEngine`) all compile and pass tests,
but `enable()` reports `driverNotLoadedYet` because there's no embedded
`.driver` to copy into `~/Library/Audio/Plug-Ins/HAL/`.

## Status of property handlers

`SpotiglassEQPlugin.cpp` has `TODO(PROP)` markers on the property-routing
dispatchers. The DSP path (`DoIOOperation` → `SpotiglassEQDSP_Apply`) is
complete and is exercised independently by the Swift tests via the same
biquad math implementation. Apple's `NullAudio` sample (and the open-source
BlackHole / BackgroundMusic plugins) demonstrate the exact selector
dispatch table each of those `TODO` functions has to fill in.
