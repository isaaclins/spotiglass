#!/usr/bin/env python3
"""
postToolUse hook: after edits to app/test/workflow code, remind the agent to check docs/.
Reads JSON from stdin; prints optional additional_context JSON on stdout. Fail-open.
"""
from __future__ import annotations

import json
import sys

# Paths that imply user-facing or operator-facing docs may need updates.
CODE_MARKERS = (
    "Spotiglass/",
    "SpotiglassTests/",
    ".github/workflows/",
)

# Paths where edits are usually documentation themselves — skip reminder.
SKIP_MARKERS = (
    "docs/",
    ".cursor/rules/",
)


def _extract_paths(payload: object) -> list[str]:
    paths: list[str] = []
    if isinstance(payload, dict):
        for key in ("path", "file_path", "target_file", "old_path", "new_path"):
            v = payload.get(key)
            if isinstance(v, str) and v:
                paths.append(v)
        # Nested tool-specific shapes
        ti = payload.get("tool_input") or payload.get("input") or payload.get("arguments")
        if isinstance(ti, dict):
            paths.extend(_extract_paths(ti))
        elif isinstance(ti, str):
            try:
                nested = json.loads(ti)
                paths.extend(_extract_paths(nested))
            except json.JSONDecodeError:
                pass
    return paths


def should_remind_for_path(path: str) -> bool:
    if not path:
        return False
    p = path.replace("\\", "/")
    if any(m in p for m in SKIP_MARKERS):
        return False
    return any(m in p for m in CODE_MARKERS)


def is_edit_tool(tool: str) -> bool:
    """Only remind after mutations — not after Read/Grep/etc. on source files."""
    if not tool:
        return False
    t = tool.lower()
    if any(ro in t for ro in ("read", "grep", "glob", "list_dir", "semantic", "web_search", "fetch_mcp")):
        return False
    return any(
        e in t
        for e in ("write", "strreplace", "apply_patch", "delete", "patch", "edit", "multiedit")
    )


def main() -> None:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return
        data = json.loads(raw)
    except (json.JSONDecodeError, OSError):
        return

    tool = str(data.get("tool_name") or data.get("tool") or data.get("hook_event_name") or "")
    if not is_edit_tool(tool):
        return

    candidates: list[str] = []
    candidates.extend(_extract_paths(data))
    # Top-level path sometimes present
    for key in ("path", "file_path"):
        v = data.get(key)
        if isinstance(v, str):
            candidates.append(v)

    if not candidates:
        return

    if not any(should_remind_for_path(p) for p in candidates):
        return

    msg = (
        "Documentation: If this change affects setup, build/CI, storage, limits, or "
        "user-visible behavior, update the matching page under docs/ (index: docs/README.md). "
        "Keep root README.md short; put detail in docs/."
    )
    print(json.dumps({"additional_context": msg}), flush=True)


if __name__ == "__main__":
    main()
