import XCTest
@testable import Spotiglass

/// The browser's library edits that only some providers offer (remove from playlist, delete
/// playlist, save album), and the URI rules that let Apple Music songs into the shared edits.
@MainActor
final class PlaylistBrowserLibraryEditsTests: XCTestCase {
    private let me = "apple-music-library"

    private func playlist(_ id: String, _ name: String, owner: String? = nil) -> MusicPlaylistSummary {
        MusicPlaylistSummary(id: id, name: name, ownerID: owner ?? me, ownerName: "You", imageURL: nil, trackCount: 2, snapshotID: "applemusic")
    }

    private func row(_ id: String, position: Int) -> TrackRowViewModel {
        TrackRowViewModel(
            MusicPlaylistTrackItem(id: "\(position)-\(id)", content: .track(AppleMusicLibraryEditorTests.track(id: id, name: "Song \(id)"))),
            listPosition: position
        )
    }

    private func makeViewModel(_ api: LibraryEditsMockAPI) async -> PlaylistBrowserViewModel {
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledBrowsingCache())
        await viewModel.load()
        return viewModel
    }

    // MARK: - Spotify stays as it was

    func testProvidersWithoutTheEditsOfferNoNewMenuItems() async {
        let api = LibraryEditsMockAPI(edits: [])
        api.playlists = [playlist("pl1", "Mine")]
        let viewModel = await makeViewModel(api)

        XCTAssertFalse(viewModel.canRemoveRows(fromPlaylist: "pl1"))
        XCTAssertFalse(viewModel.canDeletePlaylist(playlist("pl1", "Mine")))
        viewModel.requestPlaylistDeletion(playlist("pl1", "Mine"))
        XCTAssertNil(viewModel.playlistPendingDeletion)
        await viewModel.loadSavedAlbumState(for: "album")
        XCTAssertNil(viewModel.savedAlbumState(for: "album"))
        XCTAssertEqual(api.calls, [])
    }

    func testSpotifyURIRulesAreUnchangedAndAppleMusicSongsJoinThem() {
        XCTAssertEqual(LibraryEditableTrackURI.trackID("spotify:track:abc"), "abc")
        XCTAssertEqual(LibraryEditableTrackURI.trackID("applemusic:song:i.9"), "i.9")
        XCTAssertNil(LibraryEditableTrackURI.trackID("spotify:episode:abc"))
        XCTAssertNil(LibraryEditableTrackURI.trackID("spotify:local:a:b:c:1"))
        XCTAssertNil(LibraryEditableTrackURI.trackID("applemusic:music-video:1"))
        XCTAssertNil(LibraryEditableTrackURI.trackID("spotify:track:"))
        XCTAssertNil(LibraryEditableTrackURI.trackID(nil))
    }

    // MARK: - Remove from playlist

    func testRemoveFromPlaylistSendsPositionsAndReloadsTheList() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        let viewModel = await makeViewModel(api)
        XCTAssertTrue(viewModel.canRemoveRows(fromPlaylist: "-1"))
        XCTAssertFalse(viewModel.canRemoveRows(fromPlaylist: SpotiglassSidebarLibrary.likedSongsVirtualPlaylistID))

        await viewModel.removeRowsFromPlaylist([row("-30", position: 2)], playlistID: "-1", playlistName: "Spotiglass test")

        XCTAssertEqual(api.removals.map(\.uri), ["applemusic:song:-30"])
        XCTAssertEqual(api.removals.map(\.positions), [[1]])
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.format("playlist.mutation.removedFromPlaylist", Int64(1), "Spotiglass test"))
    }

    func testRemoveFromSomeoneElsesPlaylistIsNotOffered() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("pl.apple", "Today's Hits", owner: "Apple Music")]
        let viewModel = await makeViewModel(api)
        XCTAssertFalse(viewModel.canRemoveRows(fromPlaylist: "pl.apple"))
        XCTAssertFalse(viewModel.canDeletePlaylist(playlist("pl.apple", "Today's Hits", owner: "Apple Music")))
    }

    func testAFailedRemovalShowsTheProvidersOneLineHint() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        api.error = AppleMusicLibraryEditError.musicControlDenied
        let viewModel = await makeViewModel(api)

        await viewModel.removeRowsFromPlaylist([row("-30", position: 1)], playlistID: "-1", playlistName: "Spotiglass test")

        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("appleMusic.edit.error.musicControlDenied"))
    }

    // MARK: - Delete playlist

    func testDeletingAPlaylistRemovesItFromTheSidebarAndLeavesItsPage() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let doomed = playlist("-1", "Spotiglass test")
        api.playlists = [doomed, playlist("-2", "Italian")]
        let viewModel = await makeViewModel(api)
        await viewModel.selectSidebar(.playlist("-1"))

        viewModel.requestPlaylistDeletion(doomed)
        XCTAssertEqual(viewModel.playlistPendingDeletion, doomed)
        await viewModel.deletePlaylist(doomed)

        XCTAssertEqual(api.calls, ["deletePlaylist(-1)"])
        XCTAssertNil(viewModel.playlistPendingDeletion)
        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.id), ["-2"])
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.format("playlist.mutation.deletedPlaylist", "Spotiglass test"))
    }

    /// A deleted playlist leaves the back history: back names the place
    /// before it and opens that, not "Playlist" and an unavailable page.
    func testBackSkipsADeletedPlaylist() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let doomed = playlist("-1", "Spotiglass test")
        api.playlists = [doomed, playlist("-2", "Italian")]
        let viewModel = await makeViewModel(api)
        await viewModel.selectSidebar(.playlist("-2"))
        await viewModel.selectSidebar(.playlist("-1"))

        await viewModel.deletePlaylist(doomed)

        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertFalse(viewModel.backNavigationStack.contains(.sidebar(.playlist("-1"))))
        XCTAssertEqual(viewModel.backDestination, .sidebar(.playlist("-2")))
        XCTAssertEqual(viewModel.backDestination.map { viewModel.displayName(for: $0) }, "Italian")

        await viewModel.navigateBack()
        XCTAssertEqual(viewModel.sidebarSelection, .playlist("-2"))
    }

    /// Deleting a playlist while an artist opened from it is showing: back goes
    /// to the place before the playlist, and the title follows instead of
    /// keeping the deleted playlist's name.
    func testDeletingThePlaylistBehindTheCurrentPageLeavesTheTitleToo() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let doomed = playlist("-1", "Spotiglass test")
        api.playlists = [doomed, playlist("-2", "Italian")]
        let viewModel = await makeViewModel(api)
        await viewModel.selectSidebar(.home)
        await viewModel.selectSidebar(.playlist("-1"))
        await viewModel.selectArtist(id: "artist-bonobo", origin: .extend, displayName: "Bonobo")

        await viewModel.deletePlaylist(doomed)

        XCTAssertEqual(viewModel.backDestination, .sidebar(.home))
        XCTAssertFalse(viewModel.breadcrumbPath.contains { $0.kind == .playlist(id: "-1") })
        await viewModel.navigateBack()
        XCTAssertEqual(viewModel.sidebarSelection, .home)
        XCTAssertNotEqual(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath), "Spotiglass test")
        XCTAssertEqual(BrowserToolbarPresentation.windowTitle(for: viewModel.breadcrumbPath), AppMetadata.displayName)
    }

    func testAFailedDeletionKeepsThePlaylist() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let doomed = playlist("-1", "Spotiglass test")
        api.playlists = [doomed]
        api.error = AppleMusicLibraryEditError.notInMusicYet
        let viewModel = await makeViewModel(api)

        await viewModel.deletePlaylist(doomed)

        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.id), ["-1"])
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("appleMusic.edit.error.notInMusicYet"))
    }

    // MARK: - Albums

    func testAlbumToggleShowsTheNewStateAtOnceAndGoesBackOnFailure() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.albumSaved = false
        let viewModel = await makeViewModel(api)
        await viewModel.loadSavedAlbumState(for: "1440")
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), false)

        await viewModel.toggleAlbumInLibrary(albumID: "1440", albumName: "Computer World")
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), true)
        XCTAssertEqual(api.calls.last, "saveAlbums(1440)")

        api.error = AppleMusicLibraryEditError.requestFailed
        await viewModel.toggleAlbumInLibrary(albumID: "1440", albumName: "Computer World", confirmed: true)
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), true, "the failed removal goes back")
        XCTAssertEqual(viewModel.trackMutationToast, SpotiglassL10n.string("appleMusic.edit.error.requestFailed"))
    }

    // MARK: - Removing from the library asks first

    /// In Apple Music, Liked Songs are the library, and a song deleted from the library leaves
    /// every playlist on every device. The unlike must not run before the user confirms.
    func testUnlikeAsksFirstWhenRemovingEmptiesPlaylists() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        let viewModel = await makeViewModel(api)
        let song = row("699902614", position: 1)

        await viewModel.unfavoriteRows([song])
        XCTAssertEqual(api.calls, [], "nothing is removed before the confirmation")
        guard case let .songs(rows) = try XCTUnwrap(viewModel.pendingLibraryRemoval) else {
            return XCTFail("expected the songs confirmation")
        }
        XCTAssertEqual(rows.map(\.id), [song.id])

        // As in the app: the alert's dismissal clears the pending removal before the button's task runs.
        let removal = try XCTUnwrap(viewModel.pendingLibraryRemoval)
        viewModel.pendingLibraryRemoval = nil
        await viewModel.confirmLibraryRemoval(removal)
        XCTAssertNil(viewModel.pendingLibraryRemoval)
        XCTAssertEqual(api.calls, ["removeSavedTracks(699902614)"])
        XCTAssertEqual(viewModel.savedTrackState(for: "699902614"), false)
    }

    /// A song removed from the library leaves every playlist it was in. A playlist's kept track
    /// list must go too, or reopening it shows the removed song (#442).
    func testRemovingASongFromTheLibraryDropsKeptPlaylistTracks() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("pl1", "Mine")]
        let cache = MemoryBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)
        await viewModel.load()
        let kept = [MusicPlaylistTrackItem(id: "1-699902614", content: .track(AppleMusicLibraryEditorTests.track(id: "699902614", name: "Computer Love")))]
        try cache.saveTracks(kept, playlistID: "pl1", snapshotID: "applemusic", cachedAt: Date())

        await viewModel.unfavoriteRows([row("699902614", position: 1)], confirmed: true)

        XCTAssertEqual(api.calls, ["removeSavedTracks(699902614)"])
        XCTAssertNil(try cache.loadTracksIgnoringAge(playlistID: "pl1", snapshotID: "applemusic"))
    }

    func testCancelledUnlikeRemovesNothing() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let viewModel = await makeViewModel(api)

        await viewModel.unfavoriteRows([row("699902614", position: 1)])
        viewModel.pendingLibraryRemoval = nil

        XCTAssertEqual(api.calls, [])
    }

    func testAlbumRemovalAsksFirstAndSavingDoesNot() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.albumSaved = true
        let viewModel = await makeViewModel(api)
        await viewModel.loadSavedAlbumState(for: "1440")

        await viewModel.toggleAlbumInLibrary(albumID: "1440", albumName: "Computer World")
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), true, "the menu keeps the state until confirmed")
        guard case let .album(id, name) = try XCTUnwrap(viewModel.pendingLibraryRemoval) else {
            return XCTFail("expected the album confirmation")
        }
        XCTAssertEqual(id, "1440")
        XCTAssertEqual(name, "Computer World")

        let albumRemoval = try XCTUnwrap(viewModel.pendingLibraryRemoval)
        viewModel.pendingLibraryRemoval = nil
        await viewModel.confirmLibraryRemoval(albumRemoval)
        XCTAssertEqual(api.calls, ["removeSavedAlbums(1440)"])
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), false)

        await viewModel.toggleAlbumInLibrary(albumID: "1440", albumName: "Computer World")
        XCTAssertNil(viewModel.pendingLibraryRemoval, "saving needs no confirmation")
        XCTAssertEqual(api.calls.last, "saveAlbums(1440)")
    }

    /// An album edit changes its songs' liked state; a song menu opened before must not keep
    /// offering the opposite action.
    func testAnAlbumEditForgetsTheCachedLikedStates() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.albumSaved = false
        let viewModel = await makeViewModel(api)
        await viewModel.favoriteRows([row("11", position: 1)])
        XCTAssertEqual(viewModel.savedTrackState(for: "11"), true)
        await viewModel.loadSavedAlbumState(for: "1440")

        await viewModel.toggleAlbumInLibrary(albumID: "1440", albumName: "Computer World")

        XCTAssertNil(viewModel.savedTrackState(for: "11"), "loads again from the library")
    }

    /// The reverse: removing an album's songs from Liked Songs changes the album's state, so the
    /// album menu loads it again instead of offering a removal that can't work.
    func testASongEditForgetsTheCachedAlbumStates() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.albumSaved = true
        let viewModel = await makeViewModel(api)
        await viewModel.loadSavedAlbumState(for: "1440")
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), true)

        await viewModel.unfavoriteRows([row("11", position: 1)])
        let removal = try XCTUnwrap(viewModel.pendingLibraryRemoval)
        viewModel.pendingLibraryRemoval = nil
        await viewModel.confirmLibraryRemoval(removal)

        XCTAssertNil(viewModel.savedAlbumState(for: "1440"))
        api.albumSaved = false
        await viewModel.loadSavedAlbumState(for: "1440")
        XCTAssertEqual(viewModel.savedAlbumState(for: "1440"), false, "the album menu now offers Add")
    }

    // MARK: - Track counts (#407)

    private func uncounted(_ id: String, _ name: String) -> MusicPlaylistSummary {
        MusicPlaylistSummary(id: id, name: name, ownerID: me, ownerName: "You", imageURL: nil, trackCount: nil, snapshotID: "applemusic")
    }

    /// Music takes a song removed from the library out of every playlist, so the sidebar counts
    /// again instead of keeping the old numbers until the next refresh.
    func testAnUnlikeRecountsTheSidebar() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        api.trackCounts = ["-1": 10]
        let viewModel = await makeViewModel(api)
        await viewModel.playlistTrackCountTask?.value
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 10)

        api.trackCounts = ["-1": 9]
        await viewModel.unfavoriteRows([row("699902614", position: 1)], confirmed: true)
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 10, "the row keeps its count while it is counted")
        await viewModel.playlistTrackCountTask?.value

        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 9)
    }

    /// A rename that fails puts the old name back, not the count from before the request.
    func testAFailedRenameKeepsACountThatArrivedMeanwhile() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        api.trackCounts = ["-1": 8]
        let counts = LibraryEditsGate()
        let update = LibraryEditsGate()
        api.trackCountsGate = counts
        api.updateGate = update
        api.error = AppleMusicLibraryEditError.musicUnavailable
        let viewModel = await makeViewModel(api)

        let renaming = Task { await viewModel.renamePlaylist(id: "-1", name: "Road trip") }
        while viewModel.playlistState.currentValue?.last?.title != "Road trip" {
            await Task.yield()
        }
        counts.open()
        await viewModel.playlistTrackCountTask?.value
        update.open()
        await renaming.value

        let row = try XCTUnwrap(viewModel.playlistState.currentValue?.last)
        XCTAssertEqual(row.title, "Road")
        XCTAssertEqual(row.trackCount, 8)
    }

    /// An edit while the row still shows its count from before the refresh: the count read
    /// before the edit is dropped and asked for again, so the row ends with the real number,
    /// not the old one plus the edit.
    func testAnEditOnAStandInCountEndsWithTheFreshCount() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        api.trackCounts = ["-1": 10]
        let viewModel = await makeViewModel(api)
        await viewModel.playlistTrackCountTask?.value

        // Changed on another device meanwhile: the library has 11.
        api.trackCounts = ["-1": 11]
        let gate = LibraryEditsGate()
        api.trackCountsGate = gate
        await viewModel.refreshPlaylists()
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 10, "the stand-in")
        await viewModel.addRowsToPlaylist([row("699902614", position: 1), row("1", position: 2)], playlistID: "-1", playlistName: "Road")
        api.trackCounts = ["-1": 13]
        gate.open()
        await viewModel.playlistTrackCountTask?.value
        while viewModel.playlistState.currentValue?.last?.trackCount != 13 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 13)
    }

    /// A count that already has an add (the pending edit is recorded before the add returns)
    /// must not get the add again on top: the edit counts the playlist afterwards.
    func testACountThatAlreadyHasTheEditDoesNotGetItTwice() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        // The library read already sees the song being added.
        api.trackCounts = ["-1": 11]
        let viewModel = await makeViewModel(api)
        await viewModel.playlistTrackCountTask?.value
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 11)

        await viewModel.addRowsToPlaylist([row("699902614", position: 1)], playlistID: "-1", playlistName: "Road")
        while viewModel.playlistState.currentValue?.last?.trackCount != 11 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 11)
    }

    /// An empty playlist has no count; adding songs to it counts it.
    func testAddingToAPlaylistWithoutACountCountsIt() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        let viewModel = await makeViewModel(api)
        await viewModel.playlistTrackCountTask?.value
        XCTAssertNil(viewModel.playlistState.currentValue?.last?.trackCount)

        api.trackCounts = ["-1": 3]
        await viewModel.addRowsToPlaylist([row("699902614", position: 1)], playlistID: "-1", playlistName: "Road")
        while viewModel.playlistState.currentValue?.last?.trackCount == nil {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 3)
    }

    /// Counts saved with the playlist list are shown at launch but counted again, so a count
    /// changed meanwhile doesn't wait for the next refresh.
    func testCountsSavedWithTheListAreCountedAgain() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [uncounted("-1", "Road")]
        api.trackCounts = ["-1": 6]
        let gate = LibraryEditsGate()
        api.trackCountsGate = gate
        let saved = MusicPlaylistSummary(id: "-1", name: "Road", ownerID: me, ownerName: "You", imageURL: nil, trackCount: 5, snapshotID: "applemusic")
        let viewModel = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache(cachedPlaylists: [saved], playlistListCacheAge: 1))
        await viewModel.load()
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 5, "shown while it is counted")

        gate.open()
        await viewModel.playlistTrackCountTask?.value
        XCTAssertEqual(viewModel.playlistState.currentValue?.last?.trackCount, 6)
    }

    /// Spotify lists its counts: nothing is asked for, and a playlist without a total says so
    /// at once, as before.
    func testSpotifyNeverAsksForCounts() async throws {
        let api = LibraryEditsMockAPI(edits: [])
        api.playlists = [playlist("pl1", "Mine")]
        let viewModel = await makeViewModel(api)
        api.playlists = [uncounted("pl1", "Mine")]
        await viewModel.refreshPlaylists()

        XCTAssertNil(viewModel.playlistTrackCountTask)
        XCTAssertNil(viewModel.playlistState.currentValue?.last?.trackCount)
        XCTAssertEqual(api.trackCountLookups, 0)
    }

    /// An edit saves the playlist list, and the next launch shows it as saved: in the
    /// sidebar's order, not a dictionary's.
    func testAnEditSavesThePlaylistsInSidebarOrder() async throws {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = (1...12).map { playlist("-\($0)", "Playlist \($0)") }
        let cache = MockBrowsingCache()
        let viewModel = PlaylistBrowserViewModel(api: api, cache: cache)
        await viewModel.load()

        await viewModel.addRowsToPlaylist([row("699902614", position: 1)], playlistID: "-3", playlistName: "Playlist 3")

        XCTAssertEqual(cache.savedPlaylists?.map(\.id), api.playlists.map(\.id))
    }

    /// Spotify's unlike only leaves Liked Songs, so it keeps going through at once.
    func testProvidersWithoutTheConfirmationUnlikeAtOnce() async {
        let api = LibraryEditsMockAPI(edits: [.removeFromPlaylist, .deletePlaylist, .saveAlbums])
        let viewModel = await makeViewModel(api)

        await viewModel.unfavoriteRows([row("abc", position: 1)])

        XCTAssertNil(viewModel.pendingLibraryRemoval)
        XCTAssertEqual(api.calls, ["removeSavedTracks(abc)"])
    }

    // MARK: - Shared edits accept Apple Music songs

    func testLikeAndAddToPlaylistTakeAppleMusicSongs() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        let viewModel = await makeViewModel(api)
        let song = row("699902614", position: 1)

        await viewModel.favoriteRows([song])
        await viewModel.addRowsToPlaylist([song], playlistID: "-1", playlistName: "Spotiglass test")

        XCTAssertEqual(api.calls, ["saveTracks(699902614)", "addTracks(-1,applemusic:song:699902614)"])
        XCTAssertEqual(viewModel.savedTrackState(for: "699902614"), true)
    }

    // MARK: - #395

    /// A provider that creates a playlist with its songs in one step (the mock, like Apple Music) gets one call, so a song
    /// it can't add leaves no empty playlist behind.
    func testNewPlaylistWithSongsIsOneProviderCall() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let viewModel = await makeViewModel(api)

        await viewModel.createPlaylistWithRows(name: "Spotiglass test", rows: [row("-30", position: 1)])

        XCTAssertEqual(api.calls, ["createPlaylist(Spotiglass test,applemusic:song:-30)"])
        XCTAssertEqual(viewModel.playlistState.currentValue?.first?.title, "Spotiglass test")
    }

    func testAFailedNewPlaylistAddsNothingToTheSidebar() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.error = AppleMusicLibraryEditError.notEditable
        let viewModel = await makeViewModel(api)

        await viewModel.createPlaylistWithRows(name: "Spotiglass test", rows: [row("-30", position: 1)])

        XCTAssertEqual(viewModel.playlistState.currentValue?.map(\.title) ?? [], [])
        XCTAssertEqual(viewModel.trackMutationToast, AppleMusicLibraryEditError.notEditable.localizedDescription)
    }

    func testRemovingFromAPlaylistUpdatesItsSidebarCount() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        let viewModel = await makeViewModel(api)

        await viewModel.removeRowsFromPlaylist([row("-30", position: 2)], playlistID: "-1", playlistName: "Spotiglass test")

        XCTAssertEqual(viewModel.playlistsByID["-1"]?.trackCount, 1)
        XCTAssertEqual(viewModel.playlistState.currentValue?.first?.trackCount, 1)
    }

    /// Add one, remove one: the count is back where it was, not one short (seen in a real run).
    func testAddingAndRemovingKeepTheCountInStep() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        let viewModel = await makeViewModel(api)

        await viewModel.addRowsToPlaylist([row("699902614", position: 1)], playlistID: "-1", playlistName: "Spotiglass test")
        XCTAssertEqual(viewModel.playlistsByID["-1"]?.trackCount, 3)
        await viewModel.removeRowsFromPlaylist([row("699902614", position: 3)], playlistID: "-1", playlistName: "Spotiglass test")
        XCTAssertEqual(viewModel.playlistsByID["-1"]?.trackCount, 2)
    }

    /// The add went through, taking the songs out of the source didn't: the destination still
    /// has them, so its count says so.
    func testAPartialMoveStillCountsTheSongsInTheDestination() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "18P1"), playlist("-2", "Spotiglass test")]
        api.removeError = AppleMusicLibraryEditError.musicControlDenied
        let viewModel = await makeViewModel(api)

        await viewModel.moveRowsBetweenPlaylists([row("-30", position: 1)], from: "-1", to: "-2", destinationName: "Spotiglass test")

        XCTAssertEqual(viewModel.playlistsByID["-2"]?.trackCount, 3)
        XCTAssertEqual(viewModel.playlistsByID["-1"]?.trackCount, 2, "nothing left the source")
    }

    func testSpotifysSidebarCountsAreLeftAlone() async {
        let api = LibraryEditsMockAPI(edits: [])
        api.playlists = [playlist("pl1", "Mine")]
        let viewModel = await makeViewModel(api)

        await viewModel.addRowsToPlaylist([row("abc", position: 1)], playlistID: "pl1", playlistName: "Mine")

        XCTAssertEqual(viewModel.playlistsByID["pl1"]?.trackCount, 2)
    }

    func testRenamingTheOpenPlaylistRenamesTheWindowTitle() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.playlists = [playlist("-1", "Spotiglass test")]
        let viewModel = await makeViewModel(api)
        await viewModel.selectSidebar(.playlist("-1"))
        XCTAssertEqual(viewModel.breadcrumbPath.map(\.label), ["Spotiglass test"])

        await viewModel.renamePlaylist(id: "-1", name: "Spotiglass test renamed")

        XCTAssertEqual(viewModel.breadcrumbPath.map(\.label), ["Spotiglass test renamed"])
    }

    /// 18P1's row cached "not liked" under its persistent ID; the song is then liked from
    /// search under its catalog ID, and the provider now knows the row is liked.
    func testALikeUnderAnotherIDOfTheSongReachesARowsCachedAnswer() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let viewModel = await makeViewModel(api)
        viewModel.savedTrackStates = ["-1192152853020385209": false, "-30": true]

        api.knownStatuses = ["-1192152853020385209": true, "-30": true]
        await viewModel.favoriteRows([row("1441154439", position: 1)])

        XCTAssertEqual(viewModel.savedTrackState(for: "-1192152853020385209"), true)
        XCTAssertEqual(viewModel.savedTrackState(for: "1441154439"), true)

        api.knownStatuses = ["-1192152853020385209": false, "-30": true]
        await viewModel.unfavoriteRows([row("1441154439", position: 1)], confirmed: true)

        XCTAssertEqual(viewModel.savedTrackState(for: "-1192152853020385209"), false)
        XCTAssertEqual(viewModel.savedTrackStates["-30"], true, "an answer the provider agrees with stays")
    }

    /// The menu cached "not liked" before an album save reached this Mac; the row, read again,
    /// now knows better, and opening the menu again must not keep the old answer.
    func testOpeningAMenuAgainDropsAnAnswerTheProviderNowKnowsBetter() async {
        let api = LibraryEditsMockAPI(edits: .all)
        let viewModel = await makeViewModel(api)
        viewModel.savedTrackStates = ["-30": false]

        api.knownStatuses = ["-30": true]
        await viewModel.loadSavedTrackStates(for: [row("-30", position: 1)])

        XCTAssertEqual(viewModel.savedTrackState(for: "-30"), true)
    }

    func testTheMenuShowsWhatTheProviderAlreadyKnowsBeforeTheLookup() async {
        let api = LibraryEditsMockAPI(edits: .all)
        api.knownStatuses = ["-30": true]
        let viewModel = await makeViewModel(api)

        XCTAssertEqual(viewModel.savedTrackState(for: "-30"), true, "not unknown, which showed a disabled Add")
        XCTAssertNil(viewModel.savedTrackState(for: "699902614"))
    }
}

