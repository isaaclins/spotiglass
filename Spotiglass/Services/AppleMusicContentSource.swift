import Foundation
import MusicKit

/// Items from one catalog or library search, in MusicKit's own types.
struct AppleMusicSearchItems {
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    /// Which types the service reported more results for after this page. Each Search tab
    /// pages one type, so one shared flag would keep Load More on a tab that has run out.
    var moreSongs = false
    var moreAlbums = false
    var moreArtists = false
    var morePlaylists = false

    /// Every type reports more (tests and simple fixtures).
    var hasMore: Bool {
        get { moreSongs || moreAlbums || moreArtists || morePlaylists }
        set { (moreSongs, moreAlbums, moreArtists, morePlaylists) = (newValue, newValue, newValue, newValue) }
    }

    init(
        songs: [Song] = [],
        albums: [Album] = [],
        artists: [Artist] = [],
        playlists: [Playlist] = [],
        hasMore: Bool = false
    ) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
        self.hasMore = hasMore
    }
}

/// The MusicKit requests the Apple Music provider needs, as one seam.
///
/// `MusicKitContentSource` is the live implementation. It only runs MusicKit requests and
/// returns MusicKit items; everything the browser sees is mapped in `AppleMusicBrowsingProvider`
/// and `AppleMusicItemMapping`, which tests drive with items decoded from Apple Music API JSON.
///
/// IDs are MusicKit item IDs. Lookups accept both library IDs (from the user's library) and
/// catalog IDs (from search and recommendations).
protocol AppleMusicContentSource: Sendable {
    /// One page of the user's library playlists, in the library's own order.
    func libraryPlaylists(limit: Int, offset: Int) async throws -> [Playlist]
    /// The tracks of each of these library playlists, keyed by playlist ID, read in one go to
    /// count them. Playlists the library returns no tracks for are left out, so an unknown count
    /// never reads as zero.
    func libraryPlaylistTracks(playlistIDs: [String]) async throws -> [String: [Track]]
    /// The tracks of one playlist, or `nil` when no playlist has that ID.
    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]?
    /// The songs MusicKit lists as the user's library, most recently added first. Songs that are
    /// only in a playlist come with them (#401); `isInLibrary` tells them apart.
    func librarySongs(limit: Int, offset: Int) async throws -> [Song]
    /// Whether a song from `librarySongs` is really in the library: only a library song has the
    /// date it was added. Separate because MusicKit can't decode that date from JSON.
    func isInLibrary(_ song: Song) -> Bool
    func recentlyPlayedSongs(limit: Int) async throws -> [Song]
    /// Playlists from the user's personal recommendations, in Apple's order.
    func recommendedPlaylists() async throws -> [Playlist]
    /// One album with its tracks loaded.
    func album(id: String) async throws -> Album?
    /// One artist with its albums loaded.
    func artist(id: String) async throws -> Artist?
    /// Every track of an album from `album(id:)`, following MusicKit's batches up to `limit`.
    func tracks(of album: Album, limit: Int) async throws -> [Track]
    /// Every album of an artist from `artist(id:)`, following MusicKit's batches up to `limit`.
    func albums(of artist: Artist, limit: Int) async throws -> [Album]
    func artistTopSongs(artistID: String) async throws -> [Song]
    func catalogSearch(term: String, limit: Int, offset: Int) async throws -> AppleMusicSearchItems
    func librarySearch(term: String, limit: Int) async throws -> AppleMusicSearchItems
    /// Two-letter storefront country code, e.g. `ch`.
    func storefrontCountryCode() async throws -> String
    /// What the Apple Music API says about each library playlist's cover (#444).
    func libraryPlaylistCovers() async throws -> [AppleMusicPlaylistCover]
}

/// Live MusicKit requests. Library reads use `MusicLibraryRequest` (read-only on macOS),
/// catalog reads `MusicCatalogResourceRequest` / `MusicCatalogSearchRequest`.
struct MusicKitContentSource: AppleMusicContentSource {
    /// MusicKit caps a catalog search page at 25 items per type.
    static let catalogSearchPageLimit = 25

