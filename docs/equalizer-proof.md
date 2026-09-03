# Spotiglass EQ — proof bundle

What's automatically verified by XCTest, and what still requires a manual
walkthrough (`scripts/eq-qa.sh`) once a signed driver and privileged helper
load on a real Mac.

## Automatically verified (XCTest)

Run `make test`. Output is mirrored in the Xcode result bundle and the test
log. Relevant suites:

| Suite | Cases | What it proves |
|---|---:|---|
| `EqualizerCoefficientTests` | 7 | RBJ biquad math: zero-dB → bit-exact identity; peaking-EQ symmetry + 6 dB peak; low-shelf DC gain; high-shelf Nyquist gain; flat preset → identity coefficients; Bass Boost lifts only bands 0–3; every built-in preset emits finite, well-formed coefficients. |
| `EqualizerABRMSTests` | 3 | **Crit 5, A/B half** — Flat preset is bit-exact to bypass, Bass Boost lifts 32 Hz relative to 8 kHz, and no preset clips a −1 dBFS input above ±1.06. |
| `EQCoefficientPublisherTests` | 3 | Shared-memory IPC: writer round-trip, sequence always even at rest, monotonically increasing across writes. |
| `EqualizerHALPluginTests` | 5+ | Isolated driver install/uninstall behavior, stale-bundle replacement, router readiness, output restoration, and all built-in coefficient frames without touching real CoreAudio output. |
| `EqualizerDriverInstallPolicyTests` | 7 | Driver release/build ordering, malformed-version handling, missing/stale/repair decisions, downgrade handling, and the rule that helper-install failures keep diagnostics out of user-facing error text. |
| `EqualizerPresetsTests` | 7 | Built-in roster intact, JSON round-trip stable, normalization clamps, `find()` walks both built-ins and user presets, and `apply()` writes preamp, bands, and activePresetName atomically. |

Plus:

| Script | What it proves |
|---|---|
| `scripts/eq-mic-permission-audit.sh` | Zero hits for microphone, process-tap, and input-scope APIs in the EQ code. |
| `SpotiglassEQDriver/build-driver.sh` | The C/C++ plugin compiles cleanly against the macOS SDK and produces a Mach-O universal bundle. |
| `make embed-driver` | The built `.driver` lands at `Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver`. |

## Manually verified by user

These require a real audio environment and a signed, notarized build:

1. **Authorization + install** — toggling Enable Equalizer produces macOS's
   standard authorization prompt for the registered LaunchDaemon, then writes
   the driver to `/Library/Audio/Plug-Ins/HAL/`.
2. **CoreAudio restart** — the helper restarts `coreaudiod` and the virtual
   device is re-enumerated without a shell command or log-out.
3. **Device-visible** — System Settings → Sound → Output lists Spotiglass EQ.
4. **Default-route** — the default output switches to Spotiglass EQ.
5. **Preset: Flat … Loudness** — the DSP math is covered by XCTest; listening
   confirms the expected tonal changes.
6. **Save, reload, and delete preset** — the saved curve survives relaunch and
   can be removed from the picker and settings file.
7. **Disable-route** — the previous default output is restored.
8. **Upgrade + repair** — a stale or damaged installed bundle is replaced by
   the helper without another authorization prompt and without a user-facing
   error or repair action.

The helper registration and authorization prompt cannot be proven by the
unsigned CI build. They need a signed build running on a real Mac.

## Honest gap inventory

- **Developer ID signing:** CI builds are intentionally unsigned. The release
  script signs the app, helper, and driver before notarization. Verify that
  the signed artifact contains the helper under
  `Contents/Library/PrivilegedHelperTools` and the plist under
  `Contents/Library/LaunchDaemons`.
- **CoreAudio behavior:** a valid signature does not prove that `coreaudiod`
  accepts the driver. Verify device enumeration and audible forwarding by hand.
