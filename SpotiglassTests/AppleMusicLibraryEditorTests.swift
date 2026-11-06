import MusicKit
import XCTest
@testable import Spotiglass

/// The two edit routes behind Apple Music library edits, with both mocked: which route each edit
/// takes, which IDs it sends, and what the browser sees before the library on this Mac catches up.
///
/// The IDs are the ones a real run against an Apple Music account produced (macOS 27): library
/// songs shown under `i.` IDs, playlist rows under the Music persistent ID as a signed decimal.
final class AppleMusicLibraryEditorTests: XCTestCase {
    private var lookup: MockLibraryLookup!
    private var cloud: MockCloudLibrary!
    private var musicApp: MockMusicApp!
    private var pending: AppleMusicPendingLibraryEdits!
    private var editor: AppleMusicLibraryEditor!

    override func setUp() {
        super.setUp()
        lookup = MockLibraryLookup()
        cloud = MockCloudLibrary()
        musicApp = MockMusicApp()
        pending = AppleMusicPendingLibraryEdits()
        editor = AppleMusicLibraryEditor(
            lookup: lookup,
            cloud: cloud,
            musicApp: musicApp,
            pending: pending,
            songReferences: AppleMusicSongReferenceRegistry()
        )
    }

    // MARK: - Liked Songs

    func testLikeSavesACatalogSongToTheLibraryAndLovesIt() async throws {
        lookup.catalogTracksByID["699902614"] = Self.track(id: "699902614", name: "Computer Love")

        try await editor.saveSongs(ids: ["699902614"])

        XCTAssertEqual(cloud.calls, ["addToLibrary(songs:699902614 albums:)", "rate(love,699902614,catalog)"])
        XCTAssertTrue(pending.isSaved(["699902614"]))
        let statuses = try await editor.songStatuses(ids: ["699902614"])
        XCTAssertEqual(statuses, [true], "the like shows before the library on this Mac has the song")
    }

    func testLikeOfASongAlreadyInTheLibraryOnlyLovesIt() async throws {
        lookup.songsByID["i.aJGomv4H36dmrrA"] = Self.librarySong("i.aJGomv4H36dmrrA", catalog: "1710983273", persistent: "367911FB05FE6876")

        try await editor.saveSongs(ids: ["i.aJGomv4H36dmrrA"])

        XCTAssertEqual(cloud.calls, ["rate(love,1710983273,catalog)"])
    }

    func testUnlikeRemovesTheSongThroughMusicByPersistentIDAndClearsTheLove() async throws {
        lookup.songsByID["i.aJGomv4H36dmrrA"] = Self.librarySong("i.aJGomv4H36dmrrA", catalog: "1710983273", persistent: "367911FB05FE6876")

        try await editor.removeSongs(ids: ["i.aJGomv4H36dmrrA"])

        XCTAssertEqual(musicApp.calls, ["removeFromLibrary([persistentID(\"367911FB05FE6876\")])"])
        XCTAssertEqual(cloud.calls, ["rate(clear,1710983273,catalog)"])
        let statuses = try await editor.songStatuses(ids: ["i.aJGomv4H36dmrrA"])
        XCTAssertEqual(statuses, [false], "the unlike shows before MusicKit's copy of the library catches up")
    }

    /// The real run: unliking seconds after a like. MusicKit's library doesn't have the song yet,
    /// so Music is asked for it by title, artist and album from the pending like.
    func testUnlikeRightAfterALikeFindsTheSongInMusicByItsTitle() async throws {
        lookup.catalogTracksByID["699902614"] = Self.track(
            id: "699902614", name: "Computer Love", artist: "Kraftwerk", album: "Computer World (Remastered)"
        )
        try await editor.saveSongs(ids: ["699902614"])

        let savedAt = try XCTUnwrap(pending.savedSong(matching: ["699902614"])?.at)

        try await editor.removeSongs(ids: ["699902614"])

        XCTAssertEqual(musicApp.matches, [[
            .metadata(name: "Computer Love", artist: "Kraftwerk", album: "Computer World (Remastered)", addedSince: savedAt),
        ]])
        XCTAssertFalse(pending.isSaved(["699902614"]))
        let statuses = try await editor.songStatuses(ids: ["699902614"])
        XCTAssertEqual(statuses, [false])
    }

    /// Liking catalog song B while the library already has song A with the same title, artist and
    /// album: unliking B before it reaches Music must not match A. The script only takes tracks
    /// Music added since the like.
    func testUnlikeRightAfterALikeOnlyMatchesSongsAddedSinceTheLike() {
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        let script = MusicAppScripts.removeFromLibrary(
            [.metadata(name: "Computer Love", artist: "Kraftwerk", album: "Computer World", addedSince: savedAt)],
            now: savedAt.addingTimeInterval(20)
        )

        let margin = 20 + MusicAppScripts.addedSinceMarginSeconds
        XCTAssertTrue(script.hasPrefix("set scriptNow to (current date)\ntell application \"Music\""), script)
        XCTAssertTrue(script.contains("set cutoff to (scriptNow - \(margin))"), script)
        XCTAssertTrue(script.contains(
            #"name is "Computer Love" and artist is "Kraftwerk" and album is "Computer World" and date added is greater than cutoff"#
        ), script)
    }

    /// Unlike, then like again while MusicKit's copy of the library still lists the song: the like
    /// must save it again, not only love it.
    func testLikeRightAfterAnUnlikeSavesTheSongAgain() async throws {
        lookup.songsByID["i.aJGomv4H36dmrrA"] = Self.librarySong("i.aJGomv4H36dmrrA", catalog: "1710983273", persistent: "367911FB05FE6876")
        try await editor.removeSongs(ids: ["i.aJGomv4H36dmrrA"])
        cloud.calls = []

        try await editor.saveSongs(ids: ["i.aJGomv4H36dmrrA"])

        XCTAssertEqual(cloud.calls, ["addToLibrary(songs:1710983273 albums:)", "rate(love,1710983273,catalog)"])
        XCTAssertFalse(pending.isRemoved(["i.aJGomv4H36dmrrA"]))
        let statuses = try await editor.songStatuses(ids: ["i.aJGomv4H36dmrrA"])
        XCTAssertEqual(statuses, [true])
    }

    func testUnlikeOfASongNobodyCanFindSaysMusicIsNotThereYet() async {
        await XCTAssertThrowsEditError(.notInMusicYet) { try await self.editor.removeSongs(ids: ["699902614"]) }
        XCTAssertEqual(musicApp.calls, [])
    }

    func testAFailedLoveDoesNotUndoTheSave() async throws {
        cloud.ratingError = AppleMusicLibraryEditError.requestFailed
        try await editor.saveSongs(ids: ["699902614"])
        XCTAssertEqual(cloud.calls.first, "addToLibrary(songs:699902614 albums:)")
    }

    // MARK: - Albums

    func testSavingACatalogAlbumAddsItThroughTheAPI() async throws {
        lookup.albumsByID["1440"] = AppleMusicAlbumReference(itemID: "1440", catalogID: "1440", isInLibrary: false, librarySongs: [])

        try await editor.saveAlbums(ids: ["1440"])

        XCTAssertEqual(cloud.calls, ["addToLibrary(songs: albums:1440)"])
        let statuses = try await editor.albumStatuses(ids: ["1440"])
        XCTAssertEqual(statuses, [true])
    }

