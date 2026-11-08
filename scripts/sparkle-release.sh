#!/usr/bin/env bash
# Package a Release Spotiglass.app for Sparkle + GitHub Releases (local maintainer flow).
# CI mirrors these steps in .github/workflows/release-artifact.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MARKETING_VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
RELEASE_NOTES="${3:-}"
# A relative notes path means relative to where the script was run from, so
# resolve it before changing into the repo root.
if [[ -n "$RELEASE_NOTES" && "$RELEASE_NOTES" != /* ]]; then
  RELEASE_NOTES="$PWD/$RELEASE_NOTES"
fi
cd "$ROOT"

if [[ -z "$MARKETING_VERSION" ]]; then
  echo "Usage: $0 <marketing_version> [build_number] [release_notes_markdown_file]" >&2
  echo "Example: $0 0.2.0 42 docs/release-notes/v0.2.0.md" >&2
  exit 1
fi

PROJECT_FILE="$ROOT/Spotiglass.xcodeproj/project.pbxproj"

# Highest CURRENT_PROJECT_VERSION recorded in the project file. Every build
# configuration that sets it should agree, so disagreement means a manual Xcode
# edit, a bad merge, or an aborted release, and is refused rather than silently
# compared against whichever value happens to come first in the file.
read_project_build_number() {
  local values
  values="$(
    sed -n -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]*);$/\1/p' "$PROJECT_FILE"
  )"
  if [[ -z "$values" ]]; then
    echo "ERROR: Could not find CURRENT_PROJECT_VERSION in $PROJECT_FILE" >&2
    return 1
  fi

  local value
  while IFS= read -r value; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      echo "ERROR: CURRENT_PROJECT_VERSION in $PROJECT_FILE is not an integer: $value" >&2
      return 1
    fi
  done <<< "$values"

  local distinct
  distinct="$(printf '%s\n' "$values" | sort -u | wc -l | tr -d ' ')"
  if [[ "$distinct" -ne 1 ]]; then
    echo "ERROR: Build configurations disagree on CURRENT_PROJECT_VERSION in $PROJECT_FILE:" >&2
    printf '%s\n' "$values" | sort -u | sed 's/^/  /' >&2
    echo "Reconcile them before cutting a release." >&2
    return 1
  fi

  printf '%s\n' "$values" | sort -n | tail -1
}

validate_release_versions() {
  # #85's URL rewrite assumes exactly three numeric components, and the value is
  # interpolated into a sed replacement below, where & and / are metacharacters.
  if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Marketing version must be MAJOR.MINOR.PATCH: $MARKETING_VERSION" >&2
    return 1
  fi
  # Leading zeros would be written verbatim into CFBundleVersion and into delta
  # filenames, so reject them instead of silently normalizing.
  if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Release build number must be a positive integer without leading zeros: $BUILD_NUMBER" >&2
    return 1
  fi

  local current_project_build
  current_project_build="$(read_project_build_number)" || return 1
  if (( BUILD_NUMBER <= current_project_build )); then
    echo "ERROR: Refusing release build ${BUILD_NUMBER}: $PROJECT_FILE already records CURRENT_PROJECT_VERSION ${current_project_build}. CFBundleVersion must strictly increase or Sparkle will not offer the update." >&2
    return 1
  fi
  echo "==> Validated release ${MARKETING_VERSION} (${BUILD_NUMBER}) against project build ${current_project_build}"
}

update_project_versions() {
  local marketing_pattern='^[[:space:]]*MARKETING_VERSION = [^;]*;$'
  local build_pattern='^[[:space:]]*CURRENT_PROJECT_VERSION = [^;]*;$'
  local marketing_matches
  local build_matches
  marketing_matches="$(grep -E -c "$marketing_pattern" "$PROJECT_FILE" || true)"
  build_matches="$(grep -E -c "$build_pattern" "$PROJECT_FILE" || true)"

  if [[ "$marketing_matches" -eq 0 ]]; then
    echo "ERROR: No MARKETING_VERSION entries matched the expected pattern in $PROJECT_FILE" >&2
    return 1
  fi
  if [[ "$build_matches" -eq 0 ]]; then
    echo "ERROR: No CURRENT_PROJECT_VERSION entries matched the expected pattern in $PROJECT_FILE" >&2
    return 1
  fi

  # The left-hand sides are anchored exactly like the counting patterns above, so
  # the set of rewritten lines is the set that was counted. That makes the
  # post-check below meaningful: it can detect a missed entry.
  sed -i '' -E \
    -e "s/^([[:space:]]*MARKETING_VERSION = )[^;]*;$/\\1${MARKETING_VERSION};/" \
    -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION = )[^;]*;$/\\1${BUILD_NUMBER};/" \
    "$PROJECT_FILE"

  local updated_marketing_matches
  local updated_build_matches
  updated_marketing_matches="$(grep -E -c "^[[:space:]]*MARKETING_VERSION = ${MARKETING_VERSION};$" "$PROJECT_FILE" || true)"
  updated_build_matches="$(grep -E -c "^[[:space:]]*CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};$" "$PROJECT_FILE" || true)"
  if [[ "$updated_marketing_matches" -ne "$marketing_matches" ]]; then
    echo "ERROR: Updated ${updated_marketing_matches} of ${marketing_matches} MARKETING_VERSION entries in $PROJECT_FILE" >&2
    return 1
  fi
  if [[ "$updated_build_matches" -ne "$build_matches" ]]; then
    echo "ERROR: Updated ${updated_build_matches} of ${build_matches} CURRENT_PROJECT_VERSION entries in $PROJECT_FILE" >&2
    return 1
  fi

  echo "==> Updated $PROJECT_FILE to ${MARKETING_VERSION} (${BUILD_NUMBER}) across ${build_matches} configurations"
}

# generate_appcast takes exactly one --download-url-prefix and applies it to every
# item, so each release rewrote historical full-zip enclosures to the tag being
# published, where those assets do not exist. Each Spotiglass-<version>.zip is
# attached to the release tagged v<version>, so pin every full-zip URL to the tag
# matching its own filename. The newest item already agrees and is left alone.
#
# The match is anchored on `<enclosure url="` so it cannot touch delta
# enclosures, the feed URL, or a download link that appears inside embedded
# release notes.
rewrite_appcast_download_urls() {
  local appcast="$1"
  if [[ ! -f "$appcast" ]]; then
    echo "ERROR: Appcast not found: $appcast" >&2
    return 1
  fi

  local enclosure_zip='<enclosure url="[^"]*/download/[^"/]+/Spotiglass-[^"/]+\.zip"'
  local before
  before="$(grep -E -c "$enclosure_zip" "$appcast" || true)"
  if [[ "$before" -eq 0 ]]; then
    echo "ERROR: No full-zip enclosure URLs matched the expected pattern in $appcast" >&2
    return 1
  fi

  local original
  original="$(mktemp -t spotiglass-appcast-before)"
  cp "$appcast" "$original"

  sed -i '' -E \
    -e 's#(<enclosure url="[^"]*/download/)[^"/]+(/Spotiglass-([0-9]+\.[0-9]+\.[0-9]+)\.zip")#\1v\3\2#g' \
    "$appcast"

  # Report rewrites actually performed, not merely lines that matched.
  local changed
  changed="$(diff <(grep -oE "$enclosure_zip" "$original") <(grep -oE "$enclosure_zip" "$appcast") | grep -c '^>' || true)"
  rm -f "$original"

  # Every full-zip enclosure must now carry the tag matching its own version. A
  # version shape the rewrite does not understand would silently keep the wrong
  # tag, which is the exact bug this closes, so treat any leftover as fatal.
  local mismatched
  mismatched="$(
    grep -oE "$enclosure_zip" "$appcast" \
      | sed -E 's#.*/download/([^"/]+)/Spotiglass-([^"/]+)\.zip"#\1 v\2#' \
      | awk '$1 != $2 { print }'
  )"
  if [[ -n "$mismatched" ]]; then
    echo "ERROR: full-zip enclosure URLs still point at a tag that does not match their version:" >&2
    printf '%s\n' "$mismatched" | sed 's/^/  tag=/' >&2
    return 1
  fi

  echo "==> Pinned ${changed} of ${before} full-zip enclosure URLs to their own release tags"
}

