import XCTest
@testable import Spotiglass

@MainActor
final class PlaylistBrowserDisplayErrorTests: XCTestCase {
    func testDisplayErrorMapsSpotifyAPIErrors() {
        let cases: [(SpotifyAPIError, String, Bool)] = [
            (.unauthorized, "Sign in again", false),
            (.insufficientScope(requiredScopes: ["playlist-read-private"], message: nil, details: nil), "Reconnect Spotify", false),
            (.forbidden(message: "Nope", details: nil), "Access denied", false),
            (.rateLimited(retryAfter: 30), "Spotify is rate limiting requests", true),
            (.notFound(message: "gone"), "Not found", true),
            (.network("offline"), "Network unavailable", true),
            (.decoding("shape"), "Could not read Spotify response", true),
            (.badRequest(message: "bad", details: nil), "Spotify rejected the request", false),
            (.server(statusCode: 503, message: "down", details: nil), "Spotify service issue", true),
            (.invalidRequest("invalid"), "Invalid request", false),
        ]
        for (error, title, canRetry) in cases {
            let display = PlaylistBrowserViewModel.displayError(for: error)
            XCTAssertEqual(display.title, title, "\(error)")
            XCTAssertEqual(display.canRetry, canRetry, "\(error)")
        }
    }

    func testDisplayErrorFallsBackForGenericError() {
        struct Sample: Error {}
        let display = PlaylistBrowserViewModel.displayError(for: Sample())
        XCTAssertEqual(display.title, "Something went wrong")
        XCTAssertTrue(display.canRetry)
    }
}
