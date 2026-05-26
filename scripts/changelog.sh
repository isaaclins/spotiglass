#!/usr/bin/env bash
# Generate CHANGELOG.md from git history since the latest tag.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: changelog.sh [OPTIONS] [REPO_ROOT]

  REPO_ROOT   Path to git repo (default: .)

Options:
  -o, --output FILE   Write changelog to FILE (default: CHANGELOG.md in repo root)
  -h, --help          Show this help
EOF
}

REPO_ROOT="."
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -o|--output)
      OUTPUT="${2:?--output requires a path}"
      shift 2
      ;;
    -*)
      echo "changelog.sh: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      REPO_ROOT="$1"
      shift
      ;;
  esac
done

cd "$REPO_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "changelog.sh: not a git repository: $REPO_ROOT" >&2
  exit 1
fi

PYTHON=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 0) else 1)' 2>/dev/null; then
  PYTHON=python
else
  echo "changelog.sh: python3 (or python 3.x) is required but not found in PATH" >&2
  exit 1
fi

"$PYTHON" - "$REPO_ROOT" "${OUTPUT:-}" <<'PY'
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
output_override = sys.argv[2].strip() if len(sys.argv) > 2 else ""
latest_tag = ""
try:
    latest_tag = subprocess.check_output(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=root,
        text=True,
    ).strip()
except subprocess.CalledProcessError:
    pass

if latest_tag:
    rev_range = f"{latest_tag}..HEAD"
    version = latest_tag.lstrip("v")
    range_label = rev_range
else:
    rev_range = ""
    version = "Unreleased"
    range_label = "all commits"

log_cmd = ["git", "log", "--pretty=format:%s"]
if rev_range:
    log_cmd.insert(2, rev_range)

log = subprocess.check_output(log_cmd, cwd=root, text=True)
subjects = [line for line in log.splitlines() if line.strip()]

buckets = {
    "Added": [],
    "Fixed": [],
    "Changed": [],
    "Removed": [],
    "Security": [],
    "Other": [],
}


def parse_commit(subject: str):
    m = re.match(r"^([a-z]+)(!)?[:(]", subject.lower())
    if not m:
        return None, False
    return m.group(1), m.group(2) == "!"


def bucket_for(subject: str) -> str:
    t, breaking = parse_commit(subject)
    if not t:
        return "Other"
    if breaking:
        return "Changed"
    if t == "feat":
        return "Added"
    if t == "fix":
        return "Fixed"
    if t in ("chore", "refactor", "perf", "style", "build", "ci", "docs", "test"):
        return "Changed"
    if t in ("remove", "revert"):
        return "Removed"
    if t == "security":
        return "Security"
    return "Other"


for subject in subjects:
    buckets[bucket_for(subject)].append(subject)

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
lines = ["# Changelog", "", f"## [{version}] - {today}", ""]
for title, items in buckets.items():
    if not items:
        continue
    lines.append(f"### {title}")
    lines.append("")
    lines.extend(f"- {item}" for item in items)
    lines.append("")

out = Path(output_override) if output_override else root / "CHANGELOG.md"
out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print(f"Wrote {out} ({len(lines)} lines, range: {range_label})")
PY
