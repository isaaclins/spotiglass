#!/usr/bin/env bash
# scripts/audit-localization.sh — verifies Spotiglass's UI is fully localized.
#
# Four checks:
#   1. English-leak scan: greps user-visible SwiftUI/AppKit modifier patterns
#      for hardcoded string literals that aren't routed through SpotiglassL10n.
#   2. Catalog completeness: every key in Localizable.xcstrings has non-empty
#      en/es/de values.
#   3. Referenced-key existence: every key passed to SpotiglassL10n.string,
#      .string(forKey:), or .format in Swift code is present in the catalog.
#   4. Orphaned catalog keys: every catalog key is referenced by Swift source or
#      listed in scripts/localization-orphans.allowlist. The allowlist contains
#      one exact key per line for legitimate runtime-built or generated keys;
#      blank lines and lines beginning with # are ignored.
#
# Orphans fail the audit. This keeps removed strings from accumulating while
# retaining an explicit escape hatch for dynamic lookups.
#
# Exits 0 if all checks pass. Non-zero on any failure, with a brief report.

set -o pipefail

CATALOG="Spotiglass/Localizable.xcstrings"
ORPHAN_ALLOWLIST="scripts/localization-orphans.allowlist"
SOURCE_DIRS=(
  "Spotiglass/App"
  "Spotiglass/Auth"
  "Spotiglass/Browsing"
  "Spotiglass/CommandPalette"
  "Spotiglass/Pinning"
  "Spotiglass/Playback"
  "Spotiglass/Settings"
  "Spotiglass/Views"
)

if ! command -v jq >/dev/null; then
  echo "FAIL: jq is required (brew install jq)" >&2
  exit 2
fi
if ! command -v rg >/dev/null; then
  echo "FAIL: ripgrep (rg) is required (brew install ripgrep)" >&2
  exit 2
fi
if [[ ! -f "$CATALOG" ]]; then
  echo "FAIL: catalog not found at $CATALOG" >&2
  exit 2
fi

leak_count=0
missing_count=0
unknown_key_count=0
orphan_count=0

# ---- 1. English-leak scan ---------------------------------------------------
# Match string literals passed to user-visible modifiers/initializers. Anything
# routed through SpotiglassL10n (or with .string(forKey:) on a constructed key)
# is exempt. We also skip:
#   - SF Symbol names (systemName: "...")
#   - Accessibility identifiers (.accessibilityIdentifier("..."))
#   - Localized-key string literals (the first arg of SpotiglassL10n.string)
#   - Preview / #if DEBUG code paths
#   - Test files (separate target)
#   - The brand name "Spotiglass" by itself (a constant the brand policy keeps
#     identical across locales — but ANY wrapper text around it is checked).
PATTERN='(\bText|\bLabel|\bButton|\bPicker|\bToggle|\bSection|\bTextField|\bLabeledContent|\bnavigationTitle|\.help|\.accessibilityLabel|\.accessibilityHint|toolTip\s*=|CommandMenu|\.searchable\(prompt:|\.confirmationDialog|\.alert|accessibilityDescription:\s*)\(?\s*"[A-Za-z][^"]*"'

leak_hits=$(
  rg --line-number --no-heading -e "$PATTERN" \
     -g '!*Preview*' -g '!*Tests*' "${SOURCE_DIRS[@]}" 2>/dev/null \
  | rg -v 'SpotiglassL10n' \
  | rg -v 'systemName:\s*"' \
  | rg -v 'accessibilityIdentifier' \
  | rg -v '"Spotify"' \
  | rg -v '#Preview' \
  | rg -v '#if DEBUG' \
  || true
)

if [[ -n "$leak_hits" ]]; then
  leak_count=$(printf "%s\n" "$leak_hits" | wc -l | tr -d ' ')
fi

