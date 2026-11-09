import Foundation
import MusicKit

/// Browsing failures specific to Apple Music.
enum AppleMusicBrowsingError: LocalizedError, Equatable {
    /// The playlist, album or artist is neither in the library nor in the catalog.
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            SpotiglassL10n.string("appleMusic.error.notFound")
        }
    }
}

/// What went wrong with Apple Music, in terms the listener can act on.
///
/// MusicKit's own errors read in English only ("User not signed in") and say nothing about what to
/// do, so the browser shows these instead, in the app's language (#397).
enum AppleMusicFailure: Equatable {
    /// No Apple Account is signed in to Media & Purchases, or its session ended.
    case notSignedIn
    /// Apple's privacy notice for Music was never accepted on this Mac.
    case privacyNoticeNotAccepted
    /// Spotiglass's Media & Apple Music permission is off.
    case accessOff
    /// Apple Music refused this copy of the app (no developer token). Nothing the listener can fix.
    case unavailable
    /// The item is neither in the library nor in the catalog.
    case notFound
    /// The request didn't reach Apple Music.
    case network
    /// Anything else.
    case failed

    /// The failure an Apple Music error stands for, or `nil` for an error that isn't Apple Music's.
    static func from(_ error: Error) -> AppleMusicFailure? {
        switch error {
        case is AppleMusicBrowsingError:
            return .notFound
        case let error as MusicTokenRequestError:
            switch error {
            case .userNotSignedIn, .userTokenRevoked, .userTokenRequestFailed: return .notSignedIn
            case .privacyAcknowledgementRequired: return .privacyNoticeNotAccepted
            case .permissionDenied: return .accessOff
            case .developerTokenRequestFailed: return .unavailable
            // MusicKit's catch-all, often passing: keep Retry.
            case .unknown: return .failed
            @unknown default: return .failed
            }
        case let error as MusicDataRequest.Error:
            return from(httpStatus: error.status)
        case let error as MusicSubscription.Error:
            switch error {
            case .permissionDenied: return .accessOff
            case .privacyAcknowledgementRequired: return .privacyNoticeNotAccepted
            case .unknown: return .failed
            @unknown default: return .failed
            }
        case let error as MusicLibrary.Error:
            return error == .permissionDenied ? .accessOff : .failed
        default:
            return nil
        }
    }

    /// The Apple Music API's HTTP status alone doesn't say which fix applies: 401 is mostly the
    /// developer token but also a signed-out user, 403 a user-token problem or the unaccepted
    /// privacy notice (Apple's "HTTP Status Codes" reference). Those read as the generic failure
    /// with Retry; the precise cases come from MusicKit's token errors above.
    static func from(httpStatus: Int) -> AppleMusicFailure {
        httpStatus == 404 ? .notFound : .failed
    }
}

/// `MusicBrowsingProvider` for Apple Music, through MusicKit.
///
/// How the browser's surfaces map onto Apple Music:
/// - **Library playlists**: `MusicLibraryRequest<Playlist>`, in the library's own order (sorting
///   by last played aborts MusicKit's macOS library backend), every page of them.
/// - **Liked Songs**: the songs in the user's library, newest first. Apple Music has no
///   separate "liked" list a native app can read; loving a song is a rating, and MusicKit on
///   macOS offers no request for loved songs. The library is what the user chose to keep, which
///   is what Liked Songs is on Spotify.
/// - **Home**: "Recently played" is `MusicRecentlyPlayedRequest<Song>`. "Your top tracks" are the
///   songs of the user's personal mix from `MusicPersonalRecommendationsRequest` (Apple's
///   Favourites / Heavy Rotation mixes are built from what the user plays most), falling back to
///   the first recommended playlist.
/// - **Search**: library matches first, then the catalog, so the palette finds the user's own
///   music before the rest of Apple Music. Later pages are catalog only.
/// - **Edits**: MusicKit's library is read-only on macOS, so edits go through the Apple Music API
///   and the Music app (`AppleMusicLibraryEditor`, `AppleMusicBrowsingProvider+LibraryEdits`).
///   Their failures are `AppleMusicLibraryEditError`, never the protocol's Spotify defaults.
///   Reads lay the edits the library on this Mac has not caught up with over their results.
///
/// Response caching is MusicKit's own, so `cacheMode` is accepted and ignored.
struct AppleMusicBrowsingProvider: MusicBrowsingProvider {
    /// The library has no account ID a native app can read. This constant stands in for it, so
    /// pins and library row order are kept apart from every Spotify account.
    static let libraryUserID = "apple-music-library"
    /// Upper bound for Liked Songs, so a very large library cannot grow without limit.
    static let maxLibrarySongs = 10_000
    static let librarySongsPageSize = 200
    /// Upper bound for library playlists; far above any real library, it only stops a runaway.
    static let maxLibraryPlaylists = 5_000
    /// Library matches per type on the first search page.
    static let maxLibrarySearchMatches = 100
    /// Catalog pages a later search page may skip because deduplication left them empty.
    static let maxSkippedSearchPages = 10
    /// Pages of album tracks `albumTracks` follows, the same as the Spotify client.
    static let albumTrackPages = 6
    /// Upper bound for one artist's albums, singles and compilations.
    static let maxArtistAlbums = 1_000
    /// Bound for counting a library album's songs when MusicKit gives no album track count.
    static let maxLibraryAlbumTracks = 500
    /// How many library albums of an artist page are counted at once.
    static let libraryAlbumCountParallelism = 4

