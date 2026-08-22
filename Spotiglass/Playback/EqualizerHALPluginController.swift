import CoreAudio
import Foundation

protocol EqualizerSampleRateProviding: AnyObject {
    var activeSampleRate: UInt32 { get }
    var activeSampleRateDidChange: ((UInt32) -> Void)? { get set }
}

/// Owns the lifecycle of the bundled `SpotiglassEQDriver.driver` CoreAudio
/// AudioServerPlugIn. Responsibilities:
///
/// - Copy the `.driver` bundle from inside `Spotiglass.app` into
///   `~/Library/Audio/Plug-Ins/HAL/` on first enable.
/// - Surface (but never run) the `launchctl kickstart -k system/com.apple.audio.coreaudiod`
///   activation step.
/// - Switch the system default output device to "Spotiglass EQ" on enable.
/// - Restore the previously-active default output on disable.
/// - Uninstall (remove the `.driver` from disk) on user request.
///
/// **No microphone / recording permission is ever needed.** The driver is a
/// pure virtual output device; this controller only ever queries / sets the
/// default OUTPUT device, never input.
final class EqualizerHALPluginController: @unchecked Sendable, EqualizerSampleRateProviding {
    /// System-scope HAL plugins directory.
    ///
    /// macOS 26's `coreaudiod` scans only `/Library/Audio/Plug-Ins/HAL/`; the
    /// older user-scope path (`~/Library/Audio/Plug-Ins/HAL/`) is no longer
    /// loaded. Installing here therefore requires `sudo` from the user — the
    /// controller writes the path into a staging area and surfaces the copy +
    /// coreaudiod kickstart commands rather than running them itself.
    nonisolated static var defaultHALDirectory: URL {
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    }

