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

    func testTransportReadyAndNowPlayingAccessors() {
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
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
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
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
        UserDefaults.standard.set(NSNumber(value: 0.42), forKey: key)
        let viewModel = PlaybackSessionViewModel(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        XCTAssertEqual(viewModel.playbackVolume, 0.42, accuracy: 0.000_001)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
