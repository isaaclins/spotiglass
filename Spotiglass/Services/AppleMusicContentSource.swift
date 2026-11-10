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
    /// One playlist of the user's library without its tracks, or `nil` when the library lists
    /// none with that ID. Cheap next to reading the tracks: it tells whether the playlist changed
    /// since its tracks were last read (`lastModifiedDate`).
    func libraryPlaylist(id: String) async throws -> Playlist?
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
    /// Saved albums from `librarySearch` with their artists loaded, for the links under their
    /// cards (#478). Separate so only the page that shows them pays for it.
    func withArtists(libraryAlbums: [Album]) async -> [Album]
    /// Two-letter storefront country code, e.g. `ch`.
    func storefrontCountryCode() async throws -> String
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

    func libraryPlaylist(id: String) async throws -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first
    }

    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]? {
        let id = MusicItemID(playlistID)
        if let libraryPlaylist = try await libraryPlaylist(id: playlistID) {
            let detailed = try await libraryPlaylist.with([.tracks])
            return try await Self.collect(detailed.tracks, limit: limit)
        }
        if Self.isLibraryPlaylistID(playlistID) {
            // A library playlist this Mac doesn't list yet (created moments ago). The catalog
            // answers its ID with an error, which took over the whole page (#395).
            return nil
        }
        let catalog = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: id)
            .response().items.first
        guard let detailed = try await catalog?.with([.tracks]) else { return nil }
        return try await collectCatalog(
            detailed.tracks,
            limit: limit,
            relationship: AppleMusicCatalogRelationship(kind: "playlists", id: playlistID, name: "tracks")
        )
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

    /// Recently played songs arrive without their album and artists. Home groups them by album
    /// and links each artist under the card (#478), so one catalog request loads both for all
    /// of them; songs it can't resolve stay as they are.
    private static func withAlbums(_ songs: [Song]) async -> [Song] {
        guard !songs.isEmpty else { return songs }
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: songs.map(\.id))
        request.properties = [.albums, .artists]
        guard let detailed = try? await request.response().items else { return songs }
        let byID = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { byID[$0.id] ?? $0 }
    }

    /// Catalog search albums arrive without their artists. The search card links each artist
    /// under the cover (#478), so one catalog request loads them for the whole page; albums it
    /// can't resolve keep their plain artist name.
    private static func withArtists(_ albums: [Album]) async -> [Album] {
        guard !albums.isEmpty else { return albums }
        var request = MusicCatalogResourceRequest<Album>(matching: \.id, memberOf: albums.map(\.id))
        request.properties = [.artists]
        guard let detailed = try? await request.response().items else { return albums }
        let byID = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return albums.map { byID[$0.id] ?? $0 }
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

    /// `with([.tracks])` loads only the relationship's first batch; the rest is read the way
    /// its kind of album allows (see `collectCatalog`).
    func tracks(of album: Album, limit: Int) async throws -> [Track] {
        guard Self.needsMore(album.tracks, limit: limit), !(try await isLibraryAlbum(album.id)) else {
            return try await Self.collect(album.tracks, limit: limit)
        }
        return try await collectCatalog(
            album.tracks,
            limit: limit,
            relationship: AppleMusicCatalogRelationship(kind: "albums", id: album.id.rawValue, name: "tracks")
        )
    }

    /// Like album tracks, an artist's albums arrive one batch at a time.
    func albums(of artist: Artist, limit: Int) async throws -> [Album] {
        guard Self.needsMore(artist.albums, limit: limit), !(try await isLibraryArtist(artist.id)) else {
            return try await Self.collect(artist.albums, limit: limit)
        }
        return try await collectCatalog(
            artist.albums,
            limit: limit,
            relationship: AppleMusicCatalogRelationship(kind: "artists", id: artist.id.rawValue, name: "albums")
        )
    }

    /// Whether a relationship has more to read than its first batch.
    private static func needsMore<Item>(_ collection: MusicItemCollection<Item>?, limit: Int) -> Bool {
        guard let collection else { return false }
        return collection.hasNextBatch && collection.count < limit
    }

    /// Whether this item came from the library: `album(id:)` and `artist(id:)` look there first,
    /// under the same ID.
    private func isLibraryAlbum(_ id: MusicItemID) async throws -> Bool {
        var request = MusicLibraryRequest<Album>()
        request.filter(matching: \.id, equalTo: id)
        return try await !request.response().items.isEmpty
    }

    private func isLibraryArtist(_ id: MusicItemID) async throws -> Bool {
        var request = MusicLibraryRequest<Artist>()
        request.filter(matching: \.id, equalTo: id)
        return try await !request.response().items.isEmpty
    }

    private func collectCatalog<Item: MusicItem & Decodable>(
        _ firstBatch: MusicItemCollection<Item>?,
        limit: Int,
        relationship: AppleMusicCatalogRelationship
    ) async throws -> [Item] {
        try await AppleMusicCatalogPages.collect(firstBatch, limit: limit, relationship: relationship) {
            try await storefrontCountryCode()
        }
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
            albums: await Self.withArtists(Array(response.albums)),
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

    /// Saved albums arrive without their artists too. They come from the local library, so each
    /// loads its own; an album whose artists can't be read keeps its plain artist name (#478).
    func withArtists(libraryAlbums albums: [Album]) async -> [Album] {
        await withTaskGroup(of: (Int, Album).self) { group in
            for (index, album) in albums.enumerated() {
                group.addTask { (index, (try? await album.with([.artists])) ?? album) }
            }
            var loaded = albums
            for await (index, album) in group {
                loaded[index] = album
            }
            return loaded
        }
    }

    func storefrontCountryCode() async throws -> String {
        try await MusicDataRequest.currentCountryCode
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

/// One relationship of a catalog item, e.g. the albums of an artist.
struct AppleMusicCatalogRelationship: Equatable {
    /// The API's resource type: `artists`, `albums`, `playlists`.
    let kind: String
    let id: String
    let name: String

    func path(storefront: String) -> String {
        "/v1/catalog/\(storefront)/\(kind)/\(AppleMusicCloudRequests.pathComponent(id))/\(name)"
            + "?limit=\(AppleMusicCatalogPages.pageSize)"
    }
}

/// Reads a catalog relationship from the Apple Music API page by page, following each page's
/// `next` path, so MusicKit never has to load a next batch (#465).
enum AppleMusicCatalogPages {
    /// The API's largest page for an artist's albums.
    static let pageSize = 100

    private struct Next: Decodable {
        let next: String?
    }

    /// A catalog relationship past its first batch, read from the Apple Music API by offset.
    ///
    /// MusicKit can't follow a catalog relationship's batches: asking for the next one stops the
    /// whole app inside MusicKit ("Loading next batch of catalog resource collection of a non
    /// decodable music item type is not supported", macOS 27). An artist with more than 25 albums
    /// closed Spotiglass while its page loaded (#465). Library relationships page normally.
    static func collect<Item: MusicItem & Decodable>(
        _ firstBatch: MusicItemCollection<Item>?,
        limit: Int,
        relationship: AppleMusicCatalogRelationship,
        storefront: () async throws -> String = { try await MusicDataRequest.currentCountryCode },
        fetch: (String) async throws -> Data = Self.fetch
    ) async throws -> [Item] {
        guard let firstBatch, firstBatch.hasNextBatch, firstBatch.count < limit else {
            return Array((firstBatch ?? []).prefix(limit))
        }
        let path = relationship.path(storefront: try await storefront())
        return try await items(Item.self, from: path, limit: limit, fetch: fetch)
    }

    /// One API page. Its error stays MusicKit's or the network's, so a failed read shows as
    /// a failed read, not as a library change Apple Music refused.
    static func fetch(_ path: String) async throws -> Data {
        let request = AppleMusicCloudRequests.get(path)
        do {
            return try await MusicDataRequest(urlRequest: request).response().data
        } catch {
            if !(error is CancellationError) {
                SpotiglassLog.error(.api, "Apple Music GET \(request.url?.path ?? "") failed: \(error)")
            }
            throw error
        }
    }

    static func items<Item: MusicItem & Decodable>(
        _ type: Item.Type,
        from firstPath: String,
        limit: Int,
        fetch: (String) async throws -> Data
    ) async throws -> [Item] {
        var items: [Item] = []
        var seenPaths: Set<String> = []
        var next: String? = firstPath
        while let path = next, items.count < limit, seenPaths.insert(path).inserted {
            try Task.checkCancellation()
            let data = try await fetch(path)
            let page = try JSONDecoder().decode(MusicItemCollection<Item>.self, from: data)
            guard !page.isEmpty else { break }
            items.append(contentsOf: page)
            next = try JSONDecoder().decode(Next.self, from: data).next.map(withPageSize)
        }
        return Array(items.prefix(limit))
    }

    /// The API's `next` path keeps the offset but not the page size, which falls back to 25.
    static func withPageSize(_ path: String) -> String {
        guard var components = URLComponents(string: path) else { return path }
        var query = (components.queryItems ?? []).filter { $0.name != "limit" }
        query.append(URLQueryItem(name: "limit", value: String(pageSize)))
        components.queryItems = query
        return components.string ?? path
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