# Default to the next build after the one already recorded. Deriving it from the
# project file keeps the sequence contiguous; the previous default of
# `git rev-list --count HEAD` was a commit count in the hundreds, which would be
# accepted, written into the tree, and then permanently raise the floor for every
# future release.
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(( $(read_project_build_number) + 1 ))"
  echo "==> No build number given, using $BUILD_NUMBER (recorded build plus one)"
fi

# A notes path that was given but does not exist is a typo, not a request for a
# release without notes. Shipping silently without them is the wrong default.
validate_release_notes() {
  [[ -z "$RELEASE_NOTES" ]] && return 0
  if [[ ! -f "$RELEASE_NOTES" ]]; then
    echo "ERROR: Release notes file not found: $RELEASE_NOTES" >&2
    echo "       Fix the path, or omit the third argument to release without notes." >&2
    return 1
  fi
  echo "==> Using release notes $RELEASE_NOTES"
}

SPARKLE_VERSION="${SPARKLE_VERSION:-2.7.1}"
SPARKLE_TARBALL="$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}.tar.xz"
GENERATE_APPCAST="${GENERATE_APPCAST:-}"

# SHA-256 of the official Sparkle-<version>.tar.xz from
# https://github.com/sparkle-project/Sparkle/releases (the asset digest GitHub
# shows on the release page). generate_appcast runs on the machine that holds the
# Developer ID identity and the EdDSA update key, so nothing from the tarball
# runs until it matches. Bumping SPARKLE_VERSION means adding its checksum here.
sparkle_tarball_sha256() {
  case "$1" in
    2.7.1) echo "f7385c3e8c70c37e5928939e6246ac9070757b4b37a5cb558afa1b0d5ef189de" ;;
    *) return 1 ;;
  esac
}

