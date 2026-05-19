import Foundation

enum AppMetadata {
    static let displayName = "Spotiglass"
    static let bundleIdentifier = "com.isaaclins.spotiglass"

    /// `SpotiglassTests` is injected into `Spotiglass.app` (`TEST_HOST`); Xcode sets this env var so
    /// the hosted app can avoid touching the user Keychain during `restoreSessionIfAvailable()`.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// For outbound HTTP (e.g. LRCLIB); identifies the app per third-party API guidance.
    static var spotiglassHTTPUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "\(displayName)/\(version) (\(bundleIdentifier))"
    }
}
