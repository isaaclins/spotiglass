import XCTest
@testable import Spotiglass

final class SpotifyAPIErrorUserMessageTests: XCTestCase {
    /// Asserted against the catalog rather than against English literals, so the
    /// test proves the message is routed through localization instead of
    /// pinning one language's wording.
    func testUserMessagesResolveThroughTheCatalog() {
        // Guard against the whole suite passing vacuously: a missing key makes
        // SpotiglassL10n return the key itself, which would satisfy every
        // equality below while shipping "error.spotify.unauthorized" to users.
        XCTAssertNotEqual(
            SpotifyAPIError.unauthorized.userMessage,
            "error.spotify.unauthorized",
            "the key did not resolve, so the catalog entry is missing from the built bundle"
        )

        XCTAssertEqual(
            SpotifyAPIError.unauthorized.userMessage,
            SpotiglassL10n.string("error.spotify.unauthorized")
        )
        XCTAssertEqual(
            SpotifyAPIError.insufficientScope(
                requiredScopes: ["playlist-read-private"],
                message: nil,
                details: nil
            ).userMessage,
            SpotiglassL10n.string("error.spotify.insufficientPermissions")
        )
        // The server's own text for a 403 is the bare reason phrase
        // ("Forbidden"), which is not a sentence and is never translated, so the
        // localized message wins and the server text moves to diagnostics.
        XCTAssertEqual(
            SpotifyAPIError.forbidden(message: "Nope", details: nil).userMessage,
            SpotiglassL10n.string("error.spotify.forbidden")
        )
        // Asserting the catalog rather than the word "rate": the sentence is
        // localized now and should not have to carry an English keyword (#187).
        XCTAssertEqual(
            SpotifyAPIError.rateLimited(retryAfter: 5).userMessage,
            SpotiglassL10n.format(
                "error.spotify.rateLimited",
                SpotifyRateLimitDisplay.retryAfterClause(seconds: 5)
            )
        )
        // notFound keeps a descriptive server message when there is one.
        XCTAssertEqual(SpotifyAPIError.notFound(message: "gone").userMessage, "gone")
        XCTAssertEqual(
            SpotifyAPIError.notFound(message: nil).userMessage,
            SpotiglassL10n.string("error.spotify.notFound")
        )
        XCTAssertTrue(
            SpotifyAPIError.badRequest(message: "bad", details: nil).userMessage.contains("bad")
        )
        XCTAssertEqual(
            SpotifyAPIError.badRequest(message: nil, details: nil).userMessage,
            SpotiglassL10n.string("error.spotify.rejectedRequestGeneric")
        )
        XCTAssertEqual(
            SpotifyAPIError.server(statusCode: 503, message: "down", details: nil).userMessage,
            SpotiglassL10n.string("error.spotify.serverProblem")
        )
        XCTAssertEqual(
            SpotifyAPIError.decoding("shape").userMessage,
            SpotiglassL10n.string("error.spotify.unexpectedShape")
        )
        XCTAssertEqual(SpotifyAPIError.network("offline").userMessage, "offline")
        XCTAssertEqual(SpotifyAPIError.invalidRequest("need id").userMessage, "need id")
    }

    /// Everything the sentence no longer says has to still be reachable from a
    /// bug report, which is what the diagnostics disclosure is for.
    func testDeveloperFactsMoveToDiagnostics() {
        XCTAssertNil(SpotifyAPIError.unauthorized.diagnosticDetails)
        XCTAssertEqual(
            SpotifyAPIError.badRequest(message: nil, details: "diag").diagnosticDetails,
            "diag"
        )
        XCTAssertEqual(
            SpotifyAPIError.rateLimited(retryAfter: 3).diagnosticDetails,
            SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: 3)
        )

        let scoped = SpotifyAPIError.insufficientScope(
            requiredScopes: ["playlist-read-private"],
            message: nil,
            details: nil
        )
        XCTAssertEqual(scoped.diagnosticDetails?.contains("playlist-read-private"), true)

        let server = SpotifyAPIError.server(statusCode: 503, message: "down", details: nil)
        XCTAssertEqual(server.diagnosticDetails?.contains("503"), true)
        XCTAssertEqual(server.diagnosticDetails?.contains("down"), true)

        XCTAssertEqual(SpotifyAPIError.decoding("shape").diagnosticDetails, "shape")
        XCTAssertEqual(
            SpotifyAPIError.forbidden(message: "Nope", details: nil).diagnosticDetails,
            "Nope"
        )
    }

    func testLocalizedErrorDescriptionMatchesUserMessage() {
        let err: LocalizedError = SpotifyAPIError.forbidden(message: "Denied", details: nil)
        XCTAssertEqual(
            err.errorDescription,
            SpotifyAPIError.forbidden(message: "Denied", details: nil).userMessage
        )
    }
}