    func libraryPlaylists(limit: Int, offset: Int) async throws -> [Playlist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = limit
        request.offset = offset
        // No `sort(by:)`: on macOS MusicKit's library backend aborts the process on sort
        // descriptors it does not support (seen on macOS 27 with `lastPlayedDate`).
        return Array(try await request.response().items)
    }

    func libraryPlaylistTracks(playlistIDs: [String]) async throws -> [String: [Track]] {
        guard !playlistIDs.isEmpty else { return [:] }
        // One local library query for the whole batch: each playlist comes back as a section
        // holding its tracks, which follow MusicKit's batches like every other read here, up to
        // the same bound as opening the playlist.
        var request = MusicLibrarySectionedRequest<Playlist, Track>()
        request.filterSections(matching: \.id, memberOf: playlistIDs.map { MusicItemID($0) })
        let sections = try await request.response().sections
        var tracks: [String: [Track]] = [:]
        for section in sections where !section.items.isEmpty {
            tracks[section.id.rawValue] = try await Self.collect(section.items, limit: Self.maxCountedPlaylistTracks)
        }
        return tracks
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]? {
        let id = MusicItemID(playlistID)
        var libraryRequest = MusicLibraryRequest<Playlist>()
        libraryRequest.filter(matching: \.id, equalTo: id)
        let playlist: Playlist?
        if let libraryPlaylist = try await libraryRequest.response().items.first {
            playlist = libraryPlaylist
        } else if Self.isLibraryPlaylistID(playlistID) {
            // A library playlist this Mac doesn't list yet (created moments ago). The catalog
            // answers its ID with an error, which took over the whole page (#395).
            return nil
        } else {
            playlist = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
                .response().items.first
        }
        guard let playlist else { return nil }
        let detailed = try await playlist.with([.tracks])
        return try await Self.collect(detailed.tracks, limit: limit)
    }

    /// Library playlists are `p.…` (cloud library) or a persistent ID; catalog ones are `pl.…`.
    static func isLibraryPlaylistID(_ id: String) -> Bool {
        AppleMusicLibraryEditor.isCloudPlaylistID(id) || Int64(id) != nil
    }

