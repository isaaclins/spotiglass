import MusicKit
import XCTest
@testable import Spotiglass

/// Apple Music behind `MusicBrowsingProvider`. MusicKit items are decoded from Apple Music API
/// JSON (the same shape MusicKit itself decodes), so no test needs an account or a permission.
final class AppleMusicBrowsingProviderTests: XCTestCase {
    // MARK: - Mapping

    func testSongMapsToANeutralTrack() throws {
        let track = AppleMusicItemMapping.track(try AppleMusicFixtures.song(
            id: "1440818839",
            title: "Kerala",
            artist: "Bonobo",
            album: "Migration",
            durationMs: 245_500,
            explicit: true,
            artistRefs: [("5201", "Bonobo")]
        ))

        XCTAssertEqual(track.id, "1440818839")
        XCTAssertEqual(track.name, "Kerala")
        XCTAssertEqual(track.artists, ["Bonobo"])
        XCTAssertEqual(track.artistRefs, [MusicArtistRef(id: "5201", name: "Bonobo")])
        XCTAssertEqual(track.albumName, "Migration")
        XCTAssertEqual(track.durationMilliseconds, 245_500)
        XCTAssertTrue(track.isExplicit)
        XCTAssertEqual(track.isPlayable, true)
        XCTAssertEqual(track.uri, "applemusic:song:1440818839")
        XCTAssertEqual(track.albumArtworkURL?.absoluteString, "https://example.com/art/1440818839/120x120bb.jpg")
    }

    func testSongWithoutPlayParametersOrArtworkStaysBrowsable() throws {
        let track = AppleMusicItemMapping.track(try AppleMusicFixtures.song(
            id: "i.1",
            title: "Demo",
            artist: nil,
            withArtwork: false,
            playable: false
        ))

        XCTAssertEqual(track.artists, [])
        XCTAssertNil(track.albumArtworkURL)
        XCTAssertEqual(track.isPlayable, false)
        XCTAssertFalse(track.isExplicit)
        XCTAssertEqual(track.durationMilliseconds, 200_000)
    }

    func testAlbumTrackTakesTheAlbumsArtworkAndID() throws {
        let album = try AppleMusicFixtures.album(id: "l.album", title: "Migration", tracks: [("i.1", "Kerala")])
        let track = AppleMusicItemMapping.track(try XCTUnwrap(album.tracks?.first), album: album)

        XCTAssertEqual(track.albumID, "l.album")
        XCTAssertEqual(track.albumName, "Migration")
        XCTAssertEqual(track.albumArtworkURL?.absoluteString, "https://example.com/art/l.album/120x120bb.jpg")
    }

    func testMusicVideoTrackMapsWithItsOwnURIKind() throws {
        let video = try AppleMusicFixtures.decode(MusicVideo.self, """
        {"id":"mv1","type":"music-videos","attributes":{"name":"Live","artistName":"Bonobo","durationInMillis":60000,
         "playParams":{"id":"mv1","kind":"musicVideo"}}}
        """)
        let album = try AppleMusicFixtures.album(id: "a1", title: "Live Album")
        let track = AppleMusicItemMapping.track(.musicVideo(video), album: album)

        XCTAssertEqual(track.uri, "applemusic:music-video:mv1")
        XCTAssertEqual(track.albumName, "Live Album")
        XCTAssertEqual(track.albumID, "a1")
        XCTAssertEqual(track.durationMilliseconds, 60_000)
    }

    func testPlaylistOwnerIsTheCuratorOrTheLibrary() throws {
        let editorial = AppleMusicItemMapping.playlistSummary(
            try AppleMusicFixtures.playlist(id: "pl.1", name: "Chill Mix", curator: "Apple Music", trackCount: 2),
            fallbackOwnerName: "You"
        )
        XCTAssertEqual(editorial.ownerName, "Apple Music")
        XCTAssertEqual(editorial.ownerID, "Apple Music")
        XCTAssertEqual(editorial.trackCount, 2)
        XCTAssertEqual(editorial.snapshotID, AppleMusicItemMapping.playlistSnapshotID)
        XCTAssertEqual(editorial.imageURL?.absoluteString, "https://example.com/art/pl.1/600x600bb.jpg")

        let own = AppleMusicItemMapping.playlistSummary(
            try AppleMusicFixtures.playlist(id: "p.2", name: "Road", curator: "  "),
            fallbackOwnerName: "You"
        )
        XCTAssertEqual(own.ownerName, "You")
        XCTAssertEqual(own.ownerID, AppleMusicBrowsingProvider.libraryUserID)
        XCTAssertNil(own.trackCount)
    }

