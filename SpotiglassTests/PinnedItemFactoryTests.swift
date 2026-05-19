import XCTest
@testable import Spotiglass

final class PinnedItemFactoryTests: XCTestCase {

    func testPlaylistFactoryUsesPlaylistKindAndStableID() {
        let playlist = SpotifyPlaylistSummary(
            id: "p1", name: "My Mix", ownerName: "Bob",
            imageURL: URL(string: "https://x/p.jpg"), trackCount: 12,
            snapshotID: "snap"
        )
        let pin = PinnedItem.playlist(playlist)
        XCTAssertEqual(pin.kind, .playlist)
        XCTAssertEqual(pin.id, "playlist:p1")
        XCTAssertEqual(pin.title, "My Mix")
        XCTAssertEqual(pin.subtitle, "Bob")
        XCTAssertEqual(pin.spotifyURI, "spotify:playlist:p1")
        XCTAssertEqual(pin.spotifyID, "p1")
        XCTAssertFalse(pin.isStale)
    }

    func testArtistDetailFactory() {
        let detail = SpotifyArtistDetail(
            id: "a1", name: "Artist One",
            imageURL: URL(string: "https://x/a.jpg"),
            followersTotal: 100, genres: ["rock"],
            uri: "spotify:artist:a1"
        )
        let pin = PinnedItem.artist(detail)
        XCTAssertEqual(pin.kind, .artist)
        XCTAssertEqual(pin.id, "artist:a1")
        XCTAssertEqual(pin.subtitle, "Artist")
        XCTAssertEqual(pin.spotifyURI, "spotify:artist:a1")
        XCTAssertEqual(pin.spotifyID, "a1")
    }

    func testArtistLightFactory() {
        let a = SpotifyArtist(id: "a2", name: "Lighter", imageURL: nil, uri: "spotify:artist:a2")
        let pin = PinnedItem.artist(a)
        XCTAssertEqual(pin.kind, .artist)
        XCTAssertEqual(pin.id, "artist:a2")
        XCTAssertEqual(pin.title, "Lighter")
        XCTAssertEqual(pin.spotifyURI, "spotify:artist:a2")
    }

    func testArtistAlbumFactoryUsesReleaseYearOrFallback() {
        let withYear = SpotifyArtistAlbum(
            id: "al1", name: "Year Album", imageURL: nil,
            releaseYear: "2024", totalTracks: 10, group: .album,
            uri: "spotify:album:al1"
        )
        let p1 = PinnedItem.album(withYear)
        XCTAssertEqual(p1.kind, .album)
        XCTAssertEqual(p1.id, "album:al1")
        XCTAssertEqual(p1.subtitle, "2024")
        XCTAssertEqual(p1.spotifyURI, "spotify:album:al1")

        let noYear = SpotifyArtistAlbum(
            id: "al2", name: "No Year", imageURL: nil,
            releaseYear: nil, totalTracks: 4, group: .single,
            uri: "spotify:album:al2"
        )
        let p2 = PinnedItem.album(noYear)
        XCTAssertEqual(p2.subtitle, "Album")
    }

    func testSpotifyAlbumFactoryJoinsArtistsForSubtitle() {
        let album = SpotifyAlbum(
            id: "al3", name: "Some Album",
            artists: ["A", "B", "C"], imageURL: nil,
            uri: "spotify:album:al3"
        )
        let pin = PinnedItem.album(album)
        XCTAssertEqual(pin.kind, .album)
        XCTAssertEqual(pin.id, "album:al3")
        XCTAssertEqual(pin.subtitle, "A, B, C")
        XCTAssertEqual(pin.spotifyID, "al3")
    }

    func testTrackFactoryJoinsArtists() {
        let track = SpotifyTrack(
            id: "t1", name: "Song",
            artists: ["A", "B"], albumArtworkURL: URL(string: "https://x/t.jpg"),
            durationMilliseconds: 1000, isExplicit: false, isPlayable: true,
            linkedFromID: nil, uri: "spotify:track:t1"
        )
        let pin = PinnedItem.track(track)
        XCTAssertEqual(pin.kind, .track)
        XCTAssertEqual(pin.id, "track:t1")
        XCTAssertEqual(pin.title, "Song")
        XCTAssertEqual(pin.subtitle, "A, B")
        XCTAssertEqual(pin.spotifyURI, "spotify:track:t1")
    }

    func testLikedSongsFactoryHasStableIDAndNoURI() {
        let pin = PinnedItem.likedSongs(ownerDisplay: "Bob", artworkURL: nil)
        XCTAssertEqual(pin.id, PinnedItem.likedSongsID)
        XCTAssertEqual(pin.kind, .likedSongs)
        XCTAssertNil(pin.spotifyURI)
        XCTAssertNil(pin.spotifyID, "likedSongs row has no Spotify entity ID")
    }

    func testSpotifyIDReturnsNilForMalformedID() {
        let manual = PinnedItem(
            id: "no-prefix-id", kind: .playlist, title: "T", subtitle: "S",
            artworkURL: nil, spotifyURI: nil, isStale: false
        )
        XCTAssertNil(manual.spotifyID)
    }

    func testPinnedItemIDFormulaIsStable() {
        XCTAssertEqual(PinnedItem.id(forKind: .playlist, spotifyID: "x"), "playlist:x")
        XCTAssertEqual(PinnedItem.id(forKind: .album, spotifyID: "x"), "album:x")
        XCTAssertEqual(PinnedItem.id(forKind: .artist, spotifyID: "x"), "artist:x")
        XCTAssertEqual(PinnedItem.id(forKind: .track, spotifyID: "x"), "track:x")
        XCTAssertEqual(PinnedItem.id(forKind: .likedSongs, spotifyID: "x"), "likedSongs:x")
    }

    func testPinnedItemKindRoundTripsThroughRawValue() {
        for k in PinnedItemKind.allCases {
            XCTAssertEqual(PinnedItemKind(rawValue: k.rawValue), k)
        }
    }
}
