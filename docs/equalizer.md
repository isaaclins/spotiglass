# Equalizer

Spotiglass ships a live, in-app, 10-band parametric equalizer that filters the actual audio coming out of the Spotify Web Playback SDK. In **Settings → Equalizer**, the **Bands** section shows a log-frequency graph (smooth curve through ten control points). Drag any point vertically while a song is playing; each point maps to one fixed band center frequency, and the change applies on the next render quantum without restarting playback.

## How it works

1. A private Core Audio **stereo mixdown** process tap is created over **Spotiglass’s UI process and its descendant PIDs** (WebKit WebContent, GPU, Networking, etc.). `WKWebView` audio does not render in the main app process on macOS, so tapping only `getpid()` would miss playback entirely. Child PIDs are discovered with **`proc_listallpids` + `proc_pidinfo`** (with buffer growth so the listing is not truncated), merged with `proc_listchildpids` and `kern.proc.all`. When WebKit helpers are not linked to the app by BSD `ppid` alone, Spotiglass also includes helpers whose executable path matches known WebKit audio roles and that share the app’s **effective uid** and either **descend from the app on the best-effort parent map** or share its **process group**. `muteBehavior = .muted` suppresses those processes’ direct output so you only hear the EQ-processed path.
2. When the Web Playback SDK first reports a ready device, Spotiglass **rebuilds** the tap so any helpers that spawned late are included. When the signed-in playlist UI (and hidden playback `WKWebView`) appears, it schedules another debounced rebuild so the tap is less likely to miss helpers that were not present when the main window first appeared.
3. The tap is wrapped in a private aggregate device whose main sub-device is the system default output (used purely as a clock reference).
4. `AVAudioEngine` reads from the aggregate device, runs the audio through `AVAudioUnitEQ` (10 parametric bands, configurable preamp), and renders to the default output device.

This means: **EME / DRM is not bypassed** — Spotiglass only re-routes audio it is already legitimately playing back from those WebKit processes. Apple does not expose Web Audio nodes for the SDK's `<audio>` element ([spotify/web-playback-sdk#25](https://github.com/spotify/web-playback-sdk/issues/25)), so a JavaScript-side EQ is not possible; this Core Audio approach is the only working path.

Requirements: macOS 14.4 or newer, and macOS Audio Recording permission (granted on the first enable).

## External utilities and the built-in EQ

Utilities such as **SoundSource** (and similar per-app volume or “audio fixer” tools) sit in the **macOS audio stack**. They typically capture **PCM that Spotiglass’s processes are already sending** toward the default output, run DSP (EQ, limiter, volume), and play the result to your speakers or headphones. That is the same *class* of approach Spotiglass uses internally: a **Core Audio process tap** on the app’s process tree (including WebKit helpers), not a special Spotify API.

**Important:** If **both** an external per-app EQ and Spotiglass’s **Settings → Equalizer** are active for Spotiglass, you may get **double filtering**, **unexpected loudness**, or **phasey / smeared** sound—and it is easy to blame the in-app EQ. When testing or troubleshooting Spotiglass’s EQ, **turn off** per-app effects for Spotiglass in those utilities.

## Checklist when EQ misbehaves

Work through these before assuming the in-app EQ is broken:

1. **macOS version** — 14.4 or newer (the private process tap path requires it).
2. **Audio Recording** — Spotiglass is allowed under *System Settings → Privacy & Security → Audio Recording*.
3. **Web Playback is actually active** — Audio must be playing through Spotiglass’s hidden Web Playback device. Other Spotify clients on the same account use a different device; their audio is **not** what the tap sees.
4. **External per-app audio tools** — Disable SoundSource (or similar) processing **specifically for Spotiglass** while testing the built-in EQ, so only one EQ owns the path.
5. **Tap rebuild** — Toggle **Enable Equalizer** off and on while a track is playing, or ensure the signed-in playlist UI (with the hidden `WKWebView`) has appeared so debounced tap rebuilds can run.

## Bands and ranges

Each of the ten draggable graph points is tied to a **fixed parametric band** (center frequency and gain in dB). The curve between points is a visual smoothing aid; audio still passes through the ten peaking filters listed below.

| Band | Frequency | Gain range |
| ---- | --------- | ---------- |
| 1 | 32 Hz | -12 dB … +12 dB |
| 2 | 64 Hz | -12 dB … +12 dB |
| 3 | 125 Hz | -12 dB … +12 dB |
| 4 | 250 Hz | -12 dB … +12 dB |
| 5 | 500 Hz | -12 dB … +12 dB |
| 6 | 1 kHz | -12 dB … +12 dB |
| 7 | 2 kHz | -12 dB … +12 dB |
| 8 | 4 kHz | -12 dB … +12 dB |
| 9 | 8 kHz | -12 dB … +12 dB |
| 10 | 16 kHz | -12 dB … +12 dB |

The pre-amp slider applies a global gain (-12 dB … +12 dB) before the bands and is the right knob to lower if positive band gains are clipping.

## Built-in presets

Available from the **Preset** picker in Settings → Equalizer:

- **Flat** — all bands 0 dB.
- **Bass Boost** — lifts the lowest four bands.
- **Vocal** — gentle midrange bump, slight roll-off at the extremes.
- **Treble Boost** — lifts the top four bands.
- **Acoustic** — broad, natural curve good for acoustic recordings.
- **Electronic** — scoops the low-mids and lifts the lows and highs.
- **Loudness** — V-curve preset that emphasizes lows and highs.

## Saving and deleting your own presets

- **Save preset…** in Settings → Equalizer captures the current band gains and pre-amp under a name you choose. User presets are stored in the same `settings.json` file and appear under **Saved** in the picker.
- **Delete** removes the currently selected user preset (built-ins cannot be deleted).
- Hand-edits to `userPresets` in `settings.json` are picked up live.

## Backing up your settings

Everything (keybinds, equalizer state, presets) lives in a single dotfile:

```
~/.config/spotiglass/settings.json
```

Copy that file to back up or sync between Macs. Spotiglass watches the file for external changes and reloads automatically. See [Data storage](data-storage.md#settingsjson-shape) for the JSON schema.

## Troubleshooting

Start with the [Checklist when EQ misbehaves](#checklist-when-eq-misbehaves) above.

- **"Audio Recording" permission denied** — Open *System Settings → Privacy & Security → Audio Recording*, enable Spotiglass, then toggle the EQ off and on again.
- **Toggle reverts immediately** — Inspect the red error label next to the toggle. The most common cause is denied permission or running on a macOS version older than 14.4.
- **No audible change when adjusting the graph** — Make sure Spotify is actually playing through Spotiglass (the hidden Web Playback device is what the tap captures). Other Spotify clients on the same account play to a different device and are not affected. If playback is already through Spotiglass but the curve still does nothing, the Core Audio process tap may not yet include the WebKit helper that outputs audio; Spotiglass debounce-rebuilds the tap when the signed-in playlist view (with the hidden `WKWebView`) appears and when the Web Playback SDK reports a ready device. As a fallback, toggle **Enable Equalizer** off and on while a track is playing so the tap rescans PIDs (including WebKit helpers matched by process name when `proc_pidpath` is empty).
- **Sounds wrong only with another audio app running** — You may have **two** EQ or routing layers on Spotiglass (see [External utilities and the built-in EQ](#external-utilities-and-the-built-in-eq)). Disable per-app processing for Spotiglass in that tool, or disable Spotiglass’s built-in EQ and use only the external one.
