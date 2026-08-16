import Combine
import Foundation

/// Orchestrates the realtime 10-band parametric equalizer that filters Spotify
/// Web Playback SDK audio through a bundled CoreAudio HAL plugin virtual
/// output device (``SpotiglassEQDriver.driver``).
///
/// **Privacy posture.** This engine NEVER requests microphone or audio
/// recording permission. The audio path is a virtual *output* device —
/// output scope only, no input capture of any kind. The
/// `scripts/eq-mic-permission-audit.sh` audit (wired into `make test`)
/// continuously enforces that, naming the specific banned APIs in its
/// own source so they live in exactly one place in the codebase.
///
/// The view layer (``EqualizerSettingsView``) interacts with the engine via
/// the same Swift API surface that shipped in commit `2fdd179` (start, stop,
/// apply, setPreamp, setBandGain), so the resurrected UI works unchanged.
/// What changed beneath the surface: instead of an AVAudioEngine tap on the
/// system process audio, coefficient updates now travel through a
/// shared-memory seqlock (``EQCoefficientPublisher``) into a bundled CoreAudio
/// `AudioServerPlugIn` that applies vDSP biquads in its IO callback at the
/// device's native sample rate.
///
/// The pieces that load and drive the actual `.driver` bundle live in
/// ``EqualizerHALPluginController``; this engine is the SwiftUI-facing front
/// end and the place that translates dB gains into biquad coefficients.
@MainActor
final class AudioEqualizerEngine: ObservableObject {
    /// Surfaces install/route/IPC errors to the Settings → Equalizer UI.
    @Published private(set) var lastError: String?
    /// Whether the EQ is currently routing audio through the HAL plugin.
    @Published private(set) var isRunning: Bool = false

    private let pluginController: EqualizerHALPluginController
    private let coefficientPublisher: EQCoefficientPublisher

    /// In-memory mirror of the most recently applied settings. The persisted
    /// copy lives in ``SpotiglassSettingsStore``; this mirror is what's used
    /// to recompute coefficients when individual sliders change.
    private var currentSettings: EqualizerSettings = EqualizerSettings()

    init(
        pluginController: EqualizerHALPluginController = .init(),
        coefficientPublisher: EQCoefficientPublisher = .init()
    ) {
        self.pluginController = pluginController
        self.coefficientPublisher = coefficientPublisher
    }

    // MARK: - Lifecycle

    /// Installs the HAL plugin (if needed), routes the system default output
    /// to it, and publishes the current coefficient frame so the IO callback
    /// has values to apply on the next audio cycle.
    ///
    /// `forwardingTargetUID` lets the caller restore a previously-picked
    /// output device (from `EqualizerSettings.forwardingTargetUID`) so the
    /// user's pick survives a disable→enable cycle instead of resetting to
    /// the built-in speaker.
    func start(forwardingTargetUID: String? = nil) throws {
        do {
            try pluginController.enable(preferredForwardingUID: forwardingTargetUID)
            isRunning = true
            lastError = nil
            publishCoefficients()
        } catch {
            // The OSStatus, the bundle name and the staged paths are kept off
            // the settings pane, so the log is where a bug report picks them up
            // (#186).
            if let pluginError = error as? EqualizerHALPluginError,
               let details = pluginError.diagnosticDetails {
                SpotiglassLog.error(.playback, details)
            }
            lastError = error.localizedDescription
            isRunning = false
            throw error
        }
    }

    /// Restores the previous default output device. The `.driver` itself
    /// remains installed; ``EqualizerHALPluginController/uninstall()`` is the
    /// way to fully remove the plugin from disk.
    func stop() {
        pluginController.disable()
        isRunning = false
    }

    // MARK: - Coefficient updates

    /// Replaces the in-memory mirror and pushes a fresh coefficient frame.
    /// Called by the view when a preset is applied or `enabled` flips on.
    func apply(settings: EqualizerSettings) {
        currentSettings = settings
        publishCoefficients()
    }

    /// Per-slider granular update. Only mutates the in-memory mirror; the
    /// `settings.json` write is the view's responsibility.
    func setPreamp(dB: Float) {
        currentSettings.preamp = EqualizerSettings.clampPreamp(Double(dB))
        publishCoefficients()
    }

    func setBandGain(_ index: Int, dB: Float) {
        guard currentSettings.bands.indices.contains(index) else { return }
        currentSettings.bands[index] = EqualizerSettings.clampGain(Double(dB))
        publishCoefficients()
    }

    // MARK: - Forwarding-target picker

    /// Lists output-only hardware devices the EQ can forward to. Excludes
    /// the Spotiglass EQ device itself. Used by the Settings UI dropdown.
    func availableForwardingTargets() -> [AudioDeviceEnumerator.Device] {
        pluginController.availableForwardingTargets()
    }

    /// Updates where EQ-processed audio is sent. Writes the UID to the
    /// driver's target file; the driver's background watcher (~500 ms)
    /// swaps its `AudioDeviceIOProc` atomically — no need to toggle EQ.
    func setForwardingTarget(uid: String) {
        pluginController.setForwardingTarget(uid: uid)
    }

    /// The UID currently written to the target file (whatever the driver
    /// is forwarding to right now). Lets the Settings dropdown reflect the
    /// real on-disk state instead of just the last persisted preference.
    func currentForwardingTargetUID() -> String? {
        pluginController.currentForwardingTargetUID()
    }

    // MARK: - Internals

    private func publishCoefficients() {
        let sampleRate = pluginController.activeSampleRate
        let frame = EQCoefficientFrame.build(
            settings: currentSettings,
            sampleRateHz: sampleRate
        )
        coefficientPublisher.write(frame)
    }
}
