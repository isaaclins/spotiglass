# Equalizer

Spotiglass ships a realtime 10-band graphic equalizer that filters Spotify
Web Playback SDK audio. **Spotiglass EQ requires NO microphone or
audio-recording permission.** The EQ does not tap, record, or capture audio
input from anywhere — it is a virtual *output* device installed as a CoreAudio
`AudioServerPlugIn`. Music routed through it is filtered in the IO callback
using vDSP biquads at the device's native sample rate, with no resampling.

## How users turn it on

1. Open **Settings → Equalizer** in Spotiglass.
2. Toggle **Enable Equalizer**. On the first enable Spotiglass copies the
   bundled `SpotiglassEQDriver.driver` into `~/Library/Audio/Plug-Ins/HAL/`,
   re-loads `coreaudiod` (see "Activating the driver" below), and routes the
   system default output to `"Spotiglass EQ"`. Spotify Web Playback SDK audio
   is already wired to the system default, so it picks up the new device
   without restarting playback.
3. Pick a built-in preset (Flat, Bass Boost, Vocal, Treble Boost, Acoustic,
   Electronic, Loudness) or drag the 10 sliders to taste. The 80 Hz, 170 Hz,
   310 Hz, 600 Hz, 1 kHz, 3 kHz, 6 kHz, 12 kHz, 14 kHz, 16 kHz bands and the
   preamp update live on every slider change — no audio restart.
4. Save custom curves as user presets. Everything persists to
   `~/.config/spotiglass/settings.json`.

Disabling restores the previous default output and removes the
`.driver` from the user's HAL directory.

## Architecture

```
  ┌─────────────────────────────┐         ┌────────────────────────────┐
  │ Spotiglass (GUI process)    │         │ coreaudiod (system daemon) │
  │                             │         │                            │
  │  EqualizerSettingsView      │         │   AudioServerPlugIn host   │
  │           │                 │         │           │                │
  │  EqualizerStateController   │         │  SpotiglassEQDriver.driver │
  │           │                 │         │           │                │
  │           ▼                 │  shm    │           ▼                │
  │  EQCoefficientPublisher  ───┼────────►│  EQCoefficientReader       │
  │  (atomic seqlock write)     │         │  (RT-safe, no syscalls)    │
  │                             │         │                            │
  │           │                 │         │           │                │
  │           ▼                 │         │           ▼                │
  │  AudioObject default-output │         │  vDSP biquad cascade in    │
  │  setter                     │         │  IO callback @ native rate │
  └─────────────────────────────┘         └────────────────────────────┘
```

The GUI process owns persisted settings and writes coefficient updates to a
POSIX shared-memory region. The HAL plugin lives inside `coreaudiod` and reads
that region in its real-time IO callback — no syscalls, no allocations, no
locks.

## ADR-EQ-1 — AudioServerPlugIn vs AudioDriverKit

### Context

The EQ has to live below the application layer because Spotify's Web Playback
SDK plays audio through standard system output — Spotiglass can't tap into the
SDK's audio graph from JavaScript. Two macOS APIs can register a virtual
output device that runs DSP in the kernel-adjacent path:

| | AudioServerPlugIn | AudioDriverKit |
|---|---|---|
| Runs in | `coreaudiod` (user-space, root daemon) | DriverKit dext (sandboxed user space) |
| Install path | `~/Library/Audio/Plug-Ins/HAL/<name>.driver` | App bundle (`Contents/Library/SystemExtensions`) + `systemextensionsctl` |
| Entitlement | None (signed app is sufficient) | **`com.apple.developer.driverkit.transport.coreaudio`** — Apple-gated, request-only |
| User interaction to install | Plugin copy + coreaudiod restart | OSSystemExtensionRequest + user approval in System Settings → Privacy & Security |
| Long-term support | Maintained, used by BlackHole / BackgroundMusic / Loopback | Apple's recommended forward path, but practically blocked for indies |

### Decision

**AudioServerPlugIn.**

### Reason

`AudioDriverKit` is the architecturally cleaner choice, but the required
`com.apple.developer.driverkit.transport.coreaudio` entitlement is granted by
Apple only on request and is not available to indie macOS developers without
a formal review. Without it the DriverKit dext refuses to load. Every shipping
third-party EQ on macOS (eqMac, BackgroundMusic, BlackHole, Loopback,
Soundsource) uses `AudioServerPlugIn` for exactly this reason. Spotiglass
adopts the same path: a bundled `.driver`, copied to the user's HAL directory
on first enable, no Apple entitlement gate.

