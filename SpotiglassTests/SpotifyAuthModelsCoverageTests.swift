import XCTest
@testable import Spotiglass

final class SpotifyAuthModelsCoverageTests: XCTestCase {
    func testLoopbackRedirectURIUsesDefaultPort() {
        let url = SpotifyAuthConfiguration.loopbackRedirectURI()
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:43824/callback")
    }

    func testConfigurationRejectsMissingClientID() {
        let redirect = URL(string: "http://127.0.0.1:43824/callback")!
        XCTAssertThrowsError(
            try SpotifyAuthConfiguration(clientID: "   ", redirectURI: redirect)
        ) { error in
            XCTAssertEqual(error as? SpotifyAuthConfigurationError, .missingClientID)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Enter a Spotify client ID before signing in.")
        }
    }

    func testConfigurationRejectsInvalidRedirectURI() {
        XCTAssertThrowsError(
            try SpotifyAuthConfiguration(
                clientID: "id",
                redirectURI: URL(string: "https://example.com/callback")!
            )
        ) { error in
            XCTAssertEqual(error as? SpotifyAuthConfigurationError, .invalidRedirectURI)
        }
    }

    func testConfigurationTrimsClientID() throws {
        let redirect = URL(string: "http://127.0.0.1:49152/callback")!
        let config = try SpotifyAuthConfiguration(clientID: "  trimmed  ", redirectURI: redirect)
        XCTAssertEqual(config.clientID, "trimmed")
    }

    func testAuthSettingsRoundTrip() {
        var settings = SpotifyAuthSettings(defaults: makeEphemeralDefaults())
        settings.clientID = "  abc  "
        settings.grantedScope = "streaming"
        XCTAssertEqual(settings.clientID, "abc")
        XCTAssertEqual(settings.grantedScope, "streaming")
        settings.grantedScope = nil
        XCTAssertNil(settings.grantedScope)
    }

    /// Screenshot mode launches the app with `-spotify.clientID screenshot-mode`. The argument
    /// domain makes that ID read like a saved one, and the client ID field in Settings hands it back
    /// to `AuthViewModel.clientID` when it ends editing. That write used to save it, so a normal
    /// launch afterwards tried to sign in with an ID that doesn't exist.
    @MainActor
    func testAClientIDFromALaunchArgumentIsNeverSaved() throws {
        let suiteName = "SpotiglassTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let launchArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var withClientID = launchArguments
        withClientID["spotify.clientID"] = "screenshot-mode"
        defaults.setVolatileDomain(withClientID, forName: UserDefaults.argumentDomain)
        addTeardownBlock {
            defaults.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: defaults),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        XCTAssertEqual(auth.clientID, "screenshot-mode")

        // What the field's binding does when it ends editing without a change.
        auth.clientID = auth.clientID
        auth.clientID = " screenshot-mode "

        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?["spotify.clientID"],
            "A client ID passed on the command line must stay out of the saved settings."
        )
        XCTAssertEqual(SpotifyAuthSettings(defaults: defaults).clientID, "screenshot-mode")

        // An ID the user types is still theirs to save.
        auth.clientID = "typed-id"
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["spotify.clientID"] as? String, "typed-id")
    }

    func testAuthenticatedSessionExpiryAndRefresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = AuthenticatedSession(
            accessToken: "old",
            tokenType: "Bearer",
            scope: "playlist-read-private",
            expiresAt: now.addingTimeInterval(100)
        )
        XCTAssertTrue(session.expires(within: 200, now: now))
        XCTAssertFalse(session.expires(within: 50, now: now))
        XCTAssertTrue(session.grantedScopes.contains("playlist-read-private"))

        let grant = SpotifyTokenGrant(
            accessToken: "new",
            tokenType: "Bearer",
            expiresAt: now.addingTimeInterval(3_600),
            refreshToken: nil,
            scope: "streaming"
        )
        let refreshed = session.refreshed(with: grant)
        XCTAssertEqual(refreshed.accessToken, "new")
        XCTAssertEqual(refreshed.scope, "streaming")
    }

    func testAuthenticatedSessionReportsMissingFeatureScopes() {
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "playlist-read-private playlist-read-collaborative user-library-read",
            expiresAt: Date().addingTimeInterval(3_600)
        )

        XCTAssertEqual(
            session.missingScopes(SpotifyAuthConfiguration.requiredSavedTracksModifyScopes),
            ["user-library-modify"]
        )
        XCTAssertFalse(session.includesScopes(SpotifyAuthConfiguration.requiredSavedTracksModifyScopes))
        XCTAssertTrue(session.includesScopes(SpotifyAuthConfiguration.requiredSavedTracksReadScopes))
    }

    func testScopeRequirementAcceptsOnePlaylistModificationScope() {
        let requirement = SpotifyScopeRequirement(anyOf: SpotifyAuthConfiguration.requiredPlaylistModifyScopes)

        XCTAssertEqual(
            requirement.missingScopes(from: ["playlist-modify-private"]),
            []
        )
        XCTAssertEqual(
            requirement.missingScopes(from: []),
            SpotifyAuthConfiguration.requiredPlaylistModifyScopes
        )
    }

    func testAuthDisplayErrorEqualityIgnoresID() {
        let a = AuthDisplayError(message: "Same")
        let b = AuthDisplayError(message: "Same")
        let c = AuthDisplayError(message: "Different")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
