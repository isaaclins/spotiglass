import Foundation

protocol SpotifyBrowsingAPI {
    func currentUserPlaylists(limit: Int) async throws -> [SpotifyPlaylistSummary]
    func playlistTracks(playlistID: String, limit: Int) async throws -> [SpotifyPlaylistTrackItem]
}

extension SpotifyAPIClient: SpotifyBrowsingAPI {}

protocol SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]?
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

struct TrackRowViewModel: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let durationText: String
    let badgeText: String?
    let isUnavailable: Bool
    let playableURI: String?

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
        case let .episode(episode):
            self.title = episode.name
            self.subtitle = episode.showName ?? "Podcast episode"
            self.artworkURL = episode.artworkURL
            self.durationText = Self.durationText(milliseconds: episode.durationMilliseconds)
            self.badgeText = episode.isPlayable == false ? "Unavailable episode" : "Episode"
            self.isUnavailable = episode.isPlayable == false
            self.playableURI = episode.isPlayable == false ? nil : episode.uri
        case let .localTrack(track):
            self.title = track.name
            self.subtitle = track.artists.isEmpty ? "Local track" : track.artists.joined(separator: ", ")
            self.artworkURL = nil
            self.durationText = Self.durationText(milliseconds: track.durationMilliseconds)
            self.badgeText = "Local"
            self.isUnavailable = false
            self.playableURI = nil
        case let .unavailable(reason):
            self.title = "Unavailable item"
            self.subtitle = reason
            self.artworkURL = nil
            self.durationText = "--:--"
            self.badgeText = "Unavailable"
            self.isUnavailable = true
            self.playableURI = nil
        }
    }

    private static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

@MainActor
final class PlaylistBrowserViewModel: ObservableObject {
    @Published private(set) var playlistState: BrowsingLoadState<[PlaylistRowViewModel]> = .loading
    @Published private(set) var detailState: BrowsingLoadState<PlaylistDetailViewModel> = .empty("Select a playlist to inspect its tracks.")
    @Published var selectedPlaylistID: String?

    private let api: SpotifyBrowsingAPI
    private let cache: SpotifyBrowsingCache
    private let now: () -> Date
    private let maxCacheAge: TimeInterval
    private var playlistsByID: [String: SpotifyPlaylistSummary] = [:]
    private var hasLoaded = false

    var visiblePlaylists: [PlaylistRowViewModel] {
        playlistState.currentValue ?? []
    }

    init(
        api: SpotifyBrowsingAPI,
        cache: SpotifyBrowsingCache,
        now: @escaping () -> Date = Date.init,
        maxCacheAge: TimeInterval = 300
    ) {
        self.api = api
        self.cache = cache
        self.now = now
        self.maxCacheAge = maxCacheAge
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
        if let cached = try? cache.loadPlaylists(now: now(), maxAge: maxCacheAge), !cached.isEmpty {
            apply(playlists: cached, state: .staleCache(cached.map(PlaylistRowViewModel.init), nil), preserveSelection: true)
        } else {
            playlistState = .loading
        }

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
                await loadTracks(for: selectedPlaylistID, refreshCachedData: true)
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
        selectedPlaylistID = id
        guard let id else {
            detailState = .empty("Select a playlist to inspect its tracks.")
            return
        }
        await loadTracks(for: id, refreshCachedData: true)
    }

    func refreshSelectedPlaylist() async {
        guard let selectedPlaylistID else { return }
        try? cache.invalidateTracks(playlistID: selectedPlaylistID)
        await loadTracks(for: selectedPlaylistID, refreshCachedData: false)
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
        detailState = .empty("Sign in to Spotify to inspect playlist tracks.")
    }

    private func loadTracks(for playlistID: String, refreshCachedData: Bool) async {
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
            detailState = cachedTracks.isEmpty
                ? .empty("This playlist has no tracks.")
                : .staleCache(PlaylistDetailViewModel(playlist: playlistRow, tracks: cachedTracks.map(TrackRowViewModel.init)), nil)
        } else {
            detailState = .loading
        }

        let existingDetail = detailState.currentValue
        if let existingDetail {
            detailState = .refreshing(existingDetail)
        }

        do {
            // Spotify's `/v1/playlists/{id}/items` endpoint accepts a maximum
            // limit of 50 (the February 2026 rename also tightened the cap from
            // the legacy `/tracks` endpoint's 100). Passing 100 yields HTTP 400
            // invalid_request and breaks any playlist with more than 50 tracks.
            let tracks = try await api.playlistTracks(playlistID: playlist.id, limit: 50)
            try? cache.saveTracks(tracks, playlistID: playlist.id, snapshotID: playlist.snapshotID, cachedAt: now())
            if tracks.isEmpty {
                detailState = .empty("This playlist has no tracks.")
            } else {
                detailState = .loaded(PlaylistDetailViewModel(playlist: playlistRow, tracks: tracks.map(TrackRowViewModel.init)))
            }
        } catch {
            let displayError = Self.displayError(for: error)
            if let existingDetail {
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
            case let .server(_, message):
                return BrowsingDisplayError(title: "Spotify service issue", message: message ?? "Spotify returned a server error.", canRetry: true)
            case let .invalidRequest(message):
                return BrowsingDisplayError(title: "Invalid request", message: message, canRetry: false)
            }
        }

        return BrowsingDisplayError(title: "Something went wrong", message: error.localizedDescription, canRetry: true)
    }
}

private struct DisabledSpotifyBrowsingCache: SpotifyBrowsingCache {
    func loadPlaylists(now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistSummary]? { nil }
    func savePlaylists(_ playlists: [SpotifyPlaylistSummary], cachedAt: Date) throws {}
    func loadTracks(playlistID: String, snapshotID: String, now: Date, maxAge: TimeInterval) throws -> [SpotifyPlaylistTrackItem]? { nil }
    func saveTracks(_ tracks: [SpotifyPlaylistTrackItem], playlistID: String, snapshotID: String, cachedAt: Date) throws {}
    func invalidateTracks(playlistID: String) throws {}
}
