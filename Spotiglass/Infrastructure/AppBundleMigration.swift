import AppKit
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

    @MainActor
    static func run() {
        guard !AppMetadata.isRunningUnitTests,
              Bundle.main.bundleIdentifier == "com.isaaclins.spotiglass" else { return }
        let source = Bundle.main.bundleURL
        do {
            guard let destination = try moveLegacyBundle(at: source) else { return }
            // Refresh Launch Services and restart so Bundle.main and Sparkle use the new URL.
            LSRegisterURL(destination as CFURL, true)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = Array(CommandLine.arguments.dropFirst())
            configuration.environment = ProcessInfo.processInfo.environment
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { app, error in
                if app != nil {
                    exit(EXIT_SUCCESS)
                }
                // Keep the existing process usable if Launch Services cannot restart it. Never
                // overwrite an intervening install when rolling back, either.
                _ = destination.withUnsafeFileSystemRepresentation { old in
                    source.withUnsafeFileSystemRepresentation { new in
                        renamex_np(old, new, UInt32(RENAME_EXCL))
                    }
                }
                SpotiglassLog.info(.persistence, "Wax rename relaunch failed: \(String(describing: error))")
            }
        } catch {
            SpotiglassLog.info(.persistence, "Wax bundle rename deferred: \(error)")
        }
    }
}
