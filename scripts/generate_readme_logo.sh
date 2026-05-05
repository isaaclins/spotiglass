#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/build/DerivedData/Build/Products/Release/Spotiglass.app"
ICON_PATH="${APP_PATH}/Contents/Resources/AppIcon.icns"
OUTPUT_PATH="${ROOT_DIR}/assets/readme/logo.png"

print_usage() {
  cat <<'EOF'
Usage: scripts/generate_readme_logo.sh [--rebuild] [--output <path>]

Generates a README-ready PNG logo from Spotiglass.app's AppIcon.icns.

Options:
  --rebuild        Force a fresh unsigned Release build before export
  --output <path>  Override output file path (default: assets/readme/logo.png)
  -h, --help       Show this help
EOF
}

force_rebuild=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      force_rebuild=1
      shift
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      if [[ -z "${OUTPUT_PATH}" ]]; then
        echo "error: --output requires a path argument" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ "${force_rebuild}" -eq 1 || ! -f "${ICON_PATH}" ]]; then
  echo "Building unsigned Release app to refresh AppIcon.icns..."
  xcodebuild \
    -project "${ROOT_DIR}/Spotiglass.xcodeproj" \
    -scheme "Spotiglass" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${ROOT_DIR}/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null
fi

if [[ ! -f "${ICON_PATH}" ]]; then
  echo "error: App icon not found at ${ICON_PATH}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

iconset_dir="${tmp_dir}/AppIcon.iconset"
iconutil -c iconset "${ICON_PATH}" -o "${iconset_dir}"

source_png=""
for candidate in \
  "icon_512x512@2x.png" \
  "icon_512x512.png" \
  "icon_256x256@2x.png" \
  "icon_256x256.png" \
  "icon_128x128@2x.png" \
  "icon_128x128.png"; do
  if [[ -f "${iconset_dir}/${candidate}" ]]; then
    source_png="${iconset_dir}/${candidate}"
    break
  fi
done

if [[ -z "${source_png}" ]]; then
  echo "error: no usable PNG rendered from ${ICON_PATH}" >&2
  exit 1
fi

sips -s format png "${source_png}" --out "${OUTPUT_PATH}" >/dev/null
echo "Wrote README logo: ${OUTPUT_PATH}"
