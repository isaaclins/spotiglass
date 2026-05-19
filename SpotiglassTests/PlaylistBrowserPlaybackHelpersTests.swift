import XCTest
@testable import Spotiglass

final class PlaylistBrowserPlaybackHelpersTests: XCTestCase {
    private func sampleNowPlaying(uri: String = "spotify:track:abc") -> PlaybackNowPlaying {
        PlaybackNowPlaying(
            name: "Song",
            artists: ["Artist"],
            albumName: "Album",
            albumID: "al1",
            albumArtURL: nil,
            durationMilliseconds: 180_000,
            positionMilliseconds: 0,
            uri: uri
        )
    }

    func testAnchorPrefersMatchingPlayableURI() {
        let track = TrackRowViewModel(
            topTrack: SpotifyTrack(
                id: "t1",
                name: "A",
                artists: ["X"],
                albumArtworkURL: nil,
                durationMilliseconds: 1000,
                isExplicit: false,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:abc"
            ),
            listPosition: 1
        )
        let detail = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                SpotifyPlaylistSummary(
                    id: "p", name: "P", ownerName: "O",
                    imageURL: nil, trackCount: 1, snapshotID: "s"
                )
            ),
            tracks: [track]
        )
        let anchor = PlaylistBrowserPlaybackHelpers.anchorTrackIDForPlaylistListScrollRestore(
            detailContent: .playlist(detail),
            currentPlaybackURI: "spotify:track:abc",
            detailLastVisibleTrackID: "fallback"
        )
        XCTAssertEqual(anchor, track.id)
    }

    func testLyricsHalfwayTaskIDRequiresTrackID() {
        let np = sampleNowPlaying()
        XCTAssertNotNil(
            PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
                prefetchTrack: np,
                nextQueueURI: "spotify:track:next"
            )
        )
        XCTAssertNil(
            PlaylistBrowserPlaybackHelpers.lyricsHalfwayNextPreloadTaskID(
                prefetchTrack: PlaybackNowPlaying(
                    name: np.name,
                    artists: np.artists,
                    albumName: np.albumName,
                    albumID: np.albumID,
                    albumArtURL: np.albumArtURL,
                    durationMilliseconds: np.durationMilliseconds,
                    positionMilliseconds: np.positionMilliseconds,
                    uri: "spotify:episode:1"
                ),
                nextQueueURI: nil
            )
        )
    }

    func testQueueRelevantPlaybackKey() {
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.queueRelevantPlaybackKey(
                connectionState: .playing(sampleNowPlaying())
            ),
            "playing:spotify:track:abc"
        )
        XCTAssertEqual(
            PlaylistBrowserPlaybackHelpers.queueRelevantPlaybackKey(connectionState: .disconnected),
            "disconnected"
        )
    }
}