    /// Staging directory inside the user's home where the controller copies
    /// the embedded driver before prompting the user to move it system-scope.
    /// This keeps the GUI process sudo-free while making it trivial for the
    /// user to finish the install with a single `sudo cp -R` command.
    nonisolated static var stagingDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Spotiglass", isDirectory: true)
            .appendingPathComponent("staged-driver", isDirectory: true)
    }

    /// Bundle identifier of the embedded `.driver`. Must match the
    /// AudioServerPlugIn `Info.plist` key.
    nonisolated static let driverBundleID = "com.isaaclins.spotiglass.eqdriver"
    nonisolated static let driverBundleName = "SpotiglassEQDriver.driver"
    nonisolated static let virtualDeviceName = "Spotiglass EQ"

    /// Where to look for the bundled `.driver` inside the host app. Searches
    /// `Contents/Library/Audio/Plug-Ins/HAL/<name>.driver` first, then falls
    /// back to `Contents/Resources/` for a Debug-build layout.
    private let halDirectory: URL
    private let embeddedDriverURL: URL?
    private let fileManager: FileManager
    private var activeSampleRateListener: AudioObjectPropertyListenerBlock?
    private var observedSampleRateDeviceID: AudioObjectID?

    /// AudioObjectID of the device we routed away from when enabling.
    /// Persisted on disk via ``defaultOutputBackupURL`` so disable restores
    /// the original even after a process restart.
    private(set) var previousDefaultOutputID: AudioObjectID?
    /// Cache of the active sample rate the plugin is currently advertising,
    /// used by the coefficient publisher to recompute biquads on rate change.
    private(set) var activeSampleRate: UInt32 = 48_000
    var activeSampleRateDidChange: ((UInt32) -> Void)?

    init(
        halDirectory: URL = EqualizerHALPluginController.defaultHALDirectory,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) {
        self.halDirectory = halDirectory
        self.fileManager = fileManager
        self.embeddedDriverURL = Self.locateEmbeddedDriver(in: bundle)
    }

    deinit {
        removeActiveSampleRateObservation()
    }

    // MARK: - Public API

    /// Pure install step. Copies the embedded `.driver` into the HAL directory
    /// if it isn't already there. Used by ``enable()`` and exposed separately
    /// so tests can exercise just the file-copy side-effect without touching
    /// the system default output device. NEVER asks for microphone permission.
    func install() throws {
        try installIfNeeded()
    }

    /// On first enable, installs the `.driver` (if not already in the HAL
    /// directory) and routes the system default output to the Spotiglass
    /// virtual device. Throws if the bundled driver is missing or the file
    /// copy / device lookup fails. NEVER asks for microphone permission.
    ///
    /// `preferredForwardingUID` lets the caller pin the EQRouter's forwarding
    /// target to a previously-saved device UID, which is what makes the
    /// Settings → "Send EQ'd audio to" picker survive a disable→enable cycle.
    /// When nil, falls back to the previous default output (or the built-in
    /// speaker if that would loop Spotiglass EQ back to itself).
    func enable(preferredForwardingUID: String? = nil) throws {
        try installIfNeeded()
        if let deviceID = lookupSpotiglassEQDeviceID() {
            try captureCurrentDefaultOutput()
            // Always write the forwarding target so the driver's EQRouter has
            // somewhere to send the EQ'd audio. The previous default's UID is
            // only relevant when it isn't Spotiglass EQ itself (otherwise the
            // EQ would route to itself and recurse forever).
            let previousUID = previousDefaultOutputID.flatMap { previous -> String? in
                previous == deviceID ? nil : AudioDeviceEnumerator.uid(of: previous)
            }
            let targetUID = Self.resolveForwardingTargetUID(
                preferred: preferredForwardingUID,
                previousUID: previousUID
            )
            Self.writeForwardingTarget(uid: targetUID)
            try beginActiveSampleRateObservation(for: deviceID)
            do {
                try setDefaultOutputDevice(to: deviceID)
            } catch {
                removeActiveSampleRateObservation()
                throw error
            }
        } else {
            throw EqualizerHALPluginError.driverNotLoadedYet(
                installedPath: installedDriverURL.path
            )
        }
    }

    /// Fallback UID for the EQRouter's forwarding target when we don't have
    /// a captured previous default (or when the captured "previous" is the
    /// EQ device itself). MacBook's internal speaker UID is the safest
    /// default — every Mac has one and it's the most likely intent.
    nonisolated static let fallbackForwardingUID = "BuiltInSpeakerDevice"

    /// Restores the previously-active default output device. Does NOT remove
    /// the `.driver` from disk — call ``uninstall()`` for that.
    func disable() {
        removeActiveSampleRateObservation()
        guard let previous = previousDefaultOutputID else { return }
        try? setDefaultOutputDevice(to: previous)
        previousDefaultOutputID = nil
        // Forget the forwarding target so the next enable() captures a fresh
        // pre-EQ default (in case the user changed it in the meantime).
        Self.clearForwardingTarget()
    }

    /// Path of the one-shot file the C++ driver reads in StartIO to learn
    /// which real hardware output to forward EQ-processed audio to. Fixed
    /// path with no uid suffix: the Swift host writes as the logged-in user,
    /// the driver reads from inside coreaudiod where `getuid()` returns
    /// `_coreaudiod`'s uid (202), so a shared path side-steps that mismatch.
    nonisolated static var forwardingTargetURL: URL {
        URL(fileURLWithPath: "/tmp/com.isaaclins.spotiglass.eq.target")
    }

    /// Pure precedence rule for the EQRouter's forwarding target: an
    /// explicitly-persisted user pick wins; otherwise we restore the previous
    /// default output's UID; otherwise we fall back to the built-in speaker.
    /// Lifted out of `enable()` so tests can exercise the precedence without
    /// needing a loaded HAL driver in the test process.
    nonisolated static func resolveForwardingTargetUID(
        preferred: String?,
        previousUID: String?
    ) -> String {
        if let preferred = preferred, !preferred.isEmpty {
            return preferred
        }
        if let previousUID = previousUID, !previousUID.isEmpty {
            return previousUID
        }
        return fallbackForwardingUID
    }

    static func writeForwardingTarget(uid: String) {
        let url = forwardingTargetURL
        try? (uid + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func clearForwardingTarget() {
        try? FileManager.default.removeItem(at: forwardingTargetURL)
    }

    /// Public entry point for changing where EQ-processed audio is sent
    /// while the EQ is engaged. Writes the new target UID; the driver's
    /// background watcher picks it up within ~250 ms and atomically swaps
    /// the open `AudioDeviceIOProc` to the new device. Pass an empty string
    /// or nil-equivalent to fall back to ``fallbackForwardingUID``.
    func setForwardingTarget(uid: String) {
        let resolved = uid.isEmpty ? Self.fallbackForwardingUID : uid
        Self.writeForwardingTarget(uid: resolved)
    }

    /// Enumerates output-only devices the user can plausibly route EQ'd
    /// audio TO. Excludes Spotiglass EQ itself (would recurse) and any
    /// input-only devices. Used by the Settings UI dropdown.
    func availableForwardingTargets() -> [AudioDeviceEnumerator.Device] {
        AudioDeviceEnumerator.allOutputDevices()
            .filter { $0.name != Self.virtualDeviceName }
            .filter { AudioDeviceEnumerator.supportsEQForwarding(deviceID: $0.id) }
    }

    /// The UID currently written to the forwarding-target file. Reads
    /// it back from disk (driver's source of truth) so the picker stays
    /// in sync with whatever EQRouter is actually forwarding to.
    func currentForwardingTargetUID() -> String? {
        guard let data = try? String(
            contentsOf: Self.forwardingTargetURL,
            encoding: .utf8
        ) else { return nil }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes the bundled `.driver` from `~/Library/Audio/Plug-Ins/HAL/`.
    /// coreaudiod will keep the device visible until it next reloads its HAL
    /// directory (kickstart or log-out/in).
    func uninstall() throws {
        let url = installedDriverURL
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: installedDriverURL.path)
    }

    var installedDriverURL: URL {
        halDirectory.appendingPathComponent(Self.driverBundleName, isDirectory: true)
    }

    // MARK: - Install internals

    private func installIfNeeded() throws {
        let destination = installedDriverURL
        // If a copy already exists in the HAL directory, trust it. The system
        // scope (/Library/Audio/Plug-Ins/HAL) is root-owned on macOS 26, so the
        // unprivileged app process cannot replace it anyway; the install must
        // happen out-of-band via `sudo cp -pR`. Re-running the copy with a
        // writable temp dir is still useful for tests, which is what the
        // create-if-missing branch below covers.
        if fileManager.fileExists(atPath: destination.path) {
            return
        }
        guard let source = embeddedDriverURL else {
            throw EqualizerHALPluginError.embeddedDriverMissing
        }
        do {
            if !fileManager.fileExists(atPath: halDirectory.path) {
                try fileManager.createDirectory(at: halDirectory, withIntermediateDirectories: true)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            // App-scope process cannot write to /Library/Audio/Plug-Ins/HAL.
            // Stage the bundle in user-scope and surface a one-shot sudo install
            // command via ``requiresSudoInstall`` so the UI can render it.
            let staged = try stageEmbeddedDriver(from: source)
            throw EqualizerHALPluginError.requiresSudoInstall(
                stagedPath: staged.path,
                destinationPath: destination.path
            )
        }
    }

    private func stageEmbeddedDriver(from source: URL) throws -> URL {
        let stagedBundle = Self.stagingDirectory
            .appendingPathComponent(Self.driverBundleName, isDirectory: true)
        try? fileManager.removeItem(at: stagedBundle)
        try fileManager.createDirectory(
            at: Self.stagingDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: stagedBundle)
        return stagedBundle
    }

    private static func locateEmbeddedDriver(in bundle: Bundle) -> URL? {
        let candidates = [
            bundle.bundleURL
                .appendingPathComponent("Contents/Library/Audio/Plug-Ins/HAL", isDirectory: true)
                .appendingPathComponent(driverBundleName, isDirectory: true),
            bundle.resourceURL?
                .appendingPathComponent(driverBundleName, isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Sample-rate observation

    @discardableResult
    func updateActiveSampleRate(nominalRate: Double) -> Bool {
        guard let rate = normalizedSampleRate(nominalRate), rate != activeSampleRate else {
            return false
        }
        activeSampleRate = rate
        activeSampleRateDidChange?(rate)
        return true
    }

    private func beginActiveSampleRateObservation(for deviceID: AudioObjectID) throws {
        removeActiveSampleRateObservation()
        guard let nominalRate = readNominalSampleRate(from: deviceID),
              let rate = normalizedSampleRate(nominalRate)
        else {
            throw EqualizerHALPluginError.coreAudioStatus(
                kAudioHardwareUnknownPropertyError
            )
        }
        activeSampleRate = rate

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshActiveSampleRate(for: deviceID)
        }
        observedSampleRateDeviceID = deviceID
        activeSampleRateListener = listener
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            listener
        )
        guard status == noErr else {
            removeActiveSampleRateObservation()
            throw EqualizerHALPluginError.coreAudioStatus(status)
        }
    }

    private func removeActiveSampleRateObservation() {
        guard let listener = activeSampleRateListener,
              let deviceID = observedSampleRateDeviceID
        else {
            activeSampleRateListener = nil
            observedSampleRateDeviceID = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        activeSampleRateListener = nil
        observedSampleRateDeviceID = nil
    }

    private func refreshActiveSampleRate(for deviceID: AudioObjectID) {
        guard let nominalRate = readNominalSampleRate(from: deviceID) else { return }
        _ = updateActiveSampleRate(nominalRate: nominalRate)
    }

    private func normalizedSampleRate(_ nominalRate: Double) -> UInt32? {
        guard nominalRate.isFinite,
              nominalRate > 0,
              nominalRate <= Double(UInt32.max)
        else { return nil }
        let rate = UInt32(nominalRate.rounded())
        return rate > 0 ? rate : nil
    }

    private func readNominalSampleRate(from deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &rate
        )
        guard status == noErr, size == MemoryLayout<Float64>.size else { return nil }
        return rate
    }

    // MARK: - Device-routing internals

    /// Returns the AudioObjectID for the Spotiglass EQ virtual device, or nil
    /// if coreaudiod hasn't picked up the new `.driver` yet.
    func lookupSpotiglassEQDeviceID() -> AudioObjectID? {
        AudioDeviceEnumerator.allOutputDevices().first { device in
            device.name == Self.virtualDeviceName
        }?.id
    }

    private func captureCurrentDefaultOutput() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw EqualizerHALPluginError.coreAudioStatus(status)
        }
        previousDefaultOutputID = deviceID
    }

    func setDefaultOutputDevice(to deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &id
        )
        guard status == noErr else {
            throw EqualizerHALPluginError.coreAudioStatus(status)
        }
    }
}

