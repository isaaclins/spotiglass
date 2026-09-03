import Foundation
import ServiceManagement

protocol EqualizerDriverInstalling {
    func installDriver(sourceURL: URL, destinationURL: URL) throws
}

@objc protocol EqualizerPrivilegedHelperProtocol {
    func installDriver(
        from sourcePath: String,
        to destinationPath: String,
        withReply reply: @escaping (NSDictionary) -> Void
    )
}

/// Registers and talks to the root LaunchDaemon that owns the system HAL path.
/// The app only sends paths inside its own signed bundle; the helper validates
/// those paths again before it performs any privileged filesystem operation.
final class EqualizerPrivilegedHelperClient: @unchecked Sendable, EqualizerDriverInstalling {
    private let bundle: Bundle
    private let fileManager: FileManager
    private let service: SMAppService

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        service: SMAppService? = nil
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.service =
            service
            ?? SMAppService.daemon(
                plistName: EqualizerPrivilegedHelperIdentity.plistName
            )
    }

    func installDriver(sourceURL: URL, destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard isBundledDriverURL(source), destination == installedDriverURL else {
            throw EqualizerDriverInstallError.invalidRequest
        }

        try ensureRegistered()
        try awaitEnabledService()
        do {
            try requestInstall(sourceURL: source, destinationURL: destination)
        } catch let error as EqualizerDriverInstallError {
            // The helper answered badly or not at all. Re-registering is only
            // worth it when the running helper is a different build from the
            // one this app ships, and only while the registration is approved:
            // unregistering an unapproved service throws its approval away and
            // the next register needs the user again.
            guard shouldRetryAfter(error),
                !helperVersionMarkerMatches(),
                service.status == .enabled
            else { throw error }
            try reRegister()
            try awaitEnabledService()
            try requestInstall(sourceURL: source, destinationURL: destination)
        }
        writeHelperVersionMarker()
    }

    private var installedDriverURL: URL {
        EqualizerPrivilegedHelperIdentity.systemHALDirectory
            .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true)
    }

    private func isBundledDriverURL(_ sourceURL: URL) -> Bool {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        let candidates = [
            bundleURL
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverRelativePath, isDirectory: true)
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true),
            bundleURL
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.resourceDriverRelativePath, isDirectory: true)
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true),
        ]
        return candidates.contains(sourceURL)
    }

    private func ensureRegistered() throws {
        switch service.status {
        // An approved registration is left alone. Re-registering an enabled
        // daemon means unregister plus register, and the register half needs
        // the user's approval again, so doing it speculatively (on a version
        // marker that is only written after a successful install) left the
        // first enable stuck in a loop it could never leave. A stale helper is
        // detected from the failed request instead, where it is real.
        case .enabled:
            return
        // A daemon that has never been registered reports `.notFound`, not
        // `.notRegistered`, so treating it as fatal meant the very first enable
        // could never install anything. Registration itself reports the real
        // reason if the plist genuinely cannot be used.
        case .notRegistered, .requiresApproval, .notFound:
            try register()
        @unknown default:
            throw EqualizerDriverInstallError.registrationFailed(status: service.status.rawValue)
        }
    }

    /// `register()` returns before launchd has the daemon up, and a service
    /// still waiting on the user's approval never comes up at all. Connecting
    /// in either state fails in a way indistinguishable from a broken helper,
    /// which previously drove a pointless re-registration.
    private func awaitEnabledService(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while service.status != .enabled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard service.status == .enabled else {
            throw EqualizerDriverInstallError.registrationFailed(status: service.status.rawValue)
        }
    }

    private func register() throws {
        do {
            try service.register()
        } catch {
            throw EqualizerDriverInstallError.registrationFailed(
                status: (error as NSError).code
            )
        }
    }

    private func reRegister() throws {
        do {
            try service.unregister()
        } catch {
            throw EqualizerDriverInstallError.unregistrationFailed(
                status: (error as NSError).code
            )
        }
        try register()
    }

    private func shouldRetryAfter(_ error: EqualizerDriverInstallError) -> Bool {
        switch error {
        case .helperUnavailable, .invalidReply:
            true
        case .registrationFailed,
            .unregistrationFailed,
            .helperRejected,
            .helperOperationFailed,
            .invalidRequest:
            false
        }
    }

    private struct ReplyTransportError: Error {
        let message: String
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<NSDictionary, ReplyTransportError>?

        func store(_ result: Result<NSDictionary, ReplyTransportError>) {
            lock.lock()
            if self.result == nil {
                self.result = result
            }
            lock.unlock()
        }

        func load() -> Result<NSDictionary, ReplyTransportError>? {
            lock.lock()
            let result = self.result
            lock.unlock()
            return result
        }
    }

    private func requestInstall(sourceURL: URL, destinationURL: URL) throws {
        let connection = NSXPCConnection(
            machServiceName: EqualizerPrivilegedHelperIdentity.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: EqualizerPrivilegedHelperProtocol.self
        )
        connection.setCodeSigningRequirement(
            EqualizerPrivilegedHelperIdentity.helperRequirement
        )

        let completion = DispatchSemaphore(value: 0)
        let replyBox = ReplyBox()
        connection.interruptionHandler = {
            replyBox.store(.failure(ReplyTransportError(message: "connection interrupted")))
            completion.signal()
        }
        connection.invalidationHandler = {
            replyBox.store(.failure(ReplyTransportError(message: "connection invalidated")))
            completion.signal()
        }
        connection.resume()

        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                replyBox.store(.failure(ReplyTransportError(message: error.localizedDescription)))
                completion.signal()
            }) as? EqualizerPrivilegedHelperProtocol
        else {
            connection.invalidate()
            throw EqualizerDriverInstallError.helperUnavailable(
                message: "the helper proxy could not be created"
            )
        }

        proxy.installDriver(
            from: sourceURL.path,
            to: destinationURL.path
        ) { reply in
            replyBox.store(.success(reply))
            completion.signal()
        }

        let waitResult = completion.wait(timeout: .now() + 30)
        connection.invalidate()
        guard waitResult == .success else {
            throw EqualizerDriverInstallError.helperUnavailable(
                message: "the helper did not reply within 30 seconds"
            )
        }
        guard let result = replyBox.load() else {
            throw EqualizerDriverInstallError.invalidReply
        }
        switch result {
        case .failure(let error):
            throw EqualizerDriverInstallError.helperUnavailable(message: error.message)
        case .success(let reply):
            guard let status = reply["status"] as? NSNumber else {
                throw EqualizerDriverInstallError.invalidReply
            }
            guard status.intValue == 0 else {
                let message = reply["message"] as? String ?? "unknown helper failure"
                if status.intValue == 64 {
                    throw EqualizerDriverInstallError.helperRejected(
                        status: status.intValue,
                        message: message
                    )
                }
                throw EqualizerDriverInstallError.helperOperationFailed(
                    status: status.intValue,
                    message: message
                )
            }
        }
    }

    private func helperVersionMarkerMatches() -> Bool {
        guard let expectedVersion = helperVersion,
            let marker = try? String(
                contentsOf: EqualizerPrivilegedHelperIdentity.helperVersionURL,
                encoding: .utf8
            )
        else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    }

    private func writeHelperVersionMarker() {
        guard let helperVersion else { return }
        let markerURL = EqualizerPrivilegedHelperIdentity.helperVersionURL
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (helperVersion + "\n").write(
                to: markerURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            // The marker only avoids a redundant re-registration after the
            // next launch. A failed write must not undo a completed install.
            SpotiglassLog.error(
                .playback,
                "Could not record the equalizer helper version: \(error.localizedDescription)"
            )
        }
    }

    private var helperVersion: String? {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

struct EqualizerFileDriverInstaller: EqualizerDriverInstalling {
    let fileManager: FileManager

    func installDriver(sourceURL: URL, destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let temporaryURL = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
}