# Fails unless the tarball at $1 has the pinned checksum for SPARKLE_VERSION.
verify_sparkle_tarball() {
  local tarball="$1"
  local expected actual
  if ! expected="$(sparkle_tarball_sha256 "$SPARKLE_VERSION")"; then
    echo "ERROR: No pinned SHA-256 for Sparkle ${SPARKLE_VERSION}." >&2
    echo "       Add the checksum of the official Sparkle-${SPARKLE_VERSION}.tar.xz to sparkle_tarball_sha256 in $0." >&2
    return 1
  fi
  actual="$(shasum -a 256 "$tarball" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: Sparkle ${SPARKLE_VERSION} tarball checksum mismatch: $tarball" >&2
    echo "       expected $expected" >&2
    echo "       got      $actual" >&2
    echo "       Nothing from it was run. Delete the file if it is still there and run the script again to download a fresh copy." >&2
    return 1
  fi
  echo "==> Verified Sparkle ${SPARKLE_VERSION} tarball (sha256 $actual)"
}

validate_release_versions
validate_release_notes
if [[ -z "$GENERATE_APPCAST" ]]; then
  # Fail on an unknown version (no pinned checksum) before anything else runs.
  if ! sparkle_tarball_sha256 "$SPARKLE_VERSION" >/dev/null; then
    verify_sparkle_tarball "$SPARKLE_TARBALL"
  fi
  # In validation-only mode an already downloaded tarball is checked too, so a
  # bad copy is caught before a real run spends time building and notarizing.
  if [[ -f "$SPARKLE_TARBALL" ]]; then
    verify_sparkle_tarball "$SPARKLE_TARBALL"
  fi
fi
if [[ "${SPARKLE_RELEASE_VALIDATE_ONLY:-0}" == "1" ]]; then
  echo "Validation-only mode: no build or project changes performed."
  exit 0
fi

TAG="v${MARKETING_VERSION}"

# Fetch and verify the Sparkle tools before the long build and notarization, so a
# bad download fails in seconds. On every run the cached tarball is copied into a
# private temporary directory, and that copy is verified and extracted there, so
# the tool that runs is the one that was checked: nothing reopens the shared
# cache after the check, and tools left in build/ by an earlier run are never
# reused. A GENERATE_APPCAST set by the caller is the caller's own choice and is
# used as given.
SPARKLE_TOOLS_DIR=""
if [[ -z "$GENERATE_APPCAST" ]]; then
  mkdir -p "$ROOT/build/sparkle"
  if [[ ! -f "$SPARKLE_TARBALL" ]]; then
    echo "==> Download Sparkle ${SPARKLE_VERSION} tools for generate_appcast"
    SPARKLE_DOWNLOAD="$SPARKLE_TARBALL.download"
    rm -f "$SPARKLE_DOWNLOAD"
    curl -fsSL -o "$SPARKLE_DOWNLOAD" \
      "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    if ! verify_sparkle_tarball "$SPARKLE_DOWNLOAD"; then
      rm -f "$SPARKLE_DOWNLOAD"
      exit 1
    fi
    mv "$SPARKLE_DOWNLOAD" "$SPARKLE_TARBALL"
  fi
  SPARKLE_TOOLS_DIR="$(mktemp -d)"
  trap 'rm -rf "$SPARKLE_TOOLS_DIR"' EXIT
  cp "$SPARKLE_TARBALL" "$SPARKLE_TOOLS_DIR/Sparkle.tar.xz"
  verify_sparkle_tarball "$SPARKLE_TOOLS_DIR/Sparkle.tar.xz"
  mkdir "$SPARKLE_TOOLS_DIR/tools"
  tar -xf "$SPARKLE_TOOLS_DIR/Sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR/tools"
  GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/tools/bin/generate_appcast"
  if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "ERROR: generate_appcast not found in the Sparkle ${SPARKLE_VERSION} tarball" >&2
    exit 1
  fi