### Consequences

- **Pro:** No entitlement gate. Plugin is a self-contained C++ bundle inside
  `Spotiglass.app`.
- **Pro:** Standard install path means dot-files / Migration Assistant pick it
  up correctly.
- **Con:** Activating the driver requires `coreaudiod` to re-load the HAL
  directory, which `launchctl kickstart -k system/com.apple.audio.coreaudiod`
  forces but needs `sudo`. Spotiglass handles this by writing the plugin to
  `~/Library/Audio/Plug-Ins/HAL/` without sudo and then surfacing a
  one-line prompt to the user: *"Run `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`
  or log out and back in to activate the Spotiglass EQ driver."* This is the
  same activation step every other CoreAudio plugin asks for on first
  install.
- **Con:** Code signing requirements apply. Production builds need a real
  Developer ID signature for the `.driver` bundle; ad-hoc signing usually
  loads only when SIP / amfi loosening is in place. Documented under "Known
  limitations" below.

## ADR-EQ-2 — IPC for live coefficient updates

### Context

The GUI process needs to send updated biquad coefficients (10 bands × 5 floats
+ a preamp gain = 51 floats, ~204 bytes) to the HAL plugin every time the
user drags a slider or picks a preset. The plugin then reads those
coefficients from inside its IO callback, which runs on a real-time
audio-priority thread at sub-10 ms cadence. Three candidates:

| | CFMessagePort | XPC service | POSIX shared memory |
|---|---|---|---|
| Direction | Bidirectional, message-passing | Bidirectional, request/response | Unidirectional, polled |
| RT-safety | ❌ Syscall + allocation per send | ❌ Syscall + queue dispatch per send | ✅ Reader does only atomic loads |
| Setup cost | Low | Medium (.plist registration) | Low (`shm_open` once) |
| Used by audio plugins | Rarely | Rarely (mostly for control planes) | Industry standard inside CoreAudio drivers |

### Decision

**POSIX shared memory with a 64-bit atomic seqlock**, named
`"/com.isaaclins.spotiglass.eq.coeffs.v1"`.

### Reason

The HAL IO callback is a real-time thread. Per Apple's RT-audio rules
(documented in "Audio Server Plug-In Driver Programming Guide" and CoreAudio
mailing-list lore), it cannot:

- allocate memory,
- take locks that may block on the CPU scheduler,
- call into syscalls that can page-fault or be preempted by a non-RT thread.

CFMessagePort and XPC both violate all three. Shared memory with atomic
loads/stores satisfies all three: the reader does a CAS-free seqlock read
which compiles to two `lock-cmpxchg`-free loads on Apple Silicon, and the
writer (GUI process, non-RT) does two `release` stores around a
non-atomic memcpy.

### Layout

```c
struct EQCoefficientFrame {
    _Atomic(uint64_t) sequence;           // odd while writing, even when stable
    float             preampLinear;        // applied before band 0
    float             bandCoeffs[10 * 5];  // {b0, b1, b2, a1, a2} per band
    uint32_t          sampleRateHz;        // recomputed when device rate changes
    uint32_t          enabledMask;         // bit i = band i enabled (future use)
};
```

Total size 232 bytes, aligned to 16 bytes; fits in a single cacheline group
on Apple Silicon.

### Consequences

- **Pro:** No syscalls inside the IO callback. Updates are torn-free under
  the seqlock protocol (the IO callback retries at most once if it observes
  an odd sequence). Latency is one audio cycle (~5 ms).
- **Pro:** Read-only mapping in the daemon side; writer side can be
  destroyed/recreated independently for hot-swap of the GUI process.
- **Con:** Shared memory needs a stable path. We use `/tmp` and a UID-suffixed
  name to avoid collisions across user sessions.

## ADR-EQ-3 — Volume control via target-device mirror

### Context

`Spotiglass EQ` is the system default output while the EQ is engaged, so the
macOS menu-bar / Control Center volume slider acts on it — not on the
downstream device (speakers, headphones, AirPods) that actually emits sound.
Without a `kAudioVolumeControl` exposed on the virtual device, the slider
is greyed out and the user has to dive into System Settings → Sound to
adjust the EQRouter target's volume, which defeats the point of routing
audio through Spotiglass EQ in the first place.

Three ways to expose a working slider:

