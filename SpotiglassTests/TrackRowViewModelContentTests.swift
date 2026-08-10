import XCTest

@testable import Spotiglass

final class TrackRowViewModelContentTests: XCTestCase {
    func testPlaylistItemTrackMapsExplicitAndUnavailableBadges() {
        let playable = TrackRowViewModel(
            SpotifyPlaylistTrackItem(
                id: "t1",
                content: .track(
                    SpotifyTrack(
                        id: "t1",
                        name: "Song",
                        artists: ["A"],
                        albumArtworkURL: nil,
                        durationMilliseconds: 61_000,
                        isExplicit: true,
                        isPlayable: true,
                        linkedFromID: nil,
                        uri: "spotify:track:t1"
                    ))
            ),
            listPosition: 1
        )
        XCTAssertEqual(playable.badgeText, "Explicit")
        XCTAssertEqual(playable.durationText, "1:01")
        XCTAssertEqual(playable.playableURI, "spotify:track:t1")

        let blocked = TrackRowViewModel(
            SpotifyPlaylistTrackItem(
                id: "t2",
                content: .track(
                    SpotifyTrack(
                        id: "t2",
                        name: "Blocked",
                        artists: ["A"],
                        albumArtworkURL: nil,
                        durationMilliseconds: 1_000,
                        isExplicit: false,
                        isPlayable: false,
                        linkedFromID: nil,
                        uri: "spotify:track:t2"
                    ))
            ),
            listPosition: 2
        )
        XCTAssertEqual(blocked.badgeText, "Unavailable")
        XCTAssertTrue(blocked.isUnavailable)
        XCTAssertNil(blocked.playableURI)
    }

    func testEpisodeLocalAndUnavailablePlaylistItems() {
        let episode = TrackRowViewModel(
            SpotifyPlaylistTrackItem(
                id: "ep1",
                content: .episode(
                    SpotifyEpisode(
                        id: "ep1",
                        name: "Episode",
                        showName: "Show",
                        artworkURL: nil,
                        durationMilliseconds: 3_600_000,
                        isPlayable: true,
                        uri: "spotify:episode:ep1"
                    ))
            ),
            listPosition: 1
        )
        XCTAssertEqual(episode.subtitle, "Show")
        XCTAssertEqual(episode.badgeText, "Episode")
        XCTAssertEqual(episode.playableURI, "spotify:episode:ep1")

        let local = TrackRowViewModel(
            SpotifyPlaylistTrackItem(
                id: "local1",
                content: .localTrack(
                    SpotifyLocalTrack(
                        name: "Local",
                        artists: [],
                        durationMilliseconds: 120_000,
                        uri: "spotify:local:1"
                    ))
            ),
            listPosition: 2
        )
        XCTAssertEqual(local.subtitle, "Local track")
        XCTAssertEqual(local.badgeText, "Local")
        XCTAssertNil(local.playableURI)

        let missing = TrackRowViewModel(
            SpotifyPlaylistTrackItem(id: "x", content: .unavailable(reason: "Region locked")),
            listPosition: 3
        )
        XCTAssertEqual(missing.title, "Unavailable item")
        XCTAssertEqual(missing.subtitle, "Region locked")
        XCTAssertEqual(missing.durationText, "--:--")
    }

    func testNumberedFactoriesPreserveOrder() {
        let tracks = [
            PlaylistBrowsingTestFixtures.track(id: "a"),
            PlaylistBrowsingTestFixtures.track(id: "b"),
        ]
        let rows = TrackRowViewModel.numberedPlaylistRows(tracks)
        XCTAssertEqual(rows.map(\.listPosition), [1, 2])
        XCTAssertEqual(rows.map(\.id), ["a", "b"])

        let top = TrackRowViewModel.numberedTopTracks([
            PlaylistBrowsingTestFixtures.fallbackTrack(id: "t1", name: "One", artistId: "ar")
        ])
        XCTAssertEqual(top.first?.listPosition, 1)
        XCTAssertEqual(top.first?.title, "One")
    }
}
