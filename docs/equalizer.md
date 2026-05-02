# Equalizer

Spotiglass ships a live, in-app, 10-band parametric equalizer that filters the actual audio coming out of the Spotify Web Playback SDK. Drag any slider while a song is playing and the change applies on the next render quantum without restarting playback.

## How it works

1. A private Core Audio process tap is created on Spotiglass's own PID with `muteBehavior = .muted`, so the original DRM stream is suppressed at the speaker.
2. The tap is wrapped in a private aggregate device whose main sub-device is the system default output (used purely as a clock reference).
3. `AVAudioEngine` reads from the aggregate device, runs the audio through `AVAudioUnitEQ` (10 parametric bands, configurable preamp), and renders to the default output device.

This means: **EME / DRM is not bypassed** — Spotiglass only re-routes audio it is already legitimately playing back inside its own process. Apple does not expose Web Audio nodes for the SDK's `<audio>` element ([spotify/web-playback-sdk#25](https://github.com/spotify/web-playback-sdk/issues/25)), so a JavaScript-side EQ is not possible; this Core Audio approach is the only working path.

Requirements: macOS 14.4 or newer, and macOS Audio Recording permission (granted on the first enable).

## Bands and ranges

| Slider | Frequency | Range |
| ------ | --------- | ----- |
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

- **"Audio Recording" permission denied** — Open *System Settings → Privacy & Security → Audio Recording*, enable Spotiglass, then toggle the EQ off and on again.
- **Toggle reverts immediately** — Inspect the red error label next to the toggle. The most common cause is denied permission or running on a macOS version older than 14.4.
- **No audible change with sliders** — Make sure Spotify is actually playing through Spotiglass (the hidden Web Playback device is what the tap captures). Other Spotify clients on the same account play to a different device and are not affected.