| | Soft attenuation in DSP | Pass-through to target | Hybrid (mirror + DSP fallback) |
|---|---|---|---|
| Adjusts target's hardware volume? | ❌ No | ✅ Yes | Both, by device capability |
| Works on targets without VolumeScalar | ✅ Multiplies samples in DoIO | ❌ Slider does nothing | ✅ DSP path catches them |
| Cost in the IO callback | One vDSP_vsmul per cycle | Zero | One vDSP_vsmul per cycle on fallback |
| Stays in sync with target's own volume controls | ❌ Drifts | ✅ Mirrors | ✅ Mirrors when available |

### Decision

**Mirror to the EQRouter target's `kAudioDevicePropertyVolumeScalar`** for
both reads and writes, with a local atomic cache as fallback. No DSP-side
attenuation in v1.

### Reason

For the targets we ship against (built-in speakers, USB DACs, AirPods,
Bluetooth headsets), the target device accepts `kAudioDevicePropertyVolumeScalar`
on the output scope's main element. Mirroring keeps the menu-bar slider in
sync with the user's actual loudness and avoids double-attenuation
(slider value + downstream hardware gain). The cache (`PluginState::cachedVolumeScalar`)
gives the property handlers a stable answer when the EQRouter is mid-swap
or when the target temporarily refuses a read.

The IO callback intentionally stays out of the volume path so the realtime
thread budget remains untouched.

### Layout

```cpp
constexpr UInt32 kVolumeControlObjectID = 4;     // device-owned control
constexpr Float32 kVolumeMinDB = -64.0f;          // slider floor
constexpr Float32 kVolumeMaxDB =   0.0f;          // slider ceiling
// dB curve: dB = 20·log10(scalar), inverted as scalar = 10^(dB/20).
```

The control is published via the device's `kAudioObjectPropertyControlList`
(one ID) and `kAudioObjectPropertyOwnedObjects` (stream + control).

### Consequences

- **Pro:** Menu-bar slider works immediately. No syscalls or vDSP work
  inside `DoIOOperation`.
- **Pro:** Slider tracks downstream hardware-side changes (e.g. user
  presses physical headphone volume button) via `ReadTargetVolumeOrCached`.
- **Con:** Targets that don't expose `VolumeScalar` make the slider a
  no-op cache. A future ADR can lift the slider's value into a DSP
  attenuation post-EQ for those cases without changing the slider model.
- **Con:** The control reports a single channel-master scalar — no
  per-channel or balance control yet. Acceptable for the EQ use case.

## Activating the driver

On first enable Spotiglass copies the embedded `SpotiglassEQDriver.driver` to
`/Library/Audio/Plug-Ins/HAL/`. On macOS 26 `coreaudiod` only scans the
system-scope HAL directory (the legacy `~/Library/Audio/Plug-Ins/HAL/` is
ignored), so the install requires `sudo`. Since the GUI process never runs
sudo on the user's behalf, the controller stages a copy in
`~/Library/Application Support/Spotiglass/staged-driver/` and surfaces the
exact `sudo cp -pR …` command for the user to run in Terminal. After the
copy, the user reloads coreaudiod with `sudo killall coreaudiod` (the
`launchctl kickstart` route is blocked by SIP on macOS 26).

After activation, `"Spotiglass EQ"` appears in **System Settings → Sound →
Output**. Spotiglass flips the system default output to it via
`AudioObjectSetPropertyData` (kAudioHardwarePropertyDefaultOutputDevice) and
records the previous default in `~/.config/spotiglass/settings.json` so
disable can restore it.

## Adding a new preset

1. Add a case to `EqualizerPresets.builtIn` with the band gain dictionary.
2. Add a row to `SpotiglassTests/EqualizerPresetsTests.swift` asserting the
   gains.
3. Run `make test`.

## Style guide for band gains

- Built-in presets cap individual band gains at ±9 dB and preamp at ±6 dB to
  stay well below clipping for normalized streams.
- vDSP biquads use Robert Bristow-Johnson's audio EQ cookbook formulas (peaking
  EQ for the eight middle bands, low-shelf for 80 Hz, high-shelf for 16 kHz).
- Coefficients are recomputed in the GUI process whenever a slider moves or a
  preset is picked, then published through the seqlock. The plugin never
  computes filter coefficients on the RT thread.

## Privacy

Spotiglass EQ:

