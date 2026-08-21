import AppKit
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

    func testTrackRowPlaybackActionUsesCurrentTransportState() {
        XCTAssertEqual(
            TrackListRow.playbackAction(isCurrent: true, isPlaying: true),
            .pause
        )
        XCTAssertEqual(
            TrackListRow.playbackAction(isCurrent: true, isPlaying: false),
            .play
        )
        XCTAssertEqual(
            TrackListRow.playbackAction(isCurrent: false, isPlaying: true),
            .play
        )
        XCTAssertEqual(
            TrackListRow.playbackAction(isCurrent: true, isPlaying: true).label,
            SpotiglassL10n.string("playback.pause")
        )
        XCTAssertEqual(
            TrackListRow.playbackAction(isCurrent: true, isPlaying: false).label,
            SpotiglassL10n.string("browser.track.play")
        )
    }

    func testTrackRowPlaybackInvocationRoutesEachSurfaceAction() {
        XCTAssertEqual(
            TrackListRow.playbackInvocation(
                isCurrent: true,
                isPlaying: true,
                playableURI: nil
            ),
            .toggle(action: .pause)
        )
        XCTAssertTrue(
            TrackListRow.playbackInvocation(
                isCurrent: true,
                isPlaying: true,
                playableURI: nil
            ).isAvailable
        )
        XCTAssertEqual(
            TrackListRow.playbackInvocation(
                isCurrent: true,
                isPlaying: false,
                playableURI: nil
            ),
            .toggle(action: .play)
        )
        XCTAssertEqual(
            TrackListRow.playbackInvocation(
                isCurrent: false,
                isPlaying: true,
                playableURI: "spotify:track:other"
            ),
            .play(uri: "spotify:track:other")
        )
        let unavailable = TrackListRow.playbackInvocation(
            isCurrent: false,
            isPlaying: false,
            playableURI: " \n\t"
        )
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertFalse(unavailable.isAvailable)
    }

    /// The playlist row and the queue row are the same design, so the numbers
    /// that define it live in one place instead of drifting apart (#140).
    func testTrackRowGeometryIsSharedAndConsistent() {
        // The documented row height is derived from these, so they must agree.
        XCTAssertEqual(
            TrackListRow.listRowHeight,
            TrackRowMetrics.artworkSize + TrackRowMetrics.verticalPadding * 2 + 4,
            accuracy: 0.001,
            "listRowHeight is artwork plus vertical padding plus headroom"
        )
        XCTAssertEqual(TrackRowMetrics.titleLineLimit, 1)
        XCTAssertEqual(TrackRowMetrics.artworkSize, 40)
        // A hover tint below the current-row tint, not a hundredth apart from it.
        XCTAssertLessThan(TrackRowMetrics.hoverTintOpacity, TrackRowMetrics.currentTintOpacity)
    }

    /// The dump used to present itself from onAppear. It is a request line, a
    /// status, a header dump and a raw JSON body, which is bug-report material,
    /// not something to open over someone who wanted a playlist (#148).
    func testDiagnosticDetailsStayBehindAButton() throws {
        let error = BrowsingDisplayError(
            title: "Load failed",
            message: "Spotify could not be reached.",
            canRetry: true,
            diagnosticDetails: "GET https://api.spotify.com/v1/me/playlists\nHTTP 403\n{\"error\":{}}"
        )
        let view = ErrorStateView(error: error)
        ViewTestHost.host(view)

        // The sentence is on screen; the dump is not.
        XCTAssertNoThrow(try view.inspect().find(text: "Spotify could not be reached."))
        XCTAssertThrowsError(try view.inspect().find(text: error.diagnosticDetails ?? ""))
        XCTAssertNoThrow(
            try view.inspect().find(button: SpotiglassL10n.string("browser.showDetails"))
        )
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
            store: store
        )
        ViewTestHost.host(view, size: CGSize(width: 640, height: 56))
        XCTAssertNoThrow(try view.inspect().find(text: "Pinned to sidebar"))
    }

    // MARK: - Native track list

    func testTrackListViewMountsRows() throws {
        let store = pinnedStore()
        let tracks = (1 ... 24).map { index in
            trackRow(id: "vt\(index)", title: "Track \(index)", explicit: false, listPosition: index)
        }
        var restoreID: String?
        var selection: Set<String> = []
        let view = trackListView(
            tracks: tracks,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onFirstVisibleTrackChanged: { _ in }
        )
        .frame(width: 640, height: 400)
        .environmentObject(store)
        ViewTestHost.host(view, size: CGSize(width: 640, height: 400))
        XCTAssertNoThrow(try view.inspect().find(text: "Track 1"))
    }

    /// The reason the hand written virtualizer existed: a long playlist must not
    /// instantiate every row. `List` is backed by `NSTableView`, so the stable
    /// contract to test is how many rows the table draws, not wall-clock time on
    /// whichever CI runner happens to execute the suite.
    func testTrackListViewVirtualizesThousandRows() throws {
        let store = pinnedStore()
        let tracks = (1 ... 1000).map { index in
            trackRow(id: "perf\(index)", title: "Track \(index)", explicit: false, listPosition: index)
        }
        var restoreID: String?
        var selection: Set<String> = []
        let view = trackListView(
            tracks: tracks,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onFirstVisibleTrackChanged: { _ in }
        )
        .frame(width: 800, height: 600)
        .environmentObject(store)
        let controller = ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        AppKitTestSupport.pumpRunLoop(for: 0.4)

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: controller.view))
        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let visibleRows = table.rows(in: table.visibleRect)
        XCTAssertEqual(table.numberOfRows, 1000)
        XCTAssertGreaterThan(visibleRows.length, 0)
        XCTAssertLessThan(
            visibleRows.length,
            30,
            "a 600-point viewport must not draw all 1000 rows: \(visibleRows)"
        )
    }

    func testTrackListViewReportsTopmostVisibleTrackWhileScrolling() throws {
        let store = pinnedStore()
        let tracks = (1 ... 400).map { index in
            trackRow(id: "sc\(index)", title: "Track \(index)", explicit: false, listPosition: index)
        }
        var reported: [String] = []
        var restoreID: String?
        var selection: Set<String> = []
        let view = trackListView(
            tracks: tracks,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            pendingScrollRestoreTrackID: Binding(get: { restoreID }, set: { restoreID = $0 }),
            onFirstVisibleTrackChanged: { reported.append($0) }
        )
        .frame(width: 800, height: 600)
        .environmentObject(store)
        let controller = ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: controller.view),
            "List should be hosted inside an NSScrollView"
        )
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.height,
            0,
            "a collapsed clip view would make the scroll assertions meaningless"
        )
        XCTAssertEqual(reported.last, "sc1", "an unscrolled list sits on its first track")

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: TrackListRow.listRowHeight * 40))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.displayIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 1.2)

        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let topmostVisibleRow = table.rows(in: table.visibleRect).location
        XCTAssertGreaterThan(topmostVisibleRow, 0, "the list should have scrolled off the first row")

        let reportedID = try XCTUnwrap(reported.last)
        let reportedRow = try XCTUnwrap(tracks.firstIndex { $0.id == reportedID })
        // NSTableView keeps a row of realization margin above the clip view, so
        // the reported row is allowed to sit just above the first visible one.
        // Anything wider than that means the report stopped tracking the table.
        XCTAssertLessThanOrEqual(
            abs(reportedRow - topmostVisibleRow),
            2,
            "reported row \(reportedRow) drifted from the table's topmost visible row \(topmostVisibleRow)"
        )
    }

    func testTrackListViewScrollsToPendingRestoreTrackAndClearsIt() throws {
        let store = pinnedStore()
        let tracks = (1 ... 400).map { index in
            trackRow(id: "rs\(index)", title: "Track \(index)", explicit: false, listPosition: index)
        }
        let recorder = ScrollRestoreRecorder()
        let view = TrackListScrollRestoreHarness(
            tracks: tracks,
            targetTrackID: "rs300",
            recorder: recorder
        )
        .frame(width: 800, height: 600)
        .environmentObject(store)
        let controller = ViewTestHost.host(view, size: CGSize(width: 800, height: 600))
        AppKitTestSupport.pumpRunLoop(for: 0.4)

        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: controller.view),
            "List should be hosted inside an NSScrollView"
        )
        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let visibleRows = table.rows(in: table.visibleRect)
        XCTAssertTrue(
            NSLocationInRange(299, visibleRows),
            "restoring track 300 should have brought row 300 on screen, visible rows were \(visibleRows)"
        )
        XCTAssertTrue(recorder.wasCleared, "the pending restore binding should be cleared after scrolling")
    }

    // MARK: - First-visible row selection

    func testFirstVisibleTrackIDPicksTheLowestRowNumber() {
        XCTAssertEqual(
            TrackListVisibility.firstVisibleTrackID(in: [12: "l", 9: "a", 10: "b"]),
            "a"
        )
        XCTAssertEqual(TrackListVisibility.firstVisibleTrackID(in: [1: "only"]), "only")
    }

    func testFirstVisibleTrackIDIsNilWhenNothingIsVisible() {
        XCTAssertNil(TrackListVisibility.firstVisibleTrackID(in: [:]))
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
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
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
            settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
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

    func trackListView(
        tracks: [TrackRowViewModel],
        selection: Binding<Set<String>>,
        pendingScrollRestoreTrackID: Binding<String?>,
        onFirstVisibleTrackChanged: @escaping (String) -> Void
    ) -> TrackListView {
        TrackListView(
            tracks: tracks,
            selection: selection,
            rowBuilder: TrackListTestRows.row(for:),
            pendingScrollRestoreTrackID: pendingScrollRestoreTrackID,
            onFirstVisibleTrackChanged: onFirstVisibleTrackChanged
        )
    }

    static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Track list test harness

enum TrackListTestRows {
    static func row(for track: TrackRowViewModel) -> TrackListRow {
        TrackListRow(
            trackNumber: track.listPosition,
            track: track,
            playURI: { _ in },
            togglePlayPause: {},
            isCurrent: false,
            isPlaying: false,
            hasPlaybackDevice: true,
            addToQueue: { _ in },
            openArtist: { _ in },
            drawsRowHighlights: false
        )
    }
}

@MainActor
final class ScrollRestoreRecorder: ObservableObject {
    var wasCleared = false
}

/// Drives `pendingScrollRestoreTrackID` from inside the view tree, because the
/// binding has to change *after* the list is on screen for the restore to run.
private struct TrackListScrollRestoreHarness: View {
    let tracks: [TrackRowViewModel]
    let targetTrackID: String
    let recorder: ScrollRestoreRecorder

    @State private var pending: String?
    @State private var selection: Set<String> = []

    var body: some View {
        TrackListView(
            tracks: tracks,
            selection: $selection,
            rowBuilder: TrackListTestRows.row(for:),
            pendingScrollRestoreTrackID: Binding(
                get: { pending },
                set: { newValue in
                    if newValue == nil, pending != nil { recorder.wasCleared = true }
                    pending = newValue
                }
            ),
            onFirstVisibleTrackChanged: { _ in }
        )
        .frame(width: 800, height: 600)
        .task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            pending = targetTrackID
        }
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
