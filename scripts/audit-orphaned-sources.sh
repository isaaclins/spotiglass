#!/usr/bin/env bash
# Reports Swift files that their Xcode target does not compile.
#
# Periphery cannot see these by definition: a file no target compiles is
# not part of anything it analyzes. That blind spot has already shipped twice.
# Two test files, SpotiglassDesignSystemTests.swift and
# SpotiglassComponentsViewTests.swift, sat in the repo without ever compiling
# or running, and one of them had stopped compiling entirely against symbols
# that no longer exist. A test file that is not compiled is worse than no test
# file, because it reads as coverage while providing none (#107).
#
# Finding the file name somewhere in project.pbxproj is not enough: a file
# can sit in a group with a file reference and still be missing from the
# target's Sources phase, and then it never compiles either (#384). So this
# parses the project and requires, for every file under Spotiglass/ and
# SpotiglassTests/, a build-file entry in that target's Sources phase. It also
# fails on a file registered twice.
#
# Standard-library Python only, so it needs no toolchain and runs on Linux.
set -euo pipefail

if [[ ! -f "Spotiglass.xcodeproj/project.pbxproj" ]]; then
  echo "error: Spotiglass.xcodeproj/project.pbxproj not found; run from the repository root" >&2
  exit 2
fi

exec python3 -I - "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pbxproj

problems = pbxproj.audit('.')
print("Spotiglass orphaned-source audit")
print("================================")
if not problems:
    print("✓ every Swift file is compiled by its target exactly once")
    sys.exit(0)
print(f"✗ {len(problems)} problems in Spotiglass.xcodeproj/project.pbxproj:")
for path, problem in problems:
    print(f"    {path}: {problem}")
print()
print("A file its target does not compile never runs. Register it with")
print("scripts/register-test-files.py or scripts/register-source-files.py, or delete it.")
sys.exit(1)
PY
