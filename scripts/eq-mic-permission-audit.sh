#!/usr/bin/env bash
# scripts/eq-mic-permission-audit.sh — guards Spotiglass against ever
# re-introducing the microphone / audio-recording path that the legacy
# process-tap EQ (deleted from main) required.
#
# Fails the build on any reference to:
#   - NSMicrophoneUsage              (Info.plist key for mic permission)
#   - AVCaptureDevice                (any input capture)
#   - AVAudioEngine.inputNode        (the input scope of AVAudioEngine)
#   - AudioHardwareCreateProcessTap  (CoreAudio process tap)
#   - CATapDescription               (process-tap description type)
#   - kAudioObjectPropertyScopeInput / input-scope CoreAudio
#
# Greps Spotiglass/ (app sources) and SpotiglassTests/ (test target).
# Skips the audit script itself and `docs/equalizer.md`, which intentionally
# names the APIs so reviewers know exactly what's banned.
#
# Wired into `make test` (see Makefile).

set -e

# rg is bundled in modern Xcode CLT and on Homebrew. Fall back to grep if
# someone runs this outside the standard dev env.
if command -v rg >/dev/null; then
  SEARCH() { rg --no-heading --line-number "$1" Spotiglass SpotiglassTests; }
else
  SEARCH() { grep -RIn "$1" Spotiglass SpotiglassTests; }
fi

BANNED_PATTERNS=(
  'NSMicrophoneUsage'
  'AVCaptureDevice'
  'AVAudioEngine.*inputNode'
  '\.inputNode'
  'AudioHardwareCreateProcessTap'
  'CATapDescription'
  'kAudioObjectPropertyScopeInput'
)

EXCLUDE_FILES=(
  'scripts/eq-mic-permission-audit.sh'
  'docs/equalizer.md'
)

violations=0
for pattern in "${BANNED_PATTERNS[@]}"; do
  hits=$(SEARCH "$pattern" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    # Strip out exempted file paths.
    filtered=""
    while IFS= read -r line; do
      keep=1
      for excl in "${EXCLUDE_FILES[@]}"; do
        if [[ "$line" == *"$excl"* ]]; then
          keep=0
          break
        fi
      done
      if (( keep )); then
        filtered+="$line"$'\n'
      fi
    done <<< "$hits"
    filtered=${filtered%$'\n'}
    if [[ -n "$filtered" ]]; then
      echo "FAIL: banned mic / audio-recording API '$pattern' found:"
      printf "%s\n" "$filtered" | sed 's/^/    /'
      violations=$((violations + 1))
    fi
  fi
done

if (( violations > 0 )); then
  echo
  echo "Spotiglass must never request microphone permission. The HAL plugin"
  echo "path uses only OUTPUT-scope CoreAudio; if you genuinely need input,"
  echo "discuss the design before adding any of the above APIs."
  exit 1
fi

echo "OK: 0 banned mic / audio-recording APIs in Spotiglass/SpotiglassTests/"
