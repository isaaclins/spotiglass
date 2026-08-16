#!/usr/bin/env bash
# Reports Swift files that exist on disk but are in no Xcode target.
#
# Periphery cannot see these by definition: a file absent from
# project.pbxproj is not part of any target, so there is nothing for it to
# analyze. That blind spot has already shipped twice. Two test files,
# SpotiglassDesignSystemTests.swift and SpotiglassComponentsViewTests.swift,
# sat in the repo without ever compiling or running, and one of them had
# stopped compiling entirely against symbols that no longer exist. A test file
# that is not in the project is worse than no test file, because it reads as
# coverage while providing none (#107).
#
# Pure text comparison, so it needs no toolchain and runs on Linux.
set -euo pipefail

PROJECT_FILE="Spotiglass.xcodeproj/project.pbxproj"
SEARCH_DIRS=("Spotiglass" "SpotiglassTests")

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "error: $PROJECT_FILE not found; run from the repository root" >&2
  exit 2
fi

orphans=()
while IFS= read -r file; do
  name="$(basename "$file")"
  # Match the quoted or bare path entry rather than the bare word, so a file
  # named after a common token cannot be matched by an unrelated build setting.
  if ! grep -qF -- "$name" "$PROJECT_FILE"; then
    orphans+=("$file")
  fi
done < <(find "${SEARCH_DIRS[@]}" -name '*.swift' -type f | sort)

echo "Spotiglass orphaned-source audit"
echo "================================"
if [[ ${#orphans[@]} -eq 0 ]]; then
  echo "✓ 0 Swift files missing from the Xcode project"
  exit 0
fi

echo "✗ ${#orphans[@]} Swift files are not referenced by $PROJECT_FILE:"
for file in "${orphans[@]}"; do
  echo "    $file"
done
echo
echo "A file in no target never compiles and never runs. Add it to the target,"
echo "or delete it."
exit 1