    func testArtistAlbumGroupsAndReleaseYear() throws {
        let single = AppleMusicItemMapping.artistAlbum(try AppleMusicFixtures.album(id: "s", title: "S", isSingle: true))
        let compilation = AppleMusicItemMapping.artistAlbum(try AppleMusicFixtures.album(id: "c", title: "C", isCompilation: true))
        let album = AppleMusicItemMapping.artistAlbum(try AppleMusicFixtures.album(id: "a", title: "A", trackCount: 12))

        XCTAssertEqual(single.group, .single)
        XCTAssertEqual(compilation.group, .compilation)
        XCTAssertEqual(album.group, .album)
        XCTAssertEqual(album.releaseYear, "2019")
        XCTAssertEqual(album.totalTracks, 12)
        XCTAssertEqual(album.uri, "applemusic:album:a")
    }

    func testArtistDetailAndSearchCardsMap() throws {
        let artist = try AppleMusicFixtures.artist(id: "5201", name: "Bonobo", genres: ["Electronic"])
        let detail = AppleMusicItemMapping.artistDetail(artist)
        XCTAssertEqual(detail.genres, ["Electronic"])
        XCTAssertNil(detail.followersTotal)
        XCTAssertEqual(detail.uri, "applemusic:artist:5201")
        XCTAssertEqual(AppleMusicItemMapping.artist(artist).imageURL?.absoluteString, "https://example.com/art/5201/600x600bb.jpg")

        let album = AppleMusicItemMapping.album(try AppleMusicFixtures.album(id: "a", title: "Migration"))
        XCTAssertEqual(album.artists, ["Bonobo"])
        XCTAssertEqual(album.uri, "applemusic:album:a")
    }

    func testRepeatedSongsInOnePlaylistGetDistinctRowIDs() throws {
        let song = AppleMusicItemMapping.track(try AppleMusicFixtures.song(id: "1", title: "Again"))
        let items = AppleMusicItemMapping.playlistItems([song, song])
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertEqual(items.first?.content, .track(song))
    }

    // MARK: - Profile and library

    func testProfileUsesTheLibraryIDAndTheStorefrontAsMarket() async throws {
        let source = MockAppleMusicSource()
        source.countryCode = "ch"
        let profile = try await AppleMusicBrowsingProvider(source: source).currentUserProfile()

        XCTAssertEqual(profile.id, AppleMusicBrowsingProvider.libraryUserID)
        XCTAssertEqual(profile.country, "CH")
        XCTAssertNil(profile.displayName)
    }

    func testProfileWithoutAStorefrontStillLoads() async throws {
        let source = MockAppleMusicSource()
        source.countryCode = nil
        let profile = try await AppleMusicBrowsingProvider(source: source).currentUserProfile()
        XCTAssertNil(profile.country)
    }

