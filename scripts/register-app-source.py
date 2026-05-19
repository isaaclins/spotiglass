#!/usr/bin/env python3
"""Register Swift sources and resources in Spotiglass.xcodeproj/project.pbxproj."""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("Spotiglass.xcodeproj/project.pbxproj")


def next_id(text: str, prefix: str = "PRO") -> str:
    used = set(re.findall(rf"{prefix}([0-9A-F]{{22}})", text))
    for n in range(0xE0, 0xFFFF):
        a = f"{n:022X}"
        if a not in used:
            return f"{prefix}{a}"
    raise RuntimeError("no free ID")


def add_swift(text: str, path: str, group_name: str) -> str:
    name = Path(path).name
    if f"/* {name} */" in text:
        return text
    build_id = next_id(text)
    ref_id = next_id(text)
    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n/* End PBXBuildFile section */",
    )
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
    )
    group_pat = rf"(\w+ /\* {group_name} \*/ = \{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \()"
    text, n = re.subn(group_pat, rf"\1\n\t\t\t\t{ref_id} /* {name} */,", text, count=1)
    if n == 0:
        raise RuntimeError(f"group {group_name} not found")
    text = text.replace(
        "/* End PBXSourcesBuildPhase section */",
        f"\t\t\t\t{build_id} /* {name} in Sources */,\n/* End PBXSourcesBuildPhase section */",
    )
    return text


def add_resource(text: str, path: str) -> str:
    name = Path(path).name
    if f"/* {name} in Resources */" in text:
        return text
    build_id = next_id(text)
    ref_id = next_id(text)
    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n/* End PBXBuildFile section */",
    )
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.html; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
    )
    text, n = re.subn(
        r"(E50000000000000000000066 /\* Playback \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \()",
        rf"\1\n\t\t\t\tPRORESGRP00000000000001 /* Resources */,",
        text,
        count=1,
    )
    if "PRORESGRP00000000000001 /* Resources */" not in text:
        text = text.replace(
            "/* End PBXGroup section */",
            "\t\tPRORESGRP00000000000001 /* Resources */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t"
            + ref_id
            + f" /* {name} */,\n\t\t\t);\n\t\t\tpath = Resources;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n/* End PBXGroup section */",
        )
    else:
        text = text.replace(
            "PRORESGRP00000000000001 /* Resources */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (",
            "PRORESGRP00000000000001 /* Resources */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t"
            + ref_id
            + f" /* {name} */,",
        )
    text = text.replace(
        "J90000000000000000000002 /* AppIcon.icon in Resources */,",
        f"J90000000000000000000002 /* AppIcon.icon in Resources */,\n\t\t\t\t{build_id} /* {name} in Resources */,",
    )
    return text


def add_xcstrings(text: str) -> str:
    name = "Localizable.xcstrings"
    if f"/* {name} */" in text:
        return text
    ref_id = next_id(text)
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = {name}; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
    )
    text = text.replace(
        "A10000000000000000000061 /* Spotiglass */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (",
        "A10000000000000000000061 /* Spotiglass */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t"
        + ref_id
        + f" /* {name} */,",
    )
    return text


def ensure_infrastructure_group(text: str) -> str:
    if "Infrastructure */" in text:
        return text
    group_id = "PROINFGRP00000000000001"
    log_ref = next_id(text)
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{log_ref} /* SpotiglassLog.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SpotiglassLog.swift; sourceTree = \"<group>\"; }};\n/* End PBXFileReference section */",
    )
    text = text.replace(
        "/* End PBXGroup section */",
        f"\t\t{group_id} /* Infrastructure */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{log_ref} /* SpotiglassLog.swift */,\n\t\t\t);\n\t\t\tpath = Infrastructure;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n/* End PBXGroup section */",
    )
    text = text.replace(
        "A10000000000000000000062 /* App */,",
        f"{group_id} /* Infrastructure */,\n\t\t\t\tA10000000000000000000062 /* App */,",
    )
    build_id = next_id(text)
    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_id} /* SpotiglassLog.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {log_ref} /* SpotiglassLog.swift */; }};\n/* End PBXBuildFile section */",
    )
    text = text.replace(
        "/* End PBXSourcesBuildPhase section */",
        f"\t\t\t\t{build_id} /* SpotiglassLog.swift in Sources */,\n/* End PBXSourcesBuildPhase section */",
    )
    return text


def main() -> None:
    text = PBX.read_text()
    text = ensure_infrastructure_group(text)
    text = add_xcstrings(text)
    text = add_resource(text, "Spotiglass/Playback/Resources/SpotifyPlaybackHost.html")
    PBX.write_text(text)
    print("Updated project.pbxproj")


if __name__ == "__main__":
    main()
