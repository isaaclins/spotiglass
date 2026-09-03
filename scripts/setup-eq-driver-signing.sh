#!/usr/bin/env bash
# scripts/setup-eq-driver-signing.sh — one-shot dev setup for signing
# SpotiglassEQDriver.driver with the user's Apple Development cert.
#
# Why this script exists: on a fresh checkout (or after macOS sweeps stale
# anchors from the user keychain), codesign refuses the Apple Development
# identity with `errSecInternalComponent`/"unable to build chain to
# self-signed root". The Apple Inc. Root CA needs to be both present in the
# login keychain AND trusted as a root anchor before codesign will accept it.
# This script is the safest way to do that one-time setup; Xcode normally
# handles it the first time you build a signed app.
#
# Run with no args. You'll be prompted for your login password.

set -euo pipefail

CERT_URL="https://www.apple.com/appleca/AppleIncRootCertificate.cer"
# Use a fresh user-owned temp file each run, so any stale (possibly
# root-owned) leftover from prior runs doesn't bork the curl write.
CERT_PATH="$(mktemp -t AppleIncRootCertificate.XXXXXX.cer)"
trap 'rm -f "$CERT_PATH"' EXIT
KC="$HOME/Library/Keychains/login.keychain-db"

echo "==> downloading Apple Inc. Root CA from $CERT_URL → $CERT_PATH"
curl -fsSL "$CERT_URL" -o "$CERT_PATH"

echo "==> importing into your login keychain"
if ! security find-certificate -c "Apple Root CA" "$KC" >/dev/null 2>&1; then
    security import "$CERT_PATH" -k "$KC"
else
    echo "    (already present)"
fi

echo "==> trusting Apple Root CA as a root anchor (admin / system keychain)"
echo "    sudo will prompt for your account password — this writes the trust"
echo "    setting that codesign actually consults (the user-keychain variant"
echo "    silently no-ops on macOS 26)."
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_PATH"

echo "==> verifying signing identity is now trusted for code signing"
if security find-identity -v -p codesigning | grep -q "CSSMERR_TP_NOT_TRUSTED"; then
    echo "    FAIL: identity still untrusted after add-trusted-cert. Run Keychain Access manually:" >&2
    echo "        1. open ~/Library/Caches/AppleIncRootCertificate.cer in Keychain Access" >&2
    echo "        2. Get Info → Trust → set 'When using this certificate' to Always Trust" >&2
    exit 1
fi
if security find-identity -v -p codesigning | grep -q "Apple Development"; then
    echo "    OK: Apple Development identity available and trusted"
else
    echo "    WARNING: no Apple Development identity found — open Xcode → Settings → Accounts and sign in." >&2
    exit 1
fi

echo
echo "OK. The Apple Development identity is ready for signed builds."
echo "Launch a signed Spotiglass build and enable Equalizer; macOS will"
echo "authorize the helper, which installs the driver and restarts coreaudiod."