    /// Liked Songs are the library, so a saved album's songs show there before MusicKit has them.
    func testSavingAnAlbumShowsItsSongsInLikedSongsAtOnce() async throws {
        lookup.albumsByID["1440"] = AppleMusicAlbumReference(itemID: "1440", catalogID: "1440", isInLibrary: false, librarySongs: [])
        lookup.catalogAlbumTracksByID["1440"] = [Self.track(id: "11", name: "Numbers"), Self.track(id: "12", name: "Computer World")]

        try await editor.saveAlbums(ids: ["1440"])

        XCTAssertEqual(pending.applied(toLibrarySongs: [], isComplete: true).map(\.id), ["11", "12"])
        let statuses = try await editor.songStatuses(ids: ["11", "12"])
        XCTAssertEqual(statuses, [true, true])
    }

    func testRemovingAnAlbumRemovesItsLibrarySongsThroughMusic() async throws {
        lookup.albumsByID["-24"] = AppleMusicAlbumReference(itemID: "-24", catalogID: "1440", isInLibrary: true, librarySongs: [
            Self.librarySong("i.1", catalog: "11", persistent: "000000000000000A"),
            Self.librarySong("i.2", catalog: "12", persistent: "000000000000000B"),
        ])

        try await editor.removeAlbums(ids: ["-24"])

        XCTAssertEqual(musicApp.calls, ["removeFromLibrary([persistentID(\"000000000000000A\"), persistentID(\"000000000000000B\")])"])
        let statuses = try await editor.albumStatuses(ids: ["-24"])
        XCTAssertEqual(statuses, [false])
        XCTAssertTrue(pending.isRemoved(["i.1"]))
    }

    // MARK: - Playlists

    func testCreatingAPlaylistGoesThroughTheAPIAndShowsAtOnce() async throws {
        cloud.createdPlaylistID = "p.3VKWkReubWBYJJ7"

        let summary = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You")

        XCTAssertEqual(summary.id, "p.3VKWkReubWBYJJ7")
        XCTAssertEqual(summary.ownerID, AppleMusicBrowsingProvider.libraryUserID)
        XCTAssertEqual(cloud.calls, ["createPlaylist(Spotiglass test)"])
        XCTAssertEqual(pending.applied(toPlaylists: []).map(\.name), ["Spotiglass test"])
    }

    func testAddingToANewPlaylistUsesItsCloudIDAndCatalogIDs() async throws {
        lookup.songsByID["i.9oJZd2gHPRg0YYW"] = Self.librarySong("i.9oJZd2gHPRg0YYW", catalog: "506650076", persistent: "D620206AAF4A44E8")

        try await editor.addToPlaylist(playlistID: "p.3VKWkReubWBYJJ7", songIDs: ["i.9oJZd2gHPRg0YYW"])

        XCTAssertEqual(cloud.calls, ["addToPlaylist(p.3VKWkReubWBYJJ7,[songs:506650076])"])
    }

    /// MusicKit names a library playlist by persistent ID, the API by `p.` ID; the playlist's name
    /// is the bridge, and it has to be unique.
    func testAddingToALibraryPlaylistFindsItsCloudIDByName() async throws {
        lookup.playlistsByID["-107247429512612591"] = AppleMusicPlaylistReference(
            name: "Spotiglass test", musicAppPersistentID: "FE82FB07F4D3B511"
        )
        cloud.playlists = [
            AppleMusicCloudPlaylist(id: "p.other", name: "Italian"),
            AppleMusicCloudPlaylist(id: "p.3VKWkReubWBYJJ7", name: "Spotiglass test"),
        ]

        try await editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: ["699902614"])

