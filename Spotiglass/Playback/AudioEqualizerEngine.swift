import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Errors raised by ``AudioEqualizerEngine`` while standing up the Core Audio graph.
///
/// Each case carries the underlying ``OSStatus`` (when applicable) so the surfaced
/// error message in the Settings UI can include the raw HAL/AU code.
enum AudioEqualizerEngineError: LocalizedError, Equatable {
    case macOSVersionUnsupported
    case couldNotResolveOwnProcessObject(OSStatus)
    case couldNotCreateTap(OSStatus)
    case couldNotReadTapUID(OSStatus)
    case couldNotCreateAggregateDevice(OSStatus)
    case couldNotConfigureInputDevice(OSStatus)
    case couldNotStartEngine(String)

    var errorDescription: String? {
        switch self {
        case .macOSVersionUnsupported:
            return "The Spotiglass equalizer requires macOS 14.4 or newer Core Audio process taps."
        case let .couldNotResolveOwnProcessObject(status):
            return "Could not resolve this app's audio process object (OSStatus \(status))."
        case let .couldNotCreateTap(status):
            return "Failed to create Core Audio process tap (OSStatus \(status)). Audio recording permission may have been denied."
        case let .couldNotReadTapUID(status):
            return "Failed to read tap UID (OSStatus \(status))."
        case let .couldNotCreateAggregateDevice(status):
            return "Failed to create aggregate device for the equalizer (OSStatus \(status))."
        case let .couldNotConfigureInputDevice(status):
            return "Failed to bind the equalizer input to the aggregate device (OSStatus \(status))."
        case let .couldNotStartEngine(message):
            return "Failed to start the audio engine: \(message)"
        }
    }
}