/// A provider that records the optional edits; `edits` decides which it claims to support.
final class LibraryEditsMockAPI: MusicBrowsingProvider {
    let edits: MusicLibraryEdits
    var playlists: [MusicPlaylistSummary] = []
    var albumSaved = false
    var error: Error?
    private(set) var calls: [String] = []
    private(set) var removals: [MusicPlaylistTrackRemoval] = []

    init(edits: MusicLibraryEdits) {
        self.edits = edits
    }

    var supportedLibraryEdits: MusicLibraryEdits { edits }
    /// Like Apple Music: the providers with their own edits list playlists without counts.
    var listsPlaylistsWithoutTrackCounts: Bool { edits.contains(.removeFromPlaylist) }

    /// Fails only the removal, for a move whose add went through.
    var removeError: Error?

    func removeTracksFromPlaylist(playlistID: String, items: [MusicPlaylistTrackRemoval], snapshotID: String?) async throws {
        if let error = error ?? removeError { throw error }
        removals += items
        calls.append("removeTracks(\(playlistID))")
    }

    func deletePlaylist(playlistID: String) async throws {
        if let error { throw error }
        calls.append("deletePlaylist(\(playlistID))")
    }

    func saveAlbums(ids: [String]) async throws {
        if let error { throw error }
        calls.append("saveAlbums(\(ids.joined(separator: ",")))")
    }

