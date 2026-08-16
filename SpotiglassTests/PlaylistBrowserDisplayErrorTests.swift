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

    /// Spotify answers a 403 with the bare reason phrase "Forbidden". It must never reach the
    /// screen as user copy, but it must still be recoverable from the diagnostics disclosure.
    func testForbiddenKeepsServerTextOutOfUserCopyAndInDiagnostics() {
        let apiError = SpotifyAPIError.forbidden(message: "Forbidden", details: "GET /v1/me/playlists")
        let display = PlaylistBrowserViewModel.displayError(for: apiError)
        XCTAssertEqual(display.message, "Spotify denied access to this resource.")
        XCTAssertFalse(display.message.contains("Forbidden"))
        XCTAssertEqual(display.diagnosticDetails, "Forbidden\nGET /v1/me/playlists")
    }

    /// Descriptive server text on other cases is still worth showing, so the narrowing is
    /// deliberately limited to the 403 reason phrase.
    func testDescriptiveServerTextIsStillShownOnOtherCases() {
        let badRequest = SpotifyAPIError.badRequest(message: "Invalid limit", details: nil)
        XCTAssertEqual(PlaylistBrowserViewModel.displayError(for: badRequest).message, "Invalid limit")

        let notFound = SpotifyAPIError.notFound(message: "No such playlist")
        XCTAssertEqual(PlaylistBrowserViewModel.displayError(for: notFound).message, "No such playlist")
    }

    func testCachedDataCaptionStatesTheReasonWhenThereIsOne() {
        let plain = SpotiglassL10n.string("browser.cachedData")
        XCTAssertEqual(PlaylistsSidebarSectionHeader.cachedDataCaption(for: nil), plain)

        let apiError = SpotifyAPIError.forbidden(message: "Forbidden", details: nil)
        let error = PlaylistBrowserViewModel.displayError(for: apiError)
        let caption = PlaylistsSidebarSectionHeader.cachedDataCaption(for: error)
        XCTAssertNotEqual(caption, plain)
        XCTAssertTrue(caption.contains(error.message))
        XCTAssertFalse(caption.contains("Forbidden"))
    }

    func testDisplayErrorFallsBackForGenericError() {
        struct Sample: Error {}
        let display = PlaylistBrowserViewModel.displayError(for: Sample())
        XCTAssertEqual(display.title, "Something went wrong")
        XCTAssertTrue(display.canRetry)
    }
}