        XCTAssertEqual(cloud.calls, ["editablePlaylists", "addToPlaylist(p.3VKWkReubWBYJJ7,[songs:699902614])"])
    }

    func testTwoPlaylistsWithTheSameNameAreNotGuessed() async {
        lookup.playlistsByID["-1"] = AppleMusicPlaylistReference(name: "Mix", musicAppPersistentID: "FFFFFFFFFFFFFFFF")
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.a", name: "Mix"), AppleMusicCloudPlaylist(id: "p.b", name: "Mix")]

        await XCTAssertThrowsEditError(.ambiguousPlaylist) {
            try await self.editor.addToPlaylist(playlistID: "-1", songIDs: ["699902614"])
        }
        XCTAssertFalse(cloud.calls.contains { $0.hasPrefix("addToPlaylist") })
    }

    func testRemovingFromAPlaylistGoesThroughMusicWithPositions() async throws {
        lookup.songsByID["-3017376107758730008"] = AppleMusicSongReference(
            itemID: "-3017376107758730008", musicAppPersistentID: "D620206AAF4A44E8", isInLibrary: true
        )

        try await editor.removeFromPlaylist(
            playlistID: "-107247429512612591",
            removals: [(songID: "-3017376107758730008", positions: [1])],
            shownCounts: [1]
        )

        XCTAssertEqual(musicApp.calls, [
            "removeFromPlaylist(persistentID(\"FE82FB07F4D3B511\"),[persistentID(\"D620206AAF4A44E8\")@[1]])",
        ])
    }

    func testRenameAndDeleteFindAPlaylistByPersistentID() async throws {
        try await editor.renamePlaylist(playlistID: "-107247429512612591", name: "Spotiglass test renamed")
        try await editor.deletePlaylist(playlistID: "-107247429512612591")

        XCTAssertEqual(musicApp.calls, [
            "rename(persistentID(\"FE82FB07F4D3B511\"),Spotiglass test renamed)",
            "delete(persistentID(\"FE82FB07F4D3B511\"))",
        ])
    }

    func testRenameOfAPlaylistCreatedMomentsAgoFindsItByName() async throws {
        cloud.createdPlaylistID = "p.new"
        _ = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You")

        try await editor.renamePlaylist(playlistID: "p.new", name: "Renamed")
        try await editor.deletePlaylist(playlistID: "p.new")

        XCTAssertEqual(musicApp.calls, ["rename(name(\"Spotiglass test\"),Renamed)", "delete(name(\"Renamed\"))"])
        XCTAssertEqual(pending.applied(toPlaylists: []), [], "a deleted new playlist leaves the sidebar")
    }

    /// I have "Same", create another "Same" and delete the new one before it reaches Music: Music
    /// would find only the old one by name, so nothing may be sent.
    func testANewPlaylistNamedLikeAnOlderOneIsNeverFoundByName() async throws {
        cloud.createdPlaylistID = "p.new"
        _ = try await editor.createPlaylist(name: "Same", ownerName: "You", existingIDsWithSameName: ["-1"])

        await XCTAssertThrowsEditError(.ambiguousPlaylist) { try await self.editor.deletePlaylist(playlistID: "p.new") }
        await XCTAssertThrowsEditError(.ambiguousPlaylist) { try await self.editor.renamePlaylist(playlistID: "p.new", name: "Other") }
        XCTAssertEqual(musicApp.calls, [])
    }

    /// The same when the namesake only shows in the cloud list (created elsewhere meanwhile).
    func testANamesakeInTheCloudStopsTheNameFallback() async {
        cloud.createdPlaylistID = "p.new"
        _ = try? await editor.createPlaylist(name: "Same", ownerName: "You")
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.new", name: "Same"), AppleMusicCloudPlaylist(id: "p.old", name: "Same")]

        await XCTAssertThrowsEditError(.ambiguousPlaylist) { try await self.editor.deletePlaylist(playlistID: "p.new") }
        XCTAssertEqual(musicApp.calls, [])
    }

    /// A and B exist; I rename A to B. An add right after, while the cloud list still says A and
    /// B, goes to A: its cloud ID was learned before the rename.
    func testAnAddAfterARenameGoesToTheRenamedPlaylist() async throws {
        lookup.playlistsByID["-1"] = AppleMusicPlaylistReference(name: "A", musicAppPersistentID: "FFFFFFFFFFFFFFFF")
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.a", name: "A"), AppleMusicCloudPlaylist(id: "p.b", name: "B")]

        try await editor.renamePlaylist(playlistID: "-1", name: "B")
        try await editor.addToPlaylist(playlistID: "-1", songIDs: ["699902614"])

        XCTAssertEqual(cloud.calls.last, "addToPlaylist(p.a,[songs:699902614])")
    }

    /// Without the cloud ID from before the rename, a stale cloud list is not guessed from.
    func testAnAddAfterARenameWaitsWhileTheCloudListIsStale() async {
        lookup.playlistsByID["-1"] = AppleMusicPlaylistReference(name: "A", musicAppPersistentID: "FFFFFFFFFFFFFFFF")
        pending.recordRenamedPlaylist("-1", name: "B")
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.a", name: "A"), AppleMusicCloudPlaylist(id: "p.b", name: "B")]

        await XCTAssertThrowsEditError(.notInMusicYet) {
            try await self.editor.addToPlaylist(playlistID: "-1", songIDs: ["699902614"])
        }
        XCTAssertFalse(cloud.calls.contains { $0.hasPrefix("addToPlaylist") })
    }

    func testADeniedMusicPermissionSurfacesAsItsOwnError() async {
        musicApp.error = AppleMusicLibraryEditError.musicControlDenied
        await XCTAssertThrowsEditError(.musicControlDenied) {
            try await self.editor.deletePlaylist(playlistID: "-1")
        }
        XCTAssertEqual(
            AppleMusicLibraryEditError.musicControlDenied.localizedDescription,
            SpotiglassL10n.string("appleMusic.edit.error.musicControlDenied")
        )
    }

    // MARK: - IDs

    func testPersistentIDsConvertToMusicsHexForm() {
        XCTAssertEqual(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: "3925188320065120374"), "367911FB05FE6876")
        XCTAssertEqual(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: "-3017376107758730008"), "D620206AAF4A44E8")
        XCTAssertEqual(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: "-107247429512612591"), "FE82FB07F4D3B511")
        XCTAssertNil(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: "i.aJGomv4H36dmrrA"))
        XCTAssertNil(AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: "p.3VKWkReubWBYJJ7"))
    }

    func testCatalogAndPersistentIDsAreToldApart() {
        XCTAssertTrue(MusicKitLibraryLookup.isCatalogID("699902614"))
        XCTAssertFalse(MusicKitLibraryLookup.isCatalogID("i.aJGomv4H36dmrrA"))
        XCTAssertFalse(MusicKitLibraryLookup.isCatalogID("3925188320065120374"))
        XCTAssertTrue(MusicKitLibraryLookup.isPersistentID("3925188320065120374"))
        XCTAssertTrue(MusicKitLibraryLookup.isPersistentID("-3017376107758730008"))
        XCTAssertFalse(MusicKitLibraryLookup.isPersistentID("699902614"))
    }

    /// JSON as MusicKit encodes a library song on macOS (trimmed from a real one).
    func testSongIdentityReadsTheIDsMusicKitEncodes() {
        let json = #"""
        {"id":"i.xrXvb5YUMXrPzza","type":"library-songs","attributes":{"name":"!ly (feat. Coez)","playParams":{"kind":"song","musicKit_persistentID":"260349940219299206","id":"i.xrXvb5YUMXrPzza","catalogId":"1677797557","musicKit_libraryID":"i.xrXvb5YUMXrPzza","isLibrary":true}}}
        """#
        let identity = AppleMusicSongIdentity(encoded: Data(json.utf8))

        XCTAssertEqual(identity.catalogID, "1677797557")
        XCTAssertEqual(identity.cloudLibraryID, "i.xrXvb5YUMXrPzza")
        XCTAssertEqual(identity.musicKitPersistentID, "260349940219299206")
        XCTAssertEqual(identity.keys(itemID: "i.xrXvb5YUMXrPzza"), ["i.xrXvb5YUMXrPzza", "1677797557"])
    }

    /// A library song MusicKit has only on this Mac: no cloud ID, catalog ID in `meta`.
    func testSongIdentityFallsBackToTheIdentifierSet() {
        let json = #"""
        {"id":"-4954366973876942249","type":"songs","attributes":{"name":"#BrooklynBloodPop!"},"meta":{"musicKit_identifierSet":{"deviceLocalID":{"value":"-4954366973876942249"},"catalogID":{"kind":"subscriptionAdamID","value":"1600513002"}}}}
        """#
        let identity = AppleMusicSongIdentity(encoded: Data(json.utf8))

        XCTAssertEqual(identity.catalogID, "1600513002")
        XCTAssertNil(identity.cloudLibraryID)
        XCTAssertEqual(identity.musicKitPersistentID, "-4954366973876942249")
    }

    func testSongReferenceRegistryStaysBounded() {
        let registry = AppleMusicSongReferenceRegistry()
        for index in 0...AppleMusicSongReferenceRegistry.maxEntries {
            registry.remember(AppleMusicSongReference(itemID: "\(index)", isInLibrary: true))
        }
        XCTAssertNil(registry.reference(for: "0"), "the oldest entry is dropped past the bound")
        XCTAssertNotNil(registry.reference(for: "\(AppleMusicSongReferenceRegistry.maxEntries)"))
    }

    // MARK: - Helpers

    static func track(id: String, name: String, artist: String = "Kraftwerk", album: String? = nil) -> MusicTrack {
        MusicTrack(
            id: id,
            name: name,
            artists: [artist],
            albumArtworkURL: nil,
            albumName: album,
            durationMilliseconds: 1000,
            isExplicit: false,
            isPlayable: true,
            linkedFromID: nil,
            uri: "applemusic:song:\(id)"
        )
    }

    static func librarySong(_ id: String, catalog: String, persistent: String) -> AppleMusicSongReference {
        AppleMusicSongReference(
            itemID: id,
            catalogID: catalog,
            cloudLibraryID: id.hasPrefix("i.") ? id : nil,
            musicAppPersistentID: persistent,
            isInLibrary: true,
            title: "Song \(id)",
            artistName: "Artist"
        )
    }
}

// MARK: - Pending edits

final class AppleMusicPendingLibraryEditsTests: XCTestCase {
    private func summary(_ id: String, _ name: String) -> MusicPlaylistSummary {
        MusicPlaylistSummary(id: id, name: name, ownerID: "apple-music-library", ownerName: "You", imageURL: nil, trackCount: nil, snapshotID: "applemusic")
    }

    func testCreatedPlaylistStaysUntilTheLibraryShowsOneWithItsName() {
        let pending = AppleMusicPendingLibraryEdits()
        pending.recordCreatedPlaylist(summary("p.new", "Spotiglass test"))

        XCTAssertEqual(pending.applied(toPlaylists: [summary("-1", "Italian")]).map(\.id), ["p.new", "-1"])
        // The library on this Mac now has it, under its persistent ID.
        XCTAssertEqual(pending.applied(toPlaylists: [summary("-2", "Spotiglass test"), summary("-1", "Italian")]).map(\.id), ["-2", "-1"])
        XCTAssertEqual(pending.applied(toPlaylists: [summary("-1", "Italian")]).map(\.id), ["-1"], "reconciled: not shown twice")
    }

    /// A new playlist named like one I already have stays until the library lists a second one.
    func testCreatedPlaylistWithAnExistingNameStaysUntilTheNewOneShows() {
        let pending = AppleMusicPendingLibraryEdits()
        pending.recordCreatedPlaylist(summary("p.new", "Same"), existingIDsWithSameName: ["-1"])

        XCTAssertEqual(pending.applied(toPlaylists: [summary("-1", "Same")]).map(\.id), ["p.new", "-1"])
        XCTAssertEqual(pending.createdPlaylist(id: "p.new")?.name, "Same", "rename and delete still find it")
        XCTAssertEqual(pending.applied(toPlaylists: [summary("-2", "Same"), summary("-1", "Same")]).map(\.id), ["-2", "-1"])
        XCTAssertNil(pending.createdPlaylist(id: "p.new"))
    }

    func testRenamedAndDeletedPlaylistsShowTheEditUntilTheLibraryDoes() {
        let pending = AppleMusicPendingLibraryEdits()
        pending.recordRenamedPlaylist("-1", name: "New")
        pending.recordDeletedPlaylist("-2")
        let stale = [summary("-1", "Old"), summary("-2", "Gone")]

        XCTAssertEqual(pending.applied(toPlaylists: stale).map(\.name), ["New"])
        XCTAssertEqual(pending.applied(toPlaylists: [summary("-1", "New")]).map(\.name), ["New"])
        XCTAssertNil(pending.renamedName(for: "-1"), "reconciled once the library shows the new name")
        XCTAssertEqual(pending.applied(toPlaylists: [summary("-2", "Gone")]).map(\.name), ["Gone"],
                       "the deletion ended once the library no longer listed the playlist")
    }

    func testLikedSongsShowSavesOnTopAndHideRemovals() {
        let pending = AppleMusicPendingLibraryEdits()
        let liked = AppleMusicLibraryEditorTests.track(id: "699902614", name: "Computer Love")
        pending.recordSavedSong(liked, reference: AppleMusicSongReference(itemID: "699902614", catalogID: "699902614", isInLibrary: false))
        pending.recordRemovedSong(["i.gone"])
        let library = [
            (track: AppleMusicLibraryEditorTests.track(id: "i.kept", name: "Kept"), keys: Set(["i.kept", "1"])),
            (track: AppleMusicLibraryEditorTests.track(id: "i.gone", name: "Gone"), keys: Set(["i.gone", "2"])),
        ]

        XCTAssertEqual(pending.applied(toLibrarySongs: library, isComplete: true).map(\.id), ["699902614", "i.kept"])

        // The library has caught up: the like shows under its library ID, the removal is gone.
        let caughtUp = [
            (track: AppleMusicLibraryEditorTests.track(id: "i.new", name: "Computer Love"), keys: Set(["i.new", "699902614"])),
            (track: AppleMusicLibraryEditorTests.track(id: "i.kept", name: "Kept"), keys: Set(["i.kept", "1"])),
        ]
        XCTAssertEqual(pending.applied(toLibrarySongs: caughtUp, isComplete: true).map(\.id), ["i.new", "i.kept"])
        XCTAssertFalse(pending.hasPendingSongs)
    }

    func testAPartialReadDoesNotEndARemoval() {
        let pending = AppleMusicPendingLibraryEdits()
        pending.recordRemovedSong(["i.gone"])
        _ = pending.applied(toLibrarySongs: [], isComplete: false)
        XCTAssertTrue(pending.isRemoved(["i.gone"]), "a capped read that doesn't show the song proves nothing")
    }

    func testPlaylistRemovalKeepsTheOtherOccurrences() {
        let pending = AppleMusicPendingLibraryEdits()
        let song = AppleMusicLibraryEditorTests.track(id: "-30", name: "Twice")
        // The playlist listed the song twice, one was removed.
        pending.recordPlaylistRemoval(["-30"], removed: 1, shownBefore: 2, playlistID: "-1")

        let stale = [(track: song, keys: Set(["-30"])), (track: song, keys: Set(["-30"]))]
        XCTAssertEqual(pending.applied(toPlaylistTracks: stale, playlistID: "-1").count, 1)
        let caughtUp = [(track: song, keys: Set(["-30"]))]
        XCTAssertEqual(pending.applied(toPlaylistTracks: caughtUp, playlistID: "-1").count, 1, "the kept occurrence stays")
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "-1"))
    }

    func testPlaylistAdditionsShowUntilTheLibraryHasThem() {
        let pending = AppleMusicPendingLibraryEdits()
        let added = AppleMusicLibraryEditorTests.track(id: "506650076", name: "Disparate Youth")
        pending.recordPlaylistAddition(added, reference: AppleMusicSongReference(itemID: "i.9", catalogID: "506650076", isInLibrary: true), playlistID: "-1")

        XCTAssertEqual(pending.applied(toPlaylistTracks: [], playlistID: "-1").map(\.id), ["506650076"])
        let caughtUp = [(track: AppleMusicLibraryEditorTests.track(id: "-30", name: "Disparate Youth"), keys: Set(["-30", "506650076"]))]
        XCTAssertEqual(pending.applied(toPlaylistTracks: caughtUp, playlistID: "-1").map(\.id), ["-30"])
    }

    /// In [A, B, A] I remove the first A: a stale read shows [B, A], not [A, B].
    func testRemovingOneOfTwoCopiesHidesTheCopyThatWasPicked() {
        let pending = AppleMusicPendingLibraryEdits()
        let a = AppleMusicLibraryEditorTests.track(id: "-30", name: "A")
        let b = AppleMusicLibraryEditorTests.track(id: "-31", name: "B")
        pending.recordPlaylistRemoval(["-30"], removed: 1, shownBefore: 2, ordinals: [0], playlistID: "-1")

        let stale = [(track: a, keys: Set(["-30", "first"])), (track: b, keys: Set(["-31"])), (track: a, keys: Set(["-30", "second"]))]
        let shown = pending.applied(toPlaylistTracks: stale, playlistID: "-1")
        XCTAssertEqual(shown.map(\.name), ["B", "A"])
        XCTAssertTrue(pending.hasPendingTracks(playlistID: "-1"))
        XCTAssertEqual(pending.applied(toPlaylistTracks: [(b, ["-31"]), (a, ["-30"])], playlistID: "-1").map(\.name), ["B", "A"])
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "-1"), "the library shows the removal")
    }

    /// A song removed from the library leaves every playlist in Music; Spotiglass shows that at once.
    func testALibraryRemovalLeavesEveryPlaylist() {
        let pending = AppleMusicPendingLibraryEdits()
        pending.recordRemovedSong(["i.gone", "-30"])
        let gone = AppleMusicLibraryEditorTests.track(id: "-30", name: "Gone")
        let kept = AppleMusicLibraryEditorTests.track(id: "-31", name: "Kept")

        let shown = pending.applied(toPlaylistTracks: [(gone, ["-30"]), (kept, ["-31"])], playlistID: "-1")
        XCTAssertEqual(shown.map(\.id), ["-31"])
    }

    /// Adding a second copy of a song the playlist has: a stale read listing the first copy
    /// doesn't end the addition.
    func testASecondCopyOfASongStaysUntilTheLibraryListsBoth() {
        let pending = AppleMusicPendingLibraryEdits()
        let song = AppleMusicLibraryEditorTests.track(id: "506650076", name: "Disparate Youth")
        let reference = AppleMusicSongReference(itemID: "506650076", catalogID: "506650076", isInLibrary: true)
        pending.recordPlaylistAddition(song, reference: reference, playlistID: "-1", shownBefore: 1)
        let listed = (track: AppleMusicLibraryEditorTests.track(id: "-30", name: "Disparate Youth"), keys: Set(["-30", "506650076"]))

        XCTAssertEqual(pending.applied(toPlaylistTracks: [listed], playlistID: "-1").map(\.id), ["-30", "506650076"])
        XCTAssertTrue(pending.hasPendingTracks(playlistID: "-1"))
        XCTAssertEqual(pending.applied(toPlaylistTracks: [listed, listed], playlistID: "-1").map(\.id), ["-30", "-30"])
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "-1"))
    }

    /// Remove the only copy of a song, then add it back while MusicKit still lists the old copy:
    /// it shows once, and keeps showing once the library has the new copy.
    func testRemovingAndAddingASongBackShowsItOnce() {
        let pending = AppleMusicPendingLibraryEdits()
        let song = AppleMusicLibraryEditorTests.track(id: "-30", name: "Disparate Youth", artist: "Santigold")
        let listed = (track: song, keys: Set(["-30", AppleMusicPendingLibraryEdits.metadataKey(song)]))
        pending.recordPlaylistRemoval(
            ["-30"],
            metadataKey: AppleMusicPendingLibraryEdits.metadataKey(name: "Disparate Youth", artist: "Santigold"),
            removed: 1,
            shownBefore: 1,
            playlistID: "-1"
        )
        XCTAssertEqual(pending.applied(toPlaylistTracks: [listed], playlistID: "-1").count, 0)

        // Added back from search, under its catalog ID.
        let catalog = AppleMusicLibraryEditorTests.track(id: "506650076", name: "Disparate Youth", artist: "Santigold")
        pending.recordPlaylistAddition(
            catalog,
            reference: AppleMusicSongReference(itemID: "506650076", catalogID: "506650076", isInLibrary: true),
            playlistID: "-1"
        )

        XCTAssertEqual(pending.applied(toPlaylistTracks: [listed], playlistID: "-1").map(\.id), ["-30"], "stale read")
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "-1"))
        let synced = (track: AppleMusicLibraryEditorTests.track(id: "-31", name: "Disparate Youth", artist: "Santigold"),
                      keys: Set(["-31", AppleMusicPendingLibraryEdits.metadataKey(song)]))
        XCTAssertEqual(pending.applied(toPlaylistTracks: [synced], playlistID: "-1").map(\.id), ["-31"], "the library has it again")
    }

    /// The real case: a library song added to a new playlist, then MusicKit lists the playlist with
    /// the song under its persistent ID as a decimal. The addition must not show a second copy.
    func testAnAdditionEndsWhenThePlaylistListsTheSongUnderItsPersistentID() {
        let pending = AppleMusicPendingLibraryEdits()
        let reference = AppleMusicSongReference(
            itemID: "i.aJGomv4H36dmrrA", catalogID: "1710983273", cloudLibraryID: "i.aJGomv4H36dmrrA",
            musicAppPersistentID: "367911FB05FE6876", isInLibrary: true
        )
        pending.recordPlaylistAddition(AppleMusicLibraryEditorTests.track(id: "1710983273", name: "WHERE SHE GOES", artist: "Bad Bunny"), reference: reference, playlistID: "p.new")
        let listed = AppleMusicLibraryEditorTests.track(id: "3925188320065120374", name: "WHERE SHE GOES", artist: "Bad Bunny")

        XCTAssertEqual(reference.musicKitPersistentID, "3925188320065120374")
        XCTAssertEqual(pending.applied(toPlaylistTracks: [(listed, ["3925188320065120374"])], playlistID: "p.new").count, 1)
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "p.new"))
    }

    /// A song the library lists under an ID nobody knew yet still ends the pending addition by
    /// its title and artist.
    func testAnAdditionEndsOnTitleAndArtistAsALastResort() {
        let pending = AppleMusicPendingLibraryEdits()
        let added = AppleMusicLibraryEditorTests.track(id: "699902614", name: "Computer Love")
        pending.recordPlaylistAddition(added, reference: AppleMusicSongReference(itemID: "699902614", catalogID: "699902614", isInLibrary: false), playlistID: "-1")
        let listed = AppleMusicLibraryEditorTests.track(id: "-77", name: "Computer Love")

        let shown = pending.applied(toPlaylistTracks: [(listed, ["-77", AppleMusicPendingLibraryEdits.metadataKey(listed)])], playlistID: "-1")
        XCTAssertEqual(shown.map(\.id), ["-77"])
    }

    func testEntriesExpire() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let pending = AppleMusicPendingLibraryEdits(now: { clock.now })
        pending.recordRenamedPlaylist("-1", name: "New")
        XCTAssertEqual(pending.renamedName(for: "-1"), "New")
        clock.now = clock.now.addingTimeInterval(AppleMusicPendingLibraryEdits.maxAge + 1)
        XCTAssertNil(pending.renamedName(for: "-1"))
    }
}

// MARK: - Music app scripts

final class MusicAppScriptsTests: XCTestCase {
    func testQuotingKeepsTitlesInsideTheString() {
        XCTAssertEqual(MusicAppScripts.quoted(#"Say "hi" \ bye"#), #""Say \"hi\" \\ bye""#)
    }

    func testRemoveFromLibraryLooksEverythingUpBeforeDeleting() throws {
        let script = MusicAppScripts.removeFromLibrary([
            .persistentID("367911FB05FE6876"),
            .metadata(name: "Computer Love", artist: "Kraftwerk", album: "Computer World (Remastered)"),
        ])

        XCTAssertTrue(script.contains(#"every track of lib whose persistent ID is "367911FB05FE6876""#))
        XCTAssertTrue(script.contains(#"name is "Computer Love" and artist is "Kraftwerk" and album is "Computer World (Remastered)""#))
        // Two copies of a song are the song's own error, never "Two playlists have this name".
        XCTAssertTrue(script.contains("error \"ambiguous\" number 9004"))
        XCTAssertFalse(script.contains("number 9002"))
        XCTAssertEqual(
            AppleMusicLibraryEditError.ambiguousSong.localizedDescription,
            SpotiglassL10n.string("appleMusic.edit.error.ambiguousSong")
        )
        let lastLookup = try XCTUnwrap(script.range(of: "set end of targets", options: .backwards))
        let firstDelete = try XCTUnwrap(script.range(of: "delete target"))
        XCTAssertLessThan(lastLookup.lowerBound, firstDelete.lowerBound)
    }

    func testPlaylistRemovalsRunFromTheLastPositionToTheFirst() throws {
        let script = MusicAppScripts.removeFromPlaylist(.persistentID("FE82FB07F4D3B511"), removals: [
            MusicAppPlaylistRemoval(track: .persistentID("A"), positions: [0, 4]),
            MusicAppPlaylistRemoval(track: .persistentID("B"), positions: [2]),
        ])

        let indexes = script.components(separatedBy: "\n")
            .filter { $0.hasPrefix("set t to track ") }
            .map { $0.replacingOccurrences(of: "set t to track ", with: "").replacingOccurrences(of: " of pl", with: "") }
        XCTAssertEqual(indexes, ["5", "3", "1"])
        XCTAssertTrue(script.contains(#"every user playlist whose persistent ID is "FE82FB07F4D3B511""#))
        XCTAssertTrue(script.contains("if smart of pl then error"))
    }

    /// One of the songs is already gone: nothing may be deleted before every occurrence is found.
    func testPlaylistRemovalFindsEveryOccurrenceBeforeDeletingAny() throws {
        let script = MusicAppScripts.removeFromPlaylist(.persistentID("FE82FB07F4D3B511"), removals: [
            MusicAppPlaylistRemoval(track: .persistentID("A"), positions: [0]),
            MusicAppPlaylistRemoval(track: .persistentID("C"), positions: [2]),
        ])

        let lastLookup = try XCTUnwrap(script.range(of: "set end of targetIDs", options: .backwards))
        let firstDelete = try XCTUnwrap(script.range(of: "delete "))
        XCTAssertLessThan(lastLookup.lowerBound, firstDelete.lowerBound)
        XCTAssertEqual(script.components(separatedBy: "if picked is missing value then error \"not found\" number 9001").count - 1, 2)
        XCTAssertTrue(script.contains("delete (every track of pl whose id is (contents of targetID))"))
        XCTAssertTrue(script.contains("targetIDs does not contain (id of candidate)"), "two removals never pick the same entry")
    }

    func testRenameAndDeleteScripts() {
        XCTAssertTrue(MusicAppScripts.renamePlaylist(.name("Spotiglass test"), to: "New").contains(#"set name of pl to "New""#))
        XCTAssertTrue(MusicAppScripts.deletePlaylist(.name("Spotiglass test")).contains(#"whose name is "Spotiglass test""#))
    }

    func testScriptErrorsMapToCalmMessages() {
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: 9001), .notInMusicYet)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: 9002), .ambiguousPlaylist)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: 9003), .notEditable)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: 9004), .ambiguousSong)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: -1743), .musicControlDenied)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: -600), .musicUnavailable)
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: -2700), .requestFailed)
    }

    func testScriptingSkipsEmptyEdits() async throws {
        let runner = RecordingScriptRunner()
        let scripting = MusicAppLibraryScripting(runner: runner)
        try await scripting.removeFromLibrary([])
        try await scripting.removeFromPlaylist(.name("x"), removals: [MusicAppPlaylistRemoval(track: .persistentID("A"), positions: [])])
        try await scripting.deletePlaylist(.name("x"))
        XCTAssertEqual(runner.scripts.count, 1)
    }
}

// MARK: - Apple Music API requests

final class AppleMusicCloudRequestsTests: XCTestCase {
    func testAddToLibraryNamesSongsAndAlbums() throws {
        let request = try XCTUnwrap(AppleMusicCloudRequests.addToLibrary(songs: ["1", "2"], albums: ["3"]))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.music.apple.com/v1/me/library?ids%5Bsongs%5D=1,2&ids%5Balbums%5D=3")
        XCTAssertNil(AppleMusicCloudRequests.addToLibrary(songs: [], albums: []))
    }

    func testCreatePlaylistAndAddTracksBodies() throws {
        let create = AppleMusicCloudRequests.createPlaylist(name: "Spotiglass test")
        XCTAssertEqual(create.url?.path, "/v1/me/library/playlists")
        XCTAssertEqual(String(decoding: try XCTUnwrap(create.httpBody), as: UTF8.self),
                       #"{"attributes":{"description":"","name":"Spotiglass test"}}"#)

        let add = AppleMusicCloudRequests.addToPlaylist(cloudPlaylistID: "p.3VKWkReubWBYJJ7", songs: [
            AppleMusicCloudSong(id: "506650076", kind: .catalog),
            AppleMusicCloudSong(id: "i.9", kind: .library),
        ])
        XCTAssertEqual(add.url?.path, "/v1/me/library/playlists/p.3VKWkReubWBYJJ7/tracks")
        XCTAssertEqual(String(decoding: try XCTUnwrap(add.httpBody), as: UTF8.self),
                       #"{"data":[{"id":"506650076","type":"songs"},{"id":"i.9","type":"library-songs"}]}"#)
    }

    func testRatingsPutAndDelete() throws {
        let love = AppleMusicCloudRequests.rating(.love, songID: "699902614", isLibraryID: false)
        XCTAssertEqual(love.httpMethod, "PUT")
        XCTAssertEqual(love.url?.path, "/v1/me/ratings/songs/699902614")
        XCTAssertEqual(String(decoding: try XCTUnwrap(love.httpBody), as: UTF8.self), #"{"attributes":{"value":1},"type":"rating"}"#)

        let clear = AppleMusicCloudRequests.rating(nil, songID: "i.9", isLibraryID: true)
        XCTAssertEqual(clear.httpMethod, "DELETE")
        XCTAssertEqual(clear.url?.path, "/v1/me/ratings/library-songs/i.9")
        XCTAssertNil(clear.httpBody)
    }

    /// The 201 body a real create returned, trimmed.
    func testCreatedPlaylistIDComesFromTheResponse() async throws {
        let library = MusicDataRequestCloudLibrary { _ in
            Data(#"{"data":[{"id":"p.2P6WZ1KcVElPee9","type":"library-playlists","attributes":{"canEdit":true,"name":"Spotiglass test"}}]}"#.utf8)
        }
        let id = try await library.createPlaylist(name: "Spotiglass test")
        XCTAssertEqual(id, "p.2P6WZ1KcVElPee9")
    }

    func testEditablePlaylistsFollowPagesAndSkipReadOnlyOnes() async throws {
        let paths = PathRecorder()
        let library = MusicDataRequestCloudLibrary { request in
            paths.append(request.url?.absoluteString ?? "")
            if request.url?.query?.contains("offset=100") == true {
                return Data(#"{"data":[{"id":"p.c","attributes":{"name":"C","canEdit":true}}]}"#.utf8)
            }
            return Data(#"{"next":"/v1/me/library/playlists?offset=100","data":[{"id":"p.a","attributes":{"name":"A","canEdit":true}},{"id":"p.b","attributes":{"name":"Apple's","canEdit":false}}]}"#.utf8)
        }

        let playlists = try await library.editablePlaylists()

        XCTAssertEqual(playlists, [AppleMusicCloudPlaylist(id: "p.a", name: "A"), AppleMusicCloudPlaylist(id: "p.c", name: "C")])
        XCTAssertEqual(paths.values, [
            "https://api.music.apple.com/v1/me/library/playlists?limit=100",
            "https://api.music.apple.com/v1/me/library/playlists?offset=100",
        ])
    }

    func testANewEmptyPlaylistReadsAsNoTracks() async throws {
        let library = MusicDataRequestCloudLibrary { _ in throw AppleMusicLibraryEditError.requestFailed }
        let tracks = try await library.playlistTracks(cloudPlaylistID: "p.new")
        XCTAssertEqual(tracks.count, 0)
    }
}

// MARK: - The provider

final class AppleMusicBrowsingProviderLibraryEditTests: XCTestCase {
    /// Every edit fails with Apple Music's own error, never the protocol's `SpotifyAPIError`
    /// default, so it is neither shown nor handled as a Spotify error.
    func testEditsReportAppleMusicsOwnErrors() async {
        let editor = AppleMusicLibraryEditor(
            lookup: MockLibraryLookup(),
            cloud: MockCloudLibrary(),
            musicApp: MockMusicApp(),
            pending: AppleMusicPendingLibraryEdits(),
            songReferences: AppleMusicSongReferenceRegistry()
        )
        let provider = AppleMusicBrowsingProvider(editor: editor)
        let edits: [(String, () async throws -> Void)] = [
            ("add non-song", { try await provider.addTracksToPlaylist(playlistID: "p.1", uris: ["spotify:track:1"]) }),
            ("remove non-song", { try await provider.removeTracksFromPlaylist(playlistID: "p.1", items: [], snapshotID: nil) }),
            ("unlike unknown", { try await provider.removeSavedTracks(ids: ["1"]) }),
        ]
        for (name, edit) in edits {
            do {
                try await edit()
                XCTFail("\(name): expected an error")
            } catch {
                XCTAssertTrue(error is AppleMusicLibraryEditError, name)
                XCTAssertFalse(error is SpotifyAPIError, name)
            }
        }
    }

    func testProviderOffersEveryOptionalEdit() {
        XCTAssertEqual(AppleMusicBrowsingProvider().supportedLibraryEdits, .all)
    }

    func testSongURIsCarryTheirID() {
        XCTAssertEqual(AppleMusicItemMapping.songID(fromURI: "applemusic:song:i.9"), "i.9")
        XCTAssertNil(AppleMusicItemMapping.songID(fromURI: "applemusic:album:1"))
        XCTAssertNil(AppleMusicItemMapping.songID(fromURI: "applemusic:song:"))
    }
}

// MARK: - Mocks

func XCTAssertThrowsEditError(
    _ expected: AppleMusicLibraryEditError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AppleMusicLibraryEditError, expected, file: file, line: line)
    }
}

final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func append(_ value: String) { lock.withLock { recorded.append(value) } }
}

final class MockLibraryLookup: AppleMusicLibraryLookup, @unchecked Sendable {
    var songsByID: [String: AppleMusicSongReference] = [:]
    var catalogTracksByID: [String: MusicTrack] = [:]
    var albumsByID: [String: AppleMusicAlbumReference] = [:]
    var playlistsByID: [String: AppleMusicPlaylistReference] = [:]

    func songs(ids: [String]) async throws -> [AppleMusicSongReference] {
        ids.map { id in
            songsByID[id] ?? AppleMusicSongReference(
                itemID: id,
                catalogID: MusicKitLibraryLookup.isCatalogID(id) ? id : nil,
                isInLibrary: false
            )
        }
    }

    func catalogTracks(ids: [String]) async throws -> [MusicTrack] {
        ids.compactMap { catalogTracksByID[$0] }
    }

    var catalogAlbumTracksByID: [String: [MusicTrack]] = [:]
    func catalogAlbumTracks(albumIDs: [String]) async throws -> [MusicTrack] {
        albumIDs.flatMap { catalogAlbumTracksByID[$0] ?? [] }
    }

    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference] {
        ids.map { albumsByID[$0] ?? AppleMusicAlbumReference(itemID: $0, catalogID: $0, isInLibrary: false, librarySongs: []) }
    }

    func playlist(id: String) async throws -> AppleMusicPlaylistReference? {
        playlistsByID[id]
    }
}

final class MockCloudLibrary: AppleMusicCloudLibrary, @unchecked Sendable {
    var calls: [String] = []
    var createdPlaylistID = "p.created"
    var playlists: [AppleMusicCloudPlaylist] = []
    var ratingError: Error?

    func addToLibrary(songCatalogIDs: [String], albumCatalogIDs: [String]) async throws {
        calls.append("addToLibrary(songs:\(songCatalogIDs.joined(separator: ",")) albums:\(albumCatalogIDs.joined(separator: ",")))")
    }

    func createPlaylist(name: String) async throws -> String {
        calls.append("createPlaylist(\(name))")
        return createdPlaylistID
    }

    func addToPlaylist(cloudPlaylistID: String, songs: [AppleMusicCloudSong]) async throws {
        calls.append("addToPlaylist(\(cloudPlaylistID),[\(songs.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: ","))])")
    }

    func setRating(_ rating: AppleMusicRating?, songID: String, isLibraryID: Bool) async throws {
        if let ratingError { throw ratingError }
        let value = rating.map { $0 == .love ? "love" : "dislike" } ?? "clear"
        calls.append("rate(\(value),\(songID),\(isLibraryID ? "library" : "catalog"))")
    }

    func editablePlaylists() async throws -> [AppleMusicCloudPlaylist] {
        calls.append("editablePlaylists")
        return playlists
    }

    var playlistSongs: [Song] = []
    func playlistTracks(cloudPlaylistID: String) async throws -> [Song] { playlistSongs }
}

final class MockMusicApp: MusicAppLibraryControlling, @unchecked Sendable {
    var calls: [String] = []
    /// The matches of each `removeFromLibrary`, for checks on more than their description.
    var matches: [[MusicAppTrackMatch]] = []
    var error: Error?

    func removeFromLibrary(_ tracks: [MusicAppTrackMatch]) async throws {
        if let error { throw error }
        matches.append(tracks)
        calls.append("removeFromLibrary([\(tracks.map(Self.describe).joined(separator: ", "))])")
    }

    func removeFromPlaylist(_ playlist: MusicAppPlaylistMatch, removals: [MusicAppPlaylistRemoval]) async throws {
        if let error { throw error }
        let list = removals.map { "\(Self.describe($0.track))@\($0.positions)" }.joined(separator: ",")
        calls.append("removeFromPlaylist(\(Self.describe(playlist)),[\(list)])")
    }

    func renamePlaylist(_ playlist: MusicAppPlaylistMatch, to name: String) async throws {
        if let error { throw error }
        calls.append("rename(\(Self.describe(playlist)),\(name))")
    }

    func deletePlaylist(_ playlist: MusicAppPlaylistMatch) async throws {
        if let error { throw error }
        calls.append("delete(\(Self.describe(playlist)))")
    }

    private static func describe(_ value: Any) -> String {
        String(describing: value)
            .replacingOccurrences(of: "Spotiglass.MusicAppTrackMatch.", with: "")
            .replacingOccurrences(of: "Spotiglass.MusicAppPlaylistMatch.", with: "")
    }
}

private final class RecordingScriptRunner: MusicAppScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var scripts: [String] { lock.withLock { recorded } }
    func run(_ source: String) async throws { lock.withLock { recorded.append(source) } }
}

// MARK: - Provider wiring and reads

final class AppleMusicProviderEditWiringTests: XCTestCase {
    private var lookup: MockLibraryLookup!
    private var cloud: MockCloudLibrary!
    private var musicApp: MockMusicApp!
    private var pending: AppleMusicPendingLibraryEdits!
    private var source: EditTestContentSource!
    private var provider: AppleMusicBrowsingProvider!

    override func setUp() {
        super.setUp()
        lookup = MockLibraryLookup()
        cloud = MockCloudLibrary()
        musicApp = MockMusicApp()
        pending = AppleMusicPendingLibraryEdits()
        source = EditTestContentSource()
        provider = AppleMusicBrowsingProvider(
            source: source,
            editor: AppleMusicLibraryEditor(
                lookup: lookup, cloud: cloud, musicApp: musicApp, pending: pending,
                songReferences: AppleMusicSongReferenceRegistry()
            )
        )
    }

    func testEveryProviderEditReachesItsRoute() async throws {
        lookup.songsByID["i.1"] = AppleMusicLibraryEditorTests.librarySong("i.1", catalog: "11", persistent: "000000000000000A")
        lookup.albumsByID["-5"] = AppleMusicAlbumReference(itemID: "-5", catalogID: "50", isInLibrary: true, librarySongs: [
            AppleMusicLibraryEditorTests.librarySong("i.2", catalog: "12", persistent: "000000000000000B"),
        ])
        cloud.createdPlaylistID = "p.new"

        try await provider.saveTracks(ids: ["699902614"])
        try await provider.removeSavedTracks(ids: ["i.1"])
        let songStatuses = try await provider.savedTrackStatuses(ids: ["i.1", "699902614"])
        try await provider.saveAlbums(ids: ["1440"])
        try await provider.removeSavedAlbums(ids: ["-5"])
        let albumStatuses = try await provider.savedAlbumStatuses(ids: ["1440", "-5"])
        let created = try await provider.createPlaylist(userID: "ignored", name: "Spotiglass test", isPublic: true)
        try await provider.addTracksToPlaylist(playlistID: "p.new", uris: ["applemusic:song:i.1"])
        try await provider.removeTracksFromPlaylist(
            playlistID: "-1",
            items: [MusicPlaylistTrackRemoval(uri: "applemusic:song:i.1", positions: [0])],
            snapshotID: nil
        )
        try await provider.updatePlaylist(playlistID: "-1", name: "New")
        try await provider.deletePlaylist(playlistID: "-1")

        XCTAssertEqual(songStatuses, [false, true])
        XCTAssertEqual(albumStatuses, [true, false])
        XCTAssertEqual(created.id, "p.new")
        XCTAssertEqual(created.ownerName, SpotiglassL10n.string("appleMusic.library.owner"))
        XCTAssertEqual(cloud.calls.filter { !$0.hasPrefix("rate") }, [
            "addToLibrary(songs:699902614 albums:)",
            "addToLibrary(songs: albums:1440)",
            "createPlaylist(Spotiglass test)",
            "addToPlaylist(p.new,[songs:11])",
        ])
        XCTAssertEqual(musicApp.calls.count, 5)
    }

    func testReadsShowEditsTheLibraryHasNotCaughtUpWith() async throws {
        source.songs = [
            try AppleMusicFixtures.song(id: "i.kept", title: "Kept"),
            try AppleMusicFixtures.song(id: "i.gone", title: "Gone"),
        ]
        source.tracksByPlaylistID["-1"] = [.song(try AppleMusicFixtures.song(id: "-30", title: "In playlist"))]
        pending.recordRemovedSong(["i.gone"])
        pending.recordCreatedPlaylist(MusicPlaylistSummary(
            id: "p.new", name: "Spotiglass test", ownerID: "apple-music-library", ownerName: "You",
            imageURL: nil, trackCount: 0, snapshotID: "applemusic"
        ))
        pending.recordPlaylistAddition(
            AppleMusicLibraryEditorTests.track(id: "506650076", name: "Added"),
            reference: AppleMusicSongReference(itemID: "506650076", catalogID: "506650076", isInLibrary: true),
            playlistID: "-1"
        )

        let liked = try await provider.currentUserSavedTracks(limit: 50, maxPages: nil)
        let playlists = try await provider.currentUserPlaylists(limit: 50)
        let tracks = try await provider.playlistTracks(playlistID: "-1", limit: 100, maxPages: 1)

        XCTAssertEqual(liked.tracks.compactMap(\.trackID), ["i.kept"])
        XCTAssertEqual(playlists.map(\.id), ["p.new"])
        XCTAssertEqual(tracks.compactMap(\.trackID), ["-30", "506650076"])
    }

    func testANewCloudPlaylistIsReadFromTheAPIUntilTheLibraryHasIt() async throws {
        cloud.playlistSongs = [try AppleMusicFixtures.song(id: "i.9", title: "Disparate Youth")]
        let tracks = try await provider.playlistTracks(playlistID: "p.new", limit: 100, maxPages: 1)
        XCTAssertEqual(tracks.compactMap(\.trackID), ["i.9"])

        do {
            _ = try await provider.playlistTracks(playlistID: "-404", limit: 100, maxPages: 1)
            XCTFail("expected not found")
        } catch {
            XCTAssertEqual(error as? AppleMusicBrowsingError, .notFound)
        }
    }
}

final class MusicDataRequestCloudLibraryTests: XCTestCase {
    func testEditsSendTheirRequests() async throws {
        let paths = PathRecorder()
        let library = MusicDataRequestCloudLibrary { request in
            paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return Data()
        }

        try await library.addToLibrary(songCatalogIDs: ["1"], albumCatalogIDs: [])
        try await library.addToLibrary(songCatalogIDs: [], albumCatalogIDs: [])
        try await library.addToPlaylist(cloudPlaylistID: "p.1", songs: [AppleMusicCloudSong(id: "1", kind: .catalog)])
        try await library.addToPlaylist(cloudPlaylistID: "p.1", songs: [])
        try await library.setRating(.dislike, songID: "1", isLibraryID: false)

        XCTAssertEqual(paths.values, [
            "POST /v1/me/library",
            "POST /v1/me/library/playlists/p.1/tracks",
            "PUT /v1/me/ratings/songs/1",
        ])
    }

    func testPlaylistTracksDecodeLibrarySongs() async throws {
        let library = MusicDataRequestCloudLibrary { _ in
            Data(#"{"data":[{"id":"i.9","type":"library-songs","attributes":{"name":"Disparate Youth","artistName":"Santigold","playParams":{"id":"i.9","kind":"song","catalogId":"506650076","isLibrary":true}}}]}"#.utf8)
        }
        let songs = try await library.playlistTracks(cloudPlaylistID: "p.1")
        XCTAssertEqual(songs.map(\.id.rawValue), ["i.9"])
        XCTAssertEqual(AppleMusicSongIdentity(encoding: songs[0]).catalogID, "506650076")
    }

    func testAnEmptyCreateResponseIsAFailure() async {
        let library = MusicDataRequestCloudLibrary { _ in Data(#"{"data":[]}"#.utf8) }
        await XCTAssertThrowsEditError(.requestFailed) { _ = try await library.createPlaylist(name: "x") }
    }
}

private extension MusicPlaylistTrackItem {
    var trackID: String? {
        if case let .track(track) = content { return track.id }
        return nil
    }
}

final class EditTestContentSource: AppleMusicContentSource, @unchecked Sendable {
    var songs: [Song] = []
    var tracksByPlaylistID: [String: [Track]] = [:]

    func libraryPlaylists(limit: Int, offset: Int) async throws -> [Playlist] { [] }
    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]? { tracksByPlaylistID[playlistID] }
    func librarySongs(limit: Int, offset: Int) async throws -> [Song] { offset == 0 ? songs : [] }
    func recentlyPlayedSongs(limit: Int) async throws -> [Song] { [] }
    func recommendedPlaylists() async throws -> [Playlist] { [] }
    func album(id: String) async throws -> Album? { nil }
    func artist(id: String) async throws -> Artist? { nil }
    func tracks(of album: Album, limit: Int) async throws -> [Track] { [] }
    func albums(of artist: Artist, limit: Int) async throws -> [Album] { [] }
    func artistTopSongs(artistID: String) async throws -> [Song] { [] }
    func catalogSearch(term: String, limit: Int, offset: Int) async throws -> AppleMusicSearchItems { AppleMusicSearchItems() }
    func librarySearch(term: String, limit: Int) async throws -> AppleMusicSearchItems { AppleMusicSearchItems() }
    func storefrontCountryCode() async throws -> String { "ch" }
}
