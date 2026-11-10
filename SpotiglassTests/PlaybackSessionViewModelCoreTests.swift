import XCTest
@testable import Spotiglass

@MainActor
final class PlaybackSessionViewModelCoreTests: XCTestCase {
    func testDisplayErrorMapsSpotifyAPIFailures() {
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: SpotifyAPIError.unauthorized).recoveryAction,
            .reauthenticate
        )
        let forbidden = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.forbidden(message: "Need Premium", details: nil))
        XCTAssertEqual(forbidden.title, "Spotify Premium required")
        XCTAssertEqual(forbidden.message, "Need Premium")

        let rateLimited = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.rateLimited(retryAfter: 4))
        XCTAssertTrue(rateLimited.message.contains("rate limiting"))

        let other = PlaybackSessionViewModel.displayError(for: SpotifyAPIError.notFound(message: nil))
        XCTAssertEqual(other.title, "Playback command failed")

        let generic = PlaybackSessionViewModel.displayError(for: URLError(.notConnectedToInternet))
        XCTAssertEqual(generic.title, "Playback command failed")
    }

    /// #470: a Spotify command that couldn't reach Spotify showed URLSession's text (the Mac's
    /// language) or the error's debug text ("network(...)") instead of a sentence in the app's.
    func testSpotifyNetworkFailuresReadInTheAppLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-network-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }
        let german = "Verbindung zu Spotify fehlgeschlagen. Prüfe dein Netzwerk und versuche es erneut."
        let urlError = URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])

        XCTAssertEqual(PlaybackSessionViewModel.displayError(for: urlError).message, german)
        XCTAssertEqual(PlaybackSessionViewModel.playbackHostConnectionFailedError(for: urlError).message, german)
        XCTAssertEqual(PlaybackSessionViewModel.displayError(for: SpotifyAPIError.network(german)).message, german)
        XCTAssertEqual(
            PlaybackSessionViewModel.displayError(for: SpotifyAPIError.server(statusCode: 502, message: nil, details: nil)).message,
            "Bei den Servern von Spotify ist ein Problem aufgetreten. Versuchen Sie es gleich noch einmal."
        )
    }

    /// #470: the Spotify player page reports its failures in English (its own text, or the
    /// page's "Spotify Web Playback SDK could not connect to Spotify."), so a German window read
    /// a German title over an English sentence.
    func testSpotifyPlayerPageErrorsReadInTheAppLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-sdk-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        defer { SpotiglassL10n.settingsStore = nil }
        let cases: [(MusicPlaybackEvent, String, String)] = [
            (.initializationError("Spotify Web Playback SDK could not connect to Spotify."),
             "Wiedergabe konnte nicht gestartet werden",
             "Spotiglass konnte keine Verbindung zur Spotify-Wiedergabe herstellen. Prüfen Sie die Verbindung und wählen Sie „Erneut verbinden“ aus."),
            (.authenticationError("Authentication failed"),
             "Erneut anmelden",
             "Ihre Spotify-Sitzung ist abgelaufen. Verbinden Sie sich erneut, um weiter abzuspielen."),
            (.accountError("This functionality is restricted to premium users only"),
             "Spotify Premium erforderlich",
             "Zum Abspielen von Musik in Spotiglass ist Spotify Premium erforderlich."),
            (.playbackError("Playback error"),
             "Wiedergabefehler",
             "Spotify konnte das nicht ausführen. Versuche es gleich erneut.")
        ]
        for (event, title, message) in cases {
            let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
            viewModel.handle(event)
            guard case let .error(shown) = viewModel.connectionState else {
                return XCTFail("\(event) should show an error, got \(viewModel.connectionState)")
            }
            XCTAssertEqual(shown.title, title, "\(event)")
            XCTAssertEqual(shown.message, message, "\(event)")
        }
    }

    func testPlaybackToggleReadinessMatchesLocalTransportStates() {
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        XCTAssertFalse(viewModel.isPlaybackToggleReady)

        viewModel.deviceID = "local-device"
        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        for state in [
            PlaybackConnectionState.ready(deviceID: "local-device"),
            .transferring(deviceID: "local-device"),
            .playing(track),
            .paused(track)
        ] {
            viewModel.setConnectionState(state)
            XCTAssertTrue(viewModel.isPlaybackToggleReady, "expected local state to be toggle-ready: \\(state)")
        }

        viewModel.setActivePlaybackDeviceID("remote-device")
        XCTAssertTrue(viewModel.isPlaybackToggleReady)
        viewModel.setActivePlaybackDeviceID("local-device")
        XCTAssertTrue(viewModel.isPlaybackToggleReady)

        for state in [
            PlaybackConnectionState.disconnected,
            .connecting,
            .unavailable("offline"),
            .error(PlaybackDisplayError(title: "Error", message: "Failed", recoveryAction: nil))
        ] {
            viewModel.setConnectionState(state)
            XCTAssertFalse(viewModel.isPlaybackToggleReady, "expected unavailable state to be gated: \\(state)")
        }
    }

    func testTransportReadyAndNowPlayingAccessors() {
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        XCTAssertFalse(viewModel.isPlaybackTransportReady)

        let track = PlaybackNowPlaying(
            name: "Song",
            artists: ["A"],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 100,
            positionMilliseconds: 0,
            uri: "spotify:track:1"
        )
        viewModel.setConnectionState(.playing(track))
        XCTAssertTrue(viewModel.isPlaybackTransportReady)
        XCTAssertEqual(viewModel.currentNowPlaying?.name, "Song")
        XCTAssertEqual(viewModel.currentNowPlayingURI, "spotify:track:1")

        viewModel.setConnectionState(.paused(track))
        XCTAssertEqual(viewModel.currentNowPlayingURI, "spotify:track:1")

        let displayError = PlaybackDisplayError(title: "T", message: "M", recoveryAction: nil)
        viewModel.setConnectionState(.error(displayError))
        XCTAssertNil(viewModel.currentNowPlaying)
        XCTAssertEqual(viewModel.connectionStateError?.title, "T")
    }

    func testTransferOriginAutomaticFlag() {
        XCTAssertTrue(PlaybackSessionViewModel.TransferOrigin.ensureBeforePlay.isAutomatic)
        XCTAssertTrue(PlaybackSessionViewModel.TransferOrigin.autoResume.isAutomatic)
        XCTAssertFalse(PlaybackSessionViewModel.TransferOrigin.userRetry.isAutomatic)
        XCTAssertFalse(PlaybackSessionViewModel.TransferOrigin.userManualConnect.isAutomatic)
    }

    func testFallbackNowPlayingAndStableTrackURI() {
        let viewModel = PlaybackSessionViewModel(provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        XCTAssertEqual(viewModel.fallbackNowPlaying().name, "Spotify playback")

        let track = PlaybackNowPlaying(
            name: "A",
            artists: [],
            albumName: nil,
            albumID: nil,
            albumArtURL: nil,
            durationMilliseconds: 1,
            positionMilliseconds: 0,
            uri: "spotify:track:stable"
        )
        viewModel.setConnectionState(.playing(track))
        XCTAssertEqual(viewModel.stableTransportTrackURI, "spotify:track:stable")
        viewModel.setConnectionState(.disconnected)
        XCTAssertEqual(viewModel.stableTransportTrackURI, "spotify:track:stable")
    }

    func testLoadStoredPlaybackVolumeFromUserDefaults() {
        let key = "spotiglass.playbackVolume"
        let defaults = makeEphemeralDefaults()
        defaults.set(NSNumber(value: 0.42), forKey: key)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()),
            defaults: defaults
        )
        XCTAssertEqual(viewModel.playbackVolume, 0.42, accuracy: 0.000_001)
    }
}