    let source: any AppleMusicContentSource

    /// An artist page asks for its albums once per page; MusicKit delivers all of them in
    /// batches, so they are kept here briefly instead of being fetched again for every page.
    /// One cache per provider: the browser keeps its provider for its lifetime.
    let artistAlbumsCache: AppleMusicArtistAlbumsCache
    /// Library playlists come without a track count; counts loaded once are kept here so a
    /// sidebar refresh shows them straight away.
    let trackCountCache: AppleMusicPlaylistTrackCountCache
    let editor: AppleMusicLibraryEditor
    /// Library playlists whose cover Apple generated, from the last listing, by library ID and,
    /// for shared ones, by catalog ID, so search results
    /// show them with the same placeholder as the sidebar (#444). The app passes `.shared`: the
    /// Search page and the command palette search through a provider of their own, which never
    /// lists the library itself.
    let generatedCovers: AppleMusicGeneratedCoverCache
    /// The cache's answer version this provider's last listing applied (one per window's browser).
    let appliedCoverAnswer = AppleMusicAppliedCoverAnswer()
    /// How long a listing waits for the API's covers while it has no answer from it yet. Once it
    /// has one, listings use it straight away and never wait on the network.
    let coverLookupTimeout: Duration

    init(
        source: any AppleMusicContentSource = MusicKitContentSource(),
        artistAlbumsCache: AppleMusicArtistAlbumsCache = AppleMusicArtistAlbumsCache(),
        trackCountCache: AppleMusicPlaylistTrackCountCache = AppleMusicPlaylistTrackCountCache(),
        editor: AppleMusicLibraryEditor = AppleMusicLibraryEditor(),
        generatedCovers: AppleMusicGeneratedCoverCache = AppleMusicGeneratedCoverCache(),
        coverLookupTimeout: Duration = .seconds(3)
    ) {
        self.source = source
        self.artistAlbumsCache = artistAlbumsCache
        self.trackCountCache = trackCountCache
        self.editor = editor
        self.generatedCovers = generatedCovers
        self.coverLookupTimeout = coverLookupTimeout
    }

    private var libraryOwnerName: String {
        SpotiglassL10n.string("appleMusic.library.owner")
    }

    // MARK: - Profile and library

    func currentUserProfile() async throws -> MusicUserProfile {
        let country = try? await source.storefrontCountryCode()
        return MusicUserProfile(id: Self.libraryUserID, displayName: nil, country: country?.uppercased())
    }