    func removeSavedAlbums(ids: [String]) async throws {
        if let error { throw error }
        calls.append("removeSavedAlbums(\(ids.joined(separator: ",")))")
    }

    func savedAlbumStatuses(ids: [String]) async throws -> [Bool] {
        ids.map { _ in albumSaved }
    }

    func saveTracks(ids: [String]) async throws {
        if let error { throw error }
        calls.append("saveTracks(\(ids.joined(separator: ",")))")
    }

    func removeSavedTracks(ids: [String]) async throws {
        if let error { throw error }
        calls.append("removeSavedTracks(\(ids.joined(separator: ",")))")
    }

    func addTracksToPlaylist(playlistID: String, uris: [String]) async throws {
        if let error { throw error }
        calls.append("addTracks(\(playlistID),\(uris.joined(separator: ",")))")
    }

    var knownStatuses: [String: Bool] = [:]

    func createPlaylist(userID: String, name: String, isPublic: Bool, trackURIs: [String]) async throws -> MusicPlaylistSummary {
        if let error { throw error }
        calls.append("createPlaylist(\(name),\(trackURIs.joined(separator: ",")))")
        return MusicPlaylistSummary(
            id: "p.new", name: name, ownerID: "apple-music-library", ownerName: "You",
            imageURL: nil, trackCount: trackURIs.count, snapshotID: "applemusic"
        )
    }

