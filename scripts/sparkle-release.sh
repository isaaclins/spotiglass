#!/usr/bin/env bash
# Package a Release Spotiglass.app for Sparkle + GitHub Releases (local maintainer flow).
# CI mirrors these steps in .github/workflows/release-artifact.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MARKETING_VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
RELEASE_NOTES="${3:-}"

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

# Default to the next build after the one already recorded. Deriving it from the
# project file keeps the sequence contiguous; the previous default of
# `git rev-list --count HEAD` was a commit count in the hundreds, which would be
# accepted, written into the tree, and then permanently raise the floor for every
# future release.
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(( $(read_project_build_number) + 1 ))"
  echo "==> No build number given, using $BUILD_NUMBER (recorded build plus one)"
fi

validate_release_versions
if [[ "${SPARKLE_RELEASE_VALIDATE_ONLY:-0}" == "1" ]]; then
  echo "Validation-only mode: no build or project changes performed."
  exit 0
fi

TAG="v${MARKETING_VERSION}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.7.1}"
SPARKLE_TARBALL="$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}.tar.xz"
GENERATE_APPCAST="${GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" && -x "$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}/bin/generate_appcast" ]]; then
  GENERATE_APPCAST="$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}/bin/generate_appcast"
fi
if [[ -z "$GENERATE_APPCAST" && -x "$ROOT/build/sparkle/bin/generate_appcast" ]]; then
  GENERATE_APPCAST="$ROOT/build/sparkle/bin/generate_appcast"
fi
if [[ -z "$GENERATE_APPCAST" && -x /tmp/sparkle-dl/bin/generate_appcast ]]; then
  GENERATE_APPCAST="/tmp/sparkle-dl/bin/generate_appcast"
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

# Build, re-sign, and embed the SpotiglassEQDriver into the Release .app.
# The standalone build-driver.sh leaves the bundle ad-hoc signed, which
# coreaudiod refuses to load on macOS 26. Re-sign with the local Apple
# Development identity (same one `make sign-driver` uses) so the embedded
# .driver has a real TeamIdentifier when shipped to users.
echo "==> Building SpotiglassEQDriver"
(cd "$ROOT/SpotiglassEQDriver" && bash build-driver.sh)

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  echo "ERROR: No Apple Development identity in keychain: open Xcode -> Settings -> Accounts and sign in, then retry." >&2
  exit 1
fi
echo "==> Re-signing SpotiglassEQDriver with $CODESIGN_IDENTITY"
codesign --force --sign "$CODESIGN_IDENTITY" "$ROOT/build/SpotiglassEQDriver.driver"
DRIVER_TEAM=$(codesign -dv "$ROOT/build/SpotiglassEQDriver.driver" 2>&1 | awk -F= '/TeamIdentifier/ { print $2 }')
if [[ -z "$DRIVER_TEAM" || "$DRIVER_TEAM" == "not set" ]]; then
  echo "ERROR: Driver signature fell back to ad-hoc (TeamIdentifier=$DRIVER_TEAM). Run scripts/setup-eq-driver-signing.sh to trust Apple Root CA, then retry." >&2
  exit 1
fi

DRIVER_DST="$APP_SOURCE/Contents/Library/Audio/Plug-Ins/HAL"
echo "==> Embedding signed driver into $DRIVER_DST"
mkdir -p "$DRIVER_DST"
rm -rf "$DRIVER_DST/SpotiglassEQDriver.driver"
cp -pR "$ROOT/build/SpotiglassEQDriver.driver" "$DRIVER_DST/"

mkdir -p "$ARCHIVES_DIR"
ZIP_PATH="$ARCHIVES_DIR/$ZIP_NAME"
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

if [[ -n "$RELEASE_NOTES" && -f "$RELEASE_NOTES" ]]; then
  cp "$RELEASE_NOTES" "$ARCHIVES_DIR/Spotiglass-${MARKETING_VERSION}.md"
fi

if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "==> Download Sparkle ${SPARKLE_VERSION} tools for generate_appcast"
  mkdir -p "$ROOT/build/sparkle"
  curl -fsSL -o "$SPARKLE_TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xf "$SPARKLE_TARBALL" -C "$ROOT/build/sparkle"
  if [[ -x "$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}/bin/generate_appcast" ]]; then
    GENERATE_APPCAST="$ROOT/build/sparkle/Sparkle-${SPARKLE_VERSION}/bin/generate_appcast"
  else
    GENERATE_APPCAST="$ROOT/build/sparkle/bin/generate_appcast"
  fi
fi

ED_KEY_ARGS=()
if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}" && -f "$SPARKLE_EDDSA_PRIVATE_KEY_FILE" ]]; then
  ED_KEY_ARGS=(--ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_FILE")
elif [[ -f "$ROOT/scripts/sparkle_eddsa_private.key" ]]; then
  ED_KEY_ARGS=(--ed-key-file "$ROOT/scripts/sparkle_eddsa_private.key")
fi

echo "==> Generating appcast (docs/appcast.xml)"
"$GENERATE_APPCAST" \
  "${ED_KEY_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  -o "$ROOT/docs/appcast.xml" \
  "$ARCHIVES_DIR"

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
