import Combine
import Foundation

/// Orchestrates the realtime 10-band parametric equalizer that filters Spotify
/// Web Playback SDK audio through a bundled CoreAudio HAL plugin virtual
/// output device (``SpotiglassEQDriver.driver``).
///
/// **Privacy posture.** This engine NEVER requests microphone or audio
/// recording permission. The audio path is a virtual *output* device — there
/// is no input scope, no process tap, no `AVAudioEngine.inputNode`, no
/// `AVCaptureDevice`, no `AudioHardwareCreateProcessTap`. The
/// `scripts/eq-mic-permission-audit.sh` audit (wired into `make test`)
/// continuously enforces that.
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
    func start() throws {
        do {
            try pluginController.enable()
            isRunning = true
            lastError = nil
            publishCoefficients()
        } catch {
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
