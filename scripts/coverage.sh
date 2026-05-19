#!/usr/bin/env bash
# Run the test suite with code coverage enabled and print a per-target summary.
# Result bundle is saved to build/cov.xcresult; full file-level report to build/cov-report.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE="build/cov.xcresult"
REPORT="build/cov-report.txt"
LOG="run.log"

rm -rf "$BUNDLE"
mkdir -p build

echo "→ Running xcodebuild test with -enableCodeCoverage YES…"
xcodebuild test \
  -project Spotiglass.xcodeproj \
  -scheme Spotiglass \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO \
  -enableCodeCoverage YES \
  -resultBundlePath "$BUNDLE" \
  > "$LOG" 2>&1 || {
    echo "✗ xcodebuild failed; tail of $LOG:" >&2
    tail -40 "$LOG" >&2
    exit 1
}

echo
echo "→ Per-target coverage:"
xcrun xccov view --report --only-targets "$BUNDLE"

echo
echo "→ Full file-level report saved to $REPORT"
xcrun xccov view --report "$BUNDLE" > "$REPORT"

# Quick "0% files in app target" summary
echo
echo "→ App-target files at 0% coverage (top 20 by size):"
grep -E "/Spotiglass/.+\.swift" "$REPORT" | grep -vE "/SpotiglassTests/" | awk '/0\.00% \(0\// {print}' | head -20