# ---- 2. Catalog completeness ------------------------------------------------
# Every key must have non-empty en/es/de stringUnit.value. xcstrings represents
# "missing" either as (a) no localization for that locale at all, or (b) empty
# value with state "new"/"needs_review".
catalog_report=$(
  jq -r '
    .strings | to_entries[] |
    . as $entry |
    ["en", "es", "de"] |
    map({
      locale: .,
      value: ($entry.value.localizations[.].stringUnit.value // ""),
      state: ($entry.value.localizations[.].stringUnit.state // "missing")
    }) |
    map(select(.value == "" or .state == "missing" or .state == "new" or .state == "needs_review")) |
    if length > 0 then [$entry.key, ([.[] | .locale] | join(","))] else empty end |
    @tsv
  ' "$CATALOG"
)
if [[ -n "$catalog_report" ]]; then
  missing_count=$(printf "%s\n" "$catalog_report" | wc -l | tr -d ' ')
fi

# ---- 3. Referenced-key existence --------------------------------------------
# Collect every key string SpotiglassL10n is asked to resolve and confirm the
# catalog has it. We extract the immediate string-literal argument from each
# call site (so SF Symbol names on the same line don't get mis-treated as
# localization keys). Runtime-built keys like
#   SpotiglassL10n.string(forKey: "palette.command.\(id).title")
# can't be statically resolved, so we expand them manually for each editable
# palette command instead.
keys_in_code=$(
  rg --no-heading --no-line-number --no-filename -o \
    'SpotiglassL10n\.(?:string|format)\(\s*"([^"]+)"' \
    -r '$1' \
    "${SOURCE_DIRS[@]}" 2>/dev/null \
  | sort -u
)
runtime_keys_in_code=$(
  rg --no-heading --no-line-number --no-filename -o \
    'SpotiglassL10n\.string\(\s*forKey:\s*"([^"\\]+)"' \
    -r '$1' \
    "${SOURCE_DIRS[@]}" 2>/dev/null \
  | sort -u
)
catalog_keys=$(jq -r '.strings | keys[]' "$CATALOG" | sort -u)

unknown_literal_keys=$(comm -23 <(echo "$keys_in_code") <(echo "$catalog_keys") | grep -v '^$' || true)
unknown_runtime_keys=$(comm -23 <(echo "$runtime_keys_in_code") <(echo "$catalog_keys") | grep -v '^$' || true)

# Runtime-built palette command keys: only the IDs listed in
# CommandPaletteCommandCatalog.editable actually render a row, so they're the
# only IDs that need title/subtitle entries. (Bash 3.x compatibility: avoid
# associative arrays.)
palette_idents=$(
  rg -o 'commandID:\s*CommandPaletteCommandID\.(\w+)' \
    Spotiglass/CommandPalette/CommandPaletteCommandCatalog.swift \
    --replace='$1' 2>/dev/null | sort -u
)
missing_palette_keys=""
for ident in $palette_idents; do
  raw=$(rg -o "static let ${ident} = \"([^\"]+)\"" \
            Spotiglass/CommandPalette/CommandPaletteModels.swift \
            --replace='$1' 2>/dev/null | head -1)
  [[ -z "$raw" ]] && continue
  for suffix in title subtitle; do
    key="palette.command.${raw}.${suffix}"
    if ! jq -e --arg k "$key" '.strings[$k]' "$CATALOG" >/dev/null; then
      missing_palette_keys+="${key} (palette command runtime key)"$'\n'
    fi
  done
done

unknown_keys=$(printf '%s\n%s\n%s' "$unknown_literal_keys" "$unknown_runtime_keys" "$missing_palette_keys" | grep -v '^$' | sort -u || true)
if [[ -n "$unknown_keys" ]]; then
  unknown_key_count=$(printf "%s\n" "$unknown_keys" | wc -l | tr -d ' ')
fi

# ---- 4. Orphaned catalog keys -----------------------------------------------
# The existing referenced-key check intentionally scans its established source
# directories. For the reverse check, include every app Swift file so helpers
# outside those directories count as references too.
all_api_keys_in_code=$(
  {
    rg --no-heading --no-line-number --no-filename -o \
      'SpotiglassL10n\.(?:string|format)\(\s*"([^"]+)"' \
      -r '$1' \
      Spotiglass --glob '*.swift' 2>/dev/null
    rg --no-heading --no-line-number --no-filename -o \
      'SpotiglassL10n\.string\(\s*forKey:\s*"([^"\\]+)"' \
      -r '$1' \
      Spotiglass --glob '*.swift' 2>/dev/null
  } | sort -u
)

# Swift String Catalog also indexes literal strings and normalizes interpolated
# literals into format-style keys. Count catalog keys that appear literally in
# Swift source here; normalized interpolation keys belong in the allowlist.
source_literal_keys=""
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  if rg --fixed-strings --quiet --glob '*.swift' -- "\"$key\"" Spotiglass 2>/dev/null; then
    source_literal_keys+="${key}"$'\n'
  fi
done <<< "$catalog_keys"

orphan_allowlist=$(
  if [[ -f "$ORPHAN_ALLOWLIST" ]]; then
    sed -e 's/[[:space:]]*#.*$//' \
        -e '/^[[:space:]]*$/d' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        "$ORPHAN_ALLOWLIST" | sort -u
  fi
)

referenced_catalog_keys=$(
  printf '%s\n%s\n%s' "$all_api_keys_in_code" "$source_literal_keys" "$orphan_allowlist" \
    | grep -v '^$' | sort -u || true
)

catalog_key_lines=$(
  rg --line-number --no-heading '^    "[^"]+"[[:space:]]*:' "$CATALOG" \
    | sed -E 's/^([0-9]+):    "([^"]+)"[[:space:]]*:.*/\2\t\1/' \
    | sort -t $'\t' -k1,1
)
orphan_keys=$(comm -23 \
  <(printf '%s\n' "$catalog_keys") \
  <(printf '%s\n' "$referenced_catalog_keys") \
  | grep -v '^$' || true
)

orphan_report=""
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  line=$(printf '%s\n' "$catalog_key_lines" \
    | awk -F '\t' -v key="$key" '$1 == key { print $2; exit }')
  orphan_report+="${key} (catalog line ${line})"$'\n'
done <<< "$orphan_keys"

if [[ -n "$orphan_report" ]]; then
  orphan_count=$(printf "%s" "$orphan_report" | grep -c -v '^$' | tr -d ' ')
fi

# ---- Report -----------------------------------------------------------------
echo "Spotiglass localization audit"
echo "============================="
if (( leak_count == 0 )); then
  echo "✓ 0 English leaks"
else
  echo "✗ $leak_count English leaks:"
  printf "%s\n" "$leak_hits" | sed 's/^/    /'
fi

if (( missing_count == 0 )); then
  echo "✓ 0 missing translations"
else
  echo "✗ $missing_count keys missing en/es/de:"
  printf "%s\n" "$catalog_report" | sed 's/^/    /'
fi

if (( unknown_key_count == 0 )); then
  echo "✓ 0 unknown referenced keys"
else
  echo "✗ $unknown_key_count keys referenced in code but absent from the catalog:"
  printf "%s\n" "$unknown_keys" | sed 's/^/    /'
fi

if (( orphan_count == 0 )); then
  echo "✓ 0 orphaned catalog keys"
else
  echo "✗ $orphan_count orphaned catalog keys:"
  printf "%s" "$orphan_report" | sed 's/^/    /'
fi

if (( leak_count + missing_count + unknown_key_count + orphan_count > 0 )); then
  exit 1
fi
