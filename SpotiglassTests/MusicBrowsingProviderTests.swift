import XCTest
@testable import Spotiglass

/// The service-neutral browsing seam: Spotify behind `MusicBrowsingProvider`,
/// and the persisted shape of the renamed `Music*` domain models.
final class MusicBrowsingProviderTests: XCTestCase {
    private let emptySearchJSON = #"{"tracks":{"items":[],"total":0,"next":null},"artists":{"items":[],"total":0,"next":null},"albums":{"items":[],"total":0,"next":null},"playlists":{"items":[],"total":0,"next":null}}"#

    // MARK: - Spotify behind the protocol

    func testSpotifyPagedSearchThroughTheProtocolKeepsTheOffset() async throws {
        let httpClient = QueueHTTPClient([.json(emptySearchJSON)])
        let provider: any MusicBrowsingProvider = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        _ = try await provider.search(query: "mono", limit: 10, offset: 20, cacheMode: .bypassCache)

        // The protocol call must reach Spotify's paged search, not the
        // first-page-only default every provider inherits.
        let url = try XCTUnwrap(httpClient.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "20")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "mono")
    }

    func testSpotifyArtistAlbumsThroughTheProtocolSendsTheSameIncludeGroups() async throws {
        let httpClient = QueueHTTPClient([.json(#"{"items":[],"total":0,"limit":10,"offset":0,"next":null}"#)])
        let provider: any MusicBrowsingProvider = SpotifyAPIClient(
            tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"),
            httpClient: httpClient
        )

        _ = try await provider.artistAlbumsPage(
            id: "artist-1",
            includeGroups: [.album, .single, .compilation],
            limit: 10,
            offset: 0,
            nextURL: nil,
            cacheMode: .bypassCache
        )

        let url = try XCTUnwrap(httpClient.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "include_groups" }?.value, "album,single,compilation")
    }

    func testIncludeGroupsDefaultMatchesTheEarlierSpotifyString() {
        // The default used to be the literal "album,single,compilation,appears_on".
        // The GET cache keys on the query string, so it must not change.
        XCTAssertEqual(
            SpotifyAPIClient.includeGroupsQueryValue(MusicArtistAlbumGroup.allCases),
            "album,single,compilation,appears_on"
        )
        XCTAssertEqual(SpotifyAPIClient.includeGroupsQueryValue([]), "")
    }

    func testTopItemsTimeRangesUseSpotifyWireValues() {
        XCTAssertEqual(MusicTopItemsTimeRange.shortTerm.rawValue, "short_term")
        XCTAssertEqual(MusicTopItemsTimeRange.mediumTerm.rawValue, "medium_term")
        XCTAssertEqual(MusicTopItemsTimeRange.longTerm.rawValue, "long_term")
    }

    // MARK: - Default search for providers without paging

    func testDefaultPagedSearchServesTheFirstPageAndNothingAfterIt() async throws {
        let provider = FirstPageOnlySearchProvider()

        let first = try await provider.search(query: "q", limit: 10, offset: 0, cacheMode: .freshOnly)
        let later = try await provider.search(query: "q", limit: 10, offset: 10, cacheMode: .freshOnly)

        XCTAssertEqual(first.tracks.map(\.id), ["t1"])
        XCTAssertEqual(provider.searchCalls, 1)
        XCTAssertTrue(later.tracks.isEmpty)
        XCTAssertTrue(later.artists.isEmpty)
        XCTAssertTrue(later.albums.isEmpty)
        XCTAssertTrue(later.playlists.isEmpty)
    }

    // MARK: - Persisted shape

    func testTrackJSONWrittenByEarlierBuildsStillDecodes() throws {
        // Exactly what the playlist cache stored for a `SpotifyTrack` before the rename.
        let stored = #"""
        {"id":"t1","name":"Song","artists":["A"],"artistRefs":[{"id":"a1","name":"A"}],
         "albumArtworkURL":"https://i.scdn.co/image/x","albumName":"Album","albumID":"al1",
         "durationMilliseconds":1000,"isExplicit":false,"isPlayable":true,"uri":"spotify:track:t1"}
        """#
        let track = try JSONDecoder().decode(MusicTrack.self, from: Data(stored.utf8))

        XCTAssertEqual(track.id, "t1")
        XCTAssertEqual(track.artistRefs, [MusicArtistRef(id: "a1", name: "A")])
        XCTAssertEqual(track.albumID, "al1")
        XCTAssertNil(track.linkedFromID)
        XCTAssertEqual(track.uri, "spotify:track:t1")
    }

    func testPlaylistItemJSONWrittenByEarlierBuildsStillDecodes() throws {
        let stored = #"""
        [{"id":"row-1","content":{"track":{"_0":{"id":"t1","name":"Song","artists":["A"],
          "durationMilliseconds":1000,"isExplicit":true,"uri":"spotify:track:t1"}}}},
         {"id":"row-2","content":{"unavailable":{"reason":"gone"}}}]
        """#
        let items = try JSONDecoder().decode([MusicPlaylistTrackItem].self, from: Data(stored.utf8))

        XCTAssertEqual(items.map(\.id), ["row-1", "row-2"])
        guard case let .track(track) = items[0].content else {
            return XCTFail("expected a track")
        }
        XCTAssertEqual(track.artistRefs, [])
        XCTAssertEqual(items[1].content, .unavailable(reason: "gone"))
    }

    func testPlaylistSummaryRoundTripKeepsItsKeys() throws {
        let summary = MusicPlaylistSummary(
            id: "p1",
            name: "Mix",
            ownerID: "me",
            ownerName: "Me",
            imageURL: nil,
            trackCount: 3,
            snapshotID: "s1"
        )
        let data = try JSONEncoder().encode(summary)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys

        XCTAssertEqual(Set(keys), ["id", "name", "ownerID", "ownerName", "trackCount", "snapshotID"])
        XCTAssertEqual(try JSONDecoder().decode(MusicPlaylistSummary.self, from: data), summary)
    }
}

/// A provider that only knows single-page search, like a service without offsets.
private final class FirstPageOnlySearchProvider: MusicBrowsingProvider {
    private(set) var searchCalls = 0

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        searchCalls += 1
        let track = MusicTrack(
            id: "t1",
            name: "Song",
            artists: ["A"],
            albumArtworkURL: nil,
            durationMilliseconds: 1000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "provider:track:t1"
        )
        return MusicSearchResults(tracks: [track], artists: [], albums: [], playlists: [])
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { [] }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] { [] }
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
    func currentUserProfile() async throws -> MusicUserProfile {
        MusicUserProfile(id: "me", displayName: nil, country: nil)
    }
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        throw SpotifyAPIError.invalidRequest("unused")
    }
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        throw SpotifyAPIError.invalidRequest("unused")
    }
    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        MusicCachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        MusicArtistAlbumsPage(items: [], next: nil)
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] { [] }
}
