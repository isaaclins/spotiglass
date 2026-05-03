import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// Errors raised by ``AudioEqualizerEngine`` while standing up the Core Audio graph.
///
/// Each case carries the underlying ``OSStatus`` (when applicable) so the surfaced
/// error message in the Settings UI can include the raw HAL/AU code.
enum AudioEqualizerEngineError: LocalizedError, Equatable {
    case macOSVersionUnsupported
    case noTapTargets
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
        case .noTapTargets:
            return "Could not resolve any Core Audio process objects for Spotiglass or its helper processes."
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
/// 4. Mutating any band's `gain`/`bypass`, the unit's ``AVAudioNode/bypass``, or `globalGain` is
///    live: parameter changes take effect on the next render quantum without a graph restart.
///
/// EME / DRM is not bypassed: only the audio that this process already plays back is
/// captured for re-routing through the EQ, and the original output is muted at the
/// device level via the tap so the user only hears the processed copy.
@MainActor
final class AudioEqualizerEngine: ObservableObject {
#if DEBUG
    private static let logger = Logger(subsystem: AppMetadata.bundleIdentifier, category: "AudioEqualizerEngine")
#endif

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
#if DEBUG
            print("[EqualizerEngine] eq.bypass immediately after engine.start(): \(eq.bypass)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                print("[EqualizerEngine] eq.bypass 2s after engine.start(): \(self.eq.bypass)")
            }
#endif
            ensureEQProcessingActive()
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

    /// Tears down and recreates the tap/aggregate/engine graph so PIDs that spawned
    /// after the first start (e.g. WKWebView WebContent processes) are included.
    func restart(with settings: EqualizerSettings) {
        guard settings.enabled else { return }
        if isRunning {
            stop()
        }
        do {
            try start()
            apply(settings: settings)
            lastError = nil
        } catch {
            // `start()` surfaces HAL failures via `lastError`.
        }
    }

    /// Live-mutates the dB gain of a single band. No-op if `index` is out of range.
    func setBandGain(_ index: Int, dB: Float) {
        guard index >= 0, index < eq.bands.count else { return }
        ensureEQProcessingActive()
        eq.bands[index].gain = dB
    }

    /// Live-mutates `globalGain` (used as a pre-amp for clipping headroom).
    func setPreamp(dB: Float) {
        ensureEQProcessingActive()
        eq.globalGain = dB
    }

    /// Applies a full settings snapshot at once (gains, preamp, enable/disable).
    func apply(settings: EqualizerSettings) {
        ensureEQProcessingActive()
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
        eq.bypass = false
    }

    /// `AVAudioUnitEQ` inherits ``AVAudioNode/bypass`` from ``AVAudioUnitEffect``. When that is
    /// `true`, the unit passes input through unchanged, so per-band `gain` has no timbral effect.
    /// Attaching to ``AVAudioEngine`` or restarting the engine can restore defaults; keep both the
    /// node and each band off bypass whenever we run the graph or push parameters.
    private func ensureEQProcessingActive() {
        eq.bypass = false
        for band in eq.bands {
            band.bypass = false
        }
    }

    private func setupTapAndAggregate() throws {
        let audioObjectIDs = ProcessAudioTapResolver.audioObjectIDsForSpotiglassProcessTree()
        guard !audioObjectIDs.isEmpty else {
            throw AudioEqualizerEngineError.noTapTargets
        }
#if DEBUG
        Self.logger.debug(
            "EQ process tap: \(audioObjectIDs.count) Core Audio process object(s) (Spotiglass + WebKit helpers)"
        )
#endif
        let description = CATapDescription(stereoMixdownOfProcesses: audioObjectIDs)
        description.name = "Spotiglass Equalizer Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let createTap = AudioHardwareCreateProcessTap(description, &newTap)
#if DEBUG
        print(
            "[EqualizerTap] AudioHardwareCreateProcessTap OSStatus=\(createTap) \(Self.describeOSStatus(createTap)) assignedTapObjectID=\(newTap)"
        )
#endif
        guard createTap == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEqualizerEngineError.couldNotCreateTap(createTap)
        }
        tapID = newTap

        // Anchor the aggregate to the current default output as its main sub-device so
        // the HAL has a stable clock reference; AVAudioEngine reads the tap as input
        // and outputs separately to the default output (we never write back to the
        // aggregate, so this sub-device is purely the master clock).
        let outputUID = try Self.defaultOutputDeviceUID()
        // Aggregate wiring must reference the tap UID assigned by Core Audio (readable via
        // kAudioTapPropertyUID); never assume `CATapDescription.uuid` matches after creation.
        let tapUIDForAggregate = try Self.copyTapUIDString(tapObjectID: newTap)

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
                    kAudioSubTapUIDKey as String: tapUIDForAggregate,
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

        engine.reset()

        engine.attach(eq)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
#if DEBUG
        print(
            "[EqualizerEngine] inputNode.outputFormat(forBus: 0) after aggregate bind: sampleRate=\(inputFormat.sampleRate) channelCount=\(inputFormat.channelCount) isInvalid=\(inputFormat.sampleRate == 0 || inputFormat.channelCount == 0)"
        )
#endif
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            engine.detach(eq)
            throw AudioEqualizerEngineError.couldNotStartEngine(
                "Equalizer input format is invalid after binding the aggregate device."
            )
        }

        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        let eqOutputFormat = eq.outputFormat(forBus: 0)
        engine.connect(eq, to: engine.mainMixerNode, format: eqOutputFormat)

        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mixerOutputFormat)

        ensureEQProcessingActive()

        engine.prepare()
    }

    private func teardownEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeInput(engine.outputNode)
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.disconnectNodeInput(eq)
        engine.detach(eq)
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

#if DEBUG
    private static func describeOSStatus(_ status: OSStatus) -> String {
        if status == noErr { return "(noErr)" }
        let u = UInt32(bitPattern: status)
        let b0 = UInt8(truncatingIfNeeded: (u >> 24) & 0xff)
        let b1 = UInt8(truncatingIfNeeded: (u >> 16) & 0xff)
        let b2 = UInt8(truncatingIfNeeded: (u >> 8) & 0xff)
        let b3 = UInt8(truncatingIfNeeded: u & 0xff)
        let bytes = [b0, b1, b2, b3]
        let fourCC = String(bytes: bytes, encoding: .ascii).map { "'\($0)'" } ?? "'????'"
        return "(non-zero; fourCC=\(fourCC) hex=0x\(String(u, radix: 16)))"
    }
#endif

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

    /// HAL-assigned tap UID string for ``kAudioSubTapUIDKey`` (must match ``kAudioTapPropertyUID``).
    private static func copyTapUIDString(tapObjectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(tapObjectID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            throw AudioEqualizerEngineError.couldNotReadTapUID(sizeStatus)
        }
        var cfUID: CFString = "" as CFString
        let copyStatus = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &dataSize, pointer)
        }
        guard copyStatus == noErr else {
            throw AudioEqualizerEngineError.couldNotReadTapUID(copyStatus)
        }
        return cfUID as String
    }
}
