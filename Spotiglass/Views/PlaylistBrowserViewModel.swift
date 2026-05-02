import Foundation

protocol SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem]
    func currentUserProfile() async throws -> SpotifyUserProfile
    func artist(id: String) async throws -> SpotifyArtistDetail
    func artistTopTracks(id: String, market: String?) async throws -> [SpotifyTrack]
    func artistAlbums(id: String, includeGroups: String, limit: Int) async throws -> [SpotifyArtistAlbum]
    func search(query: String, limit: Int) async throws -> SpotifySearchResults
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [SpotifyTrack]
}

extension SpotifyAPIClient: SpotifyBrowsingAPI {}

protocol SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]?
    /// On-disk playlist list and its age; used to skip a redundant `me/playlists` round-trip when the cache is still fresh.
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)?
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]?
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    func invalidateTracks(playlistID: String) throws
}

extension SpotifyLocalCache: SpotifyBrowsingCache {}

struct BrowsingDisplayError: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let canRetry: Bool
    let diagnosticDetails: String?

    init(title: String, message: String, canRetry: Bool, diagnosticDetails: String? = nil) {
        self.title = title
        self.message = message
        self.canRetry = canRetry
        self.diagnosticDetails = diagnosticDetails
    }

    static func == (lhs: BrowsingDisplayError, rhs: BrowsingDisplayError) -> Bool {
        lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.canRetry == rhs.canRetry
            && lhs.diagnosticDetails == rhs.diagnosticDetails
    }
}

enum BrowsingLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty(String)
    case staleCache(Value, BrowsingDisplayError?)
    case refreshing(Value)
    case error(BrowsingDisplayError)

    var currentValue: Value? {
        switch self {
        case let .loaded(value), let .staleCache(value, _), let .refreshing(value):
            value
        case .loading, .empty, .error:
            nil
        }
    }
}

struct PlaylistRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let owner: String
    let trackCountText: String
    let artworkURL: URL?
    let snapshotID: String

    init(_ playlist: SpotifyPlaylistSummary) {
        self.id = playlist.id
        self.title = playlist.name
        self.owner = playlist.ownerName
        self.trackCountText = playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks"
        self.artworkURL = playlist.imageURL
        self.snapshotID = playlist.snapshotID
    }
}

struct PlaylistDetailViewModel: Equatable {
    let playlist: PlaylistRowViewModel
    let tracks: [TrackRowViewModel]
}

enum BrowsingDetailContent: Equatable {
    case playlist(PlaylistDetailViewModel)
    case artist(ArtistDetailViewModel)
}

struct ArtistAlbumRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let artworkURL: URL?
    let yearText: String?
    let trackCountText: String
    let uri: String

    init(_ album: SpotifyArtistAlbum) {
        id = album.id
        title = album.name
        artworkURL = album.imageURL
        yearText = album.releaseYear
        trackCountText = album.totalTracks == 1 ? "1 track" : "\(album.totalTracks) tracks"
        uri = album.uri
    }
}

struct ArtistDetailViewModel: Equatable {
    let artist: SpotifyArtistDetail
    let tracks: [TrackRowViewModel]
    let albums: [ArtistAlbumRowViewModel]
    let singles: [ArtistAlbumRowViewModel]
    let compilations: [ArtistAlbumRowViewModel]
    let appearsOn: [ArtistAlbumRowViewModel]

