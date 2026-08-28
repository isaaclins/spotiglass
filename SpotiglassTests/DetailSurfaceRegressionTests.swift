import AppKit
import SwiftUI
import ViewInspector
import XCTest

@testable import Spotiglass

@MainActor
final class DetailSurfaceRegressionTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testArtistRowsUseSharedNativeSelectionAndFeedSelectionMenuState() throws {
        let artist = SpotifyArtistDetail(
            id: "artist-1",
            name: "Artist",
            imageURL: nil,
            followersTotal: nil,
            genres: [],
            uri: "spotify:artist:artist-1"
        )
        let track = PlaylistBrowsingTestFixtures.fallbackTrack(
            id: "artist-track",
            name: "Artist Track",
            artistId: artist.id
        )
        let detail = ArtistDetailViewModel(artist: artist, tracks: [track], albums: [])
        let browserViewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let view = ArtistDetailContent(
            detail: detail,
            browserViewModel: browserViewModel,
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
        .environmentObject(pinnedStore())

        ViewTestHost.host(view, size: CGSize(width: 800, height: 700))
        XCTAssertNoThrow(try view.inspect().find(TrackListView.self))

        browserViewModel.detailState = .loaded(.artist(detail))
        browserViewModel.selectedDetailTrackIDs = [detail.tracks[0].id]
        let selectedRows = browserViewModel.selectedTrackRows

        XCTAssertEqual(selectedRows.map(\.id), [detail.tracks[0].id])
        XCTAssertTrue(
            PlaylistBrowserView.canEnqueueTrackSelection(
                rows: selectedRows,
                hasPlaybackDevice: true
            )
        )
        XCTAssertEqual(
            PlaylistBrowserView.trackSelectionPinState(
                for: selectedRows.compactMap { $0.pinnedTrackItem() },
                isPinned: { _ in false }
            ),
            .pin
        )
    }

    func testNativeTrackListWritesSelectionBinding() throws {
        let track = TrackRowViewModel.numberedTopTracks([
            PlaylistBrowsingTestFixtures.fallbackTrack(
                id: "selectable-track",
                name: "Selectable Track",
                artistId: "artist-1"
            )
        ])[0]
        var selection: Set<String> = []
        let view = TrackListView(
            tracks: [track],
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            rowBuilder: { row in
                TrackListRow(
                    trackNumber: row.listPosition,
                    track: row,
                    playURI: { _ in },
                    togglePlayPause: {},
                    isCurrent: false,
                    isPlaying: false,
                    openArtist: { _ in },
                    drawsRowHighlights: false,
                    isKeyboardFocusable: false
                )
            },
            pendingScrollRestoreTrackID: .constant(nil),
            onFirstVisibleTrackChanged: { _ in }
        )
        .environmentObject(pinnedStore())
        let controller = ViewTestHost.host(view, size: CGSize(width: 700, height: 300))
        AppKitTestSupport.pumpRunLoop(for: 0.2)
        let table = try XCTUnwrap(Self.firstTableView(in: controller.view))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.displayIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.2)

