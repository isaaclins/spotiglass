#!/usr/bin/env bash
# Regenerate coverage-allowlist.json from a coverage bundle (files still below threshold).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE="${1:-build/cov.xcresult}"
THRESHOLD="${COVERAGE_THRESHOLD:-80}"
OUT="${2:-scripts/coverage-allowlist.json}"

if [[ ! -d "$BUNDLE" ]]; then
  echo "✗ Missing $BUNDLE" >&2
  exit 1
fi

JSON="$(mktemp)"
trap 'rm -f "$JSON"' EXIT
xcrun xccov view --report --json "$BUNDLE" > "$JSON"

python3 - "$JSON" "$THRESHOLD" "$OUT" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
threshold = float(sys.argv[2]) * 0.01 if float(sys.argv[2]) > 1 else float(sys.argv[2]) / 100.0
out = Path(sys.argv[3])

app_target = None
for target in data.get("targets", []):
    if "Spotiglass.app" in target.get("name", "") or target.get("name", "").endswith("Spotiglass"):
        if "Tests" not in target.get("name", ""):
            app_target = target
            break

below: list[str] = []
for entry in app_target.get("files", []) if app_target else []:
    path = entry.get("path", "")
    if "/Spotiglass/" not in path or not path.endswith(".swift"):
        continue
    if path.endswith("SpotiglassApp.swift"):
        continue
    rel = "Spotiglass/" + path.split("/Spotiglass/", 1)[-1]
    cov = entry.get("lineCoverage")
    if cov is None:
        total = entry.get("executableLines", 0) or 1
        cov = entry.get("coveredLines", 0) / total
    if cov + 1e-9 < threshold:
        below.append(rel)

below.sort()
out.write_text(json.dumps({"files": below}, indent=2) + "\n")
print(f"Wrote {len(below)} files below {threshold*100:.0f}% to {out}")
PY
