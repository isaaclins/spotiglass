import Foundation

extension PlaylistBrowserViewModel {
    /// Quick-access tiles for the top of the home grid, derived synchronously from
    /// already-loaded library state (no extra network). Liked Songs is pinned first,
    /// followed by the user's playlists.
    var homeQuickAccessCards: [HomeMediaCard] {
        var cards: [HomeMediaCard] = [
            HomeMediaCard(
                id: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID,
                title: SpotiglassL10n.string("browser.likedSongs.title"),
                subtitle: "",
                artworkURL: nil,
                destination: .likedSongs
            )
        ]
        cards.append(contentsOf: visiblePlaylists.prefix(11).map { playlist in
            HomeMediaCard(
                id: playlist.id,
                title: playlist.title,
                subtitle: playlist.owner,
                artworkURL: playlist.artworkURL,
                destination: .playlist(id: playlist.id)
            )
        })
        return cards
    }

    /// Time-of-day greeting shown in the home header.
    func homeGreeting(now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        switch hour {
        case 5..<12:
            return SpotiglassL10n.string("home.greeting.morning")
        case 12..<18:
            return SpotiglassL10n.string("home.greeting.afternoon")
        default:
            return SpotiglassL10n.string("home.greeting.evening")
        }
    }

    /// Entry point for showing the home surface: marks the detail column as Home and
    /// kicks off the independent section loads. Safe to call repeatedly (refresh).
    func loadHomeFeed(session: Int) async {
        guard session == detailSession else { return }
        detailState = .loaded(.home)
        await reloadHomeSections()
    }

    /// Reloads the network-backed home sections (recently played, top tracks)
    /// concurrently. Quick access is derived state and needs no reload here.
    func reloadHomeSections(forceRefresh: Bool = false) async {
        homeFeedGeneration += 1
        let generation = homeFeedGeneration
        let cacheMode: SpotifyRequestCacheMode = forceRefresh ? .bypassCache : .freshOnly
        homeRecentlyPlayed = .loading
        homeTopTracks = .loading
        homeTopTrackData = []
        async let recently: Void = loadHomeRecentlyPlayed(generation: generation, cacheMode: cacheMode)
        async let top: Void = loadHomeTopTracks(generation: generation, cacheMode: cacheMode)
        _ = await (recently, top)
    }

    private func loadHomeRecentlyPlayed(
        generation: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async {
        do {
            let tracks = try await api.recentlyPlayedTracks(limit: 50, cacheMode: cacheMode)
            guard generation == homeFeedGeneration else { return }
            var seenAlbums: Set<String> = []
            let cards = tracks.compactMap { track -> HomeMediaCard? in
                guard let card = HomeMediaCard(recentlyPlayed: track) else { return nil }
                guard seenAlbums.insert(card.id).inserted else { return nil }
                return card
            }
            homeRecentlyPlayed = .loaded(cards)
        } catch is CancellationError {
            return
        } catch {
            guard generation == homeFeedGeneration else { return }
            homeRecentlyPlayed = homeSectionState(for: error)
        }
    }

    private func loadHomeTopTracks(
        generation: Int,
        cacheMode: SpotifyRequestCacheMode
    ) async {
        do {
            let tracks = try await api.topTracks(
                limit: 20,
                timeRange: "short_term",
                cacheMode: cacheMode
            )
            guard generation == homeFeedGeneration else { return }
            homeTopTrackData = tracks
            invalidateLibraryContinuationCache()
            homeTopTracks = .loaded(TrackRowViewModel.numberedTopTracks(tracks))
        } catch is CancellationError {
            return
        } catch {
            guard generation == homeFeedGeneration else { return }
            homeTopTracks = homeSectionState(for: error)
        }
    }

    /// Maps a section load failure to a terminal state. Missing-scope failures
    /// degrade to `.unavailable` (inline reconnect hint) rather than `.failed`,
    /// so accounts authorized before the home-feed scopes were added aren't
    /// shown a scary error.
    private func homeSectionState<Value>(for error: Error) -> HomeSectionState<Value> {
        if let apiError = error as? SpotifyAPIError {
            switch apiError {
            case .insufficientScope, .forbidden:
                return .unavailable
            default:
                return .failed(apiError.userMessage)
            }
        }
        return .failed(error.localizedDescription)
    }
}
