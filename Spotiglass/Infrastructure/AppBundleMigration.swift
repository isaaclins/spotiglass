import Foundation
import Darwin

/// Sparkle deliberately retains the installed filename. Rename only our historical filename,
/// on the same volume, without ever replacing another installation or copying user data.
enum AppBundleMigration {
    static func moveLegacyBundle(at source: URL) throws -> URL? {
        guard source.lastPathComponent == "Spotiglass.app",
              !source.pathComponents.contains("AppTranslocation") else { return nil }
        let destination = source.deletingLastPathComponent().appendingPathComponent("Wax.app")
        // RENAME_EXCL closes the check-then-move race and preserves local file identity.
        // Pre-update login aliases are repaired by the launch adapter. No elevated helper, deletion
        // or fallback copy: an occupied/read-only destination leaves the working app untouched.
        let result = source.withUnsafeFileSystemRepresentation { old in
            destination.withUnsafeFileSystemRepresentation { new in
                renamex_np(old, new, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return destination
    }

    /// The launch adapter supplies system effects; the migration itself is testable without
    /// opening apps, exiting the test host, or touching the user's Dock/login preferences.
    ///
    /// Blocks until `relaunch` answers, so the old copy doesn't go on launching from a bundle that
    /// has moved. An answer that hasn't come within `timeout` counts as a failed relaunch: the
    /// rename is undone and the late answer is refused (`completion` returns false), so it can
    /// neither quit this copy mid-session nor move the bundle again.
    static func migrate(
        source: URL,
        register: (URL) -> Void,
        relaunch: (URL, @escaping (Bool) -> Bool) -> Void,
        finish: @escaping (URL) -> Void,
        log: @escaping (String) -> Void,
        timeout: DispatchTimeInterval = .seconds(30)
    ) {
        let destination: URL
        do {
            guard let moved = try moveLegacyBundle(at: source) else { return }
            destination = moved
        } catch {
            log("Wax bundle rename deferred: \(error)")
            return
        }
        register(destination)
        let answer = RelaunchAnswer()
        let answered = DispatchSemaphore(value: 0)
        relaunch(destination) { succeeded in
            guard answer.take() else { return false }
            if succeeded {
                finish(destination)
            } else {
                rollBack(destination, to: source, because: "relaunch failed", log: log)
            }
            answered.signal()
            return true
        }
        if answered.wait(timeout: .now() + timeout) == .timedOut, answer.take() {
            rollBack(destination, to: source, because: "relaunch did not answer", log: log)
        }
    }

    private static func rollBack(_ destination: URL, to source: URL, because reason: String, log: (String) -> Void) {
        let result = destination.withUnsafeFileSystemRepresentation { old in
            source.withUnsafeFileSystemRepresentation { new in
                renamex_np(old, new, UInt32(RENAME_EXCL))
            }
        }
        log("Wax rename \(reason); rollback status \(result)")
    }
}

/// The first of the relaunch's answer and the timeout wins; the other is ignored.
private final class RelaunchAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var isTaken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isTaken { return false }
        isTaken = true
        return true
    }
}
