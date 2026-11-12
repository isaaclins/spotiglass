import XCTest
@testable import Spotiglass

/// Artist album pagination as the app runs it: the artist page in `PlaylistBrowserViewModel`
/// (first pages on open, then Load More) over the real `SpotifyAPIClient`, with only the HTTP
/// answers stood in.
@MainActor
final class SpotifyAPIClientArtistAlbumsPaginationTests: XCTestCase {
    func testOpeningAnArtistAsksForTenAlbumsAndFollowsSpotifysNextURL() async throws {
        let http = ArtistAlbumsHTTPClient(albumPages: 2)
        let viewModel = makeViewModel(http: http, initialPages: 2)

        await viewModel.selectArtist(id: "ar1")

        let requests = http.albumRequests
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(first.path, "/v1/artists/ar1/albums")
        XCTAssertEqual(first.queryItems?.first { $0.name == "limit" }?.value, "10")
        XCTAssertEqual(requests.last, ArtistAlbumsHTTPClient.pageURL(offset: 10), "the second page is Spotify's next URL")
        XCTAssertEqual(try shownAlbumIDs(viewModel), ["alb-0", "alb-1"])
        XCTAssertFalse(try shownDetail(viewModel).canLoadMoreAlbums)
    }

    /// Opening reads only the first pages; Load More reads one more each time, until Spotify
    /// has no next page.
    func testOpeningStopsAtTheFirstPagesAndLoadMoreReadsTheRestOneByOne() async throws {
        let http = ArtistAlbumsHTTPClient(albumPages: 4)
        let viewModel = makeViewModel(http: http, initialPages: 2)

        await viewModel.selectArtist(id: "ar1")
        XCTAssertEqual(http.albumRequests.count, 2, "opening the artist reads only the first pages")
        XCTAssertEqual(try shownAlbumIDs(viewModel), ["alb-0", "alb-1"])
        XCTAssertTrue(try shownDetail(viewModel).canLoadMoreAlbums)

        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(http.albumRequests.count, 3)
        XCTAssertEqual(http.albumRequests.last, ArtistAlbumsHTTPClient.pageURL(offset: 20))
        XCTAssertEqual(try shownAlbumIDs(viewModel), ["alb-0", "alb-1", "alb-2"])
        XCTAssertTrue(try shownDetail(viewModel).canLoadMoreAlbums)

        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(try shownAlbumIDs(viewModel), ["alb-0", "alb-1", "alb-2", "alb-3"])
        XCTAssertFalse(try shownDetail(viewModel).canLoadMoreAlbums, "the last page has no next URL")

        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(http.albumRequests.count, 4, "nothing left to load")
    }

    /// A next URL Spotify already sent once ends the list instead of asking for the same page
    /// again and again.
    func testARepeatedNextURLEndsThePaginationOnOpenAndOnLoadMore() async throws {
        let http = ArtistAlbumsHTTPClient(albumPages: 99, repeatsNextURL: true)
        let viewModel = makeViewModel(http: http, initialPages: 5)

        await viewModel.selectArtist(id: "ar1")
        XCTAssertEqual(http.albumRequests.count, 2, "the repeated next URL was followed again")
        XCTAssertEqual(try shownAlbumIDs(viewModel), ["alb-0", "alb-1"])

        await viewModel.loadMoreArtistAlbums()
        XCTAssertEqual(http.albumRequests.count, 2, "Load More asked for a page it had read already")
        XCTAssertFalse(try shownDetail(viewModel).canLoadMoreAlbums)
    }

    // MARK: - Helpers

    private struct ArtistNotShown: Error {}

    private func makeViewModel(http: ArtistAlbumsHTTPClient, initialPages: Int) -> PlaylistBrowserViewModel {
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: http)
        return PlaylistBrowserViewModel(
            api: client,
            cache: MockBrowsingCache(),
            initialArtistAlbumPageCount: initialPages
        )
    }

    private func shownDetail(_ viewModel: PlaylistBrowserViewModel) throws -> ArtistDetailViewModel {
        guard case let .loaded(.artist(detail)) = viewModel.detailState else {
            XCTFail("expected a loaded artist, got \(viewModel.detailState)")
            throw ArtistNotShown()
        }
        return detail
    }

    private func shownAlbumIDs(_ viewModel: PlaylistBrowserViewModel) throws -> [String] {
        let detail = try shownDetail(viewModel)
        return (detail.albums + detail.singles + detail.compilations + detail.appearsOn).map(\.id).sorted()
    }
}

/// Answers the Spotify Web API the way the artist page uses it: the profile, the artist, its
/// album pages (one album per page, chained by `next`), an empty search and empty album tracks.
private final class ArtistAlbumsHTTPClient: HTTPClient {
    private let lock = NSLock()
    private let albumPages: Int
    private let repeatsNextURL: Bool
    private var recordedAlbumRequests: [URL] = []

    var albumRequests: [URL] { lock.withLock { recordedAlbumRequests } }

    init(albumPages: Int, repeatsNextURL: Bool = false) {
        self.albumPages = albumPages
        self.repeatsNextURL = repeatsNextURL
    }

    static func pageURL(offset: Int) -> URL {
        URL(string: "https://api.spotify.com/v1/artists/ar1/albums?include_groups=album&limit=10&offset=\(offset)")!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        let path = url.path
        let body: String
        if path == "/v1/me" {
            body = #"{"id":"user-1","display_name":"Listener","images":[],"country":"CH","product":"premium"}"#
        } else if path == "/v1/artists/ar1/albums" {
            body = albumPage(for: url)
        } else if path == "/v1/artists/ar1" {
            body = #"{"id":"ar1","name":"Paged Artist","images":[],"followers":{"total":1},"genres":[],"uri":"spotify:artist:ar1"}"#
        } else if path == "/v1/search" {
            body = "{}"
        } else if path.hasPrefix("/v1/albums/") {
            body = #"{"limit":10,"next":null,"total":0,"items":[]}"#
        } else {
            XCTFail("unexpected request \(url)")
            throw URLError(.badURL)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func albumPage(for url: URL) -> String {
        let index = lock.withLock { () -> Int in
            recordedAlbumRequests.append(url)
            return recordedAlbumRequests.count - 1
        }
        let next: String
        if repeatsNextURL {
            next = "\"\(Self.pageURL(offset: 10).absoluteString)\""
        } else if index + 1 < albumPages {
            next = "\"\(Self.pageURL(offset: (index + 1) * 10).absoluteString)\""
        } else {
            next = "null"
        }
        return """
        {
          "limit": 10,
          "next": \(next),
          "total": \(albumPages),
          "items": [
            {
              "id": "alb-\(index)",
              "name": "Album \(index)",
              "images": [],
              "release_date": "2020-01-01",
              "total_tracks": 1,
              "uri": "spotify:album:alb-\(index)",
              "album_group": "album"
            }
          ]
        }
        """
    }
}
