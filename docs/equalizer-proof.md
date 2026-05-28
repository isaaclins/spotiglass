# Spotiglass EQ — proof bundle

What's automatically verified by `make test`, and what still requires a
manual walkthrough (`scripts/eq-qa.sh`) once a Developer ID-signed `.driver`
loads in `coreaudiod`.

## Automatically verified (XCTest)

Run `make test`. Output is mirrored in the Xcode result bundle and the
test log. Relevant suites:

| Suite | Cases | What it proves |
|---|---|---|
| `EqualizerCoefficientTests` | 7 | RBJ biquad math: zero-dB → bit-exact identity; peaking-EQ symmetry + 6 dB peak; low-shelf DC gain; high-shelf Nyquist gain; flat preset → identity coefficients; Bass Boost lifts only bands 0–3; every built-in preset emits finite, well-formed coefficients. |
| `EqualizerABRMSTests` | 3 | **Crit 5, A/B half** — Flat preset is bit-exact to bypass (zero RMS delta, far inside the ±0.05 dB bar). Bass Boost lifts 32 Hz RMS relative to 8 kHz RMS by >2 dB. No preset clips a −1 dBFS input above ±1.06. |
| `EQCoefficientPublisherTests` | 3 | Shared-memory IPC: writer round-trip, sequence always even at rest, monotonically increasing across writes. |
| `EqualizerHALPluginTests` | 5 | Install copies the embedded `.driver` into a temp HAL dir, uninstall is idempotent, re-install replaces stale files, missing-payload surfaces `embeddedDriverMissing` cleanly, all 7 built-ins produce distinguishable coefficient frames. |
| `EqualizerPresetsTests` | 7 | Resurrected from 2fdd179: built-in roster intact, JSON round-trip stable, normalization clamps, `find()` walks both built-ins and user presets, `apply()` writes preamp+bands+activePresetName atomically. |

Plus:

| Script | What it proves |
|---|---|
| `scripts/eq-mic-permission-audit.sh` | Zero hits for `NSMicrophoneUsage`, `AVCaptureDevice`, `inputNode`, `AudioHardwareCreateProcessTap`, `CATapDescription`, `kAudioObjectPropertyScopeInput` in `Spotiglass/` and `SpotiglassTests/`. Wired into `make test` as a prerequisite. |
| `SpotiglassEQDriver/build-driver.sh` | The C/C++ plugin source compiles cleanly on the macOS 26 SDK against `CoreAudio.framework` and produces a Mach-O universal bundle (x86_64 + arm64). |
| `make embed-driver` | The built `.driver` lands at `Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver`, satisfying criterion 1's "the `.driver` is embedded in Spotiglass.app". |

## Manually verified by user (criterion 5)

These require a real audio environment + Developer ID signing.
`scripts/eq-qa.sh` walks the user through them and writes
`build/qa/manual-qa-<timestamp>.log`:

1. **install** — toggling Enable in Settings → Equalizer copies the
   embedded `.driver` to `~/Library/Audio/Plug-Ins/HAL/`. *(Path
   automatically verified by `EqualizerHALPluginTests` against a fixture;
   user confirms the real path is also written.)*
2. **coreaudiod kickstart** — `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`
3. **device-visible** — `system_profiler SPAudioDataType` shows Spotiglass EQ;
   System Settings → Sound → Output lists it. **Requires Developer ID
   signing.**
4. **default-route** — default output switches to Spotiglass EQ. *(Swift
   path verified by `EqualizerHALPluginController` unit tests.)*
5. **preset:Flat … preset:Loudness** — tonality shifts as expected. *(The
   DSP math is verified by `EqualizerABRMSTests`; the listening half is
   the user's call.)*
6. **save-preset** — "MyTest" lands in `~/.config/spotiglass/settings.json`.
   *(Persistence path verified by `EqualizerPresetsTests`.)*
7. **reload-preset** — survives a quit + relaunch.
8. **delete-preset** — preset disappears.
9. **disable-route** — default output restored.
10. **uninstall** — driver gone from `~/Library/Audio/Plug-Ins/HAL/`.
11. **default-restored** — original default device is back.

## Honest gap inventory

What's NOT done in this codebase:

- **Developer ID signing** of the embedded `.driver`. Without it, macOS 26
  `coreaudiod` will refuse to register the device. The driver itself is
  ad-hoc signed during `build-driver.sh`; the user must re-sign with a
  Developer ID identity before installing on a production machine.
- **Property dispatcher** in `SpotiglassEQPlugin.cpp` — `HasProperty`,
  `GetPropertyData`, `GetPropertyDataSize`, `IsPropertySettable`,
  `SetPropertyData`. These are the AudioObject ABI handlers that
  coreaudiod calls before it'll register the device. Marked `TODO(PROP)`.
  ~600-1000 lines of selector-switch boilerplate; Apple's `NullAudio`
  sample is the canonical template.
- **Xcode target** for the `.driver`. Currently built via `clang` from
  `make embed-driver`. Documented under `docs/equalizer-xcode-target.md`.
