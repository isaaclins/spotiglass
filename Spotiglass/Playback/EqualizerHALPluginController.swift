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
    func enable() throws {
        try installIfNeeded()
        if let deviceID = lookupSpotiglassEQDeviceID() {
            try captureCurrentDefaultOutput()
            // Always write the forwarding target so the driver's EQRouter has
            // somewhere to send the EQ'd audio. If the previous default was
            // already Spotiglass EQ (e.g., EQ was already enabled, user
            // toggled off then on without changing default elsewhere), fall
            // back to the system's built-in speaker UID, since picking
            // Spotiglass EQ as its own forwarding target would recurse
            // forever.
            let targetUID: String? = {
                if let previous = previousDefaultOutputID,
                   previous != deviceID,
                   let uid = AudioDeviceEnumerator.uid(of: previous) {
                    return uid
                }
                return Self.fallbackForwardingUID
            }()
            if let uid = targetUID {
                Self.writeForwardingTarget(uid: uid)
            }
            try setDefaultOutputDevice(to: deviceID)
        } else {
            throw EqualizerHALPluginError.driverNotLoadedYet(
                hint: "The Spotiglass EQ driver is installed at \(installedDriverURL.path) but coreaudiod has not picked it up yet. Log out and back in, OR run `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` once. This is a one-time CoreAudio activation step; Spotiglass never runs sudo for you."
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

    private static func writeForwardingTarget(uid: String) {
        let url = forwardingTargetURL
        try? (uid + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func clearForwardingTarget() {
        try? FileManager.default.removeItem(at: forwardingTargetURL)
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
    case requiresSudoInstall(stagedPath: String, destinationPath: String)

    var errorDescription: String? {
        switch self {
        case .embeddedDriverMissing:
            return "Spotiglass.app does not contain the embedded SpotiglassEQDriver.driver bundle."
        case let .driverNotLoadedYet(hint):
            return hint
        case let .coreAudioStatus(status):
            return "CoreAudio error \(status) while routing the default output device."
        case let .requiresSudoInstall(staged, destination):
            return """
                Spotiglass cannot install the EQ driver itself — macOS 26's coreaudiod only loads HAL plugins from /Library/Audio/Plug-Ins/HAL/, which is root-owned. The driver has been staged at:
                  \(staged)
                To finish the install, open Terminal and run:
                  sudo cp -pR "\(staged)" "\(destination.replacingOccurrences(of: "/SpotiglassEQDriver.driver", with: "/"))"
                  sudo killall coreaudiod
                Then re-enable the EQ.
                """
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
