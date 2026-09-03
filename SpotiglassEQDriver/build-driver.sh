#!/usr/bin/env bash
# SpotiglassEQDriver/build-driver.sh — standalone build of the .driver bundle
# using clang directly, without Xcode.
#
# Produces a SpotiglassEQDriver.driver bundle at build/SpotiglassEQDriver.driver
# that has the right layout for coreaudiod loading:
#
#     SpotiglassEQDriver.driver/
#       Contents/
#         Info.plist
#         MacOS/SpotiglassEQDriver       (Mach-O bundle, mh_bundle)
#
# This script is the no-Xcode escape hatch: it lets reviewers verify the C/C++
# compiles cleanly on macOS 26 SDK and produces a valid Mach-O without
# needing to add a new Xcode target.
#
# The Xcode-target version (which adds proper embed-in-host-app integration
# and signing) is documented in docs/equalizer-xcode-target.md.

set -euo pipefail

cd "$(dirname "$0")"
SRC="."
OUT_ROOT="../build/SpotiglassEQDriver.driver"
OUT_BIN="$OUT_ROOT/Contents/MacOS/SpotiglassEQDriver"
OUT_PLIST="$OUT_ROOT/Contents/Info.plist"
# Release builds pass the app's versions so driver upgrades are detected even
# when the driver target is compiled by this standalone script.
DRIVER_MARKETING_VERSION="${DRIVER_MARKETING_VERSION:-0.1.0}"
DRIVER_BUILD_VERSION="${DRIVER_BUILD_VERSION:-1}"
DRIVER_CODESIGN_IDENTITY="${DRIVER_CODESIGN_IDENTITY:-}"
DRIVER_CODESIGN_KEYCHAIN="${DRIVER_CODESIGN_KEYCHAIN:-}"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

mkdir -p "$(dirname "$OUT_BIN")" "$(dirname "$OUT_PLIST")"

CXX_FLAGS=(
    -std=c++17
    -isysroot "$SDK"
    -mmacosx-version-min="$DEPLOYMENT_TARGET"
    -O2
    -fno-exceptions
    -fno-rtti
    -fvisibility=hidden
    -Wall -Wextra -Wno-unused-parameter
    -arch arm64
    -arch x86_64
)
C_FLAGS=(
    -std=c11
    -isysroot "$SDK"
    -mmacosx-version-min="$DEPLOYMENT_TARGET"
    -O2
    -fvisibility=hidden
    -Wall -Wextra -Wno-unused-parameter
    -arch arm64
    -arch x86_64
)

# Opt-in diagnostic logging: writes per-cycle DoIO / StartIO / EQRouter /
# OutputCallback events to /tmp/com.isaaclins.spotiglass.eq.router.log.
# Off by default so release builds stay quiet; enable for driver bring-up.
if [ -n "${SPOTIGLASS_EQ_DEBUG:-}" ]; then
    echo "==> SPOTIGLASS_EQ_DEBUG=1 — verbose driver logging will be compiled in"
    CXX_FLAGS+=( -DSPOTIGLASS_EQ_DEBUG=1 )
    C_FLAGS+=( -DSPOTIGLASS_EQ_DEBUG=1 )
fi
LINK_FLAGS=(
    -bundle
    -isysroot "$SDK"
    -mmacosx-version-min="$DEPLOYMENT_TARGET"
    -arch arm64
    -arch x86_64
    -framework CoreAudio
    -framework CoreFoundation
    -framework AudioToolbox
)

# Compile C and C++ sources separately so we can pick the right driver.
echo "==> compiling SpotiglassEQDSP.c"
xcrun clang   "${C_FLAGS[@]}"   -c "$SRC/SpotiglassEQDSP.c"        -o "$SRC/SpotiglassEQDSP.o"
echo "==> compiling EQCoefficientReader.c"
xcrun clang   "${C_FLAGS[@]}"   -c "$SRC/EQCoefficientReader.c"     -o "$SRC/EQCoefficientReader.o"
echo "==> compiling EQRouter.cpp"
xcrun clang++ "${CXX_FLAGS[@]}" -c "$SRC/EQRouter.cpp"              -o "$SRC/EQRouter.o"
echo "==> compiling SpotiglassEQPlugin.cpp"
xcrun clang++ "${CXX_FLAGS[@]}" -c "$SRC/SpotiglassEQPlugin.cpp"    -o "$SRC/SpotiglassEQPlugin.o"

echo "==> linking SpotiglassEQDriver bundle binary"
xcrun clang++ "${LINK_FLAGS[@]}" \
    "$SRC/SpotiglassEQDSP.o" \
    "$SRC/EQCoefficientReader.o" \
    "$SRC/EQRouter.o" \
    "$SRC/SpotiglassEQPlugin.o" \
    -o "$OUT_BIN"

echo "==> copying Info.plist"
cp "$SRC/Info.plist" "$OUT_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DRIVER_MARKETING_VERSION" "$OUT_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DRIVER_BUILD_VERSION" "$OUT_PLIST"

if [ -n "$DRIVER_CODESIGN_IDENTITY" ]; then
    echo "==> codesigning driver with $DRIVER_CODESIGN_IDENTITY"
    codesign_args=(--force --sign "$DRIVER_CODESIGN_IDENTITY" --timestamp=none)
    if [ -n "$DRIVER_CODESIGN_KEYCHAIN" ]; then
        codesign_args+=(--keychain "$DRIVER_CODESIGN_KEYCHAIN")
    fi
    codesign "${codesign_args[@]}" "$OUT_ROOT"
else
    echo "==> ad-hoc codesigning (Developer ID or local identity needed for coreaudiod)"
    codesign --force --sign - --timestamp=none "$OUT_ROOT"
fi

# Clean up object files so the source tree stays git-clean.
rm -f "$SRC"/*.o

echo
echo "OK: $OUT_ROOT"
echo "    $(file "$OUT_BIN")"
echo
echo "Embed this bundle with: make embed-driver"
echo "A signed Spotiglass build installs it through the registered privileged helper."
echo
if [ -z "$DRIVER_CODESIGN_IDENTITY" ]; then
    echo "NOTE: ad-hoc signing is not enough for coreaudiod on macOS 26 (kAudioHardwareIllegalOperationError)."
    echo "Re-sign with a Developer ID identity before installing on a production system."
else
    echo "Driver signed with $DRIVER_CODESIGN_IDENTITY."
fi
