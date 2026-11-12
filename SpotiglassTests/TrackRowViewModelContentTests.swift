import XCTest
@testable import Spotiglass

final class TrackRowViewModelContentTests: XCTestCase {
    func testPlaylistItemTrackMapsExplicitAndUnavailableBadges() {
        let playable = TrackRowViewModel(
            MusicPlaylistTrackItem(
                id: "t1",
                content: .track(MusicTrack(
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
            MusicPlaylistTrackItem(
                id: "t2",
                content: .track(MusicTrack(
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
            MusicPlaylistTrackItem(
                id: "ep1",
                content: .episode(MusicEpisode(
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
            MusicPlaylistTrackItem(
                id: "local1",
                content: .localTrack(MusicLocalTrack(
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
            MusicPlaylistTrackItem(id: "x", content: .unavailable(reason: .track)),
            listPosition: 3
        )
        XCTAssertEqual(missing.title, "Unavailable item")
        XCTAssertEqual(missing.subtitle, "Track is unavailable.")
        // The placeholder comes from the catalog now, not a literal (#159).
        XCTAssertEqual(missing.durationText, SpotiglassL10n.string("browser.duration.unknown"))
        XCTAssertEqual(missing.durationMilliseconds, 0)
    }

    /// The length used to be recovered by splitting its own display text, which
    /// breaks as soon as a locale presents it differently (#159).
    func testDurationIsCarriedAsANumberNotReparsedFromText() {
        let row = TrackRowViewModel(PlaylistBrowsingTestFixtures.track(id: "t"), listPosition: 1)
        XCTAssertEqual(row.durationMilliseconds, 180_000)
        XCTAssertEqual(row.durationText, TrackDuration.text(milliseconds: 180_000))

        // The shared formatter agrees with the playback model's entry point.
        XCTAssertEqual(
            PlaybackNowPlaying.durationText(milliseconds: 180_000),
            TrackDuration.text(milliseconds: 180_000)
        )
        XCTAssertEqual(TrackDuration.text(milliseconds: -5), TrackDuration.text(seconds: 0))
    }

    func testNumberedFactoriesPreserveOrder() {
        let tracks = [
            PlaylistBrowsingTestFixtures.track(id: "a"),
            PlaylistBrowsingTestFixtures.track(id: "b")
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

    func testPlaylistOccurrenceKeepsRowIDButPinsCanonicalTrackIdentity() {
        let canonicalTrack = MusicTrack(
            id: "track-real",
            name: "Same Song",
            artists: ["Artist"],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:track-real"
        )
        let row = TrackRowViewModel(
            MusicPlaylistTrackItem(id: "track-real:7", content: .track(canonicalTrack)),
            listPosition: 8
        )

        XCTAssertEqual(row.id, "track-real:7")
        XCTAssertEqual(row.pinnedTrackItem()?.id, "track:track-real")
        XCTAssertEqual(row.pinnedTrackItem()?.spotifyURI, "spotify:track:track-real")

        let movedRow = TrackRowViewModel(
            MusicPlaylistTrackItem(id: "track-real:2", content: .track(canonicalTrack)),
            listPosition: 3
        )
        XCTAssertEqual(movedRow.pinnedTrackItem(), row.pinnedTrackItem())
    }

    /// Apple Music songs pin from their row (context menu, Playback menu, drag) under the same
    /// ID the palette pins them with, so a palette pin can be undone from the row (#400).
    func testAppleMusicSongRowPinsLikeThePalette() {
        let song = MusicTrack(
            id: "i.8WEXyq3cKlvL",
            name: "Diamonds",
            artists: ["Rihanna"],
            albumArtworkURL: nil,
            durationMilliseconds: 225_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "applemusic:song:i.8WEXyq3cKlvL"
        )
        let row = TrackRowViewModel(
            MusicPlaylistTrackItem(id: "i.8WEXyq3cKlvL:3", content: .track(song)),
            listPosition: 4
        )

        XCTAssertEqual(row.pinnedTrackItem(), PinnedItem.track(song))
        XCTAssertEqual(row.pinnedTrackItem()?.spotifyURI, "applemusic:song:i.8WEXyq3cKlvL")
        XCTAssertEqual(TrackRowViewModel(topTrack: song, listPosition: 1).pinnedTrackItem(), PinnedItem.track(song))
        // The library continuation stays a Spotify feature.
        XCTAssertNil(row.spotifyTrackForPinning())
    }
}