- **Never** requests Microphone / Audio Recording permission.
- **Never** uses `AudioHardwareCreateProcessTap` / `CATapDescription`.
- **Never** uses input-scope CoreAudio. The `.driver` registers
  `kAudioDeviceTransportTypeVirtual` with output streams only.
- **Never** captures, records, or persists audio data — coefficients are
  applied in-place in the IO callback's output buffer.

A pre-commit audit script
(`scripts/eq-mic-permission-audit.sh`, wired into `make test`) greps for the
above APIs in the EQ code and fails the build on any hit.

## Building the driver

Two paths:

1. **`make embed-driver`** (recommended) — builds the host app, then builds
   the `.driver` universal Mach-O bundle, then copies it into
   `Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/`. Uses `clang`
   directly via `SpotiglassEQDriver/build-driver.sh`, so it doesn't need
   a separate Xcode target.

2. **`./SpotiglassEQDriver/build-driver.sh`** alone — builds the driver
   bundle at `build/SpotiglassEQDriver.driver` without touching the host
   app. Useful for inspecting the Mach-O or for CI.

A fully-wired Xcode target (proper integration with Run/Test schemes, no
Makefile escape hatch) is documented in `docs/equalizer-xcode-target.md`
as the recommended next step once Developer ID signing is wired up.

## Known limitations

- **Code signing:** macOS 26 will load a HAL plugin signed with a free
  *Apple Development* identity (Personal Team) — full *Developer ID
  Application* signing is not required for the driver to register in
  `coreaudiod` and appear in System Settings → Sound → Output. The
  embedded build at
  `Spotiglass.app/Contents/Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver`
  is signed with whichever identity the user passes via
  `XCODE_EXTRA='CODE_SIGN_IDENTITY=…'`. For shipping outside developer
  machines, sign with a Developer ID Application identity and notarize.

  When copying the `.driver` into `/Library/Audio/Plug-Ins/HAL/` outside
  Xcode (e.g. for testing on a different account), use `cp -pR`, NOT
  `cp -R`. The signature embeds the source file's mtime as `cs_mtime`;
  a plain copy bumps the destination mtime, the kernel sees
  `cs_mtime != mtime`, taints the page, and refuses to load with
  `CODE SIGNING: rejecting invalid page`. `cp -pR` preserves mtimes; or
  re-sign in place at the destination (`sudo codesign --force --sign
  <identity> /Library/Audio/Plug-Ins/HAL/SpotiglassEQDriver.driver`).
- **coreaudiod restart:** macOS does not provide a sudo-free way to reload
  HAL plugins from `~/Library/Audio/Plug-Ins/HAL/`. Spotiglass surfaces
  instructions but does not run sudo on the user's behalf.
- **Sample-rate changes:** When the device's active sample rate changes
  (e.g., user picks a new monitor), the driver re-publishes the rate and the
  GUI process re-derives coefficients. Brief glitch may be audible during
  the recomputation cycle.
- **Trust anchor for signing:** A fresh checkout (or a login keychain that
  has been swept of stale anchors) won't have the Apple Inc. Root CA cert
  trust-anchored. Without that, `codesign` rejects the Apple Development
  identity with `errSecInternalComponent` / "unable to build chain to
  self-signed root" and silently falls back to ad-hoc — which coreaudiod
  refuses to load. Run `bash scripts/setup-eq-driver-signing.sh` once per
  user/account; it downloads the cert from `apple.com`, imports it into the
  login keychain, and runs `security add-trusted-cert -r trustRoot` (you'll
  be prompted for your login password). Xcode does this the first time you
  build a signed app, so most dev machines already have it.

- **In-driver forwarding (EQRouter):** A virtual output device with no
  real backing produces silence. To make the EQ audible, `SpotiglassEQDSP`
  applies biquads to the in-place IO buffer and then hands the processed
  frames to `EQRouter` (see `SpotiglassEQDriver/EQRouter.{h,cpp}`), which
  opens a public-client `AudioDeviceIOProc` on the *previous* default
  output (e.g. MacBook Pro Speakers) and writes the processed audio there
  via a lock-free SPSC ring buffer. The Swift controller writes the
  forwarding target's UID to `/tmp/com.isaaclins.spotiglass.eq.target.u<uid>`
  before flipping default-output to Spotiglass EQ. **EQRouter is
  output-scope only.** It never opens an input IOProc and never reads from
  any input stream — no microphone path exists by construction.