/// Live, premium 10-band equalizer applied to Spotiglass's own process audio.
///
/// ## How it works
///
/// 1. Creates a private Core Audio process tap on this app's PID (which is what the
///    Spotify Web Playback `WKWebView` plays through). The tap is configured with
///    `muteBehavior = .muted` so the original DRM stream is suppressed at the
///    speaker, and only the EQ-processed copy is heard.
/// 2. Wraps the tap in a private aggregate device, used as the input device of an
///    ``AVAudioEngine``.
/// 3. Routes `inputNode -> AVAudioUnitEQ (10 bands) -> mainMixerNode -> outputNode`,
///    where ``outputNode`` plays back to the system default output device.
/// 4. Mutating any band's `gain`/`bypass` or `globalGain` is live: parameter changes
///    take effect on the next render quantum without a graph restart.
///
/// EME / DRM is not bypassed: only the audio that this process already plays back is
/// captured for re-routing through the EQ, and the original output is muted at the
/// device level via the tap so the user only hears the processed copy.
@MainActor
final class AudioEqualizerEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published var lastError: String?

    let bandFrequencies: [Float]

    private let engine = AVAudioEngine()
    private let eq: AVAudioUnitEQ
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var defaultOutputListenerInstalled: Bool = false

    init() {
        let frequencies = EqualizerSettings.bandFrequenciesHz.map(Float.init)
        self.bandFrequencies = frequencies
        self.eq = AVAudioUnitEQ(numberOfBands: frequencies.count)
        configureBands()
    }

    deinit {
        if defaultOutputListenerInstalled {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                Self.staticDefaultOutputListenerBlock
            )
        }
        if engine.isRunning { engine.stop() }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - Public API

    /// Starts the EQ pipeline. Idempotent: returns immediately if already running.
    /// Errors are stored in ``lastError`` and re-thrown so callers can decide whether
    /// to fall back (e.g. revert the enable toggle).
    func start() throws {
        guard !isRunning else { return }
        do {
            try setupTapAndAggregate()
            try setupEngine()
            try engine.start()
            installDefaultOutputListener()
            isRunning = true
            lastError = nil
        } catch let error as AudioEqualizerEngineError {
            teardownEngine()
            teardownTapAndAggregate()
            lastError = error.errorDescription
            throw error
        } catch {
            teardownEngine()
            teardownTapAndAggregate()
            let wrapped = AudioEqualizerEngineError.couldNotStartEngine(error.localizedDescription)
            lastError = wrapped.errorDescription
            throw wrapped
        }
    }

    /// Stops the EQ pipeline and releases the tap + aggregate device. Safe to call
    /// when not running.
    func stop() {
        guard isRunning else { return }
        teardownEngine()
        teardownTapAndAggregate()
        isRunning = false
    }

    /// Live-mutates the dB gain of a single band. No-op if `index` is out of range.
    func setBandGain(_ index: Int, dB: Float) {
        guard index >= 0, index < eq.bands.count else { return }
        eq.bands[index].gain = dB
    }

    /// Live-mutates `globalGain` (used as a pre-amp for clipping headroom).
    func setPreamp(dB: Float) {
        eq.globalGain = dB
    }

    /// Applies a full settings snapshot at once (gains, preamp, enable/disable).
    func apply(settings: EqualizerSettings) {
        for (index, value) in settings.bands.enumerated() where index < eq.bands.count {
            eq.bands[index].gain = Float(value)
        }
        eq.globalGain = Float(settings.preamp)
    }

    // MARK: - Setup

    private func configureBands() {
        for (index, frequency) in bandFrequencies.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        eq.globalGain = 0
    }

    private func setupTapAndAggregate() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let processObjectID = try Self.audioProcessObjectID(forPID: pid)
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "Spotiglass Equalizer Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let createTap = AudioHardwareCreateProcessTap(description, &newTap)
        guard createTap == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEqualizerEngineError.couldNotCreateTap(createTap)
        }
        tapID = newTap

        // Anchor the aggregate to the current default output as its main sub-device so
        // the HAL has a stable clock reference; AVAudioEngine reads the tap as input
        // and outputs separately to the default output (we never write back to the
        // aggregate, so this sub-device is purely the master clock).
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Spotiglass Equalizer Aggregate",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID as String],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                ],
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let createAggregate = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregate)
        guard createAggregate == noErr, newAggregate != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEqualizerEngineError.couldNotCreateAggregateDevice(createAggregate)
        }
        aggregateDeviceID = newAggregate
    }

    private func setupEngine() throws {
        guard let inputAudioUnit = engine.inputNode.audioUnit else {
            throw AudioEqualizerEngineError.couldNotConfigureInputDevice(-1)
        }
        var deviceID = aggregateDeviceID
        let status = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw AudioEqualizerEngineError.couldNotConfigureInputDevice(status)
        }

        engine.attach(eq)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: inputFormat)
        engine.prepare()
    }

    private func teardownEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.disconnectNodeInput(eq)
        engine.detach(eq)
        // Re-attach EQ for next start so configure remains valid.
        engine.attach(eq)
    }

    private func teardownTapAndAggregate() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Default output device tracking

    private func installDefaultOutputListener() {
        guard !defaultOutputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            Self.staticDefaultOutputListenerBlock
        )
        if status == noErr {
            defaultOutputListenerInstalled = true
        }
    }

    /// Static block so we can register/unregister the same closure object. The handler
    /// itself is a no-op: ``AVAudioEngine``'s output node tracks the system default
    /// device automatically; we keep the listener for diagnostics and to give the
    /// engine an opportunity to react if Apple changes that behavior. Marked
    /// `nonisolated` so `deinit` can reference it without crossing actor boundaries.
    nonisolated(unsafe) private static let staticDefaultOutputListenerBlock: AudioObjectPropertyListenerBlock = { _, _ in }

    // MARK: - HAL helpers

    private static func audioProcessObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEqualizerEngineError.couldNotResolveOwnProcessObject(status)
        }
        return processObjectID
    }

    private static func defaultOutputDeviceUID() throws -> CFString {
        var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let defaultStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &defaultSize,
            &defaultDeviceID
        )
        guard defaultStatus == noErr, defaultDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEqualizerEngineError.couldNotReadTapUID(defaultStatus)
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(defaultDeviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard uidStatus == noErr else {
            throw AudioEqualizerEngineError.couldNotReadTapUID(uidStatus)
        }
        return uid
    }
}