    init(artist: SpotifyArtistDetail, tracks: [SpotifyTrack], albums: [SpotifyArtistAlbum]) {
        self.artist = artist
        self.tracks = tracks.map { TrackRowViewModel(topTrack: $0) }
        let grouped = Dictionary(grouping: albums, by: \.group)
        let sort: (SpotifyArtistAlbum, SpotifyArtistAlbum) -> Bool = { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        self.albums = (grouped[.album] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.singles = (grouped[.single] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.compilations = (grouped[.compilation] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
        self.appearsOn = (grouped[.appearsOn] ?? []).sorted(by: sort).map(ArtistAlbumRowViewModel.init)
    }
}

struct TrackRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    let badgeText: String?
    let isUnavailable: Bool
    let playableURI: String?
    let artistRefs: [SpotifyArtistRef]

    init(_ item: SpotifyPlaylistTrackItem) {
        self.id = item.id

        switch item.content {
        case let .track(track):
            self.title = track.name
            self.subtitle = track.artists.joined(separator: ", ")
            self.artworkURL = track.albumArtworkURL
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
            self.isUnavailable = track.isPlayable == false
            self.playableURI = track.isPlayable == false ? nil : track.uri
            self.artistRefs = track.artistRefs
        case let .episode(episode):
            self.title = episode.name
            self.subtitle = episode.showName ?? "Podcast episode"
            self.artworkURL = episode.artworkURL
            self.durationText = Self.durationText(milliseconds: episode.durationMilliseconds)
            self.badgeText = episode.isPlayable == false ? "Unavailable episode" : "Episode"
            self.isUnavailable = episode.isPlayable == false
            self.playableURI = episode.isPlayable == false ? nil : episode.uri
            self.artistRefs = []
        case let .localTrack(track):
            self.title = track.name
            self.subtitle = track.artists.isEmpty ? "Local track" : track.artists.joined(separator: ", ")
            self.artworkURL = nil
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = "Local"
            self.isUnavailable = false
            self.playableURI = nil
            self.artistRefs = []
        case let .unavailable(reason):
            self.title = "Unavailable item"
            self.subtitle = reason
            self.artworkURL = nil
            self.durationText = "--:--"
            self.badgeText = "Unavailable"
            self.isUnavailable = true
            self.playableURI = nil
            self.artistRefs = []
        }
    }

    init(topTrack track: SpotifyTrack) {
        self.id = track.id
        self.title = track.name
        self.subtitle = track.artists.joined(separator: ", ")
        self.artworkURL = track.albumArtworkURL
        self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
        self.badgeText = track.isPlayable == false ? "Unavailable" : (track.isExplicit ? "Explicit" : nil)
        self.isUnavailable = track.isPlayable == false
        self.playableURI = track.isPlayable == false ? nil : track.uri
        self.artistRefs = track.artistRefs
    }

    private static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

@MainActor
final class PlaylistBrowserViewModel: ObservableObject {
    @Published private(set) var playlistState: BrowsingLoadState<[PlaylistRowViewModel]> = .loading
    @Published private(set) var detailState: BrowsingLoadState<BrowsingDetailContent> = .empty("Select a playlist or open an artist from search.")
    @Published var selectedPlaylistID: String?

    private let api: SpotifyBrowsingAPI
    private let cache: SpotifyBrowsingCache
    private let now: () -> Date
    private let maxCacheAge: TimeInterval
    /// When the saved playlist list is younger than this, `load()` does not call `refreshPlaylists()` (tracks for the selection still revalidate in the background when a track cache hit exists).
    private let playlistListAutoRefreshMinInterval: TimeInterval
    private var playlistsByID: [String: SpotifyPlaylistSummary] = [:]
    private var hasLoaded = false
    private var detailSession = 0

    var visiblePlaylists: [PlaylistRowViewModel] {
        playlistState.currentValue ?? []
    }

    init(
        api: SpotifyBrowsingAPI,
        cache: SpotifyBrowsingCache,
        now: @escaping () -> Date = Date.init,
        maxCacheAge: TimeInterval = 300,
        playlistListAutoRefreshMinInterval: TimeInterval = 1800
    ) {
        self.api = api
        self.cache = cache
        self.now = now
        self.maxCacheAge = maxCacheAge
        self.playlistListAutoRefreshMinInterval = playlistListAutoRefreshMinInterval
    }

    static func live(tokenProvider: SpotifyAccessTokenProviding) -> PlaylistBrowserViewModel {
        let api = SpotifyAPIClient(tokenProvider: tokenProvider)
        let cache: SpotifyBrowsingCache = (try? SpotifyLocalCache()) ?? DisabledSpotifyBrowsingCache()
        return PlaylistBrowserViewModel(api: api, cache: cache)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        if let bundle = try? cache.loadPlaylistsBundle(now: now()), !bundle.playlists.isEmpty {
            apply(playlists: bundle.playlists, state: .loaded(bundle.playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)
            if bundle.age >= playlistListAutoRefreshMinInterval {
                await refreshPlaylists()
            } else {
                if let selectedPlaylistID {
                    detailSession += 1
                    let session = detailSession
                    await loadTracks(for: selectedPlaylistID, refreshCachedData: true, session: session)
                }
            }
            return
        }

        playlistState = .loading
        await refreshPlaylists()
    }

    func refreshPlaylists() async {
        let existingRows = playlistState.currentValue
        if let existingRows, !existingRows.isEmpty {
            playlistState = .refreshing(existingRows)
        }

        do {
            let playlists = try await api.currentUserPlaylists(limit: 50)
            try? cache.savePlaylists(playlists, cachedAt: now())
            if playlists.isEmpty {
                playlistsByID = [:]
                selectedPlaylistID = nil
                playlistState = .empty("Your Spotify library has no playlists yet.")
                detailState = .empty("Create or follow a playlist in Spotify, then refresh.")
                return
            }
            apply(playlists: playlists, state: .loaded(playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)
            if let selectedPlaylistID {
                detailSession += 1
                let session = detailSession
                await loadTracks(for: selectedPlaylistID, refreshCachedData: true, session: session)
            }
        } catch {
            let displayError = Self.displayError(for: error)
            if let existingRows, !existingRows.isEmpty {
                playlistState = .staleCache(existingRows, displayError)
            } else {
                playlistState = .error(displayError)
            }
        }
    }

    func selectPlaylist(id: String?) async {
        detailSession += 1
        let session = detailSession
        selectedPlaylistID = id
        guard let id else {
            detailState = .empty("Select a playlist or open an artist from search.")
            return
        }
        await loadTracks(for: id, refreshCachedData: true, session: session)
    }

    func selectArtist(id: String) async {
        selectedPlaylistID = nil
        detailSession += 1
        let session = detailSession
        detailState = .loading
        do {
            let profile = try await api.currentUserProfile()
            let market = profile.country
            async let detail = api.artist(id: id)
            async let albums = api.artistAlbums(id: id, includeGroups: "album,single,compilation,appears_on", limit: 10)
            let (artistDetail, albumList) = try await (detail, albums)
            guard session == detailSession else { return }
            let resolved = await resolveArtistTracks(artistId: id, artist: artistDetail, albums: albumList, market: market)
            let vm = ArtistDetailViewModel(artist: artistDetail, tracks: resolved, albums: albumList)
            detailState = .loaded(.artist(vm))
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }

    /// Prefer Spotify top-tracks; when forbidden/unavailable (common for Web API dev-mode apps), fall back to search then album-derived tracks.
    private func resolveArtistTracks(
        artistId: String,
        artist: SpotifyArtistDetail,
        albums: [SpotifyArtistAlbum],
        market: String?
    ) async -> [SpotifyTrack] {
        do {
            let top = try await api.artistTopTracks(id: artistId, market: market)
            if !top.isEmpty {
                return top
            }
        } catch {
            // Non-fatal: continue with fallbacks (403 Forbidden on `/top-tracks` is expected for dev-mode apps).
        }

        do {
            let sanitizedName = artist.name.replacingOccurrences(of: "\"", with: "")
            let query = "artist:\"\(sanitizedName)\""
            let results = try await api.search(query: query, limit: 10)
            let matching = results.tracks.filter { $0.artistRefs.contains { $0.id == artistId } }
            if !matching.isEmpty {
                return Array(matching.prefix(10))
            }
        } catch {
            // Non-fatal: try album-derived list.
        }

        let selectedAlbums = Self.albumsForTrackFallback(from: albums)
        var collected: [SpotifyTrack] = []
        var seenNames: Set<String> = []
        for album in selectedAlbums {
            do {
                let albumTracks = try await api.albumTracks(albumID: album.id, market: market, limit: 50)
                for track in albumTracks {
                    let key = track.name.lowercased()
                    guard !seenNames.contains(key) else { continue }
                    seenNames.insert(key)
                    let withArt: SpotifyTrack
                    if track.albumArtworkURL == nil, let url = album.imageURL {
                        withArt = SpotifyTrack(
                            id: track.id,
                            name: track.name,
                            artists: track.artists,
                            artistRefs: track.artistRefs,
                            albumArtworkURL: url,
                            durationMilliseconds: track.durationMilliseconds,
                            isExplicit: track.isExplicit,
                            isPlayable: track.isPlayable,
                            linkedFromID: track.linkedFromID,
                            uri: track.uri
                        )
                    } else {
                        withArt = track
                    }
                    collected.append(withArt)
                    if collected.count >= 10 {
                        return collected
                    }
                }
            } catch {
                // Skip this album and continue.
            }
        }
        return collected
    }

    /// Latest album and single releases first (by four-digit year when present).
    private static func albumsForTrackFallback(from albums: [SpotifyArtistAlbum]) -> [SpotifyArtistAlbum] {
        let filtered = albums.filter { $0.group == .album || $0.group == .single }
        let sorted = filtered.sorted { lhs, rhs in
            let ly = Int(lhs.releaseYear ?? "") ?? 0
            let ry = Int(rhs.releaseYear ?? "") ?? 0
            if ly != ry {
                return ly > ry
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(6))
    }

    func refreshSelectedPlaylist() async {
        if let selectedPlaylistID {
            detailSession += 1
            let session = detailSession
            try? cache.invalidateTracks(playlistID: selectedPlaylistID)
            await loadTracks(for: selectedPlaylistID, refreshCachedData: false, session: session)
        } else if let artistID = artistIDForRefreshingDetail {
            await selectArtist(id: artistID)
        }
    }

    /// When viewing an artist page (no playlist selection), refresh reloads that artist.
    private var artistIDForRefreshingDetail: String? {
        switch detailState {
        case let .loaded(content), let .staleCache(content, _), let .refreshing(content):
            if case let .artist(vm) = content {
                return vm.artist.id
            }
            return nil
        case .loading, .empty, .error:
            return nil
        }
    }

    func selectNextPlaylist() async {
        await selectAdjacentPlaylist(offset: 1)
    }

    func selectPreviousPlaylist() async {
        await selectAdjacentPlaylist(offset: -1)
    }

    func clearForSignOut() {
        selectedPlaylistID = nil
        playlistsByID = [:]
        playlistState = .empty("Connect Spotify to browse playlists.")
        detailState = .empty("Sign in to Spotify to browse playlists and artists.")
    }

    private func loadTracks(for playlistID: String, refreshCachedData: Bool, session: Int) async {
        guard session == detailSession else { return }
        guard let playlist = playlistsByID[playlistID] else {
            detailState = .error(BrowsingDisplayError(
                title: "Playlist unavailable",
                message: "This playlist disappeared or is no longer accessible.",
                canRetry: true
            ))
            return
        }

        let playlistRow = PlaylistRowViewModel(playlist)

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: playlist.id, snapshotID: playlist.snapshotID, now: now(), maxAge: maxCacheAge) {
            if cachedTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: cachedTracks.map(TrackRowViewModel.init))))
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        let existingDetail = detailState.currentValue
        detailState = .loading
        guard session == detailSession else { return }
        if let existingDetail {
            detailState = .refreshing(existingDetail)
        }
        await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
    }

    private func revalidatePlaylistTracks(playlist: SpotifyPlaylistSummary, playlistRow: PlaylistRowViewModel, session: Int) async {
        do {
            // Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum
            // limit of 50 (the February 2026 rename also tightened the cap from
            // the legacy `/tracks` endpoint's 100). Passing 100 yields HTTP 400
            // invalid_request and breaks any playlist with more than 50 tracks.
            let tracks = try await api.playlistTracks(playlistID: playlist.id, limit: 50)
            try? cache.saveTracks(tracks, playlistID: playlist.id, snapshotID: playlist.snapshotID, cachedAt: now())
            guard session == detailSession else { return }
            if tracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: tracks.map(TrackRowViewModel.init))))
            }
        } catch {
            guard session == detailSession else { return }
            let displayError = Self.displayError(for: error)
            if let existingDetail = detailState.currentValue {
                detailState = .staleCache(existingDetail, displayError)
            } else {
                detailState = .error(displayError)
            }
        }
    }

    private func selectAdjacentPlaylist(offset: Int) async {
        let playlists = visiblePlaylists
        guard !playlists.isEmpty else { return }
        let currentIndex = playlists.firstIndex { $0.id == selectedPlaylistID } ?? 0
        let nextIndex = min(max(0, currentIndex + offset), playlists.count - 1)
        await selectPlaylist(id: playlists[nextIndex].id)
    }

    private func apply(
        playlists: [SpotifyPlaylistSummary],
        state: BrowsingLoadState<[PlaylistRowViewModel]>,
        preserveSelection: Bool
    ) {
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistState = state

        if preserveSelection, let selectedPlaylistID, playlistsByID[selectedPlaylistID] != nil {
            return
        }

        if selectedPlaylistID != nil {
            detailState = .error(BrowsingDisplayError(
                title: "Playlist unavailable",
                message: "The selected playlist was deleted or is no longer accessible.",
                canRetry: true
            ))
        }
        selectedPlaylistID = playlists.first?.id
    }

    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(title: "Sign in again", message: "Your Spotify sign-in expired. Disconnect and connect Spotify again.", canRetry: false)
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: "Reconnect Spotify",
                    message: "Your current Spotify session is missing playlist permissions. Disconnect and connect again to grant required scopes.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .forbidden(message, _):
                return BrowsingDisplayError(
                    title: "Access denied",
                    message: message ?? "Spotify denied access to this resource.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .rateLimited(retryAfter):
                let retry = retryAfter.map { " Try again in \(Int($0)) seconds." } ?? ""
                return BrowsingDisplayError(title: "Spotify is rate limiting requests", message: "Too many requests were sent to Spotify.\(retry)", canRetry: true)
            case let .notFound(message):
                return BrowsingDisplayError(title: "Not found", message: message ?? "This Spotify resource is no longer available.", canRetry: true)
            case let .network(message):
                return BrowsingDisplayError(title: "Network unavailable", message: message, canRetry: true)
            case .decoding:
                return BrowsingDisplayError(title: "Could not read Spotify response", message: apiError.userMessage, canRetry: true)
            case let .badRequest(message, _):
                return BrowsingDisplayError(
                    title: "Spotify rejected the request",
                    message: message ?? "Spotify rejected this request.",
                    canRetry: false,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .server(_, message, _):
                return BrowsingDisplayError(
                    title: "Spotify service issue",
                    message: message ?? "Spotify returned a server error.",
                    canRetry: true,
                    diagnosticDetails: apiError.diagnosticDetails
                )
            case let .invalidRequest(message):
                return BrowsingDisplayError(title: "Invalid request", message: message, canRetry: false)
            }
        }

        return BrowsingDisplayError(title: "Something went wrong", message: error.localizedDescription, canRetry: true)
    }
}

private struct DisabledSpotifyBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func loadPlaylistsBundle(now: Date) throws -> (playlists: [SpotifyPlaylistSummary], age: TimeInterval)? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}