enum EqualizerHALPluginError: LocalizedError {
    case embeddedDriverMissing
    case driverNotLoadedYet(installedPath: String)
    case coreAudioStatus(OSStatus)
    case requiresSudoInstall(stagedPath: String, destinationPath: String)

    // These reach the user: EqualizerSettingsView assigns localizedDescription
    // to lastError and to the save sheet. So they are sentences from the
    // catalog, and the OSStatus, the bundle name and the paths live in
    // diagnosticDetails instead (#186).
    var errorDescription: String? {
        switch self {
        case .embeddedDriverMissing:
            return SpotiglassL10n.string("eq.error.embeddedDriverMissing")
        case .driverNotLoadedYet:
            return SpotiglassL10n.string("eq.error.driverNotLoadedYet")
        case .coreAudioStatus:
            return SpotiglassL10n.string("eq.error.coreAudioStatus")
        case let .requiresSudoInstall(staged, destination):
            // The commands stay in the sentence, because running them is the
            // action being asked for.
            return SpotiglassL10n.format(
                "eq.error.requiresSudoInstall",
                Self.installCommands(staged: staged, destination: destination)
            )
        }
    }

    /// Paths, status codes and bundle names, for a bug report rather than for
    /// the sentence a listener reads.
    var diagnosticDetails: String? {
        switch self {
        case .embeddedDriverMissing:
            return "missing bundle: SpotiglassEQDriver.driver"
        case let .driverNotLoadedYet(installedPath):
            return """
                installed driver: \(installedPath)
                coreaudiod has not picked it up yet; a one-time activation, which \
                Spotiglass never performs for you:
                  sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
                """
        case let .coreAudioStatus(status):
            return "CoreAudio OSStatus \(status) while routing the default output device"
        case let .requiresSudoInstall(staged, destination):
            return "staged: \(staged)\ndestination: \(destination)"
        }
    }

