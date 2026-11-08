#!/usr/bin/env bash
# Replays #383: `make clean` used to delete DerivedData and then every
# Keychain item for the Spotify login, so cleaning build output signed you out.
#
# Runs the real Makefile targets with a fake `security` first on PATH. The fake
# pretends two refresh tokens are stored and logs every call, so the test sees
# exactly what each target would have done to the Keychain without touching it.
# DERIVED_DATA points at a temp folder so the real build output is left alone.
#
# Needs only bash and make, so it runs on Linux too.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/security" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_SECURITY_LOG"
if [[ "${1:-}" == "delete-generic-password" ]]; then
  left="$(cat "$FAKE_SECURITY_ITEMS")"
  if (( left > 0 )); then
    echo $((left - 1)) >"$FAKE_SECURITY_ITEMS"
    exit 0
  fi
  exit 44 # errSecItemNotFound, what the real tool returns once nothing is left
fi
exit 1
FAKE
chmod +x "$work/bin/security"

export FAKE_SECURITY_LOG="$work/security.log"
export FAKE_SECURITY_ITEMS="$work/items"
export PATH="$work/bin:$PATH"

fail=0
reset() {
  : >"$FAKE_SECURITY_LOG"
  echo 2 >"$FAKE_SECURITY_ITEMS"
  mkdir -p "$work/DerivedData/Build"
  touch "$work/DerivedData/Build/stale.o"
}
run_make() {
  make -s -C "$repo" "$1" DERIVED_DATA="$work/DerivedData" >/dev/null
}

# make clean: build output gone, login untouched.
reset
run_make clean
if [[ -e "$work/DerivedData" ]]; then
  echo "FAIL: make clean left DerivedData behind" >&2
  fail=1
fi
if grep -q '^delete-generic-password' "$FAKE_SECURITY_LOG"; then
  echo "FAIL: make clean deleted Keychain items (signs you out of Spotify):" >&2
  grep '^delete-generic-password' "$FAKE_SECURITY_LOG" >&2
  fail=1
fi
if [[ "$(cat "$FAKE_SECURITY_ITEMS")" != 2 ]]; then
  echo "FAIL: make clean changed the stored login" >&2
  fail=1
fi

# make sign-out: every stored login item gone, build output untouched.
reset
run_make sign-out
if [[ "$(cat "$FAKE_SECURITY_ITEMS")" != 0 ]]; then
  echo "FAIL: make sign-out left $(cat "$FAKE_SECURITY_ITEMS") login item(s) in the Keychain" >&2
  fail=1
fi
service="$(awk -F':= ' '/^KEYCHAIN_SERVICE/ { print $2 }' "$repo/Makefile")"
if grep '^delete-generic-password' "$FAKE_SECURITY_LOG" | grep -qv -- "-s $service\$"; then
  echo "FAIL: make sign-out deleted something other than service $service:" >&2
  cat "$FAKE_SECURITY_LOG" >&2
  fail=1
fi
if [[ ! -e "$work/DerivedData/Build/stale.o" ]]; then
  echo "FAIL: make sign-out removed build output" >&2
  fail=1
fi

if (( fail )); then
  exit 1
fi
echo "OK: make clean keeps the Spotify login; make sign-out removes it"
