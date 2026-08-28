import XCTest

@testable import Spotiglass

final class LibraryContinuationRankingTests: XCTestCase {
    private func track(
        _ id: String,
        artistID: String,
        artistName: String? = nil,
        playable: Bool? = true,
        linkedFromID: String? = nil
    ) -> SpotifyTrack {
        let resolvedArtistName = artistName ?? artistID
        return SpotifyTrack(
            id: id,
            name: "Track \(id)",
            artists: [resolvedArtistName],
            artistRefs: [SpotifyArtistRef(id: artistID, name: resolvedArtistName)],
            albumArtworkURL: nil,
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: playable,
            linkedFromID: linkedFromID,
            uri: "spotify:track:\(id)"
        )
    }

    private func artist(_ id: String, name: String? = nil) -> SpotifyArtist {
        let resolvedName = name ?? id
        return SpotifyArtist(
            id: id,
            name: resolvedName,
            imageURL: nil,
            uri: "spotify:artist:\(id)"
        )
    }

    func testRanksSameArtistFirstAndExcludesSeedDuplicatesAndUnplayableTracks() {
        let seed = track("seed", artistID: "seed-artist")
        let sameArtist = track("same", artistID: "seed-artist")
        let collaborator = track("collab", artistID: "other-artist")
        let unavailable = track("unavailable", artistID: "seed-artist", playable: false)
        let library = LibraryContinuationLibrary(
            savedTracks: [seed, sameArtist, sameArtist, unavailable],
            playlists: [
                LibraryContinuationPlaylist(
                    id: "playlist",
                    tracks: [seed, collaborator]
                )
            ]
        )

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20)

        XCTAssertEqual(result.map(\.id), ["same", "collab"])
    }

    func testPlaylistCoOccurrenceOutranksTopTrackAndRemainingLibraryFiller() {
        let seed = track("seed", artistID: "seed-artist")
        let cooccurring = track("co", artistID: "co-artist")
        let topTrack = track("top", artistID: "top-artist")
        let filler = track("filler", artistID: "filler-artist")
        let library = LibraryContinuationLibrary(
            savedTracks: [seed, filler, topTrack],
            playlists: [
                LibraryContinuationPlaylist(
                    id: "mood",
                    tracks: [seed, cooccurring]
                )
            ],
            topTracks: [topTrack]
        )

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20)

        XCTAssertEqual(result.map(\.id), ["co", "top", "filler"])
    }

    func testTopArtistAndFollowedArtistSignalsBreakFillerTies() {
        let seed = track("seed", artistID: "seed-artist")
        let followed = track("followed", artistID: "followed-artist")
        let topArtist = track("top-artist-track", artistID: "top-artist")
        let ordinary = track("ordinary", artistID: "ordinary-artist")
        let library = LibraryContinuationLibrary(
            savedTracks: [seed, ordinary, followed, topArtist],
            topArtists: [artist("top-artist"), artist("other-top")],
            followedArtists: [artist("followed-artist")]
        )

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20)

        XCTAssertEqual(result.map(\.id), ["top-artist-track", "followed", "ordinary"])
    }

    func testArtistTopTracksAreOnlyUsedWhenTheyAreAlreadyInTheCollectedLibrary() {
        let seed = track("seed", artistID: "seed-artist")
        let ownedSameArtist = track("owned", artistID: "seed-artist")
        let catalogOnly = track("catalog-only", artistID: "seed-artist")
        let library = LibraryContinuationLibrary(
            savedTracks: [seed, ownedSameArtist],
            artistTopTracks: [catalogOnly, ownedSameArtist]
        )

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20)

        XCTAssertEqual(result.map(\.id), ["owned"])
    }

    func testDeduplicatesRelinkedTrackRepresentations() {
        let seed = track("seed", artistID: "seed-artist")
        let relinked = track("regional", artistID: "other-artist", linkedFromID: "original")
        let original = track("original", artistID: "other-artist")
        let library = LibraryContinuationLibrary(savedTracks: [seed, relinked, original])

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20)

        XCTAssertEqual(result.map(\.id), ["regional"])
    }

    func testMatchesArtistNamesWhenAResponseHasNoArtistIDAndHonorsLimit() {
        let seed = track("seed", artistID: "seed-artist", artistName: "Beyonce")
        let sameName = track("same-name", artistID: "missing-id", artistName: "BEYONCE")
        let other = track("other", artistID: "other-artist")
        let library = LibraryContinuationLibrary(savedTracks: [seed, sameName, other])

        let result = LibraryContinuationRanking.rank(seed: seed, library: library, limit: 1)

        XCTAssertEqual(result.map(\.id), ["same-name"])
    }

    func testReturnsNoTracksForZeroLimitOrOnlyTheSeed() {
        let seed = track("seed", artistID: "seed-artist")
        let library = LibraryContinuationLibrary(savedTracks: [seed])

        XCTAssertEqual(LibraryContinuationRanking.rank(seed: seed, library: library, limit: 0), [])
        XCTAssertEqual(LibraryContinuationRanking.rank(seed: seed, library: library, limit: 20), [])
    }

    func testCacheEntryHonorsItsAge() {
        let seed = track("seed", artistID: "seed-artist")
        let entry = LibraryContinuationCacheEntry(
            library: LibraryContinuationLibrary(savedTracks: [seed]),
            cachedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(entry.isValid(now: Date(timeIntervalSince1970: 100 + 899), maxAge: 900))
        XCTAssertFalse(entry.isValid(now: Date(timeIntervalSince1970: 100 + 901), maxAge: 900))
    }
}
