#!/usr/bin/env bash
# Compiles and runs the driver's unit tests.
#
# The driver is built with clang directly rather than Xcode, so it has no test
# target and CI never compiled it. The router's layout handling and its
# lifetime guard are the two pieces that fail silently (wrong stereo, or a
# router closed while a render callback still holds it), so they are tested
# here against the real EQRouter.cpp. EQRouter_OpenWithError is never called, so this
# touches no audio hardware and is safe to run in CI.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
BIN="$(mktemp -d)/eq_router_tests"

xcrun clang++ \
    -std=c++17 \
    -isysroot "$SDK" \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -O1 \
    -fno-exceptions \
    -fno-rtti \
    -Wall -Wextra -Wno-unused-parameter \
    "$SRC/tests/eq_router_tests.cpp" \
    "$SRC/EQRouter.cpp" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$BIN"

"$BIN"
