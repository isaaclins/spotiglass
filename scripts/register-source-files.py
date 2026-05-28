#!/usr/bin/env python3
"""
Register one or more main-target Swift source files in
Spotiglass.xcodeproj/project.pbxproj.

Usage:
    python3 scripts/register-source-files.py GROUP_ANCHOR file1.swift file2.swift ...

GROUP_ANCHOR is the basename of an existing file already in the same Xcode
group as the new files (used to find both the group children list and the
Sources build phase). The new files MUST already exist on disk at
`Spotiglass/<group_dir>/<filename>` (the script reads the disk layout
implicitly via the anchor's location in the .pbxproj).

The script:
  1. Allocates a fresh hex id-pair per file (uses the SRC* namespace).
  2. Adds PBXBuildFile + PBXFileReference entries.
  3. Inserts the ref into the same group's children as GROUP_ANCHOR.
  4. Inserts the build entry into the Spotiglass target's Sources phase.

Idempotent: skips files whose path already appears as a PBXFileReference.
"""
import re
import sys
from pathlib import Path

PBX = Path('Spotiglass.xcodeproj/project.pbxproj')


def next_src_pair(text):
    used = set(re.findall(r'SRC([0-9A-F]{22})', text))
    for n in range(0x10, 0xFFFF):
        a = f"{n:022X}"
        b = f"{n + 0x80000:022X}"
        if a not in used and b not in used:
            return f"SRC{a}", f"SRC{b}"
    raise RuntimeError("no free ID")


def find_anchor_ids(text, anchor_name):
    """Find the PBXBuildFile id and PBXFileReference id for `anchor_name`."""
    fileref_match = re.search(
        rf'(\w+) /\* {re.escape(anchor_name)} \*/ = \{{isa = PBXFileReference;',
        text,
    )
    buildfile_match = re.search(
        rf'(\w+) /\* {re.escape(anchor_name)} in Sources \*/ = \{{isa = PBXBuildFile;',
        text,
    )
    if not fileref_match or not buildfile_match:
        raise SystemExit(f"could not locate anchor entries for {anchor_name}")
    return buildfile_match.group(1), fileref_match.group(1)


def main():
    if len(sys.argv) < 3:
        print("usage: register-source-files.py GROUP_ANCHOR file1.swift [file2.swift ...]")
        sys.exit(2)
    anchor_name = sys.argv[1]
    files = sys.argv[2:]
    text = PBX.read_text()
    anchor_build_id, anchor_ref_id = find_anchor_ids(text, anchor_name)

    GROUP_ANCHOR_LINE = f"{anchor_ref_id} /* {anchor_name} */,"
    SOURCES_ANCHOR_LINE = f"{anchor_build_id} /* {anchor_name} in Sources */,"
    BUILDFILE_DEF = f"{anchor_build_id} /* {anchor_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {anchor_ref_id} /* {anchor_name} */; }};"
    FILEREF_DEF = f"{anchor_ref_id} /* {anchor_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {anchor_name}; sourceTree = \"<group>\"; }};"

    for f in files:
        name = Path(f).name
        # Idempotency: skip if a PBXFileReference for this filename already exists.
        if re.search(rf'/\* {re.escape(name)} \*/ = \{{isa = PBXFileReference;', text):
            print(f"skip (already registered): {name}")
            continue
        build_id, ref_id = next_src_pair(text)

        # 1) PBXBuildFile
        new_buildfile = f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};"
        text = text.replace(BUILDFILE_DEF, BUILDFILE_DEF + "\n" + new_buildfile)

        # 2) PBXFileReference
        new_fileref = (
            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        )
        text = text.replace(FILEREF_DEF, FILEREF_DEF + "\n" + new_fileref)

        # 3) Group children
        text = text.replace(
            GROUP_ANCHOR_LINE,
            GROUP_ANCHOR_LINE + f"\n\t\t\t\t{ref_id} /* {name} */,",
        )

        # 4) Sources build phase
        text = text.replace(
            SOURCES_ANCHOR_LINE,
            SOURCES_ANCHOR_LINE + f"\n\t\t\t\t{build_id} /* {name} in Sources */,",
        )

        print(f"registered {name}  (build={build_id}, ref={ref_id})")

    PBX.write_text(text)


if __name__ == "__main__":
    main()