        XCTAssertEqual(selection, [track.id])
    }

    func testDetailHeaderPlaybackTargetsCoverPlaylistAlbumLikedSongsAndArtist() {
        let playlist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "playlist-1", name: "Playlist")
            ),
            tracks: []
        )
        let playlistTarget = DetailHeaderPlayback.target(for: playlist)
        XCTAssertEqual(playlistTarget, .context(uri: "spotify:playlist:playlist-1"))
        XCTAssertTrue(playlistTarget.isPlayable)

        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                albumDisplayName: "Album",
                artistsDisplay: "Artist",
                totalTrackCount: 1,
                artworkURL: nil,
                albumID: "album-1"
            ),
            tracks: []
        )
        XCTAssertEqual(
            DetailHeaderPlayback.target(for: album),
            .context(uri: "spotify:album:album-1")
        )

        let likedTrack = TrackRowViewModel.numberedTopTracks([
            PlaylistBrowsingTestFixtures.fallbackTrack(
                id: "liked-track",
                name: "Liked Track",
                artistId: "artist-1"
            )
        ])
        let likedSongs = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                likedSongsOwnerDisplay: "You",
                totalTrackCount: 1,
                artworkURL: nil
            ),
            tracks: likedTrack
        )
        let likedSongsTarget = DetailHeaderPlayback.target(for: likedSongs)
        XCTAssertEqual(
            likedSongsTarget,
            .tracks(
                uris: ["spotify:track:liked-track"],
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
            )
        )
        XCTAssertTrue(likedSongsTarget.isPlayable)
        XCTAssertFalse(
            DetailHeaderPlayback.target(
                for: PlaylistDetailViewModel(
                    playlist: PlaylistRowViewModel(
                        likedSongsOwnerDisplay: "You",
                        totalTrackCount: 0,
                        artworkURL: nil
                    ),
                    tracks: []
                )
            ).isPlayable
        )

        let artist = ArtistDetailViewModel(
            artist: SpotifyArtistDetail(
                id: "artist-1",
                name: "Artist",
                imageURL: nil,
                followersTotal: nil,
                genres: [],
                uri: "spotify:artist:artist-1"
            ),
            tracks: [],
            albums: []
        )
        XCTAssertEqual(
            DetailHeaderPlayback.target(for: artist),
            .context(uri: "spotify:artist:artist-1")
        )
    }

    func testShuffleHeaderEnablesShuffleBeforePlayingContext() async {
        let playbackAPI = MockPlaybackAPI()
        let playbackViewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander(),
            postShuffleSyncDelay: .seconds(60)
        )
        playbackViewModel.deviceID = "device-1"
        playbackViewModel.hasTransferredPlaybackToCurrentDevice = true
        playbackViewModel.setTransportStateKnown(true)

        await DetailHeaderPlayback.shuffleAndPlay(
            target: .context(uri: "spotify:playlist:playlist-1"),
            using: playbackViewModel
        )

        XCTAssertEqual(
            playbackAPI.actions.filter {
                $0.hasPrefix("setShuffle:") || $0.hasPrefix("play-context:")
            },
            [
                "setShuffle:device-1:true",
                "play-context:device-1:spotify:playlist:playlist-1",
            ]
        )
    }

    func testLikedSongsHeaderPlaysItsLoadedURIList() async {
        let playbackAPI = MockPlaybackAPI()
        let playbackViewModel = PlaybackSessionViewModel(
            playbackAPI: playbackAPI,
            webCommander: MockWebPlaybackCommander()
        )
        playbackViewModel.deviceID = "device-1"
        playbackViewModel.hasTransferredPlaybackToCurrentDevice = true

        await DetailHeaderPlayback.play(
            target: .tracks(
                uris: ["spotify:track:first", "spotify:track:second"],
                playlistID: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID
            ),
            using: playbackViewModel
        )

        XCTAssertEqual(
            playbackAPI.actions,
            ["play-list:device-1:spotify:track:first,spotify:track:second"]
        )
    }

    func testEachDetailHeaderExposesPlayAndShuffleDisabledWithoutDevice() throws {
        let store = pinnedStore()
        let playlist = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                PlaylistBrowsingTestFixtures.playlist(id: "playlist-1", name: "Playlist")
            ),
            tracks: []
        )
        let album = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                albumDisplayName: "Album",
                artistsDisplay: "Artist",
                totalTrackCount: 0,
                artworkURL: nil,
                albumID: "album-1"
            ),
            tracks: []
        )
        let likedSongs = PlaylistDetailViewModel(
            playlist: PlaylistRowViewModel(
                likedSongsOwnerDisplay: "You",
                totalTrackCount: 0,
                artworkURL: nil
            ),
            tracks: []
        )
        let artist = ArtistDetailViewModel(
            artist: SpotifyArtistDetail(
                id: "artist-1",
                name: "Artist",
                imageURL: nil,
                followersTotal: nil,
                genres: [],
                uri: "spotify:artist:artist-1"
            ),
            tracks: [],
            albums: []
        )

        let views: [AnyView] = [
            AnyView(playlistView(detail: playlist).environmentObject(store)),
            AnyView(playlistView(detail: album).environmentObject(store)),
            AnyView(playlistView(detail: likedSongs).environmentObject(store)),
            AnyView(artistView(detail: artist).environmentObject(store)),
        ]
        for view in views {
            ViewTestHost.tearDownAll()
            ViewTestHost.host(view, size: CGSize(width: 800, height: 500))
            let inspected = try view.inspect()
            XCTAssertTrue(
                try inspected.find(button: SpotiglassL10n.string("playback.play")).isDisabled()
            )
            XCTAssertTrue(
                try inspected.find(button: SpotiglassL10n.string("menu.playback.shuffle")).isDisabled()
            )
        }
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    private func pinnedStore() -> PinnedItemsStore {
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "detail-surface-tests")
        return store
    }

    private func browserViewModel() -> PlaylistBrowserViewModel {
        PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
    }

    private func playlistView(detail: PlaylistDetailViewModel) -> PlaylistDetailContent {
        PlaylistDetailContent(
            detail: detail,
            pendingScrollRestoreTrackID: .constant(nil),
            onTrackEnteredViewportApproximation: { _ in },
            playURI: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            browserViewModel: browserViewModel()
        )
    }

    private func artistView(detail: ArtistDetailViewModel) -> ArtistDetailContent {
        ArtistDetailContent(
            detail: detail,
            browserViewModel: browserViewModel(),
            playTrack: { _ in },
            openAlbum: { _ in },
            playAlbumContext: { _ in },
            currentPlaybackURI: nil,
            isPlaying: false,
            togglePlayPause: {},
            hasPlaybackDevice: false,
            addToQueue: { _ in },
            openArtist: { _ in },
            loadMoreAlbums: {}
        )
    }
}
