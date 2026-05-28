import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

@MainActor
final class ListDetailViewsTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - Browser state chrome

    func testEmptyStateView() throws {
        let view = EmptyStateView(title: "No tracks", message: "This playlist is empty.")
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "No tracks"))
        XCTAssertNoThrow(try view.inspect().find(text: "This playlist is empty."))
    }

    func testErrorStateView() throws {
        let error = BrowsingDisplayError(title: "Load failed", message: "Network error", canRetry: true)
        let view = ErrorStateView(error: error)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Load failed"))
        XCTAssertNoThrow(try view.inspect().find(text: "Network error"))
    }

    func testStaleCacheBanner() throws {
        let view = StaleCacheBanner(
            error: BrowsingDisplayError(title: "Stale", message: "Cached playlists", canRetry: false)
        )
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Cached playlists"))
    }

    // MARK: - Track list row

    func testTrackListRowShowsTitleAndDuration() throws {
        let store = pinnedStore()
        let track = trackRow(id: "t1", title: "Midnight Run", explicit: false)
        let view = trackListRow(track: track, trackNumber: 1, isCurrent: false, isPlaying: false, store: store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(text: "Midnight Run"))
    }

    func testTrackListRowExplicitBadge() throws {
        let store = pinnedStore()
        let track = trackRow(id: "t2", title: "Explicit Song", explicit: true)
        let view = trackListRow(track: track, trackNumber: 2, isCurrent: false, isPlaying: false, store: store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(text: "Explicit Song"))
    }

    func testTrackListRowCurrentPlayingState() throws {
        let store = pinnedStore()
        let track = trackRow(id: "t3", title: "Now Playing", explicit: false)
        let view = trackListRow(track: track, trackNumber: 3, isCurrent: true, isPlaying: true, store: store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(text: "Now Playing"))
    }

    func testTrackListRowArtistRefButtons() throws {
        let store = pinnedStore()
        let base = PlaylistBrowsingTestFixtures.fallbackTrack(id: "t4", name: "Collab", artistId: "a0")
        let track = TrackRowViewModel(
            topTrack: base.withArtistRefs([
                SpotifyArtistRef(id: "a1", name: "Alpha"),
                SpotifyArtistRef(id: "a2", name: "Beta")
            ]),
            listPosition: 4
        )
        let view = trackListRow(track: track, trackNumber: 4, isCurrent: false, isPlaying: false, store: store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(text: "Alpha"))
        XCTAssertNoThrow(try view.inspect().find(text: "Beta"))
    }

    func testTrackListRowPinnedBadgeWhenPinned() throws {
        let track = trackRow(id: "t5", title: "Pinned Track", explicit: false)
        let store = pinnedStore()
        if let item = track.pinnedTrackItem() {
            store.pin(item)
        }
        let view = trackListRow(
            track: track,
            trackNumber: 5,
            isCurrent: false,
            isPlaying: false,
            store: store,
            surfaceID: "pl:test"
        )
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityLabel: "Pinned to sidebar"))
    }

    // MARK: - Virtualized track list

    func testVirtualizedTrackListMountsRows() throws {
        let store = pinnedStore()
        let tracks = (1 ... 24).map { index in
            trackRow(id: "vt\(index)", title: "Track \(index)", explicit: false, listPosition: index)
        }
        var restoreID: String?
        let view = VirtualizedTrackList(
            tracks: tracks,
            rowBuilder: { track in
                TrackListRow(
                    trackNumber: track.listPosition,
                    track: track,
                    playURI: { _ in },
                    togglePlayPause: {},
                    isCurrent: false,
                    isPlaying: false,
                    hasPlaybackDevice: true,
                    addToQueue: { _ in },
                    openArtist: { _ in }
                )
            },
            pendingScrollRestoreTrackID: Binding(
                get: { restoreID },
                set: { restoreID = $0 }
            ),
            onFirstVisibleTrackChanged: { _ in }
        )
        .environmentObject(store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 400))
        XCTAssertNoThrow(try view.inspect().find(text: "Track 1"))
    }

    // MARK: - Playlist detail

    func testPlaylistDetailContentHeaderAndTracks() throws {
        let playlist = PlaylistRowViewModel(
            PlaylistBrowsingTestFixtures.playlist(id: "pl1", name: "Deep Focus")
        )
        let tracks = TrackRowViewModel.numberedPlaylistRows([
            PlaylistBrowsingTestFixtures.track(id: "pt1"),
            PlaylistBrowsingTestFixtures.track(id: "pt2")
        ])
        let detail = PlaylistDetailViewModel(playlist: playlist, tracks: tracks)
        var restoreID: String?
        let view = PlaylistDetailContent(
            detail: detail,
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onTrackEnteredViewportApproximation: { _ in },
            playURI: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            browserViewModel: PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            )
        )
        .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 720, height: 520))
        XCTAssertNoThrow(try view.inspect().find(text: "Deep Focus"))
        XCTAssertNoThrow(try view.inspect().find(text: "Track pt1"))
    }

    func testPlaylistDetailContentEmptyPlaylist() throws {
        let playlist = PlaylistRowViewModel(
            PlaylistBrowsingTestFixtures.playlist(id: "empty", name: "Empty List")
        )
        let detail = PlaylistDetailViewModel(playlist: playlist, tracks: [])
        var restoreID: String?
        let view = PlaylistDetailContent(
            detail: detail,
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onTrackEnteredViewportApproximation: { _ in },
            playURI: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            browserViewModel: PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            )
        )
        .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 720, height: 400))
        XCTAssertNoThrow(try view.inspect().find(text: "No tracks"))
    }

    func testPlaylistDetailContentLikedSongsHeader() throws {
        let liked = PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: 42, artworkURL: nil)
        let detail = PlaylistDetailViewModel(playlist: liked, tracks: [])
        var restoreID: String?
        let view = PlaylistDetailContent(
            detail: detail,
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onTrackEnteredViewportApproximation: { _ in },
            playURI: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            browserViewModel: PlaylistBrowserViewModel(
                api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                cache: MockBrowsingCache()
            )
        )
        .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 720, height: 400))
        XCTAssertNoThrow(try view.inspect().find(text: "Liked Songs"))
    }

    // MARK: - Artist detail

    func testArtistDetailContentHeaderTracksAndAlbums() throws {
        let detail = sampleArtistDetail(canLoadMore: false)
        let view = artistDetailContent(detail: detail)
            .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 800, height: 700))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Sample Artist"))
        XCTAssertNoThrow(try inspected.find(text: "Tracks"))
        XCTAssertNoThrow(try inspected.find(text: "Albums"))
    }

    func testArtistDetailContentSinglesAndLoadMore() throws {
        let detail = sampleArtistDetail(canLoadMore: true, loadingMore: false)
        let view = artistDetailContent(detail: detail)
            .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 800, height: 800))
        XCTAssertNoThrow(try view.inspect().find(text: "Singles"))
        XCTAssertNoThrow(try view.inspect().find(text: "Hit Single"))
        XCTAssertNoThrow(try view.inspect().find(text: "Load more releases"))
    }

    func testArtistDetailContentLoadingMoreAlbums() throws {
        let detail = sampleArtistDetail(canLoadMore: true, loadingMore: true)
        let view = artistDetailContent(detail: detail)
            .environmentObject(pinnedStore())
        ViewTestHost.host(view, size: CGSize(width: 800, height: 800))
        XCTAssertNoThrow(try view.inspect().find(text: "Loading more releases..."))
    }

    // MARK: - Auth chrome

    func testSpotifyClientIDAndActionsWelcomeLayout() throws {
        let viewModel = AuthViewModel(
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signedOut
        )
        viewModel.clientID = "test-client-id"
        let view = SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .welcome)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Connect Spotify"))
    }

    func testSpotifyClientIDAndActionsSigningInShowsCancel() throws {
        let viewModel = AuthViewModel(
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            initialState: .signingIn
        )
        let view = SpotifyClientIDAndActionsView(viewModel: viewModel, layout: .settings)
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Cancel"))
    }

    // MARK: - Album card tap router

    func testAlbumCardTapRouterSingleTapDefersDoubleTapWins() async {
        let router = AlbumCardTapRouter(doubleClickDelayNanoseconds: 80_000_000)
        var singleCount = 0
        var doubleCount = 0
        router.handleSingleTap(albumID: "alb") { singleCount += 1 }
        router.handleDoubleTap { doubleCount += 1 }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(singleCount, 0)
        XCTAssertEqual(doubleCount, 1)
    }

    func testAlbumCardTapRouterSingleTapFiresAfterDelay() async {
        let router = AlbumCardTapRouter(doubleClickDelayNanoseconds: 50_000_000)
        var singleCount = 0
        router.handleSingleTap(albumID: "alb") { singleCount += 1 }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(singleCount, 1)
    }
}

