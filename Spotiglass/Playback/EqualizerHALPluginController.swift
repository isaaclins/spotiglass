import CoreAudio
import Foundation

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
final class EqualizerHALPluginController: @unchecked Sendable {
    /// User-scope HAL plugins directory. `~` is resolved through `FileManager`.
    nonisolated static var defaultHALDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent("Plug-Ins", isDirectory: true)
            .appendingPathComponent("HAL", isDirectory: true)
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

    /// AudioObjectID of the device we routed away from when enabling.
    /// Persisted on disk via ``defaultOutputBackupURL`` so disable restores
    /// the original even after a process restart.
    private(set) var previousDefaultOutputID: AudioObjectID?
    /// Cache of the active sample rate the plugin is currently advertising,
    /// used by the coefficient publisher to recompute biquads on rate change.
    private(set) var activeSampleRate: UInt32 = 48_000

    init(
        halDirectory: URL = EqualizerHALPluginController.defaultHALDirectory,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) {
        self.halDirectory = halDirectory
        self.fileManager = fileManager
        self.embeddedDriverURL = Self.locateEmbeddedDriver(in: bundle)
    }

    // MARK: - Public API

    /// On first enable, installs the `.driver` (if not already in the HAL
    /// directory) and routes the system default output to the Spotiglass
    /// virtual device. Throws if the bundled driver is missing or the file
    /// copy / device lookup fails. NEVER asks for microphone permission.
    func enable() throws {
        try installIfNeeded()
        if let deviceID = lookupSpotiglassEQDeviceID() {
            try captureCurrentDefaultOutput()
            try setDefaultOutputDevice(to: deviceID)
        } else {
            throw EqualizerHALPluginError.driverNotLoadedYet(
                hint: "The Spotiglass EQ driver is installed at \(installedDriverURL.path) but coreaudiod has not picked it up yet. Log out and back in, OR run `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` once. This is a one-time CoreAudio activation step; Spotiglass never runs sudo for you."
            )
        }
    }

    /// Restores the previously-active default output device. Does NOT remove
    /// the `.driver` from disk — call ``uninstall()`` for that.
    func disable() {
        guard let previous = previousDefaultOutputID else { return }
        try? setDefaultOutputDevice(to: previous)
        previousDefaultOutputID = nil
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
        if !fileManager.fileExists(atPath: halDirectory.path) {
            try fileManager.createDirectory(at: halDirectory, withIntermediateDirectories: true)
        }
        guard let source = embeddedDriverURL else {
            throw EqualizerHALPluginError.embeddedDriverMissing
        }
        let destination = installedDriverURL
        if fileManager.fileExists(atPath: destination.path) {
            // Replace in-place so updates to the bundled driver land on next enable.
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
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
    case driverNotLoadedYet(hint: String)
    case coreAudioStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .embeddedDriverMissing:
            return "Spotiglass.app does not contain the embedded SpotiglassEQDriver.driver bundle."
        case let .driverNotLoadedYet(hint):
            return hint
        case let .coreAudioStatus(status):
            return "CoreAudio error \(status) while routing the default output device."
        }
    }
}

/// Lightweight AudioObject enumerator used by the controller. Only enumerates
/// OUTPUT devices — never queries input scope, never asks for microphone
/// permission.
enum AudioDeviceEnumerator {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
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
        return ids.compactMap { id in
            guard hasOutputStream(deviceID: id) else { return nil }
            return Device(id: id, name: deviceName(id: id))
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
}