    private static func installCommands(staged: String, destination: String) -> String {
        let folder = destination.replacingOccurrences(
            of: "/SpotiglassEQDriver.driver",
            with: "/"
        )
        return """
              sudo cp -pR "\(staged)" "\(folder)"
              sudo killall coreaudiod
            """
    }
}

/// Lightweight AudioObject enumerator used by the controller. Only enumerates
/// OUTPUT devices — never queries input scope, never asks for microphone
/// permission.
enum AudioDeviceEnumerator {
    struct Device: Equatable, Hashable {
        let id: AudioObjectID
        let name: String
        let uid: String
    }

    static func allOutputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids.compactMap { id -> Device? in
            guard hasOutputStream(deviceID: id) else { return nil }
            guard let deviceUID = uid(of: id) else { return nil }
            return Device(id: id, name: deviceName(id: id), uid: deviceUID)
        }
    }

    private static func hasOutputStream(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    static func supportsEQForwarding(format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 2,
              format.mFramesPerPacket == 1
        else { return false }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame: UInt32 = nonInterleaved ? 4 : 8
        return format.mBytesPerFrame == bytesPerFrame
            && format.mBytesPerPacket == bytesPerFrame
    }

    static func supportsEQForwarding(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &format
        )
        guard status == noErr, size == MemoryLayout<AudioStreamBasicDescription>.size else {
            return false
        }
        return supportsEQForwarding(format: format)
    }

    private static func deviceName(id: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw)
        guard status == noErr, let raw else { return "" }
        return raw.takeRetainedValue() as String
    }

    /// Returns the persistent device UID for an AudioObjectID. The EQ
    /// driver uses this UID to re-resolve the device inside coreaudiod and
    /// open its output IOProc for forwarding.
    static func uid(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw)
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }
}