// MARK: - Fixtures

private extension ListDetailViewsTests {
    func pinnedStore() -> PinnedItemsStore {
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "list-detail-tests")
        return store
    }

    func trackRow(
        id: String,
        title: String,
        explicit: Bool,
        listPosition: Int = 1
    ) -> TrackRowViewModel {
        TrackRowViewModel(
            topTrack: SpotifyTrack(
                id: id,
                name: title,
                artists: ["Artist"],
                artistRefs: [SpotifyArtistRef(id: "ar1", name: "Artist")],
                albumArtworkURL: nil,
                durationMilliseconds: 180_000,
                isExplicit: explicit,
                isPlayable: true,
                linkedFromID: nil,
                uri: "spotify:track:\(id)"
            ),
            listPosition: listPosition
        )
    }

    func trackListRow(
        track: TrackRowViewModel,
        trackNumber: Int,
        isCurrent: Bool,
        isPlaying: Bool,
        store: PinnedItemsStore,
        surfaceID: String? = nil
    ) -> some View {
        TrackListRow(
            trackNumber: trackNumber,
            track: track,
            playURI: { _ in },
            togglePlayPause: {},
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            tracksSurfaceID: surfaceID
        )
        .environmentObject(store)
    }

    func sampleArtistDetail(canLoadMore: Bool, loadingMore: Bool = false) -> ArtistDetailViewModel {
        let artist = SpotifyArtistDetail(
            id: "artist1",
            name: "Sample Artist",
            imageURL: nil,
            followersTotal: 1_234_567,
            genres: ["pop", "rock"],
            uri: "spotify:artist:artist1"
        )
        let tracks = [
            PlaylistBrowsingTestFixtures.fallbackTrack(id: "top1", name: "Top Song", artistId: "artist1")
        ]
        let albums = [
            SpotifyArtistAlbum(
                id: "alb1", name: "Debut Album", imageURL: nil, releaseYear: "2020",
                totalTracks: 10, group: .album, uri: "spotify:album:alb1"
            ),
            SpotifyArtistAlbum(
                id: "single1", name: "Hit Single", imageURL: nil, releaseYear: "2021",
                totalTracks: 1, group: .single, uri: "spotify:album:single1"
            )
        ]
        return ArtistDetailViewModel(
            artist: artist,
            tracks: tracks,
            albums: albums,
            canLoadMoreAlbums: canLoadMore,
            isLoadingMoreAlbums: loadingMore
        )
    }

    func artistDetailContent(detail: ArtistDetailViewModel) -> ArtistDetailContent {
        ArtistDetailContent(
            detail: detail,
            playTrack: { _ in },
            openAlbum: { _ in },
            playAlbumContext: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            loadMoreAlbums: {}
        )
    }
}

private extension SpotifyTrack {
    func withArtistRefs(_ refs: [SpotifyArtistRef]) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: name,
            artists: refs.map(\.name),
            artistRefs: refs,
            albumArtworkURL: albumArtworkURL,
            durationMilliseconds: durationMilliseconds,
            isExplicit: isExplicit,
            isPlayable: isPlayable,
            linkedFromID: linkedFromID,
            uri: uri
        )
    }
}
