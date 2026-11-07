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
        let viewModel = PlaylistBrowserViewModel(api: api, cache: DisabledSpotifyBrowsingCache())
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

    func updatePlaylist(playlistID: String, name: String) async throws {
        if let error { throw error }
        calls.append("updatePlaylist(\(playlistID),\(name))")
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