fi

DERIVED_DATA="$ROOT/build/DerivedData"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/Spotiglass.app"
ARCHIVES_DIR="$ROOT/docs/sparkle-archives"
DMG_DIR="$ROOT/build/release"
ZIP_NAME="Spotiglass-${MARKETING_VERSION}.zip"
DMG_NAME="Spotiglass-${MARKETING_VERSION}.dmg"
DOWNLOAD_PREFIX="https://github.com/isaaclins/spotiglass/releases/download/${TAG}/"

echo "==> Building Release ${MARKETING_VERSION} (${BUILD_NUMBER})"
xcodebuild \
  -project Spotiglass.xcodeproj \
  -scheme Spotiglass \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  clean build

echo "==> Building SpotiglassEQDriver"
(
  cd "$ROOT/SpotiglassEQDriver"
  DRIVER_MARKETING_VERSION="$MARKETING_VERSION" \
    DRIVER_BUILD_VERSION="$BUILD_NUMBER" \
    bash build-driver.sh
)

# Embed the driver before signing anything. Signing a bundle seals its contents,
# so every nested item has to be in place first, otherwise adding the driver
# afterwards invalidates the app signature.
DRIVER_DST="$APP_SOURCE/Contents/Library/Audio/Plug-Ins/HAL"
echo "==> Embedding driver into $DRIVER_DST"
mkdir -p "$DRIVER_DST"
rm -rf "$DRIVER_DST/SpotiglassEQDriver.driver"
cp -pR "$ROOT/build/SpotiglassEQDriver.driver" "$DRIVER_DST/"

# Developer ID Application is the only certificate class Gatekeeper accepts for
# software distributed outside the App Store, and the only one Apple will
# notarize. This script previously signed with Apple Development, which is a
# local development certificate. That produced a real TeamIdentifier, so a
# release looked signed, but it cannot be notarized and Gatekeeper rejects it on
# every Mac except one that already trusts that development certificate. That is
# why users saw "unidentified developer" on a build that appeared to be signed.
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'\"' '/Developer ID Application/ { print $2; exit }')}"
NOTARY_PROFILE="${NOTARY_PROFILE:-spotiglass}"
ALLOW_UNSIGNED_RELEASE="${ALLOW_UNSIGNED_RELEASE:-0}"
ALLOW_UNNOTARIZED_RELEASE="${ALLOW_UNNOTARIZED_RELEASE:-0}"

if [[ -z "$DEVELOPER_ID_IDENTITY" ]]; then
  if [[ "$ALLOW_UNSIGNED_RELEASE" == "1" ]]; then
    echo "WARNING: No Developer ID Application certificate found, and ALLOW_UNSIGNED_RELEASE=1." >&2
    echo "WARNING: The resulting build is ad-hoc signed. It will NOT pass Gatekeeper on other Macs." >&2
    echo "WARNING: Use this only for local testing, never to publish a release." >&2
  else
    echo "ERROR: No 'Developer ID Application' certificate in the keychain." >&2
    echo "       A release must be signed with Developer ID so Gatekeeper accepts it elsewhere." >&2
    echo "       Install one from https://developer.apple.com/account/resources/certificates" >&2
    echo "       Contributors who only need a local build can set ALLOW_UNSIGNED_RELEASE=1." >&2
    exit 1
  fi
fi

