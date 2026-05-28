# Adding `SpotiglassEQDriver.driver` as an Xcode target

The current build path is `make embed-driver`, which uses `clang` via
`SpotiglassEQDriver/build-driver.sh` and a Makefile copy step. That keeps
the EQ driver buildable without touching `Spotiglass.xcodeproj`. The
recommended long-term path is a real Xcode target. Until that lands, this
document is what someone wiring it up should follow.

## Steps in Xcode UI

1. Open `Spotiglass.xcodeproj` → **File** → **New** → **Target…**
2. Pick **macOS** → **Bundle** → **Next**
3. Settings:
   - Product Name: `SpotiglassEQDriver`
   - Bundle Identifier: `com.isaaclins.spotiglass.eqdriver`
   - Language: Objective-C (it doesn't matter, the source files are C/C++)
   - Project: Spotiglass
   - Embed in Application: **Spotiglass**
4. Configure the new target:
   - **Build Settings**:
     - `WRAPPER_EXTENSION = driver`
     - `MACH_O_TYPE = mh_bundle`
     - `INSTALL_PATH = $(LOCAL_LIBRARY_DIR)/Audio/Plug-Ins/HAL`
     - `DEPLOYMENT_LOCATION = NO` (so Xcode doesn't install to the user
       Library on every build — `EqualizerHALPluginController.enable()`
       handles install from the embedded copy)
     - `INSTALL_PATH = /Library/Audio/Plug-Ins/HAL` (for the inherent
       plugin metadata; the actual install is controlled by Swift)
     - `CLANG_CXX_LANGUAGE_STANDARD = c++17`
     - `CLANG_CXX_LIBRARY = libc++`
     - `CODE_SIGN_STYLE = Automatic` (or `Manual` with a Developer ID
       identity — see "Code signing" below)
   - **Info.plist**: use `SpotiglassEQDriver/Info.plist` (it's already
     correct for an AudioServerPlugIn)
   - **Build Phases**:
     - **Compile Sources**: `SpotiglassEQDriver/SpotiglassEQDSP.c`,
       `SpotiglassEQDriver/EQCoefficientReader.c`,
       `SpotiglassEQDriver/SpotiglassEQPlugin.cpp`
     - **Link Binary with Libraries**: `CoreAudio.framework`,
       `CoreFoundation.framework`, `AudioToolbox.framework`
     - **Headers**: no public headers needed (the plugin is loaded by
       coreaudiod, not linked against by other targets)
5. On the **Spotiglass** main target:
   - **Build Phases** → **New Copy Files Phase**:
     - Destination: `Wrapper`
     - Subpath: `Contents/Library/Audio/Plug-Ins/HAL`
     - Add: `SpotiglassEQDriver.driver` from the Products group
     - Code Sign On Copy: ON

## Code signing

`coreaudiod` on macOS 26 refuses to load `.driver` bundles that aren't
Developer ID signed. Options:

- **Developer ID + Notarization (production)**: set
  `CODE_SIGN_IDENTITY = "Developer ID Application: <your name>"` on the
  `SpotiglassEQDriver` target, and notarize the embedded driver as part
  of the host app's notarization (`xcrun notarytool submit` carries the
  embedded driver). This is the only path that works on a user's machine
  without manual `spctl` overrides.

- **Local development**: stick with "Sign to Run Locally" / ad-hoc. The
  driver builds and embeds cleanly, and the Swift unit tests stage
  fixtures so they don't depend on coreaudiod loading the real driver.
  When you want to actually hear the EQ during development you'll need
  to either:
  1. Disable amfi restrictions on a development machine (not recommended)
  2. Get a Developer ID identity and sign locally

## Verification after wiring the target

```bash
make build
# Check the .driver is embedded:
ls "build/DerivedData/Build/Products/Debug/Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/"
# → SpotiglassEQDriver.driver

# Check it's a universal Mach-O bundle:
file "build/DerivedData/Build/Products/Debug/Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver/Contents/MacOS/SpotiglassEQDriver"
# → Mach-O universal binary with 2 architectures: [x86_64...] [arm64...]
```

Once Developer ID signing is in place, install + reload coreaudiod:

```bash
cp -R "build/DerivedData/.../Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver" \
       ~/Library/Audio/Plug-Ins/HAL/
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
system_profiler SPAudioDataType | grep -A2 "Spotiglass EQ"
```
