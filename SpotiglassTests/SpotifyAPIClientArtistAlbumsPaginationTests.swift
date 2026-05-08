import XCTest
@testable import Spotiglass

/// Exercise the same `/v1/artists/{id}/albums` pagination rules as the former in-app
/// `SpotifyAPIClient.artistAlbums` helper (kept here so production stays Periphery-clean).
private func testTarget_fetchAllArtistAlbums(
    client: SpotifyAPIClient,
    id: String,
    includeGroups: String = "album,single,compilation,appears_on",
    limit: Int = 10
) async throws -> [SpotifyArtistAlbum] {
    guard !id.isEmpty else {
        throw SpotifyAPIError.invalidRequest("Artist ID is required.")
    }
    let effectiveLimit = min(max(1, limit), 10)
    let maxPages = 20
    var results: [SpotifyArtistAlbum] = []
    var nextURL: URL?
    var pagesFetched = 0
    var seenNextURLs: Set<String> = []
    repeat {
        try Task.checkCancellation()
        let page: SpotifyAPIClient.SpotifyArtistAlbumsPage
        if let url = nextURL {
            let key = url.absoluteString
            if seenNextURLs.contains(key) {
                break
            }
            seenNextURLs.insert(key)
            page = try await client.artistAlbumsPage(
                id: id,
                includeGroups: includeGroups,
                limit: effectiveLimit,
                offset: 0,
                nextURL: url,
                cacheMode: .freshOnly
            )
        } else {
            page = try await client.artistAlbumsPage(
                id: id,
                includeGroups: includeGroups,
                limit: effectiveLimit,
                offset: 0,
                nextURL: nil,
                cacheMode: .freshOnly
            )
        }
        pagesFetched += 1
        results.append(contentsOf: page.items)
        nextURL = page.next
        if pagesFetched >= maxPages {
            break
        }
    } while nextURL != nil

    return results
}

final class SpotifyAPIClientArtistAlbumsPaginationTests: XCTestCase {
    func testArtistAlbumsRequestsLimitTenAndPaginates() async throws {
        let httpClient = QueueHTTPClient([
            .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=0&limit=10",
              "limit": 10,
              "next": "https://api.spotify.com/v1/artists/ar1/albums?include_groups=album%2Csingle%2Ccompilation%2Cappears_on&limit=10&offset=10",
              "offset": 0,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "id": "alb1",
                  "name": "First Album",
                  "images": [],
                  "release_date": "2020-01-01",
                  "total_tracks": 10,
                  "uri": "spotify:album:alb1",
                  "album_group": "album"
                }
              ]
            }
            """),
            .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=10&limit=10",
              "limit": 10,
              "next": null,
              "offset": 10,
              "previous": null,
              "total": 2,
              "items": [
                {
                  "id": "alb2",
                  "name": "Second Album",
                  "images": [],
                  "release_date": "2021-01-01",
                  "total_tracks": 8,
                  "uri": "spotify:album:alb2",
                  "album_group": "single"
                }
              ]
            }
            """)
        ])
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await testTarget_fetchAllArtistAlbums(client: client, id: "ar1")

        let firstURL = try XCTUnwrap(httpClient.requests.first?.url?.absoluteString)
        XCTAssertTrue(firstURL.contains("/v1/artists/ar1/albums"))
        XCTAssertTrue(firstURL.contains("limit=10"))
        XCTAssertFalse(firstURL.contains("limit=50"))
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.map(\.id), ["alb1", "alb2"])
    }

    func testArtistAlbumsPaginationStopsWhenNextURLRepeats() async throws {
        let loopingPage = """
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=0&limit=10",
              "limit": 10,
              "next": "https://api.spotify.com/v1/artists/ar1/albums?include_groups=album&limit=10&offset=10",
              "offset": 0,
              "previous": null,
              "total": 999,
              "items": [
                {
                  "id": "alb-loop",
                  "name": "Loop Album",
                  "images": [],
                  "release_date": "2020-01-01",
                  "total_tracks": 1,
                  "uri": "spotify:album:alb-loop",
                  "album_group": "album"
                }
              ]
            }
            """
        let responses = (0..<5).map { _ in QueueHTTPClient.Response.json(loopingPage) }
        let httpClient = QueueHTTPClient(responses)
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await testTarget_fetchAllArtistAlbums(client: client, id: "ar1", includeGroups: "album", limit: 10)

        XCTAssertEqual(httpClient.requests.count, 2, "A repeated next URL should break pagination before duplicate page storms.")
        XCTAssertEqual(albums.count, 2)
    }

    func testArtistAlbumsPaginationStillCapsAtTwentyPagesForUniqueNextURLs() async throws {
        let responses: [QueueHTTPClient.Response] = (0..<25).map { index in
            let next: String
            if index < 24 {
                next = "\"https://api.spotify.com/v1/artists/ar1/albums?include_groups=album&limit=10&offset=\((index + 1) * 10)\""
            } else {
                next = "null"
            }
            return .json("""
            {
              "href": "https://api.spotify.com/v1/artists/ar1/albums?offset=\(index * 10)&limit=10",
              "limit": 10,
              "next": \(next),
              "offset": \(index * 10),
              "previous": null,
              "total": 999,
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
            """)
        }
        let httpClient = QueueHTTPClient(responses)
        let client = SpotifyAPIClient(tokenProvider: StaticSpotifyAccessTokenProvider(token: "token"), httpClient: httpClient)

        let albums = try await testTarget_fetchAllArtistAlbums(client: client, id: "ar1", includeGroups: "album", limit: 10)

        XCTAssertEqual(httpClient.requests.count, 20, "Pagination should stop at the max page cap when next URLs are unique.")
        XCTAssertEqual(albums.count, 20)
    }
}