    func testLibraryPlaylistsMap() async throws {
        let source = MockAppleMusicSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: "p.1", name: "Road")]
        let playlists = try await AppleMusicBrowsingProvider(source: source).currentUserPlaylists(limit: 50)

        XCTAssertEqual(playlists.map(\.name), ["Road"])
        XCTAssertEqual(source.calls, ["libraryPlaylists(50)"])
    }

    func testPlaylistTracksAskForEveryPageAndReportMissingPlaylists() async throws {
        let source = MockAppleMusicSource()
        source.playlistTracksByID["p.1"] = [.song(try AppleMusicFixtures.song(id: "1", title: "One"))]
        let provider = AppleMusicBrowsingProvider(source: source)

        let items = try await provider.playlistTracks(playlistID: "p.1", limit: 100, maxPages: 3)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(source.calls, ["playlistTracks(p.1,300)"])

        do {
            _ = try await provider.playlistTracks(playlistID: "missing", limit: 100, maxPages: 1)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppleMusicBrowsingError, .notFound)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLikedSongsAreTheLibrarySongsPagedUntilTheLastShortPage() async throws {
        let source = MockAppleMusicSource()
        source.librarySongCount = 450
        let result = try await AppleMusicBrowsingProvider(source: source).currentUserSavedTracks(limit: 50, maxPages: nil)

        XCTAssertEqual(result.tracks.count, 450)
        XCTAssertEqual(result.totalAvailable, 450)
        XCTAssertEqual(source.calls, ["librarySongs(200,0)", "librarySongs(200,200)", "librarySongs(200,400)"])
    }

    func testLikedSongsHonourAPageCap() async throws {
        let source = MockAppleMusicSource()
        source.librarySongCount = 450
        let result = try await AppleMusicBrowsingProvider(source: source).currentUserSavedTracks(limit: 50, maxPages: 1)

        XCTAssertEqual(result.tracks.count, 50)
        XCTAssertEqual(source.calls, ["librarySongs(50,0)"])
    }

    // MARK: - Home

    func testRecentlyPlayedMapsSongs() async throws {
        let source = MockAppleMusicSource()
        source.recentSongs = [try AppleMusicFixtures.song(id: "1", title: "Recent")]
        let tracks = try await AppleMusicBrowsingProvider(source: source).recentlyPlayedTracks(limit: 50, cacheMode: .freshOnly)
        XCTAssertEqual(tracks.map(\.name), ["Recent"])
    }

    func testTopTracksComeFromThePersonalMix() async throws {
        let source = MockAppleMusicSource()
        source.recommended = [
            try AppleMusicFixtures.playlist(id: "pl.editorial", name: "Chill", kind: "editorial"),
            try AppleMusicFixtures.playlist(id: "pl.mix", name: "Favourites Mix", kind: "personal-mix"),
        ]
        source.playlistTracksByID["pl.mix"] = [.song(try AppleMusicFixtures.song(id: "1", title: "Favourite"))]
        let tracks = try await AppleMusicBrowsingProvider(source: source).topTracks(limit: 20, timeRange: .shortTerm, cacheMode: .freshOnly)

        XCTAssertEqual(tracks.map(\.name), ["Favourite"])
        XCTAssertTrue(source.calls.contains("playlistTracks(pl.mix,20)"))
    }

    func testTopTracksFallBackToTheFirstRecommendationOrNothing() async throws {
        let source = MockAppleMusicSource()
        let provider = AppleMusicBrowsingProvider(source: source)
        let none = try await provider.topTracks(limit: 20, timeRange: .shortTerm, cacheMode: .freshOnly)
        XCTAssertEqual(none, [])

        source.recommended = [try AppleMusicFixtures.playlist(id: "pl.editorial", name: "Chill", kind: "editorial")]
        source.playlistTracksByID["pl.editorial"] = [.song(try AppleMusicFixtures.song(id: "2", title: "Calm"))]
        let fallback = try await provider.topTracks(limit: 20, timeRange: .shortTerm, cacheMode: .freshOnly)
        XCTAssertEqual(fallback.map(\.name), ["Calm"])
    }

    // MARK: - Album and artist detail

    func testAlbumTracksCarryTheAlbumAndRespectTheLimit() async throws {
        let source = MockAppleMusicSource()
        source.albumsByID["a1"] = try AppleMusicFixtures.album(id: "a1", title: "Migration", tracks: [("1", "One"), ("2", "Two")])
        let provider = AppleMusicBrowsingProvider(source: source)

        let tracks = try await provider.albumTracks(albumID: "a1", market: nil, limit: 1)
        XCTAssertEqual(tracks.map(\.name), ["One"])
        XCTAssertEqual(tracks.first?.albumID, "a1")

        let firstPage = try await provider.albumTracksFirstPage(albumID: "a1", market: nil, limit: 10)
        XCTAssertEqual(firstPage.count, 2)

        do {
            _ = try await provider.albumTracks(albumID: "missing", market: nil, limit: 10)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppleMusicBrowsingError, .notFound)
        }
    }

    func testArtistDetailAlbumsArePagedAndFilteredByGroup() async throws {
        let source = MockAppleMusicSource()
        source.artistsByID["5201"] = try AppleMusicFixtures.artist(id: "5201", name: "Bonobo", albums: [
            (id: "a1", single: false), (id: "a2", single: false), (id: "s1", single: true),
        ])
        source.topSongsByArtistID["5201"] = [try AppleMusicFixtures.song(id: "t1", title: "Top")]
        let provider = AppleMusicBrowsingProvider(source: source)

        let detail = try await provider.artistCached(id: "5201", cacheMode: .allowStale)
        XCTAssertEqual(detail.value.name, "Bonobo")
        XCTAssertFalse(detail.isStale)

        let firstPage = try await provider.artistAlbumsPage(
            id: "5201", includeGroups: [.album, .single], limit: 2, offset: 0, nextURL: nil, cacheMode: .bypassCache
        )
        XCTAssertEqual(firstPage.items.map(\.id), ["a1", "a2"])
        let next = try XCTUnwrap(firstPage.next)
        XCTAssertEqual(URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "2")

        let lastPage = try await provider.artistAlbumsPage(
            id: "5201", includeGroups: [.album, .single], limit: 2, offset: 2, nextURL: next, cacheMode: .bypassCache
        )
        XCTAssertEqual(lastPage.items.map(\.id), ["s1"])
        XCTAssertNil(lastPage.next)

        let albumsOnly = try await provider.artistAlbumsCached(id: "5201", includeGroups: [.album], limit: 10, cacheMode: .allowStale)
        XCTAssertEqual(albumsOnly.value.map(\.id), ["a1", "a2"])

        let top = try await provider.artistTopTracks(id: "5201", market: nil, cacheMode: .freshOnly)
        XCTAssertEqual(top.map(\.name), ["Top"])

        do {
            _ = try await provider.artist(id: "missing", cacheMode: .bypassCache)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppleMusicBrowsingError, .notFound)
        }
    }

    // MARK: - Search

    func testSearchPutsLibraryMatchesFirstAndDropsCatalogDuplicates() async throws {
        let source = MockAppleMusicSource()
        source.librarySearchItems = AppleMusicSearchItems(
            songs: [try AppleMusicFixtures.song(id: "i.1", title: "Kerala", artist: "Bonobo")],
            playlists: [try AppleMusicFixtures.playlist(id: "p.1", name: "Road")]
        )
        source.catalogSearchItems = AppleMusicSearchItems(
            songs: [
                try AppleMusicFixtures.song(id: "1", title: "Kerala", artist: "Bonobo"),
                try AppleMusicFixtures.song(id: "2", title: "Cirrus", artist: "Bonobo"),
            ],
            albums: [try AppleMusicFixtures.album(id: "a", title: "Migration")],
            artists: [try AppleMusicFixtures.artist(id: "5201", name: "Bonobo")],
            hasMore: true
        )
        let results = try await AppleMusicBrowsingProvider(source: source).search(query: " bonobo ", limit: 10)

        XCTAssertEqual(results.tracks.map(\.id), ["i.1", "2"])
        XCTAssertEqual(results.playlists.map(\.id), ["p.1"])
        XCTAssertEqual(results.albums.map(\.id), ["a"])
        XCTAssertEqual(results.artists.map(\.id), ["5201"])
        XCTAssertTrue(source.calls.contains("catalogSearch(bonobo,10,0)"))
        XCTAssertTrue(source.calls.contains("librarySearch(bonobo,10)"))
        let next = try XCTUnwrap(results.tracksPaging?.next)
        XCTAssertEqual(URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "10")
    }

    func testLaterSearchPagesAreCatalogOnlyAndCappedAtMusicKitsPageSize() async throws {
        let source = MockAppleMusicSource()
        source.catalogSearchItems = AppleMusicSearchItems(songs: [try AppleMusicFixtures.song(id: "1", title: "One")])
        let results = try await AppleMusicBrowsingProvider(source: source).search(
            query: "one", limit: 50, offset: 25, cacheMode: .bypassCache
        )

        XCTAssertEqual(source.calls, ["catalogSearch(one,25,25)"])
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertNil(results.tracksPaging?.next)
    }

    func testSearchSurvivesOneSideFailingButNotBoth() async throws {
        let source = MockAppleMusicSource()
        source.catalogSearchError = URLError(.notConnectedToInternet)
        source.librarySearchItems = AppleMusicSearchItems(songs: [try AppleMusicFixtures.song(id: "i.1", title: "Mine")])
        let provider = AppleMusicBrowsingProvider(source: source)

        let libraryOnly = try await provider.search(query: "mine", limit: 10)
        XCTAssertEqual(libraryOnly.tracks.map(\.name), ["Mine"])

        source.librarySearchError = URLError(.cancelled)
        do {
            _ = try await provider.search(query: "mine", limit: 10)
            XCTFail("expected the catalog error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testBlankSearchDoesNotReachMusicKit() async throws {
        let source = MockAppleMusicSource()
        let results = try await AppleMusicBrowsingProvider(source: source).search(query: "   ", limit: 10)
        XCTAssertEqual(results.tracks, [])
        XCTAssertEqual(source.calls, [])
    }

    func testEditsReportUnsupported() async {
        let provider = AppleMusicBrowsingProvider(source: MockAppleMusicSource())
        do {
            try await provider.saveTracks(ids: ["1"])
            XCTFail("expected unsupported")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}

// MARK: - Library artwork

final class AppleMusicArtworkRegistryTests: XCTestCase {
    func testOnlyNonHTTPArtworkNeedsMusicKit() throws {
        XCTAssertFalse(AppleMusicArtworkRegistry.needsMusicKit(try XCTUnwrap(URL(string: "https://example.com/a.jpg"))))
        XCTAssertFalse(AppleMusicArtworkRegistry.needsMusicKit(try XCTUnwrap(URL(string: "http://127.0.0.1/a.jpg"))))
        XCTAssertTrue(AppleMusicArtworkRegistry.needsMusicKit(try XCTUnwrap(URL(string: "musicKit://artwork/transient/600x600?id=A"))))
    }

    func testLibraryArtworkIsRegisteredUnderItsURLAndCatalogArtworkIsNot() throws {
        let registry = AppleMusicArtworkRegistry()
        let library = try AppleMusicFixtures.decode(Artwork.self, #"{"url":"musicKit://artwork/transient/{w}x{h}?id=A","width":600,"height":600}"#)
        let catalog = try AppleMusicFixtures.decode(Artwork.self, #"{"url":"https://example.com/{w}x{h}bb.jpg","width":600,"height":600}"#)

        let libraryURL = try XCTUnwrap(AppleMusicItemMapping.artworkURL(library, size: 120, registry: registry))
        let catalogURL = try XCTUnwrap(AppleMusicItemMapping.artworkURL(catalog, size: 120, registry: registry))

        XCTAssertEqual(registry.artwork(for: libraryURL), library)
        XCTAssertNil(registry.artwork(for: catalogURL))
        XCTAssertEqual(registry.count, 1)
        XCTAssertNil(AppleMusicItemMapping.artworkURL(nil, size: 120, registry: registry))
    }

    func testRegistryStaysBounded() throws {
        let registry = AppleMusicArtworkRegistry()
        let artwork = try AppleMusicFixtures.decode(Artwork.self, #"{"url":"musicKit://artwork/transient/{w}x{h}?id=A","width":1,"height":1}"#)
        for index in 0...AppleMusicArtworkRegistry.maxEntries {
            registry.register(artwork, for: try XCTUnwrap(URL(string: "musicKit://artwork/\(index)")))
        }
        XCTAssertLessThanOrEqual(registry.count, AppleMusicArtworkRegistry.maxEntries)
        XCTAssertNotNil(registry.artwork(for: try XCTUnwrap(URL(string: "musicKit://artwork/\(AppleMusicArtworkRegistry.maxEntries)"))))
    }
}

// MARK: - Service selection and session

final class AppleMusicSelectionAndSessionTests: XCTestCase {
    func testSpotifyUnlessTheHiddenSwitchSaysAppleMusic() {
        XCTAssertEqual(MusicServiceSelection.resolve(storedValue: nil, isScreenshotMode: false, isRunningUnitTests: false), .spotify)
        XCTAssertEqual(MusicServiceSelection.resolve(storedValue: "nonsense", isScreenshotMode: false, isRunningUnitTests: false), .spotify)
        XCTAssertEqual(MusicServiceSelection.resolve(storedValue: "appleMusic", isScreenshotMode: false, isRunningUnitTests: false), .appleMusic)
    }

    func testScreenshotModeAndTestsNeverReachAppleMusic() {
        XCTAssertEqual(MusicServiceSelection.resolve(storedValue: "appleMusic", isScreenshotMode: true, isRunningUnitTests: false), .spotify)
        XCTAssertEqual(MusicServiceSelection.resolve(storedValue: "appleMusic", isScreenshotMode: false, isRunningUnitTests: true), .spotify)
        XCTAssertEqual(MusicServiceSelection.current, .spotify)
    }

    @MainActor
    func testSessionAsksOnlyWhenTheUserHasNotAnswered() async {
        let authorization = MockAppleMusicAuthorization(status: .notDetermined, afterRequest: .authorized, canPlay: false)
        let session = AppleMusicSession(authorization: authorization)
        XCTAssertEqual(session.state, .checking)

        await session.refresh()
        XCTAssertEqual(session.state, .needsPermission)
        XCTAssertEqual(authorization.requestCount, 0)

        await session.requestAccess()
        XCTAssertEqual(session.state, .authorized)
        XCTAssertEqual(session.canPlayCatalogContent, false)
        XCTAssertEqual(authorization.requestCount, 1)

        await session.requestAccess()
        XCTAssertEqual(authorization.requestCount, 1)
    }

    @MainActor
    func testDeniedAndRestrictedPointToSystemSettings() async {
        for status in [MusicAuthorization.Status.denied, .restricted] {
            let session = AppleMusicSession(authorization: MockAppleMusicAuthorization(status: status))
            await session.requestAccess()
            XCTAssertEqual(session.state, .denied)
            XCTAssertNil(session.canPlayCatalogContent)
        }
        XCTAssertEqual(AppleMusicSession.privacySettingsURL.scheme, "x-apple.systempreferences")
    }
}

// MARK: - Test doubles

private final class MockAppleMusicAuthorization: AppleMusicAuthorizing, @unchecked Sendable {
    private var status: MusicAuthorization.Status
    private let afterRequest: MusicAuthorization.Status
    private let canPlay: Bool?
    private(set) var requestCount = 0

    init(status: MusicAuthorization.Status, afterRequest: MusicAuthorization.Status? = nil, canPlay: Bool? = nil) {
        self.status = status
        self.afterRequest = afterRequest ?? status
        self.canPlay = canPlay
    }

    func currentStatus() -> MusicAuthorization.Status { status }

    func requestAuthorization() async -> MusicAuthorization.Status {
        requestCount += 1
        status = afterRequest
        return status
    }

    func canPlayCatalogContent() async -> Bool? { canPlay }
}

private final class MockAppleMusicSource: AppleMusicContentSource, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    var calls: [String] { lock.withLock { recordedCalls } }

    var playlists: [Playlist] = []
    var playlistTracksByID: [String: [Track]] = [:]
    var librarySongCount = 0
    var recentSongs: [Song] = []
    var recommended: [Playlist] = []
    var albumsByID: [String: Album] = [:]
    var artistsByID: [String: Artist] = [:]
    var topSongsByArtistID: [String: [Song]] = [:]
    var catalogSearchItems = AppleMusicSearchItems()
    var librarySearchItems = AppleMusicSearchItems()
    var catalogSearchError: Error?
    var librarySearchError: Error?
    var countryCode: String? = "us"

    private func record(_ call: String) {
        lock.withLock { recordedCalls.append(call) }
    }

    func libraryPlaylists(limit: Int) async throws -> [Playlist] {
        record("libraryPlaylists(\(limit))")
        return playlists
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]? {
        record("playlistTracks(\(playlistID),\(limit))")
        return playlistTracksByID[playlistID]
    }

    func librarySongs(limit: Int, offset: Int) async throws -> [Song] {
        record("librarySongs(\(limit),\(offset))")
        let end = min(librarySongCount, offset + limit)
        guard offset < end else { return [] }
        return try (offset..<end).map { try AppleMusicFixtures.song(id: "i.\($0)", title: "Song \($0)") }
    }

    func recentlyPlayedSongs(limit: Int) async throws -> [Song] {
        record("recentlyPlayed(\(limit))")
        return recentSongs
    }

    func recommendedPlaylists() async throws -> [Playlist] {
        record("recommendedPlaylists")
        return recommended
    }

    func album(id: String) async throws -> Album? {
        record("album(\(id))")
        return albumsByID[id]
    }

    func artist(id: String) async throws -> Artist? {
        record("artist(\(id))")
        return artistsByID[id]
    }

    func artistTopSongs(artistID: String) async throws -> [Song] {
        record("artistTopSongs(\(artistID))")
        return topSongsByArtistID[artistID] ?? []
    }

    func catalogSearch(term: String, limit: Int, offset: Int) async throws -> AppleMusicSearchItems {
        record("catalogSearch(\(term),\(limit),\(offset))")
        if let catalogSearchError { throw catalogSearchError }
        return catalogSearchItems
    }

    func librarySearch(term: String, limit: Int) async throws -> AppleMusicSearchItems {
        record("librarySearch(\(term),\(limit))")
        if let librarySearchError { throw librarySearchError }
        return librarySearchItems
    }

    func storefrontCountryCode() async throws -> String {
        guard let countryCode else { throw URLError(.userAuthenticationRequired) }
        return countryCode
    }
}

/// MusicKit items decoded from Apple Music API resource JSON.
enum AppleMusicFixtures {
    static func decode<Item: Decodable>(_ type: Item.Type, _ json: String) throws -> Item {
        try JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func artwork(_ id: String) -> [String: Any] {
        ["url": "https://example.com/art/\(id)/{w}x{h}bb.jpg", "width": 3000, "height": 3000]
    }

    static func song(
        id: String,
        title: String,
        artist: String? = "Bonobo",
        album: String? = "Migration",
        durationMs: Int = 200_000,
        explicit: Bool = false,
        withArtwork: Bool = true,
        playable: Bool = true,
        artistRefs: [(String, String)] = []
    ) throws -> Song {
        var attributes: [String: Any] = ["name": title, "durationInMillis": durationMs]
        if let artist { attributes["artistName"] = artist }
        if let album { attributes["albumName"] = album }
        if explicit { attributes["contentRating"] = "explicit" }
        if withArtwork { attributes["artwork"] = artwork(id) }
        if playable { attributes["playParams"] = ["id": id, "kind": "song"] }
        var resource: [String: Any] = ["id": id, "type": "songs", "attributes": attributes]
        if !artistRefs.isEmpty {
            resource["relationships"] = ["artists": ["data": artistRefs.map {
                ["id": $0.0, "type": "artists", "attributes": ["name": $0.1]]
            }]]
        }
        return try decode(Song.self, try json(resource))
    }

    static func album(
        id: String,
        title: String,
        trackCount: Int = 10,
        isSingle: Bool = false,
        isCompilation: Bool = false,
        tracks: [(id: String, title: String)] = []
    ) throws -> Album {
        var resource: [String: Any] = [
            "id": id,
            "type": "albums",
            "attributes": [
                "name": title,
                "artistName": "Bonobo",
                "trackCount": trackCount,
                "releaseDate": "2019-01-11",
                "isSingle": isSingle,
                "isCompilation": isCompilation,
                "artwork": artwork(id),
            ] as [String: Any],
        ]
        if !tracks.isEmpty {
            // Album tracks arrive without their own artwork or album reference.
            resource["relationships"] = ["tracks": ["data": tracks.map {
                [
                    "id": $0.id,
                    "type": "songs",
                    "attributes": ["name": $0.title, "artistName": "Bonobo", "durationInMillis": 1000,
                                   "playParams": ["id": $0.id, "kind": "song"]] as [String: Any],
                ] as [String: Any]
            }]]
        }
        return try decode(Album.self, try json(resource))
    }

    static func playlist(
        id: String,
        name: String,
        curator: String? = nil,
        kind: String? = nil,
        trackCount: Int? = nil
    ) throws -> Playlist {
        var attributes: [String: Any] = ["name": name, "artwork": artwork(id)]
        if let curator { attributes["curatorName"] = curator }
        if let kind { attributes["playlistType"] = kind }
        var resource: [String: Any] = ["id": id, "type": "playlists", "attributes": attributes]
        if let trackCount {
            resource["relationships"] = ["tracks": ["data": (0..<trackCount).map {
                ["id": "t\($0)", "type": "songs", "attributes": ["name": "Track \($0)", "artistName": "Bonobo"]]
            }]]
        }
        return try decode(Playlist.self, try json(resource))
    }

    static func artist(
        id: String,
        name: String,
        genres: [String] = [],
        albums: [(id: String, single: Bool)] = []
    ) throws -> Artist {
        var resource: [String: Any] = [
            "id": id,
            "type": "artists",
            "attributes": ["name": name, "genreNames": genres, "artwork": artwork(id)] as [String: Any],
        ]
        if !albums.isEmpty {
            resource["relationships"] = ["albums": ["data": albums.map { album in
                [
                    "id": album.id,
                    "type": "albums",
                    "attributes": [
                        "name": album.id,
                        "artistName": name,
                        "trackCount": 1,
                        "isSingle": album.single,
                        "isCompilation": false,
                    ] as [String: Any],
                ] as [String: Any]
            }]]
        }
        return try decode(Artist.self, try json(resource))
    }
}
