import Foundation

extension Notification.Name {
    /// Posted when the Spotify Web Playback SDK reports a ready device. Used to
    /// rebuild the Core Audio process tap after WebKit helper processes spawn.
    static let spotiglassPlaybackDeviceReady = Notification.Name("com.isaaclins.spotiglass.playbackDeviceReady")

    /// Posted when the main playlist UI (including the hidden ``WKWebView`` playback host) appears.
    /// Used to debounce-rebuild the equalizer tap so PIDs exist even if the SDK ``ready`` event already fired.
    static let spotiglassPlaybackSurfaceAppeared = Notification.Name("com.isaaclins.spotiglass.playbackSurfaceAppeared")
}

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
