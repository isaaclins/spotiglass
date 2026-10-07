import Foundation

/// Screenshot mode runs the app against a local stand-in for Spotify, so the real UI can be
/// captured with a sample library and no Spotify account. `scripts/screenshots.sh` turns it on
/// by launching the app with `SPOTIGLASS_MOCK_BASE=http://127.0.0.1:<port>`; see
/// `docs/screenshots.md`.
///
/// Normal launches never set that variable, so every value here resolves to Spotify and the app
/// behaves exactly as it would without this type. Only loopback addresses are accepted, so the
/// variable cannot point the app's tokens or requests at another machine.
enum ScreenshotMode {
    static let environmentKey = "SPOTIGLASS_MOCK_BASE"

    /// Refresh token the mock server accepts. Screenshot mode signs in with it at launch and keeps
    /// it in memory only, so the user's Keychain item is never read or written.
    static let refreshToken = "screenshot-mode"

    /// Base URL of the local mock, or `nil` for a normal launch.
    static let mockBaseURL: URL? = mockBaseURL(in: ProcessInfo.processInfo.environment)

    static var isActive: Bool { mockBaseURL != nil }

    /// Spotify accounts service (`/authorize`, `/api/token`).
    static var accountsBaseURL: URL { accountsBaseURL(mockBase: mockBaseURL) }

    /// Spotify Web API (`/v1/...`).
    static var webAPIBaseURL: URL { webAPIBaseURL(mockBase: mockBaseURL) }

    static func mockBaseURL(in environment: [String: String]) -> URL? {
        guard let raw = environment[environmentKey],
            let url = URL(string: raw),
            url.scheme == "http",
            let host = url.host,
            ["127.0.0.1", "localhost"].contains(host)
        else { return nil }
        return url
    }

    static func accountsBaseURL(mockBase: URL?) -> URL {
        mockBase ?? URL(string: "https://accounts.spotify.com")!
    }

    static func webAPIBaseURL(mockBase: URL?) -> URL {
        mockBase ?? URL(string: "https://api.spotify.com")!
    }

    /// Swaps the Web Playback SDK `<script src>` in the playback host page for the stand-in SDK the
    /// mock serves. The script is inlined because the host page runs on an https base URL and
    /// WebKit blocks a plain-http script source there. Returns `page` unchanged outside
    /// screenshot mode or when the mock cannot be reached.
    static func inliningMockPlaybackSDK(
        into page: String,
        mockBase: URL? = mockBaseURL,
        load: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> String {
        guard let mockBase,
            let data = load(mockBase.appendingPathComponent("sdk/spotify-player.js")),
            let script = String(data: data, encoding: .utf8)
        else { return page }
        return page.replacingOccurrences(
            of: "<script src=\"https://sdk.scdn.co/spotify-player.js\"></script>",
            with: "<script>" + script + "</script>"
        )
    }
}
