#!/usr/bin/env bash
# Screenshot mode: run the real app against a local Spotify stand-in and capture its windows.
# No Spotify account, Premium, Keychain item or audio driver is used. See docs/screenshots.md.
#
#   scripts/screenshots.sh start [--light] [--now-playing "Title"]   build, start mock, launch app
#   scripts/screenshots.sh shot <name> [window-title]                 capture a window to $SHOTS_DIR/<name>.png
#   scripts/screenshots.sh key <keycode> [cmd] [shift] [alt]           press a shortcut, e.g. `key 40 cmd` = ⌘K
#   scripts/screenshots.sh stop                                       quit app, stop mock, remove all state
#
# Between `shot`s, drive the app by hand, with `key`, or with cliclick for clicks and typing.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$ROOT/build/screenshot-mode"
SHOTS_DIR="${SHOTS_DIR:-$WORK/shots}"
PORT="${SPOTIGLASS_MOCK_PORT:-43900}"
# A separate bundle id keeps the run's UserDefaults out of the real app's domain; the fake home
# keeps settings, caches and logs out of ~/Library.
BUNDLE_ID="com.isaaclins.spotiglass.screenshots"
APP="$WORK/Spotiglass.app"
FAKE_HOME="$WORK/home"
WINDOW_FRAME="${WINDOW_FRAME:-120, 80, 1320, 860}"   # x, y, width, height in points

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

app_pid() { pgrep -f "$APP/Contents/MacOS/Spotiglass" | head -1; }

# Prints "<windowID> <title>" for each on-screen window of the screenshot app, largest first.
windows() {
    local pid; pid="$(app_pid)"
    [ -n "$pid" ] || { echo "screenshots: app is not running" >&2; return 1; }
    cat > "$WORK/windows.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
for w in mine.sorted(by: { area($0) > area($1) }) {
    print(w[kCGWindowNumber as String] as! Int, w[kCGWindowName as String] as? String ?? "")
}
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    return b["Width"]! * b["Height"]!
}
SWIFT
    swift "$WORK/windows.swift" "$pid"
}

start() {
    local scheme="dark" now_playing=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --light) scheme="light" ;;
            --now-playing) now_playing="$2"; shift ;;
            *) usage ;;
        esac
        shift
    done
    [ -z "$(app_pid)" ] || { echo "screenshots: already running; run 'stop' first" >&2; exit 1; }
    mkdir -p "$WORK" "$SHOTS_DIR"

    echo "==> building Debug app"
    make build UNSIGNED=1 >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; exit 1; }

    echo "==> staging $APP ($BUNDLE_ID)"
    rm -rf "$APP"
    cp -R build/DerivedData/Build/Products/Debug/Spotiglass.app "$APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1

    echo "==> seeding settings ($scheme)"
    rm -rf "$FAKE_HOME"
    mkdir -p "$FAKE_HOME/Library/Application Support/Spotiglass"
    # Empty keybind metadata makes the app seed its default shortcuts (⌘K and friends).
    # The EQ shows the Electronic preset; screenshot mode never starts the audio driver.
    cat >"$FAKE_HOME/Library/Application Support/Spotiglass/settings.json" <<JSON
{
  "version": 2, "keybinds": [], "seededKeybindCommands": [],
  "appearance": { "colorScheme": "$scheme", "language": "en" },
  "equalizer": { "enabled": true, "activePresetName": "Electronic", "preamp": -1,
                 "bands": [4, 3, 1, 0, -2, 2, 1, 1, 3, 4], "userPresets": [] }
}
JSON

    echo "==> starting mock on 127.0.0.1:$PORT"
    python3 scripts/screenshot-mode/mock_spotify.py --port "$PORT" --cache "$WORK/library-cache.json" \
        ${now_playing:+--now-playing "$now_playing"} >"$WORK/mock.log" 2>&1 &
    echo $! >"$WORK/mock.pid"
    for _ in $(seq 1 120); do
        curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
        kill -0 "$(cat "$WORK/mock.pid")" 2>/dev/null || { cat "$WORK/mock.log"; exit 1; }
        sleep 0.5
    done

    echo "==> launching"
    # -spotify.clientID goes to the argument domain: read by the app, never persisted.
    open -n --env "SPOTIGLASS_MOCK_BASE=http://127.0.0.1:$PORT" --env "CFFIXED_USER_HOME=$FAKE_HOME" \
        "$APP" --args -spotify.clientID screenshot-mode
    for _ in $(seq 1 60); do
        [ -n "$(app_pid)" ] && windows 2>/dev/null | grep -q . && break
        sleep 0.5
    done
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $(app_pid))
        set frontmost to true
        set {x, y, w, h} to {$WINDOW_FRAME}
        set position of window 1 to {x, y}
        set size of window 1 to {w, h}
    end tell" >/dev/null
    sleep 4   # let the library, artwork and player bar settle
    echo "running. capture with: $0 shot <name>"
}

# Captures the largest app window, or the first one whose title contains $2.
shot() {
    [ $# -ge 1 ] || usage
    local name="$1" match="${2:-}" id
    mkdir -p "$SHOTS_DIR"
    if [ -n "$match" ]; then
        id="$(windows | grep -F -- "$match" | head -1 | cut -d' ' -f1)"
    else
        id="$(windows | head -1 | cut -d' ' -f1)"
    fi
    [ -n "$id" ] || { echo "screenshots: no matching window" >&2; exit 1; }
    screencapture -x -o -l "$id" "$SHOTS_DIR/$name.png"
    echo "$SHOTS_DIR/$name.png"
}

# Posts a real key event (with its virtual key code) so the app's keymap sees it; typed text
# from other tools often lacks the key code. Modifiers are pressed and released explicitly so
# none stays held afterwards.
key() {
    [ $# -ge 1 ] || usage
    if [ ! -x "$WORK/key" ]; then
        cat > "$WORK/key.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let code = CGKeyCode(CommandLine.arguments[1])!
let modifiers: [(CGKeyCode, CGEventFlags)] = CommandLine.arguments.dropFirst(2).compactMap {
    switch $0 {
    case "cmd": return (55, .maskCommand)
    case "shift": return (56, .maskShift)
    case "alt": return (58, .maskAlternate)
    default: return nil
    }
}
var flags: CGEventFlags = []
func post(_ key: CGKeyCode, _ down: Bool) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(25_000)
}
for (key, flag) in modifiers { flags.insert(flag); post(key, true) }
post(code, true)
post(code, false)
for (key, flag) in modifiers.reversed() { flags.remove(flag); post(key, false) }
SWIFT
        swiftc -O "$WORK/key.swift" -o "$WORK/key"
    fi
    "$WORK/key" "$@"
}

stop() {
    local pid; pid="$(app_pid || true)"
    if [ -n "$pid" ]; then
        osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set frontmost to true" \
            -e 'tell application "System Events" to keystroke "q" using command down' >/dev/null 2>&1 || true
        sleep 2
        kill "$pid" 2>/dev/null || true
    fi
    [ -f "$WORK/mock.pid" ] && { kill "$(cat "$WORK/mock.pid")" 2>/dev/null || true; rm -f "$WORK/mock.pid"; }
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$FAKE_HOME" "$APP" "$WORK/windows.swift" "$WORK/key.swift" "$WORK/key"
    echo "stopped; screenshots stay in $SHOTS_DIR"
}

case "${1:-}" in
    start) shift; start "$@" ;;
    shot) shift; shot "$@" ;;
    windows) windows ;;
    key) shift; key "$@" ;;
    stop) stop ;;
    *) usage ;;
esac