# Sign one bundle with the hardened runtime and a secure timestamp, both of which
# notarization requires.
#
# --deep is deliberately not used. It is deprecated, and it applies the same
# identity and entitlements to nested code that may need different ones, which is
# a common cause of notarization rejections. Every nested bundle is signed
# explicitly below, deepest first, because signing a container seals whatever is
# inside it at that moment.
sign_bundle() {
  local target="$1"
  shift
  [[ -e "$target" ]] || return 0
  echo "    signing $(basename "$target")"
  codesign --force --sign "$DEVELOPER_ID_IDENTITY" --options runtime --timestamp "$@" "$target"
}

if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  echo "==> Signing with $DEVELOPER_ID_IDENTITY"
  SPARKLE_FRAMEWORK="$APP_SOURCE/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSIONS="$SPARKLE_FRAMEWORK/Versions/B"

  # Deepest first: the XPC services and the updater app live inside the
  # framework, so they must be sealed before the framework is signed.
  sign_bundle "$SPARKLE_VERSIONS/XPCServices/Downloader.xpc"
  sign_bundle "$SPARKLE_VERSIONS/XPCServices/Installer.xpc"
  sign_bundle "$SPARKLE_VERSIONS/Autoupdate"
  sign_bundle "$SPARKLE_VERSIONS/Updater.app"
  sign_bundle "$SPARKLE_FRAMEWORK"

  # The privileged helper is launched by system launchd rather than by the
  # app, so it needs its own hardened-runtime signature before the app seals
  # the nested executable.
  sign_bundle "$APP_SOURCE/Contents/Library/PrivilegedHelperTools/SpotiglassEQPrivilegedHelper"

  # The audio driver is loaded by coreaudiod rather than by the app, so it is
  # signed as its own bundle. The hardened runtime is required for notarization;
  # verify audio still works on a signed build before publishing.
  sign_bundle "$DRIVER_DST/SpotiglassEQDriver.driver"

  # The app last, with its entitlements, so it seals everything above.
  sign_bundle "$APP_SOURCE" --entitlements "$ROOT/Spotiglass/Spotiglass.entitlements"

  echo "==> Verifying signature"
  codesign --verify --strict --verbose=2 "$APP_SOURCE"

  APP_TEAM=$(codesign -dv "$APP_SOURCE" 2>&1 | awk -F= '/TeamIdentifier/ { print $2 }')
  APP_SIGNATURE=$(codesign -dv "$APP_SOURCE" 2>&1 | awk -F= '/Signature/ { print $2 }')
  if [[ "$APP_SIGNATURE" == "adhoc" || -z "$APP_TEAM" || "$APP_TEAM" == "not set" ]]; then
    echo "ERROR: App is not Developer ID signed (Signature=$APP_SIGNATURE TeamIdentifier=$APP_TEAM)." >&2
    exit 1
  fi
  echo "==> Signed as team $APP_TEAM"
fi

mkdir -p "$ARCHIVES_DIR"
ZIP_PATH="$ARCHIVES_DIR/$ZIP_NAME"

# Notarization: upload the signed app, wait for Apple's verdict, then staple the
# resulting ticket into the bundle so Gatekeeper can verify it without network
# access. The archive is rebuilt from the stapled app afterwards, because a zip
# made before stapling does not contain the ticket.
NOTARIZED=0
if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE_DIR="$(mktemp -d)"
    NOTARIZE_ZIP="$NOTARIZE_DIR/Spotiglass-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_SOURCE" "$NOTARIZE_ZIP"

    echo "==> Submitting to Apple for notarization (this can take several minutes)"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP_SOURCE"
    xcrun stapler validate "$APP_SOURCE"
    rm -rf "$NOTARIZE_DIR"
    NOTARIZED=1

    # The real question is not whether the signature is valid but whether
    # Gatekeeper will run it. An app is executable code, so assess it with the
    # execute policy rather than the installer-package policy.
    echo "==> Gatekeeper assessment"
    spctl --assess --verbose=4 --type execute "$APP_SOURCE"
  elif [[ "$ALLOW_UNNOTARIZED_RELEASE" == "1" ]]; then
    echo "WARNING: No notarytool keychain profile named '$NOTARY_PROFILE'." >&2
    echo "WARNING: ALLOW_UNNOTARIZED_RELEASE=1 permits a signed but unnotarized local artifact." >&2
    echo "WARNING: Gatekeeper will warn users. Never publish this artifact." >&2
  else
    echo "ERROR: No notarytool keychain profile named '$NOTARY_PROFILE'." >&2
    echo "       A published release must be notarized so Gatekeeper accepts it." >&2
    echo "       Create the profile with:" >&2
    echo "       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <team> --password <app-specific-password>" >&2
    echo "       For local signing tests only, set ALLOW_UNNOTARIZED_RELEASE=1." >&2
    exit 1
  fi
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_SOURCE" "$ZIP_PATH"

