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

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "1")"
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
