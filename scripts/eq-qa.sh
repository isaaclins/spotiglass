#!/usr/bin/env bash
# scripts/eq-qa.sh — interactive manual-QA walkthrough for the Spotiglass EQ.
#
# Usage: scripts/eq-qa.sh
#
# Walks the tester through the success-criterion-5 checklist:
#   authorization + install → enable → device-visible → route → toggle each preset →
#   save+reload "MyTest" → delete → disable → default-restored
#
# At each step the script prints a "do X, then press y or n" prompt and
# appends the result + timestamp + a screenshot-prompt to build/qa/manual-qa.log.

set -eu

LOG_DIR="build/qa"
LOG_FILE="$LOG_DIR/manual-qa-$(date +%Y%m%d-%H%M%S).log"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_NAME="SpotiglassEQDriver.driver"

mkdir -p "$LOG_DIR"

log() {
  printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"
}

prompt() {
  local step="$1"
  local instruction="$2"
  local screenshot="${3:-}"
  echo
  echo "=== $step ==="
  echo "$instruction"
  if [[ -n "$screenshot" ]]; then
    echo "Screenshot suggestion: $screenshot"
  fi
  local answer
  read -r -p "PASS? (y/n/skip): " answer
  case "$answer" in
    y|Y) log "PASS  $step";;
    n|N) log "FAIL  $step"; failures=$((failures + 1));;
    *)   log "SKIP  $step";;
  esac
}

failures=0

log "BEGIN  Spotiglass EQ manual QA"
log "HAL dir: $HAL_DIR"
log "Looking for: $DRIVER_NAME"

# 1. authorization + install
prompt "authorization + install" \
  "Launch Spotiglass. Open Settings → Equalizer and toggle 'Enable Equalizer'. \
macOS should show its standard authorization prompt once. After approval, the \
helper should copy SpotiglassEQDriver.driver into /Library/Audio/Plug-Ins/HAL/. \
Check: \`ls /Library/Audio/Plug-Ins/HAL\` shows the driver, and the pane never \
shows Terminal instructions or a repair button." \
  "Settings → Equalizer pane with toggle ON and the macOS authorization dialog"

# 2. coreaudiod activation
prompt "coreaudiod restart" \
  "The helper should restart coreaudiod after the copy. Do not run a command or \
log out and back in. The virtual device should appear after the app waits for \
CoreAudio to re-enumerate it." \
  ""

# 3. enable + device-visible
prompt "device-visible" \
  "Run: system_profiler SPAudioDataType | grep -A2 'Spotiglass EQ' \
The device should appear. Also visible in System Settings → Sound → Output." \
  "System Settings → Sound → Output listing Spotiglass EQ"

# 4. default-output is Spotiglass EQ
prompt "default-route" \
  "In System Settings → Sound → Output, confirm the default output device is \
now 'Spotiglass EQ'. Spotify Web Playback SDK audio should already be routed \
to it." \
  "Sound → Output highlight on Spotiglass EQ"

# 5. preset toggle (each of the 7 built-ins)
for preset in "Flat" "Bass Boost" "Vocal" "Treble Boost" "Acoustic" "Electronic" "Loudness"; do
  prompt "preset:$preset" \
    "In Settings → Equalizer, pick '$preset' from the preset picker. \
The 10 sliders should snap to the preset's curve. Play a familiar track and \
listen: $preset should change the tonality in the expected direction (e.g. \
Bass Boost lifts lows, Treble Boost lifts highs, etc.)." \
    ""
done

# 6. save user preset
prompt "save-preset" \
  "Drag some sliders to a non-built-in curve. Click 'Save preset…', name it \
'MyTest', click Save. The picker should now show 'MyTest' under Saved." \
  "Picker dropdown showing 'MyTest' under Saved"

# 7. reload MyTest
prompt "reload-preset" \
  "Quit Spotiglass. Relaunch. Open Settings → Equalizer. \
Confirm 'MyTest' is still in the picker under Saved (proves the save persisted \
to ~/.config/spotiglass/settings.json)." \
  "Picker dropdown after relaunch still showing 'MyTest'"

# 8. delete MyTest
prompt "delete-preset" \
  "Pick 'MyTest' in the picker; click Delete. The preset should disappear \
from the picker and from settings.json." \
  ""

# 9. disable (route restored)
prompt "disable-route" \
  "Toggle 'Enable Equalizer' OFF. The default output device should switch \
back to whatever it was before you enabled the EQ. Run \
\`system_profiler SPAudioDataType | grep -i default\` to confirm." \
  ""

# 10. silent upgrade + repair
prompt "silent upgrade + repair" \
  "Use a signed build with an older installed driver, then enable Equalizer \
with a newer bundled driver. Also repeat with a damaged installed bundle. The \
helper should replace it without another authorization prompt, Terminal \
instructions, or a repair button." \
  ""

# 11. default restored after disable
prompt "default-restored" \
  "In System Settings → Sound → Output, confirm the default output device \
is back to the original (whatever you used before step 1)." \
  ""

echo
if (( failures > 0 )); then
  echo "QA finished with $failures failure(s). Log: $LOG_FILE"
  exit 1
fi
echo "QA finished. All checked steps PASS. Log: $LOG_FILE"
log "END    Spotiglass EQ manual QA — 0 failures"
