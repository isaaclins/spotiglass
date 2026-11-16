import Foundation
import Darwin

/// Sparkle deliberately retains the installed filename. Rename only our historical filename,
/// on the same volume, without ever replacing another installation or copying user data.
enum AppBundleMigration {
    static func moveLegacyBundle(at source: URL) throws -> URL? {
        guard source.lastPathComponent == "Spotiglass.app",
              !source.pathComponents.contains("AppTranslocation") else { return nil }
        let destination = source.deletingLastPathComponent().appendingPathComponent("Wax.app")
        // RENAME_EXCL closes the check-then-move race and preserves bundle identity (including
        // Finder aliases/bookmarks used by the Dock and login items). No elevated helper, deletion
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
    static func migrate(
        source: URL,
        register: (URL) -> Void,
        relaunch: (URL, @escaping (Bool) -> Void) -> Void,
        finish: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        do {
            guard let destination = try moveLegacyBundle(at: source) else { return }
            register(destination)
            relaunch(destination) { succeeded in
                if succeeded {
                    finish()
                    return
                }
                let result = destination.withUnsafeFileSystemRepresentation { old in
                    source.withUnsafeFileSystemRepresentation { new in
                        renamex_np(old, new, UInt32(RENAME_EXCL))
                    }
                }
                log("Wax rename relaunch failed; rollback status \(result)")
            }
        } catch {
            log("Wax bundle rename deferred: \(error)")
        }
    }
}
