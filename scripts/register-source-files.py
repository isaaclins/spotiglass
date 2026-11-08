#!/usr/bin/env python3
"""
Register main-target Swift files in Spotiglass.xcodeproj/project.pbxproj.

Usage:
    python3 scripts/register-source-files.py GROUP_ANCHOR file1.swift file2.swift ...

GROUP_ANCHOR is the basename of a file already in the Xcode group the new
files belong to. The new files go into that group's folder. For each file the
script adds a file reference to the group and a build-file entry to the
Spotiglass target's Sources phase.

- A file the target already compiles is skipped, so running it twice changes
  nothing.
- Object IDs are derived from the file's path, so two branches adding
  different files never collide on merge.
- If the anchor or any insertion point is missing, nothing is written.
"""
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pbxproj  # noqa: E402


def anchor_dir(anchor_name):
    project = pbxproj.Project.load()
    matches = sorted({
        str(PurePosixPath(path).parent)
        for oid, path in project.path_of.items()
        if project.objects[oid].get('isa') == 'PBXFileReference'
        and PurePosixPath(path).name == anchor_name
        and path.startswith('Spotiglass/')
    })
    if len(matches) != 1:
        found = ', '.join(matches) or 'none'
        raise pbxproj.PBXError(f"anchor {anchor_name} must match exactly one file under Spotiglass/ (found: {found})")
    return matches[0]


def main():
    if len(sys.argv) < 3:
        print("usage: register-source-files.py GROUP_ANCHOR file1.swift [file2.swift ...]")
        sys.exit(2)
    try:
        directory = anchor_dir(sys.argv[1])
        paths = [f"{directory}/{Path(f).name}" for f in sys.argv[2:]]
        pbxproj.register_files(paths, 'Spotiglass')
    except pbxproj.PBXError as e:
        sys.exit(f"error: {e}; nothing written")


if __name__ == "__main__":
    main()