    /// `limit` is the page size, like Spotify's: every library playlist is returned, not only the
    /// first page.
    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        try await libraryPlaylists(limit: limit, checksCovers: true)
    }

    /// The library playlists. `checksCovers` drops Apple's generated covers (#444); a listing
    /// read only for the playlists' names or IDs leaves the API alone.
    func libraryPlaylists(limit: Int, checksCovers: Bool) async throws -> [MusicPlaylistSummary] {
        // Asked alongside the library read. It runs to its end in the background and its answer
        // is kept for later listings, even when this one doesn't wait for it.
        let coverLookup = checksCovers ? await generatedCovers.refresh(using: source) : nil
        let playlists = try await readLibraryPlaylists(pageSize: max(1, limit))
        let counts = await trackCountCache.counts(
            forVersions: Dictionary(playlists.map { ($0.id.rawValue, $0.lastModifiedDate) }, uniquingKeysWith: { first, _ in first })
        )
        if let coverLookup, await generatedCovers.covers == nil {
            await waitForFirstAnswer(from: coverLookup)
        }
        let answer = coverLookup == nil ? nil : await generatedCovers.answer()
        if let answer { await appliedCoverAnswer.record(answer.version) }
        let generated: Set<String>
        if let answer, let covers = answer.covers {
            let identities = playlists.map { ($0.id.rawValue, $0.name, AppleMusicItemMapping.globalID(of: $0)) }
            generated = AppleMusicPlaylistCover.generatedPlaylistIDs(identities, covers: covers)
            // Catalog search returns a shared playlist under its catalog ID (`pl.u-…`), so that
            // ID is kept too, or the gradient would come back in Search and in pins made there.
            let generatedCatalogIDs = identities.compactMap { generated.contains($0.0) ? $0.2 : nil }
            await generatedCovers.store(generated.union(generatedCatalogIDs), forAnswer: answer.version)
        } else {
            // The API hasn't answered yet (slow, offline): Apple's covers stay until it does,
            // and the browser lists again then (`missedCoverAnswer`).
            generated = []
        }
        return editor.pending.applied(toPlaylists: playlists.map {
            // A playlist edited from Spotiglass is counted again (`playlistTrackCounts`) with
            // the edits the library doesn't show yet.
            let id = $0.id.rawValue
            let cached = editor.pending.hasPendingTracks(playlistID: id) ? nil : counts[id]
            return AppleMusicItemMapping.playlistSummary(
                $0,
                fallbackOwnerName: libraryOwnerName,
                cachedTrackCount: cached,
                hasGeneratedCover: generated.contains(id)
            )
        })
    }

    /// Whether an answer about the covers arrived after this provider's last listing, so the
    /// sidebar listed from it is missing it: the browser lists again then.
    func missedCoverAnswer() async -> Bool {
        let applied = await appliedCoverAnswer.version
        return await generatedCovers.answerVersion != applied
    }

    private func readLibraryPlaylists(pageSize: Int) async throws -> [Playlist] {
        var playlists: [Playlist] = []
        while playlists.count < Self.maxLibraryPlaylists {
            try Task.checkCancellation()
            let requested = min(pageSize, Self.maxLibraryPlaylists - playlists.count)
            let page = try await source.libraryPlaylists(limit: requested, offset: playlists.count)
            playlists.append(contentsOf: page)
            if page.count < requested { break }
        }
        return playlists
    }

    /// Waits for the cover lookup, but no longer than `coverLookupTimeout`, and not at all once
    /// the listing is cancelled. The lookup itself carries on either way.
    private func waitForFirstAnswer(from lookup: Task<Void, Never>) async {
        let timeout = coverLookupTimeout
        // A race rather than a task group: a group waits for the slow side to end even after
        // the timeout won, which is the wait this exists to avoid.
        let answer = FirstAnswer<Void>()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.attach(continuation)
                answer.attach([
                    Task {
                        await lookup.value
                        answer.give(())
                    },
                    Task {
                        try? await Task.sleep(for: timeout)
                        answer.give(())
                    },
                ])
            }
        } onCancel: {
            answer.give(())
        }
    }

    var listsPlaylistsWithoutTrackCounts: Bool { true }

    func playlistTrackCounts(playlistIDs: [String]) async -> [String: Int] {
        guard !playlistIDs.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        let unedited = playlistIDs.filter { !editor.pending.hasPendingTracks(playlistID: $0) }
        if !unedited.isEmpty {
            let start = await trackCountCache.startLookup(unedited)
            // A failed lookup only leaves those rows without a count; the sidebar itself is loaded.
            if let library = try? await source.libraryPlaylistTracks(playlistIDs: unedited) {
                // Songs removed from the library that it still lists are left out, so what is
                // kept is the count the library will have once it caught up.
                counts = countsLeavingOutRemovedSongs(library)
                await trackCountCache.store(counts, tracks: library, from: start)
                // Opening one of them shows its kept tracks; what the rows need for edits is
                // worked out now, in the background, so neither the counts nor the open wait.
                let references = editor.songReferences
                Task.detached(priority: .utility) {
                    for tracks in library.values { references.prepareIdentities(of: tracks) }
                }
            }
        }
        // The library can take hours to show an add or remove made from Spotiglass, so those
        // playlists, also one edited while the library was read, are counted from their tracks
        // with the edit applied, like the open playlist.
        for id in playlistIDs where !unedited.contains(id) || editor.pending.hasPendingTracks(playlistID: id) {
            guard !Task.isCancelled else { break }
            let tracks = try? await playlistTracks(playlistID: id, limit: 100, maxPages: 100)
            counts[id] = tracks.flatMap { $0.isEmpty ? nil : $0.count }
        }
        return counts
    }

    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] {
        let total = max(1, limit) * max(1, maxPages)
        guard let tracks = try await readPlaylistTracks(playlistID: playlistID, limit: total) else {
            // A playlist created from Spotiglass moments ago is only in the cloud library yet.
            if let pending = try await pendingPlaylistTracks(playlistID: playlistID) {
                return AppleMusicItemMapping.playlistItems(pending)
            }
            // Created through the Music app moments ago: it exists, MusicKit just doesn't list it yet.
            if editor.pending.createdPlaylist(id: playlistID) != nil {
                return AppleMusicItemMapping.playlistItems(applyingPendingEdits(toPlaylistTracks: [], playlistID: playlistID))
            }
            throw AppleMusicBrowsingError.notFound
        }
        return AppleMusicItemMapping.playlistItems(applyingPendingEdits(toPlaylistTracks: tracks, playlistID: playlistID))
    }

    /// A library playlist's tracks from the last read while it provably hasn't changed since
    /// (same `lastModifiedDate`), else from MusicKit. A read of a library playlist is kept for
    /// `lastReadPlaylistTracks`. Other playlists are always read.
    private func readPlaylistTracks(playlistID: String, limit: Int) async throws -> [Track]? {
        guard MusicKitContentSource.isLibraryPlaylistID(playlistID) else {
            return try await source.playlistTracks(playlistID: playlistID, limit: limit)
        }
        let version = (try? await source.libraryPlaylist(id: playlistID))?.lastModifiedDate
        if let version, let kept = await trackCountCache.tracks(playlistID: playlistID, version: version), kept.count <= limit {
            return kept
        }
        let start = await trackCountCache.startLookup([playlistID])
        let tracks = try await source.playlistTracks(playlistID: playlistID, limit: limit)
        // A list cut at `limit` isn't kept: a later read may ask for more.
        if let tracks, tracks.count < limit {
            await trackCountCache.storeTracks(tracks, playlistID: playlistID, version: version, from: start)
        }
        return tracks
    }

    /// The songs counting or an earlier open last read for a library playlist (#442). The
    /// library gives no modification date to tell whether it changed since, so the browser
    /// shows these at once and replaces them with `playlistTracks` when that differs.
    func lastReadPlaylistTracks(playlistID: String) async -> [MusicPlaylistTrackItem]? {
        guard let tracks = await trackCountCache.lastReadTracks(playlistID: playlistID), !tracks.isEmpty else { return nil }
        return AppleMusicItemMapping.playlistItems(applyingPendingEdits(toPlaylistTracks: tracks, playlistID: playlistID))
    }

    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        try await savedTracks(limit: limit, maxPages: maxPages, firstPage: nil)
    }

    func currentUserSavedTracks(
        limit: Int,
        maxPages: Int?,
        firstPage: @escaping @Sendable (MusicSavedTracksResult) async -> Void
    ) async throws -> MusicSavedTracksResult {
        try await savedTracks(limit: limit, maxPages: maxPages, firstPage: firstPage)
    }

    private func savedTracks(
        limit: Int,
        maxPages: Int?,
        firstPage: (@Sendable (MusicSavedTracksResult) async -> Void)?
    ) async throws -> MusicSavedTracksResult {
        let pageSize = max(limit, Self.librarySongsPageSize)
        let cap = maxPages.map { min(Self.maxLibrarySongs, max(1, $0) * max(1, limit)) } ?? Self.maxLibrarySongs
        var songs: [Song] = []
        var read = 0
        while read < cap {
            try Task.checkCancellation()
            let requested = min(pageSize, cap - read)
            let page = try await source.librarySongs(limit: requested, offset: read)
            read += page.count
            // MusicKit lists songs that are only in a playlist among the library's songs; they
            // aren't liked (#401).
            songs.append(contentsOf: page.filter(source.isInLibrary))
            if page.count < requested { break }
            if read == page.count, let firstPage {
                // More pages follow: hand over what is read so far.
                let shown = applyingPendingEdits(toLibrarySongs: songs, isComplete: false)
                await firstPage(MusicSavedTracksResult(tracks: AppleMusicItemMapping.playlistItems(shown), totalAvailable: shown.count))
            }
        }
        let tracks = applyingPendingEdits(toLibrarySongs: songs, isComplete: read < cap)
        return MusicSavedTracksResult(
            tracks: AppleMusicItemMapping.playlistItems(tracks),
            totalAvailable: tracks.count
        )
    }

    // MARK: - Home

    func recentlyPlayedTracks(limit: Int, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        try await source.recentlyPlayedSongs(limit: limit).map(AppleMusicItemMapping.track)
    }

    func topTracks(limit: Int, timeRange: MusicTopItemsTimeRange, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        let playlists = try await source.recommendedPlaylists()
        guard let mix = playlists.first(where: { $0.kind == .personalMix }) ?? playlists.first,
              let tracks = try await source.playlistTracks(playlistID: mix.id.rawValue, limit: limit)
        else { return [] }
        return tracks.map { AppleMusicItemMapping.track($0) }
    }

    // MARK: - Detail

    /// `limit` is a page size, like Spotify's, which follows up to six pages of album tracks.
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, upTo: max(1, limit) * Self.albumTrackPages)
    }

    /// Only the first page, for the artist fallback that samples many albums.
    func albumTracksFirstPage(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] {
        try await albumTracks(albumID: albumID, upTo: max(1, limit))
    }

    private func albumTracks(albumID: String, upTo cap: Int) async throws -> [MusicTrack] {
        guard let album = try await source.album(id: albumID) else {
            throw AppleMusicBrowsingError.notFound
        }
        let tracks = try await source.tracks(of: album, limit: cap)
        // A library album lists its songs under persistent IDs; edits on those rows need the
        // song's other details (#395).
        editor.songReferences.remember(tracks)
        return tracks.prefix(cap).map { AppleMusicItemMapping.track($0, album: album) }
    }

    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        AppleMusicItemMapping.artistDetail(try await loadArtist(id: id))
    }

    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        MusicCachedResponse(value: try await artist(id: id, cacheMode: cacheMode), isStale: false)
    }

    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups)
        return MusicCachedResponse(value: Array(albums.prefix(limit)), isStale: false)
    }

    /// MusicKit returns an artist's albums in one go, so this pages over that list by offset.
    /// `next` is never a URL a caller could follow outside this provider.
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        let albums = try await artistAlbums(id: id, includeGroups: includeGroups)
        let start = min(max(0, offset), albums.count)
        let end = min(start + max(1, limit), albums.count)
        let next = end < albums.count ? Self.continuationURL(offset: end) : nil
        return MusicArtistAlbumsPage(items: Array(albums[start..<end]), next: next)
    }

    func artistTopTracks(id: String, market: String?, cacheMode: MusicRequestCacheMode) async throws -> [MusicTrack] {
        try await source.artistTopSongs(artistID: id).map(AppleMusicItemMapping.track)
    }

    private func loadArtist(id: String) async throws -> Artist {
        guard let artist = try await source.artist(id: id) else {
            throw AppleMusicBrowsingError.notFound
        }
        return artist
    }

    /// MusicKit gives a library album the track count of the whole album, while the library
    /// has only some of its songs and the album page lists just those: "15 tracks" on the
    /// artist page, "1 track" once opened (#400). A library album therefore carries the number
    /// of its songs in the library, the same list its album page shows. Catalog albums keep
    /// their count.
    ///
    /// The counts run a few at a time, so an artist with many library albums doesn't wait for
    /// two requests per album in a row. An album whose songs can't be read keeps MusicKit's
    /// count instead of failing the whole artist page; a cancelled load still throws, so it is
    /// never cached half counted.
    static func libraryCounted(
        _ albums: [MusicArtistAlbum],
        source: any AppleMusicContentSource
    ) async throws -> [MusicArtistAlbum] {
        var counted = albums
        try await withThrowingTaskGroup(of: (Int, MusicArtistAlbum).self) { group in
            var next = albums.startIndex
            func addNext() {
                guard next < albums.endIndex else { return }
                let index = next
                let album = albums[index]
                next += 1
                group.addTask {
                    do {
                        return (index, try await libraryCounted(album, source: source))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, album)
                    }
                }
            }
            for _ in 0..<libraryAlbumCountParallelism { addNext() }
            while let (index, album) = try await group.next() {
                counted[index] = album
                addNext()
            }
        }
        try Task.checkCancellation()
        return counted
    }

    private static func libraryCounted(
        _ album: MusicArtistAlbum,
        source: any AppleMusicContentSource
    ) async throws -> MusicArtistAlbum {
        guard !MusicKitLibraryLookup.isCatalogID(album.id),
              let detailed = try await source.album(id: album.id)
        else { return album }
        // The library never has more of an album than the album has.
        let cap = album.totalTracks > 0 ? album.totalTracks : Self.maxLibraryAlbumTracks
        let count = try await source.tracks(of: detailed, limit: cap).count
        guard count > 0, count != album.totalTracks else { return album }
        return MusicArtistAlbum(
            id: album.id,
            name: album.name,
            imageURL: album.imageURL,
            releaseYear: album.releaseYear,
            totalTracks: count,
            group: album.group,
            uri: album.uri
        )
    }

    private func artistAlbums(id: String, includeGroups: [MusicArtistAlbumGroup]) async throws -> [MusicArtistAlbum] {
        let groups = Set(includeGroups)
        let all: [MusicArtistAlbum]
        if let cached = await artistAlbumsCache.albums(forArtistID: id) {
            all = cached
        } else {
            let artist = try await loadArtist(id: id)
            all = try await Self.libraryCounted(
                source.albums(of: artist, limit: Self.maxArtistAlbums).map(AppleMusicItemMapping.artistAlbum),
                source: source
            )
            await artistAlbumsCache.store(all, forArtistID: id)
        }
        return all.filter { groups.isEmpty || groups.contains($0.group) }
    }

    // MARK: - Search

    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        try await search(query: query, limit: limit, offset: 0, cacheMode: .freshOnly)
    }

    func search(query: String, limit: Int, offset: Int, cacheMode: MusicRequestCacheMode) async throws -> MusicSearchResults {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
        }
        let pageLimit = min(max(1, limit), MusicKitContentSource.catalogSearchPageLimit)

        // The library can't be paged (no offset in MusicKit), so the first page shows all of
        // its matches, up to a bound, and later pages show catalog items only. Every page still
        // reads the library (a local query) so catalog copies of library items stay hidden on
        // later pages too.
        async let libraryResult = Self.capture {
            try await source.librarySearch(term: term, limit: Self.maxLibrarySearchMatches)
        }
        let firstCatalog = await Self.capture {
            try await source.catalogSearch(term: term, limit: pageLimit, offset: offset)
        }
        let library = await libraryResult
        let generatedCoverIDs = await generatedCovers.playlistIDs
        var page = try searchPage(
            catalog: firstCatalog, library: library, limit: limit, pageLimit: pageLimit, offset: offset,
            generatedCoverIDs: generatedCoverIDs
        )
        // A later page can come out empty only because every catalog item on it is a copy of a
        // library item. The Search view stops at an empty page, which would make everything
        // after it unreachable, so such a page is skipped while the catalog reports more.
        var pageOffset = offset
        var skipped = 0
        while offset > 0, page.isEmptyPage, page.hasNextPage, skipped < Self.maxSkippedSearchPages {
            try Task.checkCancellation()
            pageOffset += pageLimit
            skipped += 1
            let catalog = await Self.capture {
                try await source.catalogSearch(term: term, limit: pageLimit, offset: pageOffset)
            }
            page = try searchPage(
                catalog: catalog, library: library, limit: limit, pageLimit: pageLimit, offset: pageOffset,
                generatedCoverIDs: generatedCoverIDs
            )
        }
        return page
    }

    /// One search page from one catalog page and the library matches.
    private func searchPage(
        catalog: Result<AppleMusicSearchItems, Error>,
        library: Result<AppleMusicSearchItems, Error>,
        limit: Int,
        pageLimit: Int,
        offset: Int,
        generatedCoverIDs: Set<String>
    ) throws -> MusicSearchResults {
        // Past the first page only the catalog answers, so its failure is the page's failure:
        // reporting an empty page would end the results instead of letting the user retry.
        if case let .failure(error) = catalog {
            if offset > 0 { throw error }
            if case .failure = library { throw error }
        }
        let catalogItems = (try? catalog.get()) ?? AppleMusicSearchItems()
        let libraryItems = (try? library.get()) ?? AppleMusicSearchItems()
        let showsLibrary = offset == 0

        // `total` must not promise more than there is: the Search view keeps Load More while
        // `offset + items < total`, so a made-up total on the last page pages forever. Each
        // type pages on its own: a tab must not keep Load More because another type has more.
        func paging(_ count: Int, more: Bool) -> MusicSearchPaging {
            let next = more ? Self.continuationURL(offset: offset + pageLimit) : nil
            return MusicSearchPaging(total: offset + count + (more ? pageLimit : 0), next: next)
        }
        // The match key says "same recording" across library and catalog, whose IDs differ:
        // title, artist, album and rating (a clean and an explicit version share the rest).
        let tracks = Self.merged(libraryItems.songs, catalogItems.songs, limit: limit, showsLibrary: showsLibrary, id: { $0.id.rawValue }) {
            "\($0.title)|\($0.artistName)|\($0.albumTitle ?? "")|\($0.contentRating == .explicit)".lowercased()
        }
        // Artists match by name on purpose: the same artist in the library and in the catalog
        // is far more common than two different artists with one name, one of them saved.
        let artists = Self.merged(libraryItems.artists, catalogItems.artists, limit: limit, showsLibrary: showsLibrary, id: { $0.id.rawValue }) {
            $0.name.lowercased()
        }
        let albums = Self.merged(libraryItems.albums, catalogItems.albums, limit: limit, showsLibrary: showsLibrary, id: { $0.id.rawValue }) {
            "\($0.title)|\($0.artistName)|\($0.contentRating == .explicit)".lowercased()
        }
        let playlists = Self.merged(libraryItems.playlists, catalogItems.playlists, limit: limit, showsLibrary: showsLibrary, id: { $0.id.rawValue }) {
            $0.id.rawValue
        }
        return MusicSearchResults(
            tracks: tracks.map(AppleMusicItemMapping.track),
            artists: artists.map(AppleMusicItemMapping.artist),
            albums: albums.map(AppleMusicItemMapping.album),
            playlists: playlists.map {
                AppleMusicItemMapping.playlistSummary(
                    $0,
                    fallbackOwnerName: libraryOwnerName,
                    hasGeneratedCover: generatedCoverIDs.contains($0.id.rawValue)
                )
            },
            tracksPaging: paging(tracks.count, more: catalogItems.moreSongs),
            artistsPaging: paging(artists.count, more: catalogItems.moreArtists),
            albumsPaging: paging(albums.count, more: catalogItems.moreAlbums),
            playlistsPaging: paging(playlists.count, more: catalogItems.morePlaylists)
        )
    }

    // MARK: - Helpers

    /// An opaque continuation in the `offset` shape the Search view already reads.
    static func continuationURL(offset: Int) -> URL? {
        var components = URLComponents()
        components.scheme = AppleMusicItemMapping.uriScheme
        components.host = "page"
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        return components.url
    }

    /// Library items first, then the catalog items the library does not already show.
    ///
    /// The library side is already bounded by its request; the catalog side keeps up to `limit`
    /// items (its page). Library matches must not push catalog items off the
    /// page: the next page starts after this page's catalog items, so a catalog item cut here
    /// would never be shown at all. Within a side, items are told apart by `id`, so two
    /// recordings with the same title stay two rows. A catalog item is only dropped as a
    /// duplicate when the library shows the same `match` (library and catalog IDs differ for
    /// the same song).
    /// `showsLibrary` is `false` on later pages: the library items are only used to hide their
    /// catalog copies there.
    static func merged<Item>(
        _ library: [Item],
        _ catalog: [Item],
        limit: Int,
        showsLibrary: Bool = true,
        id: (Item) -> String,
        match: (Item) -> String
    ) -> [Item] {
        var seenIDs: Set<String> = []
        var libraryMatches: Set<String> = []
        var result: [Item] = []
        for item in library where seenIDs.insert(id(item)).inserted {
            libraryMatches.insert(match(item))
            if showsLibrary { result.append(item) }
        }
        for item in catalog.prefix(limit)
        where !libraryMatches.contains(match(item)) && seenIDs.insert(id(item)).inserted {
            result.append(item)
        }
        return result
    }

    private static func capture<Value>(_ body: () async throws -> Value) async -> Result<Value, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}

