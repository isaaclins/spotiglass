import Foundation
import os

/// Unified logging for Spotiglass. Mirrors every message to:
///   1. Apple's unified log (Console.app, subsystem `com.isaaclins.spotiglass`).
///   2. A plain-text file under `Application Support/Spotiglass/Logs/spotiglass.log`
///      that is truncated at every app launch, so it never grows without bound.
///
/// Never log tokens, refresh credentials, or raw OAuth callbacks.
enum SpotiglassLog {
    enum Category: String, CaseIterable {
        case auth, api, playback, browsing, pinning, settings, persistence
    }

    // Back-compat aliases so existing `SpotiglassLog.info(SpotiglassLog.playback, ...)` call sites
    // continue to compile unchanged. The type changed from `Logger` to `Category`; the entry-point
    // functions overload on Category below.
    static let auth = Category.auth
    static let api = Category.api
    static let playback = Category.playback
    static let browsing = Category.browsing
    static let pinning = Category.pinning
    static let settings = Category.settings
    static let persistence = Category.persistence

    private static let subsystem = AppMetadata.bundleIdentifier

    private static let osLoggers: [Category: Logger] = {
        Dictionary(uniqueKeysWithValues: Category.allCases.map { category in
            (category, Logger(subsystem: subsystem, category: category.rawValue))
        })
    }()

    /// File path of the current session's log; `nil` before `boot()` runs or if the file
    /// could not be opened.
    static var logFileURL: URL? { FileLogSink.shared.fileURL }

    /// Open (truncating) the per-session log file. Safe to call once at app launch.
    /// Subsequent calls are no-ops.
    static func boot() {
        FileLogSink.shared.boot()
    }

    static func error(_ category: Category, _ message: String) {
        osLoggers[category]?.error("\(message, privacy: .public)")
        FileLogSink.shared.write(level: "ERROR", category: category.rawValue, message: message)
    }

    static func info(_ category: Category, _ message: String) {
        osLoggers[category]?.info("\(message, privacy: .public)")
        FileLogSink.shared.write(level: "INFO", category: category.rawValue, message: message)
    }
}

private final class FileLogSink {
    static let shared = FileLogSink()

    private let queue = DispatchQueue(label: "com.isaaclins.spotiglass.filelog", qos: .utility)
    private var handle: FileHandle?
    private var booted = false
    private(set) var fileURL: URL?

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func boot() {
        queue.sync {
            guard !booted else { return }
            booted = true
            guard let dir = Self.logDirectory() else { return }
            let url = dir.appendingPathComponent("spotiglass.log")
            // Truncate any previous session's file by re-creating it empty.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            self.handle = handle
            self.fileURL = url
            let header = "=== Spotiglass log started \(Self.formatter.string(from: Date())) ===\n"
            try? handle.write(contentsOf: Data(header.utf8))
        }
    }

    func write(level: String, category: String, message: String) {
        let timestamp = Self.formatter.string(from: Date())
        let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"
        queue.async { [weak self] in
            guard let handle = self?.handle else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private static func logDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let logs = base.appendingPathComponent("Spotiglass/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }
}
