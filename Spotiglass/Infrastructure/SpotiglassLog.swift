import Foundation
import os

/// Unified logging for Spotiglass. Never log tokens, refresh credentials, or raw OAuth callbacks.
enum SpotiglassLog {
    private static let subsystem = AppMetadata.bundleIdentifier

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let browsing = Logger(subsystem: subsystem, category: "browsing")
    static let pinning = Logger(subsystem: subsystem, category: "pinning")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")

    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func info(_ logger: Logger, _ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