    func librarySongs(limit: Int, offset: Int) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.offset = offset
        request.sort(by: \.libraryAddedDate, ascending: false)
        return Array(try await request.response().items)
    }

    func isInLibrary(_ song: Song) -> Bool {
        song.libraryAddedDate != nil
    }

    func recentlyPlayedSongs(limit: Int) async throws -> [Song] {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = min(limit, 30)
        let songs = Array(try await request.response().items)
        return await Self.withAlbums(songs)
    }

    /// Recently played songs arrive without their album, and Home groups them by album. One
    /// catalog request loads the albums for all of them; songs it can't resolve stay as they are.
    private static func withAlbums(_ songs: [Song]) async -> [Song] {
        guard !songs.isEmpty else { return songs }
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: songs.map(\.id))
        request.properties = [.albums]
        guard let detailed = try? await request.response().items else { return songs }
        let byID = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { byID[$0.id] ?? $0 }
    }

    func recommendedPlaylists() async throws -> [Playlist] {
        let response = try await MusicPersonalRecommendationsRequest().response()
        return response.recommendations.flatMap { Array($0.playlists) }
    }

    func album(id: String) async throws -> Album? {
        let itemID = MusicItemID(id)
        var libraryRequest = MusicLibraryRequest<Album>()
        libraryRequest.filter(matching: \.id, equalTo: itemID)
        if let album = try await libraryRequest.response().items.first {
            return try await album.with([.tracks])
        }
        let catalog = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: itemID)
            .response().items.first
        return try await catalog?.with([.tracks])
    }

    func artist(id: String) async throws -> Artist? {
        let itemID = MusicItemID(id)
        var libraryRequest = MusicLibraryRequest<Artist>()
        libraryRequest.filter(matching: \.id, equalTo: itemID)
        if let artist = try await libraryRequest.response().items.first {
            return try await artist.with([.albums])
        }
        let catalog = try await MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: itemID)
            .response().items.first
        return try await catalog?.with([.albums])
    }

    /// `with([.tracks])` loads only the relationship's first batch; the rest needs `nextBatch()`.
    func tracks(of album: Album, limit: Int) async throws -> [Track] {
        try await Self.collect(album.tracks, limit: limit)
    }

    /// Like album tracks, an artist's albums arrive one batch at a time.
    func albums(of artist: Artist, limit: Int) async throws -> [Album] {
        try await Self.collect(artist.albums, limit: limit)
    }

    func artistTopSongs(artistID: String) async throws -> [Song] {
        // Top songs exist for catalog artists only; a library artist has none.
        let catalog = try await MusicCatalogResourceRequest<Artist>(
            matching: \.id,
            equalTo: MusicItemID(artistID)
        ).response().items.first
        guard let artist = try await catalog?.with([.topSongs]) else { return [] }
        return Array(artist.topSongs ?? [])
    }

    func catalogSearch(term: String, limit: Int, offset: Int) async throws -> AppleMusicSearchItems {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = min(limit, Self.catalogSearchPageLimit)
        request.offset = offset
        let response = try await request.response()
        var items = AppleMusicSearchItems(
            songs: Array(response.songs),
            albums: Array(response.albums),
            artists: Array(response.artists),
            playlists: Array(response.playlists)
        )
        items.moreSongs = response.songs.hasNextBatch
        items.moreAlbums = response.albums.hasNextBatch
        items.moreArtists = response.artists.hasNextBatch
        items.morePlaylists = response.playlists.hasNextBatch
        return items
    }

    /// MusicKit's library search has no offset, so it can't page like the catalog. This asks
    /// for MusicKit's page size and follows its batches up to `limit` per type.
    func librarySearch(term: String, limit: Int) async throws -> AppleMusicSearchItems {
        var request = MusicLibrarySearchRequest(
            term: term,
            types: [Song.self, Album.self, Artist.self, Playlist.self]
        )
        request.limit = min(limit, Self.catalogSearchPageLimit)
        let response = try await request.response()
        return AppleMusicSearchItems(
            songs: try await Self.collect(response.songs, limit: limit),
            albums: try await Self.collect(response.albums, limit: limit),
            artists: try await Self.collect(response.artists, limit: limit),
            playlists: try await Self.collect(response.playlists, limit: limit)
        )
    }

    func storefrontCountryCode() async throws -> String {
        try await MusicDataRequest.currentCountryCode
    }

    /// Upper bound for pages of library playlists, 100 each; only stops a runaway.
    static let maxPlaylistCoverPages = AppleMusicBrowsingProvider.maxLibraryPlaylists / 100

    func libraryPlaylistCovers() async throws -> [AppleMusicPlaylistCover] {
        var covers: [AppleMusicPlaylistCover] = []
        var next: String? = AppleMusicCloudRequests.libraryPlaylistsPath
        var pages = 0
        while let path = next, pages < Self.maxPlaylistCoverPages {
            try Task.checkCancellation()
            let page = try AppleMusicPlaylistCover.page(
                from: try await MusicDataRequestCloudLibrary.musicDataRequest(AppleMusicCloudRequests.get(path))
            )
            covers += page.covers
            next = page.next
            pages += 1
        }
        return covers
    }

    /// Follows MusicKit batches until `limit` items are collected or the collection ends.
    /// The most tracks a playlist is counted to: what opening it reads (100 pages of 100).
    static let maxCountedPlaylistTracks = 10_000

    private static func collect<Item>(_ collection: MusicItemCollection<Item>?, limit: Int) async throws -> [Item] {
        guard var batch = collection else { return [] }
        var items = Array(batch)
        while items.count < limit, batch.hasNextBatch, let next = try await batch.nextBatch() {
            try Task.checkCancellation()
            items.append(contentsOf: next)
            batch = next
        }
        return Array(items.prefix(limit))
    }
}

/// The live permission and subscription answers, straight from MusicKit.
struct SystemAppleMusicAuthorization: AppleMusicAuthorizing {
    func currentStatus() -> MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    func requestAuthorization() async -> MusicAuthorization.Status {
        await MusicAuthorization.request()
    }

    func canPlayCatalogContent() async -> Bool? {
        for await subscription in MusicSubscription.subscriptionUpdates {
            return subscription.canPlayCatalogContent
        }
        return nil
    }
}
