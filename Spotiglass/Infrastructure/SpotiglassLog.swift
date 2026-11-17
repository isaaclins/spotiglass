import Foundation
import os

/// Unified logging for Wax. Mirrors every message to:
///   1. Apple's unified log (Console.app, subsystem `com.isaaclins.spotiglass`).
///   2. A plain-text file under `Application Support/Spotiglass/Logs/spotiglass.log`.
///      Each launch starts a fresh `spotiglass.log` and rotates the prior session
///      to `spotiglass.previous.log`. Inside a session the file is capped at
///      ``FileLogSink/defaultMaxBytes``: when it fills up, it moves to
///      `spotiglass.earlier.log` and a new `spotiglass.log` continues, so at most three
///      capped files exist and the newest lines are never the ones dropped.
///
/// Under the unit-test host the files go to a temporary folder, so `make test` never
/// rotates away or fills the log a user would attach to a bug report.
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

    /// Open a fresh per-session log file, rotating the previous session to
    /// `spotiglass.previous.log`. Safe to call once at app launch; subsequent calls
    /// are no-ops.
    static func boot() {
        FileLogSink.shared.boot()
        installFlushOnExit()
    }

    private static var flushObserver: NSObjectProtocol?

    /// Info and debug lines are written in the background; a quit or an uncaught exception
    /// must not leave the last of them in the queue (#602). Errors are written at once anyway.
    private static func installFlushOnExit() {
        guard flushObserver == nil else { return }
        flushObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { _ in
            SpotiglassLog.info(.persistence, "Wax quitting")
            SpotiglassLog.flush()
        }
        NSSetUncaughtExceptionHandler { exception in
            SpotiglassLog.error(.persistence, "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            SpotiglassLog.flush()
        }
    }

    /// Waits until every line handed to the log so far is in the file. Lines go straight
    /// to the file descriptor, so once this returns they survive a crash.
    static func flush() {
        FileLogSink.shared.flush()
    }

    static func debug(_ category: Category, _ message: String) {
        osLoggers[category]?.debug("\(message, privacy: .public)")
        FileLogSink.shared.write(level: "DEBUG", category: category.rawValue, message: message)
    }

    /// Errors are written before this returns: they are the lines a crash right after
    /// must not lose.
    static func error(_ category: Category, _ message: String) {
        osLoggers[category]?.error("\(message, privacy: .public)")
        FileLogSink.shared.write(level: "ERROR", category: category.rawValue, message: message, synchronously: true)
    }

    static func info(_ category: Category, _ message: String) {
        osLoggers[category]?.info("\(message, privacy: .public)")
        FileLogSink.shared.write(level: "INFO", category: category.rawValue, message: message)
    }

    /// An error as a log line may carry it: the code and kind, never the request behind it.
    /// `"\(error)"` of a `URLError` prints the failing URL with its query (the song for
    /// LRCLIB, the search text for a search), which a log someone attaches must not hold (#603).
    static func describe(_ error: Error) -> String {
        switch error {
        case let urlError as URLError:
            return "URLError \(urlError.code.rawValue)"
        case let decodingError as DecodingError:
            switch decodingError {
            case let .typeMismatch(_, context), let .valueNotFound(_, context),
                 let .keyNotFound(_, context), let .dataCorrupted(context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return "could not decode the response at \(path.isEmpty ? "the top level" : path)"
            @unknown default:
                return "could not decode the response"
            }
        default:
            let nsError = error as NSError
            // Foundation and system errors print their userInfo, which may hold a URL.
            if nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain
                || nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSOSStatusErrorDomain {
                return "\(nsError.domain) \(nsError.code)"
            }
            return String(describing: error)
        }
    }

    /// The folder the log files go to: the real `Logs` folder for the app, a per-run
    /// temporary folder under the unit-test host.
    static func logDirectory(
        isRunningUnitTests: Bool = AppMetadata.isRunningUnitTests,
        applicationSupport: () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) throws -> URL {
        if isRunningUnitTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotiglassTestLogs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return try applicationSupport()
            .appendingPathComponent("\(AppMetadata.storageDirectoryName)/Logs", isDirectory: true)
    }
}

final class FileLogSink {
    static let shared = FileLogSink()

    /// About an hour of detailed playback lines; three files of this size at most.
    static let defaultMaxBytes: UInt64 = 8 * 1024 * 1024

    static let currentFileName = "spotiglass.log"
    static let earlierFileName = "spotiglass.earlier.log"
    static let previousFileName = "spotiglass.previous.log"

    private let queue = DispatchQueue(label: "com.isaaclins.spotiglass.filelog", qos: .utility)
    private let directory: () throws -> URL
    private let maxBytes: UInt64
    private let moveItem: (URL, URL) throws -> Void
    private let diagnostics = Logger(subsystem: AppMetadata.bundleIdentifier, category: "log-file")
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private var booted = false
    private var _fileURL: URL?

    var fileURL: URL? { queue.sync { _fileURL } }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(
        directory: @escaping () throws -> URL = { try SpotiglassLog.logDirectory() },
        maxBytes: UInt64 = FileLogSink.defaultMaxBytes,
        moveItem: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.moveItem = moveItem
    }

    func boot() {
        queue.sync {
            guard !booted else { return }
            booted = true
            let dir: URL
            do {
                dir = try directory()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                diagnostics.error("Log folder unavailable, the log file stays off this session: \(String(describing: error), privacy: .public)")
                return
            }
            let url = dir.appendingPathComponent(Self.currentFileName)
            // Keep the previous session's log: a crash followed by a relaunch must not wipe
            // the evidence users are asked to attach to bug reports.
            var rotationNote: String?
            if FileManager.default.fileExists(atPath: url.path) {
                let previousURL = dir.appendingPathComponent(Self.previousFileName)
                let earlierURL = dir.appendingPathComponent(Self.earlierFileName)
                do {
                    if FileManager.default.fileExists(atPath: previousURL.path) {
                        try FileManager.default.removeItem(at: previousURL)
                    }
                    try moveItem(url, previousURL)
                    // The previous session's overflow belongs to a session that is now two back.
                    try? FileManager.default.removeItem(at: earlierURL) // A leftover only costs one capped file.
                } catch {
                    // Appending keeps the previous session's lines; the size cap below still holds.
                    rotationNote = "Could not move the previous session's log aside (\(SpotiglassLog.describe(error))); appending to it instead"
                    diagnostics.error("\(rotationNote ?? "", privacy: .public)")
                }
            }
            guard open(url, header: "=== Wax log started \(Self.formatter.string(from: Date())) ===\n") else { return }
            if let rotationNote {
                append(Self.line(level: "ERROR", category: "log-file", message: rotationNote))
            }
        }
    }

    func write(level: String, category: String, message: String, synchronously: Bool = false) {
        let line = Self.line(level: level, category: category, message: message)
        if synchronously {
            queue.sync { append(line) }
        } else {
            queue.async { [weak self] in self?.append(line) }
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize() // Lines are already in the kernel; this only adds fsync.
        }
    }

    private static func line(level: String, category: String, message: String) -> String {
        "\(formatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
    }

    /// Opens `url` for appending (creating it when missing). Says in Console when it can't.
    private func open(_ url: URL, header: String) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                diagnostics.error("Could not create the log file at \(url.path, privacy: .public)")
                return false
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            bytesWritten = try handle.seekToEnd()
            self.handle = handle
            _fileURL = url
        } catch {
            diagnostics.error("Could not open the log file at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        append(header)
        return true
    }

    private func append(_ line: String) {
        guard handle != nil else { return }
        let data = Data(line.utf8)
        if bytesWritten + UInt64(data.count) > maxBytes, bytesWritten > 0 {
            rotateWithinSession()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
        } catch {
            diagnostics.error("Writing to the log file failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The current file is full: it becomes `spotiglass.earlier.log` (replacing an older
    /// part of this session) and a fresh file continues under the same name.
    private func rotateWithinSession() {
        guard let url = _fileURL else { return }
        let earlierURL = url.deletingLastPathComponent().appendingPathComponent(Self.earlierFileName)
        try? handle?.close() // The file is moved next; a failed close only leaks a descriptor.
        handle = nil
        let stamp = Self.formatter.string(from: Date())
        let header: String
        do {
            if FileManager.default.fileExists(atPath: earlierURL.path) {
                try FileManager.default.removeItem(at: earlierURL)
            }
            try moveItem(url, earlierURL)
            header = "=== Log continued \(stamp), earlier lines in \(Self.earlierFileName) ===\n"
        } catch {
            // Without the move the only way to stay under the cap is to start this session's
            // file over; the previous session's file is never touched here.
            diagnostics.error("Could not move the full log aside (\(String(describing: error), privacy: .public)); starting it over")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            header = "=== Log started over \(stamp): the full log could not be moved aside (\(SpotiglassLog.describe(error))) ===\n"
        }
        _ = open(url, header: header)
    }
}