    func knownSavedTrackStatus(id: String) -> Bool? { knownStatuses[id] }

    var updateGate: LibraryEditsGate?

    func updatePlaylist(playlistID: String, name: String) async throws {
        await updateGate?.wait()
        if let error { throw error }
        calls.append("updatePlaylist(\(playlistID),\(name))")
    }

    /// Counts the sidebar asks for after the listing (Apple Music lists playlists without one).
    var trackCounts: [String: Int] = [:]
    var trackCountsGate: LibraryEditsGate?

    private(set) var trackCountLookups = 0

    /// Reads the counts first and then waits, like a library read that is slow to answer: what
    /// it returns is from before anything that happens while it waits.
    func playlistTrackCounts(playlistIDs: [String]) async -> [String: Int] {
        trackCountLookups += 1
        let counts = trackCounts.filter { playlistIDs.contains($0.key) }
        await trackCountsGate?.wait()
        return counts
    }

    func currentUserPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] { playlists }
    func playlistTracks(playlistID: String, limit: Int, maxPages: Int) async throws -> [MusicPlaylistTrackItem] { [] }
    func currentUserSavedTracks(limit: Int, maxPages: Int?) async throws -> MusicSavedTracksResult {
        MusicSavedTracksResult(tracks: [], totalAvailable: 0)
    }
    func currentUserProfile() async throws -> MusicUserProfile {
        MusicUserProfile(id: "apple-music-library", displayName: nil, country: nil)
    }
    func artist(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicArtistDetail {
        throw AppleMusicBrowsingError.notFound
    }
    func artistCached(id: String, cacheMode: MusicRequestCacheMode) async throws -> MusicCachedResponse<MusicArtistDetail> {
        throw AppleMusicBrowsingError.notFound
    }
    func artistAlbumsCached(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicCachedResponse<[MusicArtistAlbum]> {
        MusicCachedResponse(value: [], isStale: false)
    }
    func artistAlbumsPage(
        id: String,
        includeGroups: [MusicArtistAlbumGroup],
        limit: Int,
        offset: Int,
        nextURL: URL?,
        cacheMode: MusicRequestCacheMode
    ) async throws -> MusicArtistAlbumsPage {
        MusicArtistAlbumsPage(items: [], next: nil)
    }
    func search(query: String, limit: Int) async throws -> MusicSearchResults {
        MusicSearchResults(tracks: [], artists: [], albums: [], playlists: [])
    }
    func albumTracks(albumID: String, market: String?, limit: Int) async throws -> [MusicTrack] { [] }
}

/// Holds a call until `open()`.
final class LibraryEditsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}
