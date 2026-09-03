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

Two paths:

1. **`make embed-driver`** (recommended) — builds the host app and the
   `.driver`, then copies the driver into
   `Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/`. This is the
   no-Xcode-target shortcut; uses `clang` via `./build-driver.sh` and a
   Makefile copy step.

2. **`./build-driver.sh`** alone — produces a standalone driver bundle at
   `../build/SpotiglassEQDriver.driver`. Useful for inspecting the Mach-O.

The application now contains a separate Xcode target for
`SpotiglassEQPrivilegedHelper`. That helper is registered through
`SMAppService` and copies this bundle into the system HAL directory when the
user enables EQ. The driver itself remains a standalone target for now, and
`make embed-driver` places it inside the app before a signed manual check.
`coreaudiod` on macOS 26 refuses to load `.driver` bundles signed only ad-hoc.

## Status of property handlers

`SpotiglassEQPlugin.cpp` has `TODO(PROP)` markers on the property-routing
dispatchers. The DSP path (`DoIOOperation` → `SpotiglassEQDSP_Apply`) is
complete and is exercised independently by the Swift tests via the same
biquad math implementation. Apple's `NullAudio` sample (and the open-source
BlackHole / BackgroundMusic plugins) demonstrate the exact selector
dispatch table each of those `TODO` functions has to fill in.
