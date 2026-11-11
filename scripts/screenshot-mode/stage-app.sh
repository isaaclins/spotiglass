#!/usr/bin/env bash
# Copies the built app to where screenshot mode runs it, under the bundle id it runs as, and signs
# the copy.
#
#   scripts/screenshot-mode/stage-app.sh <built.app> <staged.app> <bundle-id> <real-bundle-id>
#
# macOS keeps one Media & Apple Music permission per bundle id, tied to the signature it was given
# to. My signed builds carry the Developer ID requirement. An ad-hoc copy under the real bundle id
# doesn't match it, so macOS asks again, and allowing that moves the permission to the ad-hoc copy:
# from then on every signed build is refused, test hosts already running included, and MusicKit
# fails with MusicTokenRequestError.unknown (#520). So a copy under the real bundle id is signed
# with the Developer ID identity, and without one it isn't staged at all. A copy under its own
# bundle id never reaches MusicKit and stays ad-hoc.
set -euo pipefail

[ $# -eq 4 ] || { sed -n '5p' "$0" | sed 's/^# *//' >&2; exit 2; }
src="$1" dest="$2" bundle_id="$3" real_bundle_id="$4"

identity="-"
if [ "$bundle_id" = "$real_bundle_id" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application/ { print $2; exit }')"
    if [ -z "$identity" ]; then
        echo "screenshots: --with-apple-music needs a Developer ID Application signing identity." >&2
        echo "  An ad-hoc copy under $real_bundle_id would take over the signed app's Apple Music" >&2
        echo "  permission, and signed builds would lose Apple Music until it is allowed again." >&2
        exit 1
    fi
fi

rm -rf "$dest"
cp -R "$src" "$dest"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$dest/Contents/Info.plist"
if ! out="$(codesign --force --deep --sign "$identity" "$dest" 2>&1)"; then
    rm -rf "$dest"
    echo "screenshots: signing $dest failed:" >&2
    echo "$out" >&2
    [ "$identity" = "-" ] || echo "  (a locked keychain fails with errSecInternalComponent: unlock it first)" >&2
    exit 1
fi
