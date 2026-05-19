import XCTest
@testable import Spotiglass

final class SpotifyAPIErrorUserMessageTests: XCTestCase {
    func testUserMessagesForAllCases() {
        XCTAssertTrue(SpotifyAPIError.unauthorized.userMessage.contains("Sign in"))
        XCTAssertTrue(
            SpotifyAPIError.insufficientScope(
                requiredScopes: ["playlist-read-private"],
                message: nil,
                details: nil
            ).userMessage.contains("playlist-read-private")
        )
        XCTAssertEqual(
            SpotifyAPIError.forbidden(message: "Nope", details: nil).userMessage,
            "Nope"
        )
        XCTAssertTrue(
            SpotifyAPIError.rateLimited(retryAfter: 5).userMessage.localizedCaseInsensitiveContains("rate")
        )
        XCTAssertEqual(
            SpotifyAPIError.notFound(message: "gone").userMessage,
            "gone"
        )
        XCTAssertTrue(
            SpotifyAPIError.badRequest(message: "bad", details: nil).userMessage.contains("bad")
        )
        XCTAssertTrue(
            SpotifyAPIError.server(statusCode: 503, message: "down", details: nil).userMessage.contains("503")
        )
        XCTAssertTrue(
            SpotifyAPIError.decoding("shape").userMessage.contains("shape")
        )
        XCTAssertEqual(
            SpotifyAPIError.network("offline").userMessage,
            "offline"
        )
        XCTAssertEqual(
            SpotifyAPIError.invalidRequest("need id").userMessage,
            "need id"
        )
    }

    func testDiagnosticDetailsOnlyForEnvelopeCases() {
        XCTAssertNil(SpotifyAPIError.unauthorized.diagnosticDetails)
        XCTAssertEqual(
            SpotifyAPIError.badRequest(message: nil, details: "diag").diagnosticDetails,
            "diag"
        )
        XCTAssertEqual(
            SpotifyAPIError.rateLimited(retryAfter: 3).diagnosticDetails,
            SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: 3)
        )
    }

    func testLocalizedErrorDescriptionMatchesUserMessage() {
        let err: LocalizedError = SpotifyAPIError.forbidden(message: "Denied", details: nil)
        XCTAssertEqual(err.errorDescription, SpotifyAPIError.forbidden(message: "Denied", details: nil).userMessage)
    }
}