mkdir -p "$DMG_DIR"
DMG_PATH="$DMG_DIR/$DMG_NAME"
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_SOURCE" "$DMG_STAGE/Spotiglass.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Spotiglass ${MARKETING_VERSION}" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGE"

# The disk image is a separate distributed artifact, so it carries its own
# signature and ticket. Without this a user who downloads the .dmg rather than
# the .zip still sees a Gatekeeper warning on the image itself.
if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG_PATH"
  if [[ "$NOTARIZED" == "1" ]]; then
    echo "==> Notarizing disk image"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG_PATH"
  fi
fi

if [[ -n "$RELEASE_NOTES" ]]; then
  # generate_appcast recognizes matching .txt and .html files, not Markdown.
  # Keep the source notes as Markdown in docs/release-notes, and give Sparkle a
  # plain-text copy so the update window embeds the release notes.
  cp "$RELEASE_NOTES" "$ARCHIVES_DIR/Spotiglass-${MARKETING_VERSION}.txt"
fi

# Keep the argument array non-empty. macOS still ships Bash 3.2, where
# expanding an empty array under `set -u` aborts with "unbound variable". The
# key-file override is optional because generate_appcast can read its standard
# ed25519 item from the login keychain.
APPCAST_ARGS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --embed-release-notes
)
if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}" && -f "$SPARKLE_EDDSA_PRIVATE_KEY_FILE" ]]; then
  APPCAST_ARGS+=(--ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_FILE")
elif [[ -f "$ROOT/scripts/sparkle_eddsa_private.key" ]]; then
  APPCAST_ARGS+=(--ed-key-file "$ROOT/scripts/sparkle_eddsa_private.key")
fi

echo "==> Generating appcast (docs/appcast.xml)"
# Generated to a temp file, rewritten, checked, and only then moved into place,
# so a failure never leaves a half-corrected feed in the tracked file.
# generate_appcast treats an existing output file as an appcast to update. A
# plain mktemp creates an empty file, which Sparkle then tries to parse as XML
# and rejects as "zero length data". Give it a path that does not exist yet.
APPCAST_TMP_DIR="$(mktemp -d)"
APPCAST_TMP="$APPCAST_TMP_DIR/appcast.xml"
trap 'rm -rf "$APPCAST_TMP_DIR" ${SPARKLE_TOOLS_DIR:+"$SPARKLE_TOOLS_DIR"}' EXIT

"$GENERATE_APPCAST" \
  "${APPCAST_ARGS[@]}" \
  -o "$APPCAST_TMP" \
  "$ARCHIVES_DIR"

rewrite_appcast_download_urls "$APPCAST_TMP"
mv "$APPCAST_TMP" "$ROOT/docs/appcast.xml"
rm -rf "$APPCAST_TMP_DIR"
if [[ -n "$SPARKLE_TOOLS_DIR" ]]; then
  rm -rf "$SPARKLE_TOOLS_DIR"
fi
trap - EXIT
echo "==> Wrote docs/appcast.xml"

# Deliberately last: everything above can fail (clean build, driver signing, the
# codesign identity and TeamIdentifier checks, hdiutil, fetching the Sparkle
# tools), and this is the only step that writes to a tracked file. Mutating the
# project file earlier meant a transient failure left the new build number
# recorded, so re-running the same command was refused by the guard and the
# undocumented recovery was `git checkout -- Spotiglass.xcodeproj/project.pbxproj`.
update_project_versions

echo ""
echo "Next steps:"
echo "  1. Create GitHub Release ${TAG} and upload:"
echo "       ${DMG_PATH}"
echo "       ${ZIP_PATH}"
echo "       (and any ${ARCHIVES_DIR}/*.delta files if present)"
echo "  2. Commit docs/appcast.xml (and release notes) to main for GitHub Pages."
echo "  3. Ensure repo Pages uses branch main, folder /docs."
echo ""
echo "  gh release create ${TAG} \"${DMG_PATH}\" \"${ZIP_PATH}\" --title \"Spotiglass ${MARKETING_VERSION}\""
