#!/usr/bin/env python3
"""
Register SpotiglassTests files in Spotiglass.xcodeproj/project.pbxproj.

Usage: python3 scripts/register-test-files.py FooTests.swift Views/BarTests.swift ...

Each path is relative to SpotiglassTests/. For each file the script adds a
file reference to the Xcode group of its folder (or, when that folder has no
group, to the nearest parent group, with the relative path on the reference)
and a build-file entry to the SpotiglassTests target's Sources phase.

- A file the target already compiles is skipped, so running it twice changes
  nothing.
- Object IDs are derived from the file's path, so two branches adding
  different files never collide on merge.
- If any insertion point is missing, nothing is written.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pbxproj  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print("usage: register-test-files.py FooTests.swift [Views/BarTests.swift ...]")
        sys.exit(2)
    paths = [f"SpotiglassTests/{p}" for p in sys.argv[1:]]
    try:
        pbxproj.register_files(paths, 'SpotiglassTests')
    except pbxproj.PBXError as e:
        sys.exit(f"error: {e}; nothing written")


if __name__ == "__main__":
    main()
