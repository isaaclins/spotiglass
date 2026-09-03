import Darwin
import Foundation
import Security

@objc private protocol EqualizerPrivilegedHelperProtocol {
    func installDriver(
        from sourcePath: String,
        to destinationPath: String,
        withReply reply: @escaping (NSDictionary) -> Void
    )
}

private enum HelperOperationError: Error, CustomStringConvertible {
    case invalidRequest
    case sourceMissing
    case copyFailed(errno: Int32)
    case restartFailed(status: Int32)
    case restartCouldNotStart(String)

    var description: String {
        switch self {
        case .invalidRequest:
            return "the request did not identify this app's bundled driver"
        case .sourceMissing:
            return "the bundled driver is missing"
        case .copyFailed(let errno):
            return "copyfile failed with errno \(errno)"
        case .restartFailed(let status):
            return "coreaudiod restart returned status \(status)"
        case .restartCouldNotStart(let message):
            return "coreaudiod restart could not start: \(message)"
        }
    }
}

private final class EqualizerPrivilegedService: NSObject, EqualizerPrivilegedHelperProtocol {
    private let appBundleURL: URL
    private let fileManager = FileManager.default

    init?(executableURL: URL) {
        var bundleURL = executableURL.standardizedFileURL
        for _ in 0..<4 {
            bundleURL.deleteLastPathComponent()
        }
        guard bundleURL.pathExtension == "app" else { return nil }
        appBundleURL = bundleURL
    }

    func installDriver(
        from sourcePath: String,
        to destinationPath: String,
        withReply reply: @escaping (NSDictionary) -> Void
    ) {
        do {
            try install(
                sourceURL: URL(fileURLWithPath: sourcePath),
                destinationURL: URL(fileURLWithPath: destinationPath)
            )
            reply(Self.response(status: 0, message: ""))
        } catch {
            let status: Int32 = error is HelperOperationError && isRejected(error) ? 64 : 74
            reply(Self.response(status: status, message: String(describing: error)))
        }
    }

    private func install(sourceURL: URL, destinationURL: URL) throws {
        guard isExpectedSource(sourceURL), destinationURL == expectedDestinationURL else {
            throw HelperOperationError.invalidRequest
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw HelperOperationError.sourceMissing
        }
        guard hasValidDriverSignature(at: sourceURL) else {
            // Path checks prevent arbitrary filesystem writes. Signature
            // validation prevents a modified app bundle from becoming a
            // root-loaded CoreAudio plug-in.
            throw HelperOperationError.invalidRequest
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        // COPYFILE_ALL retains the signed bundle's metadata, including the
        // executable mtime that CoreAudio checks against its code signature.
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST
        )
        guard copyfile(sourceURL.path, temporaryURL.path, nil, flags) == 0 else {
            throw HelperOperationError.copyFailed(errno: errno)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        try restartCoreAudio()
    }

    private func hasValidDriverSignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return false }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                EqualizerPrivilegedHelperIdentity.driverRequirement as CFString,
                [],
                &requirement
            ) == errSecSuccess,
            let requirement
        else { return false }

        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    private var expectedDestinationURL: URL {
        EqualizerPrivilegedHelperIdentity.systemHALDirectory
            .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true)
            .standardizedFileURL
    }

    private func isExpectedSource(_ sourceURL: URL) -> Bool {
        let bundleURL = appBundleURL.standardizedFileURL
        let candidates = [
            bundleURL
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverRelativePath, isDirectory: true)
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true),
            bundleURL
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.resourceDriverRelativePath, isDirectory: true)
                .appendingPathComponent(EqualizerPrivilegedHelperIdentity.driverBundleName, isDirectory: true),
        ]
        return candidates.contains(sourceURL.standardizedFileURL)
    }

    private func restartCoreAudio() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["coreaudiod"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw HelperOperationError.restartCouldNotStart(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperOperationError.restartFailed(status: process.terminationStatus)
        }
    }

    private func isRejected(_ error: Error) -> Bool {
        guard let helperError = error as? HelperOperationError else { return false }
        if case .invalidRequest = helperError { return true }
        return false
    }

    private static func response(status: Int32, message: String) -> NSDictionary {
        [
            "status": NSNumber(value: status),
            "message": message,
        ] as NSDictionary
    }
}

private final class EqualizerConnectionDelegate: NSObject, NSXPCListenerDelegate {
    private var services: [ObjectIdentifier: EqualizerPrivilegedService] = [:]
    private let lock = NSLock()
    private let service: EqualizerPrivilegedService?

    init(executableURL: URL) {
        service = EqualizerPrivilegedService(executableURL: executableURL)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier != 0,
            let service
        else { return false }

        newConnection.setCodeSigningRequirement(
            EqualizerPrivilegedHelperIdentity.clientRequirement
        )
        newConnection.exportedInterface = NSXPCInterface(
            with: EqualizerPrivilegedHelperProtocol.self
        )
        newConnection.exportedObject = service
        let identifier = ObjectIdentifier(newConnection)
        store(service, for: identifier)
        newConnection.invalidationHandler = { [weak self] in
            self?.removeService(for: identifier)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.removeService(for: identifier)
        }
        newConnection.resume()
        return true
    }

    private func store(_ service: EqualizerPrivilegedService, for identifier: ObjectIdentifier) {
        lock.lock()
        services[identifier] = service
        lock.unlock()
    }

    private func removeService(for identifier: ObjectIdentifier) {
        lock.lock()
        services.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private let executableURL: URL = {
    let argument = CommandLine.arguments.first ?? ""
    if argument.hasPrefix("/") {
        return URL(fileURLWithPath: argument)
    }
    return URL(
        fileURLWithPath: argument,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    )
}()
private let connectionDelegate = EqualizerConnectionDelegate(executableURL: executableURL)
private let listener = NSXPCListener(
    machServiceName: EqualizerPrivilegedHelperIdentity.machServiceName
)
listener.delegate = connectionDelegate
listener.resume()
RunLoop.current.run()
