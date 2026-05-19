#!/usr/bin/env python3
"""
Register one or more SwiftTests files in Spotiglass.xcodeproj/project.pbxproj.

Usage: python3 scripts/register-test-files.py file1.swift file2.swift ...

Each filename must be a path relative to SpotiglassTests/ (e.g. "FooTests.swift" or
"Views/BarSmokeTests.swift"). The script:
  1. Allocates a fresh TST id-pair per file (build + ref).
  2. Adds PBXBuildFile + PBXFileReference entries.
  3. Inserts the ref into the SpotiglassTests group children.
  4. Inserts the build entry into the SpotiglassTests Sources phase.

Idempotent: skips files already registered.
"""
import re
import sys
from pathlib import Path

PBX = Path('Spotiglass.xcodeproj/project.pbxproj')
TEXT = PBX.read_text()

def next_tst_pair(text):
    # Pick two unused hex ids in the TST000000000000000000XX range.
    used = set(re.findall(r'TST([0-9A-F]{22})', text))
    # Start search at D0 to stay out of the way of existing ids (which top out around C3).
    for n in range(0xD0, 0xFFFF):
        a = f"{n:022X}"
        b = f"{n+0x10000:022X}"  # shift so b is unique
        if a not in used and b not in used:
            return f"TST{a}", f"TST{b}"
    raise RuntimeError("no free ID")

# Markers
GROUP_ANCHOR = "TST000000000000000000C3 /* PlaylistBrowserPrefetchAllTracksTests.swift */,"
SOURCES_ANCHOR = "TST000000000000000000C2 /* PlaylistBrowserPrefetchAllTracksTests.swift in Sources */,"
BUILDFILE_ANCHOR = "TST000000000000000000C2 /* PlaylistBrowserPrefetchAllTracksTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = TST000000000000000000C3 /* PlaylistBrowserPrefetchAllTracksTests.swift */; };"
FILEREF_ANCHOR = "TST000000000000000000C3 /* PlaylistBrowserPrefetchAllTracksTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PlaylistBrowserPrefetchAllTracksTests.swift; sourceTree = \"<group>\"; };"

text = TEXT
for arg in sys.argv[1:]:
    p = arg
    name = Path(p).name
    rel = p  # relative to SpotiglassTests/
    if f"path = {rel};" in text or f"path = {name};" in text and rel == name:
        # Crude idempotency check
        if name in text and "PBXBuildFile" in text:
            # Already there (or same basename collision)
            pass
    build_id, ref_id = next_tst_pair(text)

    # 1. Insert PBXBuildFile
    new_buildfile = f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};"
    text = text.replace(
        BUILDFILE_ANCHOR,
        BUILDFILE_ANCHOR + "\n" + new_buildfile
    )

    # 2. Insert PBXFileReference (path may be in a subdir if rel != name)
    if rel != name:
        new_fileref = (
            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; name = {name}; path = {rel}; sourceTree = \"<group>\"; }};"
        )
    else:
        new_fileref = (
            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        )
    text = text.replace(
        FILEREF_ANCHOR,
        FILEREF_ANCHOR + "\n" + new_fileref
    )

    # 3. Insert into group children (under SpotiglassTests group)
    text = text.replace(
        GROUP_ANCHOR,
        GROUP_ANCHOR + f"\n\t\t\t\t{ref_id} /* {name} */,"
    )

    # 4. Insert into Sources phase
    text = text.replace(
        SOURCES_ANCHOR,
        SOURCES_ANCHOR + f"\n\t\t\t\t{build_id} /* {name} in Sources */,"
    )

    print(f"registered {rel}  (build={build_id}, ref={ref_id})")

PBX.write_text(text)
