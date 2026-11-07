import MusicKit
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

    // MARK: - Apple Music (#397)

    /// MusicKit's own errors are English only ("User not signed in") and name no fix. Browsing
    /// showed them under "Something went wrong"; each now reads as a sentence that says what to do.
    func testMusicKitErrorsReadAsAppleMusicSentences() {
        let cases: [(Error, String, String)] = [
            (MusicTokenRequestError.userNotSignedIn, "Sign in to Apple Music", "appleMusic.error.signIn.message"),
            (MusicTokenRequestError.userTokenRevoked, "Sign in to Apple Music", "appleMusic.error.signIn.message"),
            (MusicTokenRequestError.privacyAcknowledgementRequired, "Open Music once", "appleMusic.error.privacyNotice.message"),
            (MusicTokenRequestError.permissionDenied, "Apple Music access is off", "error.playback.appleMusic.permission.message"),
            (MusicTokenRequestError.developerTokenRequestFailed, "Apple Music isn't available", "appleMusic.error.unavailable.message"),
            (MusicLibrary.Error.permissionDenied, "Apple Music access is off", "error.playback.appleMusic.permission.message"),
            (MusicSubscription.Error.privacyAcknowledgementRequired, "Open Music once", "appleMusic.error.privacyNotice.message"),
        ]
        for (error, title, messageKey) in cases {
            let display = PlaylistBrowserViewModel.displayError(for: error)
            XCTAssertEqual(display.title, title, "\(error)")
            XCTAssertEqual(display.message, SpotiglassL10n.string(messageKey), "\(error)")
            XCTAssertNotEqual(display.message, error.localizedDescription, "\(error)")
            // MusicKit's text is still there for a bug report.
            XCTAssertEqual(display.diagnosticDetails, String(describing: error), "\(error)")
        }
        XCTAssertFalse(PlaylistBrowserViewModel.displayError(for: MusicTokenRequestError.developerTokenRequestFailed).canRetry)
    }

    func testAppleMusicNotFoundNamesAppleMusic() {
        let display = PlaylistBrowserViewModel.displayError(for: AppleMusicBrowsingError.notFound)
        XCTAssertEqual(display.title, "Not found")
        XCTAssertEqual(display.message, "This item isn't in your library or in Apple Music.")
    }

    /// While Apple Music is on screen, an error MusicKit doesn't type still names Apple Music.
    /// Spotify's generic fallback is unchanged.
    func testUnrecognisedErrorsNameTheServiceOnScreen() {
        struct Sample: Error {}
        let appleMusic = PlaylistBrowserViewModel.appleMusicDisplayError(for: Sample(), service: .appleMusic)
        XCTAssertEqual(appleMusic?.title, "Apple Music couldn't load this")
        XCTAssertEqual(appleMusic?.message, SpotiglassL10n.string("error.playback.appleMusic.failed"))

        let offline = PlaylistBrowserViewModel.appleMusicDisplayError(for: URLError(.notConnectedToInternet), service: .appleMusic)
        XCTAssertEqual(offline?.message, "Couldn't reach Apple Music. Check your connection, then try again.")

        XCTAssertNil(PlaylistBrowserViewModel.appleMusicDisplayError(for: Sample(), service: .spotify))
        XCTAssertNil(PlaylistBrowserViewModel.appleMusicDisplayError(for: CancellationError(), service: .appleMusic))
    }

    /// Home sections showed only `localizedDescription` ("User not signed in").
    func testHomeSectionsShowTheAppleMusicSentence() {
        let state: HomeSectionState<[TrackRowViewModel]> = PlaylistBrowserViewModel.homeSectionState(
            for: MusicTokenRequestError.userNotSignedIn
        )
        XCTAssertEqual(state, .failed(SpotiglassL10n.string("appleMusic.error.signIn.message")))

        // Spotify's Home mapping is untouched.
        let spotify: HomeSectionState<[TrackRowViewModel]> = PlaylistBrowserViewModel.homeSectionState(
            for: SpotifyAPIError.forbidden(message: nil, details: nil)
        )
        XCTAssertEqual(spotify, .unavailable)
    }

    func testAppleMusicErrorsAreTranslated() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-errors-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }

        let display = PlaylistBrowserViewModel.displayError(for: MusicTokenRequestError.userNotSignedIn)
        XCTAssertEqual(display.title, "Bei Apple Music anmelden")
        XCTAssertEqual(display.message, "Öffne Musik, melde dich mit deinem Apple Account an und versuche es dann erneut.")
    }
}
