import XCTest

@testable import Spotiglass

@MainActor
final class PlaylistBrowserTapTargetResolverTests: XCTestCase {
    func testResolveArtistIDExactMatch() async throws {
        let results = SpotifySearchResults(
            tracks: [],
            artists: [
                SpotifyArtist(id: "a1", name: "Taylor Swift", imageURL: nil, uri: "spotify:artist:a1"),
                SpotifyArtist(id: "a2", name: "Other", imageURL: nil, uri: "spotify:artist:a2"),
            ],
            albums: [],
            playlists: []
        )
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Taylor Swift") { _, _ in results }
        XCTAssertEqual(id, "a1")
    }

    func testResolveArtistIDFallsBackToFirstResult() async throws {
        let results = SpotifySearchResults(
            tracks: [],
            artists: [SpotifyArtist(id: "a9", name: "Similar Name", imageURL: nil, uri: "spotify:artist:a9")],
            albums: [],
            playlists: []
        )
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "Taylor") { _, _ in results }
        XCTAssertEqual(id, "a9")
    }

    func testResolveArtistIDEmptyNameReturnsNil() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveArtistID(forName: "   ") { _, _ in
            XCTFail("search should not run")
            return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertNil(id)
    }

    func testResolveAlbumIDWithArtistHintBuildsQuery() async throws {
        var capturedQuery = ""
        let album = SpotifyAlbum(
            id: "alb1", name: "Midnights", artists: ["Taylor Swift"], imageURL: nil, uri: "spotify:album:alb1")
        let id = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(
            name: "Midnights", artistHint: "Taylor Swift"
        ) { query, limit in
            capturedQuery = query
            XCTAssertEqual(limit, 10)
            return SpotifySearchResults(tracks: [], artists: [], albums: [album], playlists: [])
        }
        XCTAssertEqual(capturedQuery, "album:\"Midnights\" artist:\"Taylor Swift\"")
        XCTAssertEqual(id, "alb1")
    }

    func testResolveAlbumIDWithoutArtistUsesAlbumOnlyQuery() async throws {
        var capturedQuery = ""
        _ = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: "Greatest Hits", artistHint: "") {
            query, _ in
            capturedQuery = query
            return SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertEqual(capturedQuery, "album:\"Greatest Hits\"")
    }

    func testResolveAlbumIDNoResultsReturnsNil() async throws {
        let id = try await PlaylistBrowserTapTargetResolver.resolveAlbumID(name: "Missing", artistHint: "") { _, _ in
            SpotifySearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        XCTAssertNil(id)
    }
}
