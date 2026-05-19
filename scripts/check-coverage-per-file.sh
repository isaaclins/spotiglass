#!/usr/bin/env bash
# Check per-file region coverage for Spotiglass.app sources.
# Usage: ./scripts/check-coverage-per-file.sh [path/to/cov.xcresult]
# Env: COVERAGE_THRESHOLD (default 80), COVERAGE_ALLOWLIST (default scripts/coverage-allowlist.json)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE="${1:-build/cov.xcresult}"
THRESHOLD="${COVERAGE_THRESHOLD:-80}"
ALLOWLIST="${COVERAGE_ALLOWLIST:-scripts/coverage-allowlist.json}"

if [[ ! -d "$BUNDLE" ]]; then
  echo "✗ Missing result bundle: $BUNDLE (run ./scripts/coverage.sh first)" >&2
  exit 1
fi

JSON="$(mktemp)"
trap 'rm -f "$JSON"' EXIT
xcrun xccov view --report --json "$BUNDLE" > "$JSON"

python3 - "$JSON" "$THRESHOLD" "$ALLOWLIST" <<'PY'
import json
import sys
from pathlib import Path

bundle_json = Path(sys.argv[1])
threshold = float(sys.argv[2])
allowlist_path = Path(sys.argv[3])

data = json.loads(bundle_json.read_text())
allowlist: set[str] = set()
if allowlist_path.is_file():
    raw = json.loads(allowlist_path.read_text())
    if isinstance(raw, list):
        allowlist = set(raw)
    elif isinstance(raw, dict) and "files" in raw:
        allowlist = set(raw["files"])

app_target = None
for target in data.get("targets", []):
    name = target.get("name", "")
    if name.endswith("Spotiglass.app") or name == "Spotiglass.app":
        app_target = target
        break
if app_target is None:
    for target in data.get("targets", []):
        if "Spotiglass" in target.get("name", "") and "Tests" not in target.get("name", ""):
            app_target = target
            break

if app_target is None:
    print("✗ Could not find Spotiglass app target in coverage JSON", file=sys.stderr)
    sys.exit(2)

files = app_target.get("files", [])
checked = 0
passing = 0
failures: list[tuple[str, float]] = []
skipped_allowlist = 0

for entry in files:
    path = entry.get("path", "")
    if "/Spotiglass/" not in path or not path.endswith(".swift"):
        continue
    if "SpotiglassTests" in path:
        continue
    basename = Path(path).name
    if basename == "SpotiglassApp.swift":
        continue

    rel = path.split("/Spotiglass/", 1)[-1]
    rel_key = f"Spotiglass/{rel}"

    line_cov = entry.get("lineCoverage")
    if line_cov is None:
        covered = entry.get("coveredLines", 0)
        total = entry.get("executableLines", 0)
        pct = (100.0 * covered / total) if total else 100.0
    else:
        pct = float(line_cov) * 100.0

    if rel_key in allowlist or rel in allowlist or basename in allowlist:
        skipped_allowlist += 1
        continue

    checked += 1
    if pct + 1e-9 >= threshold:
        passing += 1
    else:
        failures.append((rel_key, pct))

failures.sort(key=lambda x: x[1])

print(f"FILES_AT_THRESHOLD={passing}")
print(f"FILES_CHECKED={checked}")
print(f"FILES_BELOW={len(failures)}")
print(f"FILES_ALLOWLISTED={skipped_allowlist}")
print(f"THRESHOLD={threshold}")

if failures:
    print("\nBelow threshold:")
    for path, pct in failures[:40]:
        print(f"  {pct:5.1f}%  {path}")
    if len(failures) > 40:
        print(f"  … and {len(failures) - 40} more")

sys.exit(0 if len(failures) == 0 else 1)
PY
