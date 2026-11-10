import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// Home's tiles and Recently played covers had no menu, and the artist names under a cover
/// were plain text (#478). These replay that: a Home tile and a cover offer the same entries
/// the sidebar row and the artist page's album cards do, reachable without a mouse, and the
/// names under a cover open their artists.
@MainActor
final class CollectionContextMenuTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private let pinTitle = SpotiglassL10n.string("browser.pin")
    private let unpinTitle = SpotiglassL10n.string("browser.unpin")
    private let editTitle = SpotiglassL10n.string("browser.editPlaylistName")
    private let deleteTitle = SpotiglassL10n.string("browser.deletePlaylist")

    private let ownPlaylist = MusicPlaylistSummary(
        id: "mine",
        name: "Road Trip",
        ownerID: "me",
        ownerName: "Me",
        imageURL: nil,
        trackCount: 12,
        snapshotID: "s1"
    )

    private func makeBrowserViewModel(api: MusicBrowsingProvider? = nil) -> PlaylistBrowserViewModel {
        let api = api ?? MockBrowsingAPI(playlistResults: [.success([ownPlaylist])], trackResults: [:])
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        viewModel.currentUserSpotifyID = "me"
        viewModel.playlistsByID = [ownPlaylist.id: ownPlaylist]
        viewModel.playlistState = .loaded([PlaylistRowViewModel(ownPlaylist)])
        return viewModel
    }

    /// "Oh yeah?" by Steve Lacy, as Spotify's recently played returns it.
    private func recentlyPlayedTrack(
        artists: [MusicArtistRef] = [MusicArtistRef(id: "steve", name: "Steve Lacy")],
        names: [String]? = nil,
        uri: String = "spotify:track:t1"
    ) -> MusicTrack {
        MusicTrack(
            id: "t1",
            name: "Oh yeah?",
            artists: names ?? artists.map(\.name),
            artistRefs: artists,
            albumArtworkURL: nil,
            albumName: "Oh yeah?",
            albumID: "album-oh-yeah",
            durationMilliseconds: 180_000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: uri
        )
    }

    private func buttonTitles(in menu: some View) throws -> [String] {
        try menu.inspect().findAll(ViewType.Button.self).map { try $0.labelView().text().string() }
    }

    // MARK: - Menu entries

    func testHomePlaylistTileOffersTheSidebarRowsEntriesInItsOrder() throws {
        let viewModel = makeBrowserViewModel()
        let card = try XCTUnwrap(viewModel.homeQuickAccessCards.first { $0.id == ownPlaylist.id })
        let target = try XCTUnwrap(card.menuTarget)

        let homeMenu = CollectionMenu.menu(
            for: target,
            isPinned: false,
            canRename: viewModel.canRenamePlaylist(ownPlaylist),
            canDelete: viewModel.canDeletePlaylist(ownPlaylist)
        )
        // The sidebar row's menu before #478, written out: Edit playlist name, a divider,
        // Pin to Sidebar (Spotify can't delete playlists).
        XCTAssertEqual(homeMenu.sections, [[.editPlaylistName], [.pin]])

        let items = CollectionMenuItems(menu: homeMenu, placement: .content) { _ in }
        XCTAssertEqual(try buttonTitles(in: items), [editTitle, pinTitle])
    }

    func testDeleteFollowsRenameWhenTheServiceCanDeletePlaylists() throws {
        let menu = CollectionMenu.menu(for: .playlist(ownPlaylist), isPinned: true, canRename: true, canDelete: true)
        XCTAssertEqual(menu.sections, [[.editPlaylistName, .deletePlaylist], [.unpin]])
        let items = CollectionMenuItems(menu: menu, placement: .content) { _ in }
        XCTAssertEqual(try buttonTitles(in: items), [editTitle, deleteTitle, unpinTitle])

        let sidebar = CollectionMenuItems(menu: menu, placement: .sidebar) { _ in }
        XCTAssertEqual(try buttonTitles(in: sidebar).last, SpotiglassL10n.string("browser.unpin.short"))
    }

    func testSomeoneElsesPlaylistOnlyPins() {
        let theirs = PlaylistBrowsingTestFixtures.playlist(id: "theirs", name: "Theirs")
        let viewModel = makeBrowserViewModel()
        XCTAssertFalse(viewModel.canRenamePlaylist(theirs))
        XCTAssertEqual(
            CollectionMenu.menu(for: .playlist(theirs), isPinned: false, canRename: false, canDelete: true).entries,
            [.pin]
        )
    }

    /// A playlist made in another app shows up in Search before the library has loaded it, and
    /// renaming goes through the library's copy: Edit playlist name did nothing there.
    func testOwnPlaylistTheLibraryHasntLoadedOffersNoRename() {
        let viewModel = makeBrowserViewModel()
        let madeElsewhere = MusicPlaylistSummary(
            id: "new", name: "Made in Music", ownerID: "me", ownerName: "Me",
            imageURL: nil, trackCount: 0, snapshotID: "s"
        )
        XCTAssertFalse(viewModel.canRenamePlaylist(madeElsewhere))
        XCTAssertTrue(viewModel.canRenamePlaylist(ownPlaylist))
    }

    func testLikedSongsTileHasNoMenuLikeItsSidebarRow() {
        let viewModel = makeBrowserViewModel()
        let liked = viewModel.homeQuickAccessCards.first
        XCTAssertEqual(liked?.destination, .likedSongs)
        XCTAssertNil(liked?.menuTarget)
    }

    func testRecentlyPlayedCoverPinsTheSameAlbumTheAlbumPageDoes() throws {
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: recentlyPlayedTrack()))
        let pinned = try XCTUnwrap(card.menuTarget).pinnedItem
        XCTAssertEqual(pinned.id, PinnedItem.id(forKind: .album, spotifyID: "album-oh-yeah"))
        XCTAssertEqual(pinned.kind, .album)
        XCTAssertEqual(pinned.spotifyURI, "spotify:album:album-oh-yeah")
        XCTAssertEqual(
            CollectionMenu.menu(for: .pinnable(pinned), isPinned: false, canRename: true, canDelete: true).entries,
            [.pin],
            "an album's menu is the artist page's album menu: Pin only"
        )
    }

    func testAppleMusicCoverPinsAnAppleMusicAlbum() throws {
        let track = recentlyPlayedTrack(uri: "applemusic:song:1")
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: track))
        XCTAssertEqual(card.menuTarget?.pinnedItem.spotifyURI, "applemusic:album:album-oh-yeah")
    }

    // MARK: - Hosted views (keyboard and VoiceOver reach the same entries)

    func testHomeTilePinsItsPlaylistFromItsActions() throws {
        let viewModel = makeBrowserViewModel()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        let card = try XCTUnwrap(viewModel.homeQuickAccessCards.first { $0.id == ownPlaylist.id })
        let tile = HomeQuickAccessTile(card: card, browserViewModel: viewModel) {}
            .environmentObject(store)
        ViewTestHost.host(tile)

        try tile.inspect().find(button: pinTitle).tap()

        XCTAssertTrue(store.isPinned(spotifyID: ownPlaylist.id, kind: .playlist))
    }

    func testAppleMusicHomeTileDeletesAndRenamesLikeTheSidebar() async throws {
        let viewModel = makeBrowserViewModel(api: LibraryEditsMockAPI(edits: .all))
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        let card = try XCTUnwrap(viewModel.homeQuickAccessCards.first { $0.id == ownPlaylist.id })
        let tile = HomeQuickAccessTile(card: card, browserViewModel: viewModel) {}
            .environmentObject(store)
        ViewTestHost.host(tile)

        try tile.inspect().find(button: deleteTitle).tap()
        XCTAssertEqual(viewModel.playlistPendingDeletion, ownPlaylist, "asks first, like the sidebar")

        try tile.inspect().find(button: editTitle).tap()
        for _ in 0..<50 where viewModel.playlistNameEditRequestID == nil {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.playlistNameEditRequestID, ownPlaylist.id)
    }

    func testRecentlyPlayedCoverPinsAndUnpinsItsAlbum() throws {
        let viewModel = makeBrowserViewModel()
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: recentlyPlayedTrack()))
        let view = HomeMediaCardView(card: card, browserViewModel: viewModel, openArtist: { _ in }) {}
            .environmentObject(store)
        ViewTestHost.host(view)

        try view.inspect().find(button: pinTitle).tap()
        XCTAssertTrue(store.isPinned(spotifyID: "album-oh-yeah", kind: .album))

        try view.inspect().find(button: unpinTitle).tap()
        XCTAssertFalse(store.isPinned(spotifyID: "album-oh-yeah", kind: .album))
    }

    func testEachArtistUnderACoverOpensThatArtist() throws {
        let artists = [MusicArtistRef(id: "steve", name: "Steve Lacy"), MusicArtistRef(id: "fousheé", name: "Fousheé")]
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: recentlyPlayedTrack(artists: artists)))
        var opened: [MusicArtistRef] = []
        let view = HomeMediaCardView(
            card: card,
            browserViewModel: makeBrowserViewModel(),
            openArtist: { opened.append($0) }
        ) {}
            .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(view)

        try view.inspect().find(button: "Steve Lacy").tap()
        try view.inspect().find(button: "Fousheé").tap()

        XCTAssertEqual(opened, artists)
    }

    func testCoverTitleOpensTheAlbum() throws {
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: recentlyPlayedTrack()))
        var openedAlbum = false
        let view = HomeMediaCardView(card: card, browserViewModel: makeBrowserViewModel(), openArtist: { _ in }) {
            openedAlbum = true
        }
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(view)

        try view.inspect().find(text: "Oh yeah?").find(ViewType.Button.self, relation: .parent).tap()

        XCTAssertTrue(openedAlbum)
    }

    /// A line without links (a search playlist's owner) used to be part of the card's button.
    /// Moving the artist links out of it left that line dead; it opens the item again.
    func testALineWithoutLinksStillOpensTheCard() throws {
        let theirs = MusicPlaylistSummary(
            id: "theirs", name: "Today's Top Hits", ownerID: "spotify", ownerName: "Spotify",
            imageURL: nil, trackCount: 50, snapshotID: "s"
        )
        var opened = false
        let view = HomeMediaCardView(
            card: HomeMediaCard(playlist: theirs, subtitle: theirs.ownerName),
            browserViewModel: makeBrowserViewModel(),
            openArtist: { _ in XCTFail("an owner is not an artist") }
        ) {
            opened = true
        }
        .environmentObject(PinnedItemsStore(cache: InMemoryPinnedItemsCache()))
        ViewTestHost.host(view)

        try view.inspect().find(text: "Spotify").find(ViewType.Button.self, relation: .parent).tap()

        XCTAssertTrue(opened)
    }

    func testNamesWithoutIDsStayPlainText() throws {
        let card = HomeMediaCard(album: MusicAlbum(
            id: "a",
            name: "Album",
            artists: ["Unknown Artist"],
            imageURL: nil,
            uri: "spotify:album:a"
        ))
        let view = HomeCardArtistCredits(subtitle: card.subtitle, credits: card.artistCredits, openArtist: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "Unknown Artist"))
        XCTAssertThrowsError(try view.inspect().find(button: "Unknown Artist"))
    }

    /// Spotify names every artist and gives IDs only for some (a local file's has none). The
    /// one without an ID used to drop out of the line under the cover.
    func testAnArtistWithoutAnIDStaysInTheLineAsPlainText() throws {
        var opened: [MusicArtistRef] = []
        let card = HomeMediaCard(recentlyPlayed: recentlyPlayedTrack(
            artists: [MusicArtistRef(id: "steve", name: "Steve Lacy")],
            names: ["Steve Lacy", "Local Friend"]
        ))
        let line = try XCTUnwrap(card).artistCredits
        XCTAssertEqual(line, [.link(MusicArtistRef(id: "steve", name: "Steve Lacy")), .name("Local Friend")])

        var openedCard = false
        let view = HomeCardArtistCredits(
            subtitle: try XCTUnwrap(card).subtitle,
            credits: line,
            openArtist: { opened.append($0) },
            openCard: { openedCard = true }
        )
        try view.inspect().find(button: "Steve Lacy").tap()
        XCTAssertEqual(opened.map(\.id), ["steve"])
        XCTAssertFalse(openedCard)
        // The name without an ID opens the card, like a line without any links does.
        try view.inspect().find(text: "Local Friend").find(ViewType.Button.self, relation: .parent).tap()
        XCTAssertTrue(openedCard)
        XCTAssertEqual(opened.map(\.id), ["steve"], "it opens no artist")
    }

    /// Apple Music names all of a song's artists in one string and lists them apart by ID.
    func testAppleMusicsJoinedArtistNameLinksEachArtist() {
        let line = HomeArtistCredit.credits(
            names: ["Steve Lacy & Faye Webster"],
            refs: [MusicArtistRef(id: "1", name: "Steve Lacy"), MusicArtistRef(id: "2", name: "Faye Webster")]
        )
        XCTAssertEqual(line, [
            .link(MusicArtistRef(id: "1", name: "Steve Lacy")),
            .link(MusicArtistRef(id: "2", name: "Faye Webster")),
        ])
    }

    // MARK: - Edit playlist name from Home

    func testEditPlaylistNameOpensThePlaylistAndAsksItsHeaderToEdit() async throws {
        let viewModel = makeBrowserViewModel(api: MockBrowsingAPI(
            playlistResults: [.success([ownPlaylist])],
            trackResults: [ownPlaylist.id: [.success([PlaylistBrowsingTestFixtures.track(id: "t1")])]]
        ))

        await viewModel.openPlaylistForNameEditing(ownPlaylist)

        XCTAssertEqual(viewModel.sidebarSelection, .playlist(ownPlaylist.id))
        guard case let .playlist(detail)? = viewModel.detailState.currentValue else {
            return XCTFail("The playlist's page should show, with the header that edits its name")
        }
        XCTAssertEqual(detail.playlist.id, ownPlaylist.id)
        XCTAssertEqual(viewModel.playlistNameEditRequestID, ownPlaylist.id)
        XCTAssertNil(viewModel.sidebarPlaylistNameEditRequestID, "The header edits, not the sidebar")
    }

    /// A new playlist is empty, and an empty playlist's page shows a message, not the header.
    /// Edit playlist name on its tile then did nothing; its sidebar row edits instead.
    func testEditPlaylistNameOnAnEmptyPlaylistEditsItsSidebarRow() async throws {
        let viewModel = makeBrowserViewModel(api: MockBrowsingAPI(
            playlistResults: [.success([ownPlaylist])],
            trackResults: [ownPlaylist.id: [.success([])]]
        ))

        await viewModel.openPlaylistForNameEditing(ownPlaylist)

        guard case .empty = viewModel.detailState else {
            return XCTFail("Expected the empty playlist's message, got \(viewModel.detailState)")
        }
        XCTAssertEqual(viewModel.sidebarPlaylistNameEditRequestID, ownPlaylist.id)

        let playbackViewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        let store = PinnedItemsStore(cache: InMemoryPinnedItemsCache())
        store.bind(userID: "me")
        let sidebar = PlaylistsSidebarSectionContent(
            playlistState: viewModel.playlistState,
            likedSongsStubRow: PlaylistRowViewModel(likedSongsOwnerDisplay: "You", totalTrackCount: nil, artworkURL: nil),
            viewModel: viewModel,
            playbackViewModel: playbackViewModel,
            playlistSummaryFromRow: { _ in self.ownPlaylist }
        )
        .environmentObject(store)
        let host = ViewTestHost.host(sidebar, size: CGSize(width: 320, height: 400))

        // The row's name turns into the rename field, filled with the current name.
        var field: NSTextField?
        for _ in 0..<25 where field == nil {
            AppKitTestSupport.pumpRunLoop(for: 0.04)
            field = textFields(in: host.view).first { $0.isEditable }
        }
        XCTAssertEqual(field?.stringValue, ownPlaylist.name)
        XCTAssertNil(viewModel.playlistNameEditRequestID, "The row took the request")
    }

    /// With the sidebar hidden, the row used to take the rename inside the hidden column and lose
    /// its field as the sidebar came back: nothing was editable. The row now waits for it to show.
    func testEmptyPlaylistsRenameWaitsForAHiddenSidebarToShow() async {
        let viewModel = makeBrowserViewModel(api: MockBrowsingAPI(
            playlistResults: [.success([ownPlaylist])],
            trackResults: [ownPlaylist.id: [.success([])]]
        ))
        viewModel.isSidebarShown = false

        await viewModel.openPlaylistForNameEditing(ownPlaylist)

        XCTAssertEqual(viewModel.pendingSidebarPlaylistNameEditID, ownPlaylist.id, "the window shows the sidebar for it")
        XCTAssertNil(viewModel.sidebarPlaylistNameEditRequestID, "the hidden row doesn't take it")
        viewModel.isSidebarShown = true
        XCTAssertEqual(viewModel.sidebarPlaylistNameEditRequestID, ownPlaylist.id)
    }

    func testEditPlaylistNameIsDroppedWhenThePlaylistDoesntOpen() async {
        let viewModel = makeBrowserViewModel(api: MockBrowsingAPI(
            playlistResults: [.success([ownPlaylist])],
            trackResults: [ownPlaylist.id: [.failure(URLError(.notConnectedToInternet))]]
        ))

        await viewModel.openPlaylistForNameEditing(ownPlaylist)

        // Otherwise opening the playlist later, once it loads, would start editing its name.
        XCTAssertNil(viewModel.playlistNameEditRequestID)
        XCTAssertNil(viewModel.sidebarPlaylistNameEditRequestID)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    func testEditPlaylistNameIgnoresPlaylistsTheUserCantRename() async {
        let viewModel = makeBrowserViewModel()
        let theirs = PlaylistBrowsingTestFixtures.playlist(id: "theirs", name: "Theirs")

        await viewModel.openPlaylistForNameEditing(theirs)

        XCTAssertNil(viewModel.playlistNameEditRequestID)
        XCTAssertNotEqual(viewModel.sidebarSelection, .playlist(theirs.id))
    }

    // MARK: - Search results carry the artist IDs

    func testSpotifySearchAlbumKeepsItsArtistIDs() throws {
        let json = Data("""
        {"id": "al1", "name": "Gemini Rights", "uri": "spotify:album:al1", "images": [],
         "artists": [{"id": "steve", "name": "Steve Lacy"}, {"name": "No ID"}]}
        """.utf8)
        let album = try JSONDecoder().decode(SpotifySearchAlbumDTO.self, from: json).domainModel()
        XCTAssertEqual(album.artists, ["Steve Lacy", "No ID"])
        XCTAssertEqual(album.artistRefs, [MusicArtistRef(id: "steve", name: "Steve Lacy")])
        XCTAssertEqual(HomeMediaCard(album: album).artistRefs, album.artistRefs)
    }

    func testAlbumsCachedBeforeArtistIDsStillDecode() throws {
        let json = Data("""
        {"id": "al1", "name": "Old", "artists": ["Someone"], "uri": "spotify:album:al1"}
        """.utf8)
        let album = try JSONDecoder().decode(MusicAlbum.self, from: json)
        XCTAssertEqual(album.artistRefs, [])
        let roundTrip = try JSONDecoder().decode(MusicAlbum.self, from: JSONEncoder().encode(
            MusicAlbum(id: "x", name: "X", artists: ["A"], artistRefs: [MusicArtistRef(id: "a", name: "A")], imageURL: nil, uri: "u")
        ))
        XCTAssertEqual(roundTrip.artistRefs, [MusicArtistRef(id: "a", name: "A")])
    }
}
