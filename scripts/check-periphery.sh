#!/usr/bin/env bash
# Runs the dead-code detector and fails only on findings that are not already
# in the baseline.
#
# `make scan` has existed for a long time and CI never ran it, so four dead
# declarations were eventually found by hand instead (#107, #105). Turning it on
# strict from day one would fail every build on a pre-existing backlog and get
# switched off again, so this gates on new findings and leaves the existing ones
# recorded in scripts/periphery-baseline.json to be worked down.
#
# Regenerate the baseline after deliberately removing findings:
#   ./scripts/check-periphery.sh --update-baseline
set -euo pipefail

PROJECT="Spotiglass.xcodeproj"
SCHEME="Spotiglass"
BASELINE="scripts/periphery-baseline.json"
UPDATE=0
[[ "${1:-}" == "--update-baseline" ]] && UPDATE=1

if ! command -v periphery >/dev/null 2>&1; then
  echo "error: periphery is not installed (brew install peripheryapp/periphery/periphery)" >&2
  exit 2
fi

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT
periphery scan --project "$PROJECT" --schemes "$SCHEME" --targets "$SCHEME" --format json > "$raw"

python3 - "$raw" "$BASELINE" "$UPDATE" <<'PY'
import json, os, sys

raw_path, baseline_path, update = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
root = os.getcwd() + "/"

def identity(finding):
    """File, kind and name. Line numbers move with every unrelated edit, so
    including them would make the baseline expire on contact."""
    location = finding.get("location", "")
    return {
        "file": location.split(":")[0].replace(root, ""),
        "kind": finding.get("kind", ""),
        "name": finding.get("name", ""),
        "hints": sorted(finding.get("hints", [])),
    }

current = sorted(
    (identity(f) for f in json.load(open(raw_path))),
    key=lambda r: (r["file"], r["kind"], r["name"]),
)

if update:
    with open(baseline_path, "w") as handle:
        json.dump(current, handle, indent=2)
        handle.write("\n")
    print(f"baseline updated: {len(current)} findings")
    raise SystemExit(0)

baseline = json.load(open(baseline_path)) if os.path.exists(baseline_path) else []
def key(record):
    return (record["file"], record["kind"], record["name"])

baseline_keys = {key(r) for r in baseline}
current_keys = {key(r) for r in current}

new = [r for r in current if key(r) not in baseline_keys]
fixed = [r for r in baseline if key(r) not in current_keys]

print("Spotiglass dead-code scan")
print("=========================")
print(f"baseline: {len(baseline)}  current: {len(current)}")

if fixed:
    print(f"\n{len(fixed)} baseline findings are gone. Thank you; refresh the baseline with:")
    print("    ./scripts/check-periphery.sh --update-baseline")
    for record in fixed[:10]:
        print(f"    - {record['file']}: {record['kind']} {record['name']}")

if not new:
    print("\n\u2713 0 new findings")
    raise SystemExit(0)

print(f"\n\u2717 {len(new)} new findings:")
for record in new:
    hints = ", ".join(record["hints"]) or "unused"
    print(f"    {record['file']}: {record['kind']} {record['name']} ({hints})")
print("\nRemove the declaration, or wire it up. If it is genuinely needed and")
print("unreferenced (protocol conformance, KVO), refresh the baseline.")
raise SystemExit(1)
PY
