import XCTest
@testable import Spotiglass

final class SpotifyPlaybackModelsTests: XCTestCase {
    func testPlaybackProgressAnchorInterpolationAndFraction() {
        let anchor = PlaybackProgressAnchor(
            positionMilliseconds: 10_000,
            anchorDate: Date(timeIntervalSinceReferenceDate: 100),
            durationMilliseconds: 60_000,
            isAdvancing: true
        )
        let now = Date(timeIntervalSinceReferenceDate: 105)
        XCTAssertEqual(anchor.interpolatedPositionMs(at: now), 15_000)
        XCTAssertEqual(anchor.fraction(at: now), 0.25, accuracy: 0.001)
        let paused = PlaybackProgressAnchor(
            positionMilliseconds: 10_000,
            anchorDate: now,
            durationMilliseconds: 60_000,
            isAdvancing: false
        )
        XCTAssertEqual(paused.interpolatedPositionMs(at: now), 10_000)
        XCTAssertEqual(paused.fraction(at: now), 10_000.0 / 60_000.0, accuracy: 0.001)
    }

    func testPlaybackDisplayErrorEqualityIgnoresID() {
        let a = PlaybackDisplayError(title: "T", message: "M", recoveryAction: .reconnect)
        let b = PlaybackDisplayError(title: "T", message: "M", recoveryAction: .reconnect)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PlaybackDisplayError(title: "X", message: "M", recoveryAction: nil))
    }

    func testArtistTapTargetStableID() {
        XCTAssertEqual(ArtistTapTarget(id: "a1", name: "Artist").stableID, "artist-id:a1")
        XCTAssertEqual(ArtistTapTarget(id: nil, name: "Artist").stableID, "artist-name:artist")
    }

    func testSpotifyRepeatModeCycles() {
        XCTAssertEqual(SpotifyRepeatMode.off.next, .context)
        XCTAssertEqual(SpotifyRepeatMode.context.next, .track)
        XCTAssertEqual(SpotifyRepeatMode.track.next, .off)
    }

    func testQueueItemFromTrackEpisodeAndPlayback() {
        let track = PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "Song", artistId: "a1")
        let fromTrack = QueueItem.from(track: track)
        XCTAssertEqual(fromTrack.name, "Song")
        XCTAssertEqual(fromTrack.uri, track.uri)

        let episode = SpotifyEpisode(
            id: "ep1",
            name: "Episode",
            showName: "Show",
            artworkURL: nil,
            durationMilliseconds: 3_600_000,
            isPlayable: true,
            uri: "spotify:episode:ep1"
        )
        let fromEpisode = QueueItem.from(episode: episode)
        XCTAssertEqual(fromEpisode.subtitle, "Show")

        let np = PlaybackNowPlaying(
            name: "NP",
            artists: ["A"],
            albumName: "Al",
            albumID: "al1",
            albumArtURL: nil,
            durationMilliseconds: 120_000,
            positionMilliseconds: 0,
            uri: "spotify:track:np"
        )
        let fromPlayback = QueueItem.from(playback: np)
        XCTAssertEqual(fromPlayback.albumName, "Al")
        XCTAssertEqual(fromPlayback.artistTapTargets.count, 1)
    }

    func testQueueItemLyricsPrefetchRequiresTrackURI() {
        let trackItem = QueueItem(
            name: "T",
            subtitle: "A",
            albumArtURL: nil,
            durationMilliseconds: 1,
            uri: "spotify:track:abc"
        )
        XCTAssertNotNil(trackItem.playbackNowPlayingForLyricsPrefetch())
        let episodeItem = QueueItem(
            name: "E",
            subtitle: "S",
            albumArtURL: nil,
            durationMilliseconds: 1,
            uri: "spotify:episode:abc"
        )
        XCTAssertNil(episodeItem.playbackNowPlayingForLyricsPrefetch())
    }

    func testQueueItemArtistTapTargetsFromRefsAndFallback() {
        let refs = [SpotifyArtistRef(id: "1", name: "One")]
        XCTAssertEqual(QueueItem.artistTapTargets(artistRefs: refs, fallbackSubtitle: "ignored").count, 1)
        let fallback = QueueItem.artistTapTargets(artistRefs: [], fallbackSubtitle: "Alpha, Beta")
        XCTAssertEqual(fallback.count, 2)
    }

    func testSpotifyPlayerSnapshotAndConnectDevice() {
        let device = SpotifyConnectDevice(
            deviceID: "d1",
            isActive: true,
            isRestricted: false,
            name: "Mac",
            type: "computer"
        )
        XCTAssertEqual(device.id, "d1")
        let snapshot = SpotifyPlayerSnapshot(
            transport: SpotifyPlayerTransport(shuffle: true, repeatMode: .context),
            activeDevice: device,
            isPlaying: true
        )
        XCTAssertTrue(snapshot.transport.shuffle)
        XCTAssertTrue(snapshot.isPlaying)
    }
}