/// A few artists' album lists, kept for a short while so paging an artist page doesn't walk
/// MusicKit's album batches again for every page. Bounded in count and age.
actor AppleMusicArtistAlbumsCache {
    static let maxArtists = 8
    static let maxAge: TimeInterval = 10 * 60

    private var entries: [String: (albums: [MusicArtistAlbum], storedAt: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func albums(forArtistID id: String) -> [MusicArtistAlbum]? {
        guard let entry = entries[id] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < Self.maxAge else {
            entries[id] = nil
            return nil
        }
        return entry.albums
    }

    func store(_ albums: [MusicArtistAlbum], forArtistID id: String) {
        entries[id] = (albums, now())
        while entries.count > Self.maxArtists,
              let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries[oldest] = nil
        }
    }
}

/// Resumes a continuation with the first value given, ignores the rest and cancels the tasks
/// still racing for it. Either side may come first: a value given before the continuation is
/// attached (a cancelled caller) is handed over on attach, and tasks attached after the answer
/// are cancelled straight away.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var answer: Value?
    private var isAnswered = false

    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        let answered: Value? = lock.withLock {
            guard isAnswered else {
                self.continuation = continuation
                return nil
            }
            return answer
        }
        if let answered { continuation.resume(returning: answered) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let cancelNow = lock.withLock {
            if isAnswered { return true }
            self.tasks += tasks
            return false
        }
        if cancelNow { tasks.forEach { $0.cancel() } }
    }

    func give(_ value: Value) {
        let taken: (waiting: CheckedContinuation<Value, Never>?, racing: [Task<Void, Never>])? = lock.withLock {
            guard !isAnswered else { return nil }
            isAnswered = true
            answer = value
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        guard let taken else { return }
        taken.racing.forEach { $0.cancel() }
        taken.waiting?.resume(returning: value)
    }
}

/// What the Apple Music API said about the library playlists' covers (#444).
actor AppleMusicGeneratedCoverCache {
    /// The app's one cache, shared by the sidebar's provider and the one Search uses.
    static let shared = AppleMusicGeneratedCoverCache()

    /// Posted on the main thread, with the cache as object, when the answer changes. A browser
    /// whose last listing didn't apply it lists again (`missedCoverAnswer`).
    static let answerChangedNotification = Notification.Name("AppleMusicGeneratedCoverCache.answerChanged")

    /// The API's last answer, in a fixed order, `nil` until one arrived. A failed lookup keeps
    /// the one before.
    private(set) var covers: [AppleMusicPlaylistCover]?
    /// Goes up whenever `covers` changes.
    private(set) var answerVersion = 0
    /// The playlists the last listing found with a generated cover, by library ID and, for
    /// shared ones, by catalog ID, for search results.
    private(set) var playlistIDs: Set<String> = []
    private var lookup: Task<Void, Never>?
    /// Bumped by `reset`, so a lookup started for the account before doesn't land.
    private var generation = 0

    func answer() -> (covers: [AppleMusicPlaylistCover]?, version: Int) {
        (covers, answerVersion)
    }

    /// Keeps a listing's result for search, unless a newer answer arrived meanwhile or the
    /// cache was reset (the same covers can come from another account).
    func store(_ ids: Set<String>, forAnswer version: Int) {
        guard version == answerVersion else { return }
        playlistIDs = ids
    }

    /// The lookup in flight, or a new one. It always runs to its end (its paging is capped), so
    /// a library too big to read before a listing's timeout still gets its answer, and only
    /// one runs at a time however often the sidebar refreshes.
    func refresh(using source: any AppleMusicContentSource) -> Task<Void, Never> {
        if let lookup { return lookup }
        let generation = generation
        let lookup = Task {
            let answer = try? await source.libraryPlaylistCovers()
            finish(answer, generation: generation)
        }
        self.lookup = lookup
        return lookup
    }

    /// Forgets everything, for when Apple Music access is lost: when it comes back the library
    /// may be another account's.
    func reset() {
        generation += 1
        lookup = nil
        covers = nil
        playlistIDs = []
        answerVersion += 1
    }

    private func finish(_ answer: [AppleMusicPlaylistCover]?, generation: Int) {
        guard generation == self.generation else { return }
        lookup = nil
        // The API's order is not part of the answer: the same covers listed in another order
        // must not count as a change, or every listing would ask for the next one.
        guard let answer = answer?.sorted(by: Self.fixedOrder), answer != covers else { return }
        covers = answer
        answerVersion += 1
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.answerChangedNotification, object: self)
        }
    }

    private static func fixedOrder(_ a: AppleMusicPlaylistCover, _ b: AppleMusicPlaylistCover) -> Bool {
        (a.name, a.globalID ?? "", a.isGenerated ? 1 : 0) < (b.name, b.globalID ?? "", b.isGenerated ? 1 : 0)
    }
}

