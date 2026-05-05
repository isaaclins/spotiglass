import Foundation

enum SpotiglassSidebarLibrary {
    /// Synthetic ID for Liked Songs: disk cache, `List` tags, and `PlaybackSessionViewModel.activePlaylistID`.
    static let likedSongsVirtualPlaylistID = "spotiglass.likedSongs"
    static let likedSongsCacheSnapshotID = "saved-tracks"
}

enum SidebarSelection: Hashable {
    case home
    case likedSongs
    case playlist(String)
    /// Pinned-area row identified by ``PinnedItem.id``. The browser view
    /// routes the click through ``PinnedItemsStore`` to dispatch the right
    /// detail loader (or playback for pinned tracks).
    case pinnedItem(String)
}

protocol SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem]
    func currentUserSavedTracks(limit: Int, maxPages: Int) async throws -> SpotifySavedTracksResult
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
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]?
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws
    func invalidateTracks(playlistID: String) throws
}

extension SpotifyLocalCache: SpotifyBrowsingCache {}

extension SpotifyLocalCache: PinnedItemsCache {}

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

    /// Virtual library row for Liked Songs (sidebar and detail header). Pass `totalTrackCount: nil` for the sidebar before counts are known (`trackCountText` becomes “Saved tracks”).
    init(likedSongsOwnerDisplay: String, totalTrackCount: Int?, artworkURL: URL?) {
        self.id = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        self.title = "Liked Songs"
        self.owner = likedSongsOwnerDisplay
        if let totalTrackCount {
            self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
        } else {
            self.trackCountText = "Saved tracks"
        }
        self.artworkURL = artworkURL
        self.snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID
    }

    /// Pinned-album header rendered through the existing playlist detail UI.
    /// `albumID` is used as the row id so playback's `activePlaylistID` and the
    /// click-source identification stay consistent with how the rest of the
    /// app keys "currently shown collection".
    init(albumDisplayName: String, artistsDisplay: String, totalTrackCount: Int, artworkURL: URL?, albumID: String) {
        self.id = albumID
        self.title = albumDisplayName
        self.owner = artistsDisplay
        self.trackCountText = totalTrackCount == 1 ? "1 track" : "\(totalTrackCount) tracks"
        self.artworkURL = artworkURL
        self.snapshotID = "album-\(albumID)"
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
        self.tracks = TrackRowViewModel.numberedTopTracks(tracks)
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
    /// 1-based row index in playlist / artist track lists (for ``TrackListRow``).
    let listPosition: Int
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    let badgeText: String?
    let isUnavailable: Bool
    let playableURI: String?
    let artistRefs: [SpotifyArtistRef]

    /// Builds playlist rows with stable numbering without allocating `enumerated()` in SwiftUI bodies.
    static func numberedPlaylistRows(_ items: [SpotifyPlaylistTrackItem]) -> [TrackRowViewModel] {
        items.enumerated().map { index, item in
            TrackRowViewModel(item, listPosition: index + 1)
        }
    }

    /// Builds artist (or album) top-track rows with stable numbering.
    static func numberedTopTracks(_ tracks: [SpotifyTrack]) -> [TrackRowViewModel] {
        tracks.enumerated().map { index, track in
            TrackRowViewModel(topTrack: track, listPosition: index + 1)
        }
    }

    init(_ item: SpotifyPlaylistTrackItem, listPosition: Int) {
        self.listPosition = listPosition
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

    init(topTrack track: SpotifyTrack, listPosition: Int) {
        self.listPosition = listPosition
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

    /// Milliseconds parsed from ``durationText`` (`m:ss`); `0` when unparsable.
    var durationMillisecondsForPinning: Int {
        let parts = durationText.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let s = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(0, (m * 60 + s) * 1_000)
    }

    /// Domain track for palette pinning and draggable pins; `nil` for episodes, locals, and unavailable rows.
    func spotifyTrackForPinning(originPlaylistID: String?) -> SpotifyTrack? {
        guard let playableURI, playableURI.hasPrefix("spotify:track:") else { return nil }
        let names: [String] = artistRefs.map(\.name).isEmpty
            ? subtitle.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            : artistRefs.map(\.name)
        return SpotifyTrack(
            id: id,
            name: title,
            artists: names,
            artistRefs: artistRefs,
            albumArtworkURL: artworkURL,
            durationMilliseconds: durationMillisecondsForPinning,
            isExplicit: badgeText == "Explicit",
            isPlayable: !isUnavailable,
            linkedFromID: nil,
            uri: playableURI
        )
    }

    func pinnedTrackItem(originPlaylistID: String?) -> PinnedItem? {
        guard let track = spotifyTrackForPinning(originPlaylistID: originPlaylistID) else { return nil }
        return .track(track, originPlaylistID: originPlaylistID)
    }
}

extension ArtistAlbumRowViewModel {
    private var parsedTotalTrackCount: Int {
        let digits = trackCountText.prefix { $0.isNumber }
        return Int(digits) ?? 1
    }

    func spotifyArtistAlbum(group: SpotifyArtistAlbumGroup) -> SpotifyArtistAlbum {
        SpotifyArtistAlbum(
            id: id,
            name: title,
            imageURL: artworkURL,
            releaseYear: yearText,
            totalTracks: parsedTotalTrackCount,
            group: group,
            uri: uri
        )
    }

    func pinnedAlbum(group: SpotifyArtistAlbumGroup) -> PinnedItem {
        .album(spotifyArtistAlbum(group: group))
    }
}

@MainActor
final class PlaylistBrowserViewModel: ObservableObject {
    @Published private(set) var playlistState: BrowsingLoadState<[PlaylistRowViewModel]> = .loading
    @Published private(set) var detailState: BrowsingLoadState<BrowsingDetailContent> = .empty("Select an item in the sidebar or open an artist from search.")
    @Published var sidebarSelection: SidebarSelection?

    /// When the sidebar shows a Spotify playlist row; used by search / command palette.
    var selectedPlaylistID: String? {
        if case let .playlist(id) = sidebarSelection { return id }
        return nil
    }

    /// True when the browser shows a loaded playlist or Liked Songs (not Home or artist detail).
    var isCommandPaletteThisPlaylistSearchEligible: Bool {
        guard let selection = sidebarSelection else { return false }
        switch selection {
        case .playlist, .likedSongs:
            break
        case .home, .pinnedItem:
            return false
        }
        guard let content = detailState.currentValue else { return false }
        if case .playlist = content { return true }
        return false
    }

    /// Tracks in the current playlist detail, when loaded.
    var loadedPlaylistTracksForPalette: [TrackRowViewModel]? {
        guard let content = detailState.currentValue else { return nil }
        if case let .playlist(vm) = content { return vm.tracks }
        return nil
    }

    private let api: SpotifyBrowsingAPI
    private let cache: SpotifyBrowsingCache
    private let now: () -> Date
    private let maxCacheAge: TimeInterval
    /// When the saved playlist list is younger than this, `load()` does not call `refreshPlaylists()` (tracks for the selection still revalidate in the background when a track cache hit exists).
    private let playlistListAutoRefreshMinInterval: TimeInterval
    private var playlistsByID: [String: SpotifyPlaylistSummary] = [:]
    private var hasLoaded = false
    private var detailSession = 0
    /// Clears sidebar selection when opening an artist; SwiftUI then calls `selectSidebar(nil)`, which must not reset the detail pane or bump `detailSession`.
    private var ignoreNextNilSidebarSelectionForDetail = false

    var visiblePlaylists: [PlaylistRowViewModel] {
        playlistState.currentValue ?? []
    }

    init(
        api: SpotifyBrowsingAPI,
        cache: SpotifyBrowsingCache,
        now: @escaping () -> Date = Date.init,
        maxCacheAge: TimeInterval = 1800,
        playlistListAutoRefreshMinInterval: TimeInterval = 1800
    ) {
        self.api = api
        self.cache = cache
        self.now = now
        self.maxCacheAge = maxCacheAge
        self.playlistListAutoRefreshMinInterval = playlistListAutoRefreshMinInterval
    }

    static func live(tokenProvider: SpotifyAccessTokenProviding) -> PlaylistBrowserViewModel {
        let api = SpotifyAPIClient(tokenProvider: tokenProvider, getResponseCache: .shared)
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
                if let sidebarSelection {
                    detailSession += 1
                    let session = detailSession
                    await loadDetail(for: sidebarSelection, refreshCachedData: true, session: session)
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
                sidebarSelection = nil
                playlistState = .empty("Your Spotify library has no playlists yet.")
                detailState = .empty("Create or follow a playlist in Spotify, then refresh.")
                return
            }
            apply(playlists: playlists, state: .loaded(playlists.map(PlaylistRowViewModel.init)), preserveSelection: true)
            if let sidebarSelection {
                detailSession += 1
                let session = detailSession
                await loadDetail(for: sidebarSelection, refreshCachedData: true, session: session)
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

    func selectSidebar(_ selection: SidebarSelection?) async {
        guard let selection else {
            sidebarSelection = nil
            if ignoreNextNilSidebarSelectionForDetail {
                ignoreNextNilSidebarSelectionForDetail = false
                return
            }
            detailSession += 1
            detailState = .empty("Select an item in the sidebar or open an artist from search.")
            return
        }

        // Pinned-item taps are dispatched in the view layer (it owns the
        // `PinnedItemsStore` and the playback view-model needed for tracks).
        // Just record the selection so list highlight stays in sync.
        if case .pinnedItem = selection {
            sidebarSelection = selection
            return
        }

        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        sidebarSelection = selection
        await loadDetail(for: selection, refreshCachedData: true, session: session)
    }

    /// Loads an album by ID and renders it through the existing playlist
    /// detail content. Album metadata (title / artist line / artwork) is
    /// supplied by the caller (typically a pinned item snapshot) so the
    /// header is populated even when offline.
    func selectAlbum(id: String, displayTitle: String, displaySubtitle: String, artworkURL: URL?) async {
        ignoreNextNilSidebarSelectionForDetail = false
        detailSession += 1
        let session = detailSession
        detailState = .loading
        do {
            let profile = try? await api.currentUserProfile()
            let market = profile?.country
            let tracks = try await api.albumTracks(albumID: id, market: market, limit: 50)
            guard session == detailSession else { return }
            let header = PlaylistRowViewModel(
                albumDisplayName: displayTitle,
                artistsDisplay: displaySubtitle,
                totalTrackCount: tracks.count,
                artworkURL: artworkURL,
                albumID: id
            )
            let trackRows = TrackRowViewModel.numberedTopTracks(tracks)
            if trackRows.isEmpty {
                detailState = .empty("This album has no tracks available.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: header, tracks: trackRows)))
            }
        } catch {
            guard session == detailSession else { return }
            detailState = .error(Self.displayError(for: error))
        }
    }

    func selectPlaylist(id: String?) async {
        if let id {
            await selectSidebar(.playlist(id))
        } else {
            await selectSidebar(nil)
        }
    }

    func selectArtist(id: String) async {
        ignoreNextNilSidebarSelectionForDetail = true
        sidebarSelection = nil
        detailSession += 1
        let session = detailSession
        detailState = .loading
        do {
            let profile = try await api.currentUserProfile()
            let market = profile.country
            async let detail = api.artist(id: id)
            // Omit `appears_on` here: it explodes pagination for major artists and triggers strict dev-mode rate limits.
            async let albums = api.artistAlbums(id: id, includeGroups: "album,single,compilation", limit: 10)
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
        if let sidebarSelection {
            if case .pinnedItem = sidebarSelection {
                return
            }
            detailSession += 1
            let session = detailSession
            switch sidebarSelection {
            case .playlist(let playlistID):
                try? cache.invalidateTracks(playlistID: playlistID)
            case .likedSongs:
                try? cache.invalidateTracks(playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID)
            case .home, .pinnedItem:
                break
            }
            await loadDetail(for: sidebarSelection, refreshCachedData: false, session: session)
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
        sidebarSelection = nil
        playlistsByID = [:]
        playlistState = .empty("Connect Spotify to browse playlists.")
        detailState = .empty("Sign in to Spotify to browse playlists and artists.")
    }

    private func loadDetail(for selection: SidebarSelection, refreshCachedData: Bool, session: Int) async {
        switch selection {
        case .home:
            guard session == detailSession else { return }
            detailState = .empty("Home is not available yet.")
        case .likedSongs:
            await loadLikedSongsTracks(refreshCachedData: refreshCachedData, session: session)
        case let .playlist(playlistID):
            await loadTracks(for: playlistID, refreshCachedData: refreshCachedData, session: session)
        case .pinnedItem:
            guard session == detailSession else { return }
            return
        }
    }

    private func loadLikedSongsTracks(refreshCachedData: Bool, session: Int) async {
        guard session == detailSession else { return }
        let virtualID = SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
        let snapshotID = SpotiglassSidebarLibrary.likedSongsCacheSnapshotID

        if refreshCachedData,
           let cachedTracks = try? cache.loadTracks(playlistID: virtualID, snapshotID: snapshotID, now: now(), maxAge: maxCacheAge) {
            await setLikedSongsDetailState(from: cachedTracks)
            await revalidateLikedSongs(session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: virtualID, snapshotID: snapshotID) {
            await setLikedSongsDetailState(from: staleTracks)
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
            }
            await revalidateLikedSongs(session: session)
            return
        }

        let existingDetail = detailState.currentValue
        detailState = .loading
        guard session == detailSession else { return }
        if let existingDetail {
            detailState = .refreshing(existingDetail)
        }
        await revalidateLikedSongs(session: session)
    }

    private func setLikedSongsDetailState(from tracks: [SpotifyPlaylistTrackItem]) async {
        if tracks.isEmpty {
            detailState = .empty("You have no liked songs yet.")
            return
        }
        let profile = try? await api.currentUserProfile()
        let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = trimmedName.isEmpty ? "You" : trimmedName
        let row = PlaylistRowViewModel(
            likedSongsOwnerDisplay: owner,
            totalTrackCount: tracks.count,
            artworkURL: firstLikedSongsArtwork(from: tracks)
        )
        detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
    }

    private func firstLikedSongsArtwork(from tracks: [SpotifyPlaylistTrackItem]) -> URL? {
        for item in tracks.prefix(4) {
            if case let .track(t) = item.content { return t.albumArtworkURL }
            if case let .episode(e) = item.content { return e.artworkURL }
        }
        return nil
    }

    private func revalidateLikedSongs(session: Int) async {
        do {
            let result = try await api.currentUserSavedTracks(limit: 50, maxPages: 20)
            try? cache.saveTracks(
                result.tracks,
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                snapshotID: SpotiglassSidebarLibrary.likedSongsCacheSnapshotID,
                cachedAt: now()
            )
            guard session == detailSession else { return }
            let profile = try? await api.currentUserProfile()
            let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = trimmedName.isEmpty ? "You" : trimmedName
            let row = PlaylistRowViewModel(
                likedSongsOwnerDisplay: owner,
                totalTrackCount: max(result.totalAvailable, result.tracks.count),
                artworkURL: firstLikedSongsArtwork(from: result.tracks)
            )
            if result.tracks.isEmpty {
                detailState = .empty("You have no liked songs yet.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: row, tracks: TrackRowViewModel.numberedPlaylistRows(result.tracks))))
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
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(cachedTracks))))
            }
            await revalidatePlaylistTracks(playlist: playlist, playlistRow: playlistRow, session: session)
            return
        }

        if refreshCachedData,
           let staleTracks = try? cache.loadTracksIgnoringAge(playlistID: playlist.id, snapshotID: playlist.snapshotID) {
            if staleTracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(staleTracks))))
            }
            if let existingDetail = detailState.currentValue {
                detailState = .refreshing(existingDetail)
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
                detailState = .loaded(.playlist(PlaylistDetailViewModel(playlist: playlistRow, tracks: TrackRowViewModel.numberedPlaylistRows(tracks))))
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
        let order: [SidebarSelection] = [.home, .likedSongs] + visiblePlaylists.map { .playlist($0.id) }
        guard !order.isEmpty else { return }
        let currentIndex = order.firstIndex(of: sidebarSelection ?? .home) ?? 0
        let nextIndex = min(max(0, currentIndex + offset), order.count - 1)
        await selectSidebar(order[nextIndex])
    }

    private func apply(
        playlists: [SpotifyPlaylistSummary],
        state: BrowsingLoadState<[PlaylistRowViewModel]>,
        preserveSelection: Bool
    ) {
        playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        playlistState = state

        if preserveSelection, let selection = sidebarSelection {
            switch selection {
            case let .playlist(id) where playlistsByID[id] != nil:
                return
            case .likedSongs, .home, .pinnedItem:
                return
            case .playlist:
                break
            }
        }

        if case let .playlist(missingID) = sidebarSelection, playlistsByID[missingID] == nil {
            detailState = .error(BrowsingDisplayError(
                title: "Playlist unavailable",
                message: "The selected playlist was deleted or is no longer accessible.",
                canRetry: true
            ))
        }
        sidebarSelection = playlists.first.map { .playlist($0.id) }
    }

    static func displayError(for error: Error) -> BrowsingDisplayError {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .unauthorized:
                return BrowsingDisplayError(title: "Sign in again", message: "Your Spotify sign-in expired. Disconnect and connect Spotify again.", canRetry: false)
            case .insufficientScope:
                return BrowsingDisplayError(
                    title: "Reconnect Spotify",
                    message: "Your current Spotify session is missing playlist or Liked Songs permissions. Disconnect and connect again to grant required scopes.",
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
                let clause = SpotifyRateLimitDisplay.retryAfterClause(seconds: retryAfter)
                return BrowsingDisplayError(
                    title: "Spotify is rate limiting requests",
                    message: "Too many requests were sent to Spotify. \(clause)",
                    canRetry: true,
                    diagnosticDetails: SpotifyRateLimitDisplay.rawRetryDiagnostic(seconds: retryAfter)
                )
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
    func loadTracksIgnoringAge(playlistID: String, snapshotID: String) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}