/// The cover answer version one provider's last listing applied.
actor AppleMusicAppliedCoverAnswer {
    private(set) var version = 0

    func record(_ version: Int) {
        self.version = version
    }
}

/// Track counts of library playlists, and the tracks they were counted from, keyed by playlist
/// ID, for `AppleMusicBrowsingProvider`.
///
/// MusicKit reads a playlist's tracks all at once, about a second for 800 songs, so opening a
/// big playlist used to wait that long every time (#442). Counting already reads every
/// playlist's tracks right after the sidebar shows; they are kept here. Opening a playlist shows
/// them at once and reads it again in the background, or skips that read while its
/// `lastModifiedDate` is unchanged (MusicKit on macOS gives library playlists none).
///
/// A count or a track list is used again only while the playlist's `lastModifiedDate` is the one
/// it was read at and for `maxAge`, so an edit made in Music or on another device shows up on a
/// later refresh. Bounded: playlists no longer in the library are dropped on every listing, never
/// more than `maxPlaylists` counts and `maxTracks` tracks are kept.
actor AppleMusicPlaylistTrackCountCache {
    static let maxPlaylists = AppleMusicBrowsingProvider.maxLibraryPlaylists
    static let maxAge: TimeInterval = 10 * 60
    /// Tracks kept over all playlists; the least recently read playlists go first.
    static let maxTracks = 20_000

    private struct Entry {
        let count: Int
        /// The playlist's `lastModifiedDate` when it was counted.
        let version: Date?
        let storedAt: Date
    }

    private struct TrackList {
        let tracks: [Track]
        /// The playlist's `lastModifiedDate` when its tracks were read. MusicKit on macOS gives
        /// library playlists none (checked on a real library, 2026-11-09), so mostly `nil`.
        let version: Date?
        var usedAt: Date
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var trackLists: [String: TrackList] = [:]
    /// The latest `lastModifiedDate` a listing reported per playlist.
    private var versions: [String: Date?] = [:]
    /// How often each playlist was edited from Spotiglass, for `store(_:from:)`.
    private var edits: [String: Int] = [:]
    /// How often songs were removed from the library, for `store(_:from:)`.
    private var libraryRemovals = 0
    private let now: @Sendable () -> Date
    private let maxTracks: Int

    init(now: @escaping @Sendable () -> Date = Date.init, maxTracks: Int = AppleMusicPlaylistTrackCountCache.maxTracks) {
        self.now = now
        self.maxTracks = maxTracks
    }

    /// The still valid counts for a fresh listing (playlist ID to `lastModifiedDate`). Playlists
    /// missing from the listing are forgotten.
    func counts(forVersions listing: [String: Date?]) -> [String: Int] {
        versions = listing
        edits = edits.filter { listing[$0.key] != nil }
        let current = now()
        entries = entries.filter { id, entry in
            guard let listed = listing[id] else { return false }
            return entry.version == listed && current.timeIntervalSince(entry.storedAt) < Self.maxAge
        }
        trackLists = trackLists.filter { id, list in
            guard let listed = listing[id] else { return false }
            return list.version == listed && current.timeIntervalSince(list.storedAt) < Self.maxAge
        }
        return entries.mapValues(\.count)
    }

    /// The tracks last read for a playlist, while it is still at `version` (its current
    /// `lastModifiedDate`) and they are younger than `maxAge`.
    func tracks(playlistID id: String, version: Date) -> [Track]? {
        tracks(playlistID: id) { $0 == version }
    }

    /// The tracks last read for a playlist, younger than `maxAge`, whether or not it changed
    /// since: to show at once while a fresh read runs.
    func lastReadTracks(playlistID id: String) -> [Track]? {
        tracks(playlistID: id) { _ in true }
    }

    private func tracks(playlistID id: String, matching isCurrent: (Date?) -> Bool) -> [Track]? {
        guard var list = trackLists[id] else { return nil }
        let current = now()
        guard isCurrent(list.version), current.timeIntervalSince(list.storedAt) < Self.maxAge else {
            trackLists[id] = nil
            return nil
        }
        list.usedAt = current
        trackLists[id] = list
        return list.tracks
    }

    /// Keeps the tracks a read of one playlist found at `version`, unless the playlist was
    /// edited, or songs were removed from the library, since the read started.
    func storeTracks(_ tracks: [Track], playlistID id: String, version: Date?, from start: LookupStart) {
        guard start.libraryRemovals == libraryRemovals, (edits[id] ?? 0) == (start.edits[id] ?? 0) else { return }
        keep(tracks, playlistID: id, version: version)
    }

    private func keep(_ tracks: [Track], playlistID id: String, version: Date?) {
        let current = now()
        trackLists[id] = TrackList(tracks: tracks, version: version, usedAt: current, storedAt: current)
        var total = trackLists.values.reduce(0) { $0 + $1.tracks.count }
        while total > maxTracks, trackLists.count > 1,
              let oldest = trackLists.filter({ $0.key != id }).min(by: { $0.value.usedAt < $1.value.usedAt }) {
            total -= oldest.value.tracks.count
            trackLists[oldest.key] = nil
        }
    }

    /// What a lookup started from: each playlist's listed version and how often it was edited.
    struct LookupStart: Sendable {
        fileprivate let versions: [String: Date?]
        fileprivate let edits: [String: Int]
        fileprivate let libraryRemovals: Int
    }

    /// Drops the counts of playlists that were just edited, so no listing brings back the count
    /// from before the edit, and no lookup that was already running stores one.
    func forget(_ playlistIDs: [String]) {
        for id in playlistIDs {
            entries[id] = nil
            trackLists[id] = nil
            edits[id, default: 0] += 1
        }
    }

    /// Drops every count after songs were removed from the library: they leave each playlist
    /// they were in.
    func forgetAll() {
        entries = [:]
        trackLists = [:]
        libraryRemovals += 1
    }

    func startLookup(_ playlistIDs: [String]) -> LookupStart {
        LookupStart(
            versions: Dictionary(playlistIDs.map { ($0, versions[$0] ?? nil) }, uniquingKeysWith: { first, _ in first }),
            edits: Dictionary(playlistIDs.map { ($0, edits[$0] ?? 0) }, uniquingKeysWith: { first, _ in first }),
            libraryRemovals: libraryRemovals
        )
    }

    /// Keeps the counts a lookup read, and the tracks it counted, except for playlists edited or
    /// listed with a newer version since it started, or all of them after a removal from the
    /// library: those may be from before the change.
    func store(_ counts: [String: Int], tracks: [String: [Track]] = [:], from start: LookupStart) {
        guard start.libraryRemovals == libraryRemovals else { return }
        let storedAt = now()
        for (id, count) in counts {
            guard let version = start.versions[id],
                  (versions[id] ?? nil) == version,
                  (edits[id] ?? 0) == start.edits[id] else { continue }
            entries[id] = Entry(count: count, version: version, storedAt: storedAt)
        }
        for (id, list) in tracks {
            guard let version = start.versions[id],
                  (versions[id] ?? nil) == version,
                  (edits[id] ?? 0) == start.edits[id] else { continue }
            keep(list, playlistID: id, version: version)
        }
        while entries.count > Self.maxPlaylists,
              let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries[oldest] = nil
        }
    }
}

private extension MusicSearchResults {
    var isEmptyPage: Bool {
        tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }

    var hasNextPage: Bool {
        [tracksPaging, artistsPaging, albumsPaging, playlistsPaging].contains { $0?.next != nil }
    }
}
