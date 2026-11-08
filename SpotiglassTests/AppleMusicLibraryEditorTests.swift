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
        makeEditor()
    }

    private func makeEditor() {
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

    /// The time limit starts when the like was sent, with seconds of slack, so a song with the
    /// same details imported minutes earlier is outside it.
    func testTheRecentSongMatchStartsWhenTheLikeWasSent() async throws {
        lookup.catalogTracksByID["699902614"] = Self.track(id: "699902614", name: "Computer Love", album: "Computer World")
        let before = Date()
        try await editor.saveSongs(ids: ["699902614"])
        let after = Date()

        let sent = try XCTUnwrap(pending.savedSong(matching: ["699902614"])?.at)
        XCTAssertGreaterThanOrEqual(sent, before)
        XCTAssertLessThanOrEqual(sent, after)
        XCTAssertLessThanOrEqual(MusicAppScripts.addedSinceMarginSeconds, 10)
        let script = MusicAppScripts.removeFromLibrary(
            [.metadata(name: "Computer Love", artist: "Kraftwerk", album: "Computer World", addedSince: sent)],
            now: sent.addingTimeInterval(120)
        )
        XCTAssertTrue(script.contains("set cutoff to (scriptNow - \(120 + MusicAppScripts.addedSinceMarginSeconds))"), script)
    }

    /// #400 saw Liked Songs drop to one below the right count after liking a catalog song and
    /// unliking it again. This replays that sequence with every order in which the library on
    /// this Mac can catch up (before or after the like shows, before or after the unlike), and
    /// with the row the unlike was sent from in either shape. Every read after the unlike must
    /// show exactly the songs that were there before the like.
    func testLikeThenUnlikeAlwaysLeavesTheCountItStartedWith() async throws {
        let meta = { (name: String) in AppleMusicPendingLibraryEdits.metadataKey(name: name, artist: "Rihanna") }
        let others = [("i.one", "1001", "Umbrella"), ("i.two", "1002", "Diamonds (Remix)"), ("i.three", "1003", "Stay")]
            .map { id, catalog, name in
                (track: Self.track(id: id, name: name, artist: "Rihanna"), keys: Set([id, catalog, meta(name)]))
            }
        let diamonds = (track: Self.track(id: "i.dia", name: "Diamonds", artist: "Rihanna"),
                        keys: Set(["i.dia", "565345164", meta("Diamonds")]))

        for unlikeFromLibraryRow in [false, true] {
            for libraryListsTheUnlikedSong in [false, true] {
                makeEditor()
                lookup.catalogTracksByID["565345164"] = Self.track(
                    id: "565345164", name: "Diamonds", artist: "Rihanna", album: "Unapologetic"
                )
                try await editor.saveSongs(ids: ["565345164"])
                XCTAssertEqual(pending.applied(toLibrarySongs: others, isComplete: true).count, 4, "like, stale read")
                let rowID: String
                if unlikeFromLibraryRow {
                    XCTAssertEqual(pending.applied(toLibrarySongs: [diamonds] + others, isComplete: true).count, 4, "like, caught up")
                    lookup.songsByID["i.dia"] = AppleMusicSongReference(
                        itemID: "i.dia", catalogID: "565345164", cloudLibraryID: "i.dia",
                        musicAppPersistentID: "367911FB05FE6876", isInLibrary: true, title: "Diamonds", artistName: "Rihanna"
                    )
                    rowID = "i.dia"
                } else {
                    rowID = "565345164"
                }

                try await editor.removeSongs(ids: [rowID])

                let read = (libraryListsTheUnlikedSong ? [diamonds] : []) + others
                let shown = pending.applied(toLibrarySongs: read, isComplete: true)
                XCTAssertEqual(shown.map(\.id), others.map(\.track.id),
                               "row \(rowID), library still lists it: \(libraryListsTheUnlikedSong)")
                // A second read (the library catching up) keeps the count.
                XCTAssertEqual(pending.applied(toLibrarySongs: others, isComplete: true).count, 3)
            }
        }
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

    /// AppleScript ignores case: "mix" next to an older "Mix" is a namesake too.
    func testANamesakeThatDiffersOnlyInCaseStopsTheNameFallback() async {
        cloud.createdPlaylistID = "p.new"
        _ = try? await editor.createPlaylist(name: "mix", ownerName: "You")
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.new", name: "mix"), AppleMusicCloudPlaylist(id: "p.old", name: "Mix")]

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

    /// Past the bound the least recently used references go, not the first ones remembered: a
    /// playlist read first and read again keeps its rows editable (#400, #381).
    func testSongReferenceRegistryEvictsTheLeastRecentlyUsed() {
        let registry = AppleMusicSongReferenceRegistry()
        let max = AppleMusicSongReferenceRegistry.maxEntries
        for index in 0..<max {
            registry.remember(AppleMusicSongReference(itemID: "\(index)", isInLibrary: true))
        }
        XCTAssertNotNil(registry.reference(for: "0"), "the first playlist row is used again")
        for index in max..<(2 * max) {
            registry.remember(AppleMusicSongReference(itemID: "\(index)", isInLibrary: true))
            if index.isMultiple(of: 100) { XCTAssertNotNil(registry.reference(for: "0")) }
        }
        XCTAssertNotNil(registry.reference(for: "0"))
        XCTAssertNil(registry.reference(for: "1"), "a reference nobody used again is dropped")
        XCTAssertNotNil(registry.reference(for: "\(2 * max - 1)"))
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
    /// Add a song to a playlist, then remove it from the library before MusicKit lists the
    /// addition: Music takes it out of the playlist, so Spotiglass doesn't keep showing it.
    func testALibraryRemovalEndsPendingPlaylistAdditions() {
        let pending = AppleMusicPendingLibraryEdits()
        let song = AppleMusicLibraryEditorTests.track(id: "506650076", name: "Disparate Youth")
        let reference = AppleMusicSongReference(itemID: "i.9", catalogID: "506650076", isInLibrary: true)
        pending.recordPlaylistAddition(song, reference: reference, playlistID: "-1")
        XCTAssertEqual(pending.applied(toPlaylistTracks: [], playlistID: "-1").map(\.id), ["506650076"])

        pending.recordRemovedSong(reference.matchKeys)

        XCTAssertEqual(pending.applied(toPlaylistTracks: [], playlistID: "-1"), [])
        XCTAssertFalse(pending.hasPendingTracks(playlistID: "-1"))
    }

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
        let id = try await library.createPlaylist(name: "Spotiglass test", songs: [])
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

    /// Library entries by the persistent ID (MusicKit's signed form) they carry.
    var libraryIdentitiesByPersistentID: [String: AppleMusicSongIdentity] = [:]
    func libraryIdentity(of reference: AppleMusicSongReference) async throws -> AppleMusicSongIdentity? {
        reference.musicKitPersistentID.flatMap { libraryIdentitiesByPersistentID[$0] }
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

    var createError: Error?

    func createPlaylist(name: String, songs: [AppleMusicCloudSong]) async throws -> String {
        if let createError { throw createError }
        let list = songs.isEmpty ? "" : ",[\(songs.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: ","))]"
        calls.append("createPlaylist(\(name)\(list))")
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

    func addToPlaylist(_ playlist: MusicAppPlaylistMatch, tracks: [MusicAppTrackMatch]) async throws {
        if let error { throw error }
        calls.append("addToPlaylist(\(Self.describe(playlist)),[\(tracks.map(Self.describe).joined(separator: ", "))])")
    }

    var createdPersistentID = "00000000000000FF"

    func createPlaylist(name: String, tracks: [MusicAppTrackMatch]) async throws -> String {
        if let error { throw error }
        calls.append("createPlaylist(\(name),[\(tracks.map(Self.describe).joined(separator: ", "))])")
        return createdPersistentID
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
    var result: String?
    func run(_ source: String) async throws -> String? {
        lock.withLock { recorded.append(source) }
        return result
    }

    func settle(_ source: String) async throws -> String? {
        lock.withLock { recorded.append(source) }
        return nil
    }
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
        makeEditor()
    }

    private func makeEditor() {
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
        await XCTAssertThrowsEditError(.requestFailed) { _ = try await library.createPlaylist(name: "x", songs: []) }
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
    var playlists: [Playlist] = []

    func libraryPlaylists(limit: Int, offset: Int) async throws -> [Playlist] { offset == 0 ? playlists : [] }
    /// Holds the batch read, with `onLibraryTracks` run once it started.
    var libraryTracksGate: LibraryEditsGate?
    var onLibraryTracks: (@Sendable () -> Void)?

    /// The same tracks as a playlist read: like the real library, they lag behind an edit.
    func libraryPlaylistTracks(playlistIDs: [String]) async throws -> [String: [Track]] {
        let read = tracksByPlaylistID.filter { playlistIDs.contains($0.key) && !$0.value.isEmpty }
        onLibraryTracks?()
        await libraryTracksGate?.wait()
        return read
    }
    func playlistTracks(playlistID: String, limit: Int) async throws -> [Track]? { tracksByPlaylistID[playlistID] }
    func librarySongs(limit: Int, offset: Int) async throws -> [Song] { offset == 0 ? songs : [] }
    func isInLibrary(_ song: Song) -> Bool { true }
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

// MARK: - #395: playlist edits that failed or were left half done

/// The cases found testing a real library (macOS 27): rows of library playlists and library
/// albums are listed only under the Music persistent ID, with no catalog or cloud library ID.
final class AppleMusicPlaylistEditFixTests: XCTestCase {
    private var lookup: MockLibraryLookup!
    private var cloud: MockCloudLibrary!
    private var musicApp: MockMusicApp!
    private var pending: AppleMusicPendingLibraryEdits!
    private var editor: AppleMusicLibraryEditor!

    /// "Don't Stop The Music" in 18P1: the row's ID is the persistent ID, and that is all
    /// MusicKit gives for it.
    private let rowID = "-3017376107758730008"
    private let rowPersistentID = "D620206AAF4A44E8"

    override func setUp() {
        super.setUp()
        lookup = MockLibraryLookup()
        cloud = MockCloudLibrary()
        musicApp = MockMusicApp()
        pending = AppleMusicPendingLibraryEdits()
        editor = AppleMusicLibraryEditor(
            lookup: lookup, cloud: cloud, musicApp: musicApp, pending: pending,
            songReferences: AppleMusicSongReferenceRegistry()
        )
        lookup.songsByID[rowID] = AppleMusicSongReference(
            itemID: rowID, musicAppPersistentID: rowPersistentID, isInLibrary: true,
            title: "Don't Stop The Music", artistName: "Rihanna"
        )
        lookup.playlistsByID["-107247429512612591"] = AppleMusicPlaylistReference(
            name: "Spotiglass test", musicAppPersistentID: "FE82FB07F4D3B511"
        )
    }

    // Item 1

    func testAddingALibraryPlaylistRowToAPlaylistGoesThroughMusic() async throws {
        try await editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: [rowID])

        XCTAssertEqual(musicApp.calls, [
            "addToPlaylist(persistentID(\"FE82FB07F4D3B511\"),[persistentID(\"\(rowPersistentID)\")])",
        ])
        XCTAssertEqual(cloud.calls, [], "the API has no ID for this song")
    }

    /// The real case: 18P1's songs are Apple Music songs listed in the playlist but not in the
    /// library (Music: 0 library tracks with that persistent ID), so Music has to find them in
    /// the playlist they were listed in.
    func testAPlaylistRowNotInTheLibraryIsFoundInItsPlaylist() async throws {
        let registry = AppleMusicSongReferenceRegistry()
        registry.remember(
            [.song(try AppleMusicFixtures.song(id: "-1192152853020385209", title: "Don't Stop The Music", artist: "Rihanna"))],
            playlistID: "-1157253837592488300"
        )
        var reference = try XCTUnwrap(registry.reference(for: "-1192152853020385209"))
        // The real row encodes no catalog or cloud library ID (the fixture does).
        reference.catalogID = nil
        reference.cloudLibraryID = nil
        XCTAssertEqual(reference.musicAppPersistentID, "EF749F4BE5C06047")
        XCTAssertEqual(reference.sourcePlaylistPersistentID, "EFF09BC41F579694")
        lookup.songsByID["-1192152853020385209"] = reference

        try await editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: ["-1192152853020385209"])

        XCTAssertEqual(musicApp.calls, [
            "addToPlaylist(persistentID(\"FE82FB07F4D3B511\"),[playlistEntry(persistentID: \"EF749F4BE5C06047\", playlistPersistentID: \"EFF09BC41F579694\")])",
        ])
    }

    func testMusicLooksForAPlaylistEntryInTheLibraryFirstThenInItsPlaylist() throws {
        let script = MusicAppScripts.addToPlaylist(
            .persistentID("FE82FB07F4D3B511"),
            tracks: [.playlistEntry(persistentID: "EF749F4BE5C06047", playlistPersistentID: "EFF09BC41F579694")]
        )

        let library = try XCTUnwrap(script.range(of: "set found to (every track of lib whose persistent ID is \"EF749F4BE5C06047\")"))
        let source = try XCTUnwrap(script.range(of: "every user playlist whose persistent ID is \"EFF09BC41F579694\""))
        let notFound = try XCTUnwrap(script.range(of: "if (count of found) is 0 then error"))
        XCTAssertLessThan(library.lowerBound, source.lowerBound)
        XCTAssertLessThan(source.lowerBound, notFound.lowerBound)
        // The only delete takes back songs this add appended to the target playlist, by position.
        let deletes = script.components(separatedBy: "\n").filter { $0.contains("delete") }
        XCTAssertEqual(deletes, ["delete track i of pl"])
    }

    func testCatalogSongsStillGoThroughTheAPI() async throws {
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.3VKWkReubWBYJJ7", name: "Spotiglass test")]

        try await editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: ["699902614"])

        XCTAssertEqual(cloud.calls, ["editablePlaylists", "addToPlaylist(p.3VKWkReubWBYJJ7,[songs:699902614])"])
        XCTAssertEqual(musicApp.calls, [])
    }

    func testASongNeitherRouteCanAddIsRefusedBeforeAnythingIsSent() async {
        await XCTAssertThrowsEditError(.notEditable) {
            try await self.editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: ["i.unknown"])
        }
        XCTAssertEqual(cloud.calls, [])
        XCTAssertEqual(musicApp.calls, [])
    }

    // Item 2

    func testNewPlaylistFromALibraryRowIsCreatedWithTheSongInOneMusicStep() async throws {
        musicApp.createdPersistentID = "FE82FB07F4D3B511"

        let summary = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [rowID])

        XCTAssertEqual(musicApp.calls, ["createPlaylist(Spotiglass test,[persistentID(\"\(rowPersistentID)\")])"])
        XCTAssertEqual(cloud.calls, [], "no empty playlist through the API first")
        XCTAssertEqual(summary.id, "-107247429512612591", "the new playlist's persistent ID, the way MusicKit shows it")
        XCTAssertEqual(summary.trackCount, 1)
        XCTAssertEqual(pending.applied(toPlaylists: []).map(\.id), ["-107247429512612591"])
    }

    func testNewPlaylistWithCatalogSongsIsOneAPIRequest() async throws {
        cloud.createdPlaylistID = "p.new"
        lookup.catalogTracksByID["506650076"] = AppleMusicLibraryEditorTests.track(id: "506650076", name: "S&M")

        let summary = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: ["506650076"])

        XCTAssertEqual(cloud.calls, ["createPlaylist(Spotiglass test,[songs:506650076])"])
        XCTAssertEqual(summary.id, "p.new")
        XCTAssertEqual(summary.trackCount, 1)
        XCTAssertTrue(pending.hasPendingTracks(playlistID: "p.new"), "the song shows in the new playlist at once")
    }

    func testANewPlaylistWhoseSongCantBeAddedIsNeverCreated() async {
        await XCTAssertThrowsEditError(.notEditable) {
            _ = try await self.editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: ["i.unknown"])
        }
        XCTAssertEqual(cloud.calls, [])
        XCTAssertEqual(musicApp.calls, [])
        XCTAssertEqual(pending.applied(toPlaylists: []), [])
    }

    func testAFailedCreateThroughTheAPILeavesNothingBehind() async {
        cloud.createError = AppleMusicLibraryEditError.requestFailed

        await XCTAssertThrowsEditError(.requestFailed) {
            _ = try await self.editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: ["506650076"])
        }
        XCTAssertEqual(pending.applied(toPlaylists: []), [])
    }

    func testMusicCreatesThePlaylistOnlyAfterFindingEverySongAndDeletesItOnFailure() throws {
        let script = MusicAppScripts.createPlaylist(name: "Spotiglass \"test\"", tracks: [.persistentID(rowPersistentID)])

        let lookupLine = try XCTUnwrap(script.range(of: "whose persistent ID is \"\(rowPersistentID)\""))
        let makeLine = try XCTUnwrap(script.range(of: "make new user playlist with properties {name:\"Spotiglass \\\"test\\\"\"}"))
        XCTAssertLessThan(lookupLine.lowerBound, makeLine.lowerBound, "a song Music can't find stops it before the playlist exists")
        let rollback = try XCTUnwrap(script.range(of: "end if\nif newID is not \"\" then delete pl\nerror errorMessage number errorNumber"))
        XCTAssertLessThan(makeLine.lowerBound, rollback.lowerBound)
        XCTAssertTrue(script.contains("set newID to (persistent ID of pl)"))
        XCTAssertTrue(script.hasSuffix("return newID\nend tell"))
    }

    func testMusicAddFindsThePlaylistAndEverySongBeforeAddingAny() throws {
        let script = MusicAppScripts.addToPlaylist(.persistentID("FE82FB07F4D3B511"), tracks: [.persistentID(rowPersistentID)])

        let playlist = try XCTUnwrap(script.range(of: "every user playlist whose persistent ID is \"FE82FB07F4D3B511\""))
        let song = try XCTUnwrap(script.range(of: "every track of lib whose persistent ID is \"\(rowPersistentID)\""))
        let duplicate = try XCTUnwrap(script.range(of: "duplicate (contents of songItem) to pl"))
        XCTAssertLessThan(playlist.lowerBound, duplicate.lowerBound)
        XCTAssertLessThan(song.lowerBound, duplicate.lowerBound)
    }

    /// Every script compiles against Music's own dictionary. A variable named like one of its
    /// classes ("source", "track") stops the script before it runs (-2741, seen in a real run).
    func testEveryMusicScriptCompiles() throws {
        let track = MusicAppTrackMatch.persistentID(rowPersistentID)
        let saved = MusicAppTrackMatch.metadata(name: "S&M", artist: "Rihanna", album: "Loud", addedSince: Date())
        let playlist = MusicAppPlaylistMatch.persistentID("FE82FB07F4D3B511")
        let entry = MusicAppTrackMatch.playlistEntry(persistentID: rowPersistentID, playlistPersistentID: "EFF09BC41F579694")
        let scripts = [
            MusicAppScripts.addToPlaylist(playlist, tracks: [track, saved, entry]),
            MusicAppScripts.createPlaylist(name: "Spotiglass test", tracks: [track, saved]),
            MusicAppScripts.removeFromLibrary([track, saved]),
            MusicAppScripts.removeFromPlaylist(playlist, removals: [MusicAppPlaylistRemoval(track: saved, positions: [0, 2])]),
            MusicAppScripts.renamePlaylist(.name("Spotiglass test"), to: "Renamed"),
            MusicAppScripts.deletePlaylist(playlist),
        ] + [
            // What an edit runs after one of its changes answered late (#411), as the runner sends it.
            MusicAppScripts.finishRemovingFromLibrary([track, saved]),
            MusicAppScripts.finishRemovingFromPlaylist(playlist, entryIDs: ["4021", "4022"]),
            MusicAppScripts.finishRenaming(.name("Spotiglass test"), to: "Renamed"),
            MusicAppScripts.finishRenaming(playlist, to: "Renamed"),
            MusicAppScripts.finishDeleting(playlist),
            MusicAppScripts.takeBackAdd(playlist, progress: "5|\(rowPersistentID),EF749F4BE5C06047|"),
            MusicAppScripts.takeBackCreate(name: "Spotiglass test", progress: "FE82FB07F4D3B512|"),
            MusicAppScripts.takeBackCreate(name: "Spotiglass test", progress: "|FE82FB07F4D3B512"),
        ].map { MusicAppScripts.settling($0, seconds: 600) }
        for source in scripts {
            let timed = MusicAppScripts.withTimeout(source, seconds: 60)
            let script = try XCTUnwrap(NSAppleScript(source: timed))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])\n\(timed)")
        }
    }

    func testMusicPlaylistIDsMustComeBackAsHex() async {
        let runner = StubScriptRunner(result: "not an id")
        await XCTAssertThrowsEditError(.requestFailed) {
            _ = try await MusicAppLibraryScripting(runner: runner).createPlaylist(name: "x", tracks: [.persistentID(self.rowPersistentID)])
        }
        let created = try? await MusicAppLibraryScripting(runner: StubScriptRunner(result: "FE82FB07F4D3B511\n"))
            .createPlaylist(name: "x", tracks: [.persistentID(rowPersistentID)])
        XCTAssertEqual(created, "FE82FB07F4D3B511")
    }

    func testTheCreateRequestCarriesItsSongs() throws {
        let create = AppleMusicCloudRequests.createPlaylist(name: "Spotiglass test", songs: [
            AppleMusicCloudSong(id: "506650076", kind: .catalog),
            AppleMusicCloudSong(id: "i.9", kind: .library),
        ])
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(create.httpBody), as: UTF8.self),
            #"{"attributes":{"description":"","name":"Spotiglass test"},"relationships":{"tracks":{"data":[{"id":"506650076","type":"songs"},{"id":"i.9","type":"library-songs"}]}}}"#
        )
    }

    // Item 3

    func testANewPlaylistsCountFollowsItsEdits() async throws {
        cloud.createdPlaylistID = "p.new"
        _ = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: ["506650076"])
        lookup.songsByID["506650076"] = AppleMusicSongReference(
            itemID: "506650076", catalogID: "506650076", musicAppPersistentID: "0000000000000001", isInLibrary: true
        )

        try await editor.removeFromPlaylist(playlistID: "p.new", removals: [(songID: "506650076", positions: [0])], shownCounts: [1])

        XCTAssertEqual(pending.applied(toPlaylists: []).first?.trackCount, 0, "not the 1 it was created with")
    }

    func testOnlyCatalogPlaylistIDsAreAskedOfTheCatalog() {
        XCTAssertTrue(MusicKitContentSource.isLibraryPlaylistID("p.3VKWkReubWBYJJ7"))
        XCTAssertTrue(MusicKitContentSource.isLibraryPlaylistID("-107247429512612591"))
        XCTAssertFalse(MusicKitContentSource.isLibraryPlaylistID("pl.u-8aAVZAeIqoJKV"))
        XCTAssertFalse(MusicKitContentSource.isLibraryPlaylistID("pl.f4d106fed2bd41149aaacabb233eb5eb"))
    }

    /// The library lookup found the song itself (not through a remembered row): the page still
    /// opens instead of failing, and shows the song the sidebar counts.
    func testAPlaylistMusicCreatedMomentsAgoOpensWithItsSongInsteadOfFailing() async throws {
        let song = try AppleMusicFixtures.song(id: rowID, title: "Don't Stop The Music", artist: "Rihanna")
        // A library song: MusicKit gives it the date it was added.
        var found = MusicKitLibraryLookup.reference(
            song, identity: AppleMusicSongIdentity(encoding: song), itemID: rowID, isInLibrary: true
        )
        found.catalogID = nil
        found.cloudLibraryID = nil
        lookup.songsByID[rowID] = found
        musicApp.createdPersistentID = "FE82FB07F4D3B511"
        let created = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [rowID])
        let provider = AppleMusicBrowsingProvider(source: EditTestContentSource(), editor: editor)

        let items = try await provider.playlistTracks(playlistID: created.id, limit: 100, maxPages: 1)

        XCTAssertEqual(Self.names(items), ["Don't Stop The Music"])
    }

    private static func names(_ items: [MusicPlaylistTrackItem]) -> [String] {
        items.compactMap { item in
            guard case let .track(track) = item.content else { return nil }
            return track.name
        }
    }

    /// The 18P1 row the way the provider remembers it when it reads that playlist: no catalog or
    /// cloud library ID, only the persistent ID and the row itself.
    private func remembered18P1Row() throws -> AppleMusicSongReference {
        let registry = AppleMusicSongReferenceRegistry()
        registry.remember(
            [.song(try AppleMusicFixtures.song(id: "-1192152853020385209", title: "Don't Stop The Music", artist: "Rihanna"))],
            playlistID: "-1157253837592488300"
        )
        var reference = try XCTUnwrap(registry.reference(for: "-1192152853020385209"))
        reference.catalogID = nil
        reference.cloudLibraryID = nil
        lookup.songsByID[reference.itemID] = reference
        return reference
    }

    func testANewPlaylistFromALibraryRowShowsItsSongBeforeTheLibraryListsIt() async throws {
        let row = try remembered18P1Row()
        musicApp.createdPersistentID = "FE82FB07F4D3B512"
        let created = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [row.itemID])
        let provider = AppleMusicBrowsingProvider(source: EditTestContentSource(), editor: editor)

        let items = try await provider.playlistTracks(playlistID: created.id, limit: 100, maxPages: 1)

        XCTAssertEqual(Self.names(items), ["Don't Stop The Music"], "the sidebar says 1 track, so the page shows it")
    }

    /// #407 after #395: the library can take hours to show an add made from Spotiglass, so
    /// neither a refresh nor the count lookup may bring back the count from before the add.
    func testAPlaylistEditedFromSpotiglassIsCountedWithTheEdit() async throws {
        let row = try remembered18P1Row()
        let playlistID = "-107247429512612591"
        let source = EditTestContentSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: playlistID, name: "Spotiglass test")]
        source.tracksByPlaylistID[playlistID] = [.song(try AppleMusicFixtures.song(id: "i.1", title: "One", artist: "Someone"))]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        _ = try await provider.currentUserPlaylists(limit: 50)
        let before = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(before, [playlistID: 1])

        try await provider.addTracksToPlaylist(playlistID: playlistID, uris: ["applemusic:song:\(row.itemID)"])

        let listed = try await provider.currentUserPlaylists(limit: 50)
        XCTAssertNil(listed.first?.trackCount, "the count from before the add stays out of the listing")
        let after = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(after, [playlistID: 2], "counted like the open playlist, with the added song")
    }

    /// A song removed from the library leaves every playlist (Music takes it out); while the
    /// library still lists it there, the count leaves it out like the open playlist does.
    func testASongRemovedFromTheLibraryIsNotCountedInItsPlaylists() async throws {
        let playlistID = "-107247429512612591"
        let source = EditTestContentSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: playlistID, name: "Spotiglass test")]
        source.tracksByPlaylistID[playlistID] = [
            .song(try AppleMusicFixtures.song(id: rowID, title: "Don't Stop The Music", artist: "Rihanna")),
            .song(try AppleMusicFixtures.song(id: "i.1", title: "One", artist: "Someone")),
        ]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        _ = try await provider.currentUserPlaylists(limit: 50)
        let before = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(before, [playlistID: 2])

        try await provider.removeSavedTracks(ids: [rowID])

        let listed = try await provider.currentUserPlaylists(limit: 50)
        XCTAssertNil(listed.first?.trackCount, "the count with the removed song stays out of the listing")
        let after = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        let shown = try await provider.playlistTracks(playlistID: playlistID, limit: 100, maxPages: 1)
        XCTAssertEqual(after, [playlistID: 1])
        XCTAssertEqual(after[playlistID], shown.count, "the sidebar and the open playlist agree")
    }

    /// Once the library shows a removal from Spotiglass, the count kept from before it must
    /// not come back: the playlist's version doesn't always change.
    func testACountFromBeforeALibraryRemovalDoesNotComeBack() async throws {
        let playlistID = "-107247429512612591"
        let source = EditTestContentSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: playlistID, name: "Spotiglass test")]
        let removed = Track.song(try AppleMusicFixtures.song(id: rowID, title: "Don't Stop The Music", artist: "Rihanna"))
        let kept = Track.song(try AppleMusicFixtures.song(id: "i.1", title: "One", artist: "Someone"))
        source.tracksByPlaylistID[playlistID] = [removed, kept]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        _ = try await provider.currentUserPlaylists(limit: 50)
        _ = await provider.playlistTrackCounts(playlistIDs: [playlistID])

        try await provider.removeSavedTracks(ids: [rowID])
        let whileListed = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(whileListed, [playlistID: 1])
        // The library catches up: a complete library read no longer lists the song.
        source.tracksByPlaylistID[playlistID] = [kept]
        _ = pending.applied(toLibrarySongs: [], isComplete: true)
        XCTAssertFalse(pending.hasRemovedSongs)

        let listed = try await provider.currentUserPlaylists(limit: 50)
        XCTAssertNotEqual(listed.first?.trackCount, 2, "the count from before the removal is gone")
        let counted = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(counted, [playlistID: 1])
    }

    /// A playlist left out of the batch read because it had an edit, whose edit the library
    /// shows while that read runs, is still counted.
    func testAPlaylistWhoseEditClearsDuringTheBatchIsStillCounted() async throws {
        let row = try remembered18P1Row()
        let edited = "-107247429512612591"
        let other = "-2"
        let source = EditTestContentSource()
        source.playlists = [
            try AppleMusicFixtures.playlist(id: edited, name: "Spotiglass test"),
            try AppleMusicFixtures.playlist(id: other, name: "Other"),
        ]
        let one = Track.song(try AppleMusicFixtures.song(id: "i.1", title: "One", artist: "Someone"))
        source.tracksByPlaylistID[edited] = [one]
        source.tracksByPlaylistID[other] = [one]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        _ = try await provider.currentUserPlaylists(limit: 50)
        try await provider.addTracksToPlaylist(playlistID: edited, uris: ["applemusic:song:\(row.itemID)"])
        XCTAssertTrue(pending.hasPendingTracks(playlistID: edited))

        let gate = LibraryEditsGate()
        let started = LibraryEditsGate()
        source.libraryTracksGate = gate
        source.onLibraryTracks = { started.open() }
        let counting = Task { await provider.playlistTrackCounts(playlistIDs: [edited, other]) }
        await started.wait()
        source.libraryTracksGate = nil
        // The library lists the added song now, and opening the playlist sees it.
        source.tracksByPlaylistID[edited] = [one, .song(try AppleMusicFixtures.song(id: row.itemID, title: "Don't Stop The Music", artist: "Rihanna"))]
        _ = try await provider.playlistTracks(playlistID: edited, limit: 100, maxPages: 1)
        XCTAssertFalse(pending.hasPendingTracks(playlistID: edited))
        gate.open()
        let counts = await counting.value

        XCTAssertEqual(counts, [edited: 2, other: 1])
    }

    /// While a removal from the library is pending, counts are still kept (without the removed
    /// song), so a refresh doesn't read every playlist again for hours.
    func testCountsAreKeptWhileALibraryRemovalIsPending() async throws {
        let playlistID = "-107247429512612591"
        let source = EditTestContentSource()
        source.playlists = [try AppleMusicFixtures.playlist(id: playlistID, name: "Spotiglass test")]
        source.tracksByPlaylistID[playlistID] = [
            .song(try AppleMusicFixtures.song(id: rowID, title: "Don't Stop The Music", artist: "Rihanna")),
            .song(try AppleMusicFixtures.song(id: "i.1", title: "One", artist: "Someone")),
        ]
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)
        try await provider.removeSavedTracks(ids: [rowID])
        XCTAssertTrue(pending.hasRemovedSongs)
        _ = try await provider.currentUserPlaylists(limit: 50)
        let counted = await provider.playlistTrackCounts(playlistIDs: [playlistID])
        XCTAssertEqual(counted, [playlistID: 1])

        let listed = try await provider.currentUserPlaylists(limit: 50)
        XCTAssertEqual(listed.first?.trackCount, 1, "kept, without the removed song")
    }

    func testALibraryRowAddedToAPlaylistShowsThereBeforeTheLibraryListsIt() async throws {
        let row = try remembered18P1Row()
        let source = EditTestContentSource()
        source.tracksByPlaylistID["-107247429512612591"] = []
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)

        try await editor.addToPlaylist(playlistID: "-107247429512612591", songIDs: [row.itemID])
        let items = try await provider.playlistTracks(playlistID: "-107247429512612591", limit: 100, maxPages: 1)

        XCTAssertEqual(Self.names(items), ["Don't Stop The Music"])
    }

    func testACatalogSongGoesIntoAPlaylistMusicCreatedMomentsAgo() async throws {
        musicApp.createdPersistentID = "FE82FB07F4D3B512"
        let created = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [rowID])
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.fromMusic", name: "Spotiglass test")]

        try await editor.addToPlaylist(playlistID: created.id, songIDs: ["699902614"])

        XCTAssertEqual(cloud.calls, ["editablePlaylists", "addToPlaylist(p.fromMusic,[songs:699902614])"])
    }

    func testACatalogSongWaitsWhileTheCloudDoesNotListAPlaylistMusicJustCreated() async throws {
        musicApp.createdPersistentID = "FE82FB07F4D3B512"
        let created = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [rowID])

        await XCTAssertThrowsEditError(.notInMusicYet) {
            try await self.editor.addToPlaylist(playlistID: created.id, songIDs: ["699902614"])
        }
    }

    /// Created through Music, then renamed to the name an older playlist has: the cloud list
    /// shows only the older one, which must never get the song.
    func testACatalogSongIsNeverAddedToAnOlderPlaylistWithTheNewName() async throws {
        musicApp.createdPersistentID = "FE82FB07F4D3B512"
        let created = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [rowID])
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.older", name: "Spotiglass mix")]
        try await editor.renamePlaylist(playlistID: created.id, name: "Spotiglass mix")

        await XCTAssertThrowsEditError(.notInMusicYet) {
            try await self.editor.addToPlaylist(playlistID: created.id, songIDs: ["699902614"])
        }
        XCTAssertFalse(cloud.calls.contains { $0.hasPrefix("addToPlaylist") })
    }

    func testAMusicAddThatFailsPartwayTakesBackWhatItAdded() throws {
        let script = MusicAppScripts.addToPlaylist(
            .persistentID("FE82FB07F4D3B511"),
            tracks: [.persistentID(rowPersistentID), .persistentID("EF749F4BE5C06047")]
        )

        let before = try XCTUnwrap(script.range(of: "set countBefore to (count of tracks of pl)"))
        let noted = try XCTUnwrap(script.range(of: "set end of addedIDs to songID"))
        let add = try XCTUnwrap(script.range(of: "duplicate (contents of songItem) to pl"))
        let rollback = try XCTUnwrap(script.range(of: "end if\nrepeat with i from (count of tracks of pl) to (countBefore + 1) by -1"))
        XCTAssertLessThan(before.lowerBound, add.lowerBound)
        // Noted only once its add went through: a failed add must not claim a copy another
        // device appended meanwhile.
        XCTAssertLessThan(add.lowerBound, noted.lowerBound)
        XCTAssertLessThan(noted.lowerBound, rollback.lowerBound)
        // A song another device appended meanwhile has another persistent ID and stays.
        let guarded = try XCTUnwrap(script.range(of: "if addedIDs contains entryID then\ndelete track i of pl"))
        XCTAssertLessThan(rollback.lowerBound, guarded.lowerBound)
        XCTAssertTrue(script.contains("error errorMessage number errorNumber\nend try"), "the failure still reaches the editor")
    }

    func testACatalogSongIsNeverAddedToANamesakeOfAPlaylistMusicJustCreated() async throws {
        musicApp.createdPersistentID = "FE82FB07F4D3B512"
        let created = try await editor.createPlaylist(
            name: "Spotiglass test", ownerName: "You", songIDs: [rowID], existingIDsWithSameName: ["p.older"]
        )
        cloud.playlists = [AppleMusicCloudPlaylist(id: "p.older", name: "Spotiglass test")]

        await XCTAssertThrowsEditError(.ambiguousPlaylist) {
            try await self.editor.addToPlaylist(playlistID: created.id, songIDs: ["699902614"])
        }
        XCTAssertFalse(cloud.calls.contains { $0.hasPrefix("addToPlaylist") })
    }

    /// Unliked moments ago, then put into a new playlist: like an add, that brings it back, so
    /// the pending removal must not hide it in the new playlist.
    func testANewPlaylistBringsBackASongRemovedMomentsAgo() async throws {
        cloud.createdPlaylistID = "p.new"
        lookup.catalogTracksByID["506650076"] = AppleMusicLibraryEditorTests.track(id: "506650076", name: "S&M")
        pending.recordRemovedSong(["506650076"])

        _ = try await editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: ["506650076"])

        XCTAssertFalse(pending.isRemoved(["506650076"]))
    }

    /// A destination with more distinct songs than the registry holds: reading it before the
    /// add must not cost the 18P1 row its playlist, or Music looks for it in the library only.
    func testReadingALongDestinationKeepsTheRowBeingAdded() async throws {
        let registry = AppleMusicSongReferenceRegistry()
        let registryLookup = RegistryLookup(registry: registry, playlists: lookup.playlistsByID)
        let editor = AppleMusicLibraryEditor(
            lookup: registryLookup, cloud: cloud, musicApp: musicApp, pending: pending, songReferences: registry
        )
        registry.remember(
            [.song(try AppleMusicFixtures.song(id: "-1192152853020385209", title: "Don't Stop The Music", artist: "Rihanna"))],
            playlistID: "-1157253837592488300"
        )
        // The real row encodes no catalog or cloud library ID (the fixture does).
        var row = try XCTUnwrap(registry.reference(for: "-1192152853020385209"))
        row.catalogID = nil
        row.cloudLibraryID = nil
        registry.remember(row)
        let source = EditTestContentSource()
        source.tracksByPlaylistID["-107247429512612591"] = try (1...AppleMusicSongReferenceRegistry.maxEntries).map {
            .song(try AppleMusicFixtures.song(id: "-\($0)", title: "Song \($0)", artist: "Someone"))
        }
        let provider = AppleMusicBrowsingProvider(source: source, editor: editor)

        try await provider.addTracksToPlaylist(playlistID: "-107247429512612591", uris: ["applemusic:song:-1192152853020385209"])

        XCTAssertEqual(musicApp.calls.last?.contains("playlistEntry(persistentID: \"EF749F4BE5C06047\", playlistPersistentID: \"EFF09BC41F579694\")"), true)
    }

    // Item 4

    func testALibrarySongReadsAsLikedBeforeAnyLookup() {
        XCTAssertEqual(editor.knownSongStatus(id: "i.aJGomv4H36dmrrA"), true)
        XCTAssertNil(editor.knownSongStatus(id: "699902614"), "a catalog song needs the lookup")
        // A persistent ID no read remembers can be a song that is only in a playlist (#401).
        XCTAssertNil(editor.knownSongStatus(id: rowID), "a forgotten playlist row needs the lookup")
        pending.recordRemovedSong([rowID])
        XCTAssertEqual(editor.knownSongStatus(id: rowID), false, "removed moments ago")
    }

    // Item 5

    @MainActor
    func testScriptsRunOffTheMainThreadWithATimeout() async throws {
        let seen = ScriptCapture()
        let runner = AppleEventMusicAppScriptRunner(prepare: {}, execute: { source in
            seen.record(source: source, onMain: Thread.isMainThread)
            return "done"
        })

        let result = try await runner.run("tell application \"Music\" to get name")

        XCTAssertEqual(result, "done")
        XCTAssertEqual(seen.onMain, false, "Music's answer must never block the windows")
        XCTAssertEqual(seen.source, "with timeout of 60 seconds\ntell application \"Music\" to get name\nend timeout")
    }

    func testAMusicThatDoesNotAnswerReadsAsUnavailable() {
        XCTAssertEqual(MusicAppScripts.editError(forScriptErrorNumber: -1712), .musicUnavailable)
    }
}

/// The live lookup's order: a remembered row first, else a bare persistent-ID reference.
private final class RegistryLookup: AppleMusicLibraryLookup, @unchecked Sendable {
    let registry: AppleMusicSongReferenceRegistry
    let playlists: [String: AppleMusicPlaylistReference]

    init(registry: AppleMusicSongReferenceRegistry, playlists: [String: AppleMusicPlaylistReference]) {
        self.registry = registry
        self.playlists = playlists
    }

    func songs(ids: [String]) async throws -> [AppleMusicSongReference] {
        ids.map { id in
            registry.reference(for: id) ?? AppleMusicSongReference(
                itemID: id,
                musicAppPersistentID: AppleMusicLibraryEditor.musicAppPersistentID(fromMusicKitID: id),
                isInLibrary: true
            )
        }
    }

    func catalogTracks(ids: [String]) async throws -> [MusicTrack] { [] }
    func catalogAlbumTracks(albumIDs: [String]) async throws -> [MusicTrack] { [] }
    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference] { [] }
    func playlist(id: String) async throws -> AppleMusicPlaylistReference? { playlists[id] }
    func libraryIdentity(of reference: AppleMusicSongReference) async throws -> AppleMusicSongIdentity? { nil }
}

private final class StubScriptRunner: MusicAppScriptRunning, @unchecked Sendable {
    let result: String?
    init(result: String?) { self.result = result }
    func run(_ source: String) async throws -> String? { result }
    func settle(_ source: String) async throws -> String? { nil }
}

private final class ScriptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (source: String?, onMain: Bool?) = (nil, nil)
    var source: String? { lock.withLock { values.source } }
    var onMain: Bool? { lock.withLock { values.onMain } }
    func record(source: String, onMain: Bool) { lock.withLock { values = (source, onMain) } }
}

// MARK: - A change Music answers after the timeout (#411)

/// Music runs a slow change to the end even after AppleScript stopped waiting for it. Each test
/// replays that: the edit script's change times out (`MusicAppLateChange`, as the real script
/// reports it), Music finishes it meanwhile, and the edit has to end in a state it reports truthfully.
final class AppleMusicLateMusicChangeTests: XCTestCase {
    private var lookup: MockLibraryLookup!
    private var cloud: MockCloudLibrary!
    private var runner: LateChangeRunner!
    private var pending: AppleMusicPendingLibraryEdits!
    private var editor: AppleMusicLibraryEditor!

    /// "Don't Stop The Music" and "S&M" from 18P1, and the throwaway playlist.
    private let rowID = "-1192152853020385209"
    private let rowPersistentID = "EF749F4BE5C06047"
    private let secondRowID = "3098427437907169779"
    private let secondPersistentID = "2AFFD356AEC7D1F3"
    private let playlistID = "-107247429512612591"

    override func setUp() {
        super.setUp()
        lookup = MockLibraryLookup()
        cloud = MockCloudLibrary()
        runner = LateChangeRunner()
        pending = AppleMusicPendingLibraryEdits()
        editor = AppleMusicLibraryEditor(
            lookup: lookup, cloud: cloud, musicApp: MusicAppLibraryScripting(runner: runner), pending: pending,
            songReferences: AppleMusicSongReferenceRegistry()
        )
        lookup.songsByID[rowID] = AppleMusicSongReference(
            itemID: rowID, musicAppPersistentID: rowPersistentID, isInLibrary: true,
            title: "Don't Stop The Music", artistName: "Rihanna"
        )
        lookup.songsByID[secondRowID] = AppleMusicSongReference(
            itemID: secondRowID, musicAppPersistentID: secondPersistentID, isInLibrary: true,
            title: "S&M", artistName: "Rihanna"
        )
        lookup.playlistsByID[playlistID] = AppleMusicPlaylistReference(
            name: "Spotiglass test", musicAppPersistentID: "FE82FB07F4D3B511"
        )
    }

    func testAnUnlikeWhoseDeleteAnswersLateIsFinishedAndShown() async throws {
        runner.lateProgress = ""

        try await editor.removeSongs(ids: [rowID, secondRowID])

        let settle = try XCTUnwrap(runner.settled.first)
        XCTAssertTrue(settle.contains("persistent ID is \"\(rowPersistentID)\""))
        XCTAssertTrue(settle.contains("persistent ID is \"\(secondPersistentID)\""))
        // Gone already means the late delete took it; nothing errors on it.
        XCTAssertTrue(settle.contains("if (count of found) is 1 then delete (item 1 of found)"))
        XCTAssertFalse(settle.contains("number \(MusicAppScripts.notFoundError)"))
        XCTAssertTrue(pending.isRemoved([rowID]), "Liked Songs shows the removal")
    }

    func testAnAddThatAnswersLateIsTakenBackOnceMusicIsDone() async throws {
        // Music had 5 songs in the playlist, added the first song and was still adding the second.
        runner.lateProgress = "5|\(rowPersistentID)|\(secondPersistentID)"

        await XCTAssertThrowsEditError(.musicUnavailable) {
            try await self.editor.addToPlaylist(playlistID: self.playlistID, songIDs: [self.rowID, self.secondRowID])
        }

        let settle = try XCTUnwrap(runner.settled.first)
        XCTAssertTrue(settle.contains("persistent ID is \"FE82FB07F4D3B511\""))
        XCTAssertTrue(settle.contains("set countBefore to 5"))
        XCTAssertTrue(settle.contains("set addedIDs to {\"\(rowPersistentID)\", \"\(secondPersistentID)\"}"))
        XCTAssertTrue(settle.contains("if addedIDs contains entryID then\ndelete track i of pl"))
        XCTAssertFalse(pending.hasPendingTracks(playlistID: playlistID), "the playlist shows no add that didn't stay")
    }

    func testANewPlaylistThatAnswersLateIsDeletedAgain() async throws {
        lookup.songsByID[rowID]?.sourcePlaylistPersistentID = "EFF09BC41F579694"
        runner.lateProgress = "FE82FB07F4D3B512|"

        await XCTAssertThrowsEditError(.musicUnavailable) {
            _ = try await self.editor.createPlaylist(name: "Spotiglass test", ownerName: "You", songIDs: [self.rowID])
        }

        XCTAssertEqual(runner.settled, [
            "tell application \"Music\"\ndelete (every user playlist whose persistent ID is \"FE82FB07F4D3B512\")\nend tell",
        ])
    }

    func testAPlaylistMusicMadeLateIsFoundAmongTheNamesakes() {
        // The make itself answered late, so the script never learned the new playlist's ID.
        let settle = MusicAppScripts.takeBackCreate(name: "Spotiglass test", progress: "|AAAAAAAAAAAAAAAA")

        XCTAssertTrue(settle.contains("set namesakesBefore to {\"AAAAAAAAAAAAAAAA\"}"))
        XCTAssertTrue(settle.contains("repeat with candidate in (every user playlist whose name is \"Spotiglass test\")"))
        XCTAssertTrue(settle.contains("if (count of made) is 1 then delete (item 1 of made)"))
    }

    /// The namesake search, run for real on stand-in playlists: one new namesake is the one this
    /// edit made; two (one made on another device during the wait) can't be told apart.
    func testOnlyAPlaylistThatIsClearlyTheNewOneIsDeleted() throws {
        let settle = MusicAppScripts.takeBackCreate(name: "Spotiglass test", progress: "|AAAA")
        let start = try XCTUnwrap(settle.range(of: "set made to {}")?.lowerBound)
        let end = try XCTUnwrap(settle.range(of: "end tell", options: .backwards)?.lowerBound)
        let search = String(settle[start..<end])
            .replacingOccurrences(of: "(every user playlist whose name is \"Spotiglass test\")", with: "namesakes")
            .replacingOccurrences(of: "(persistent ID of candidate)", with: "(contents of candidate)")
            .replacingOccurrences(of: "delete (item 1 of made)", with: "return \"deleted \" & (item 1 of made)")
        func run(_ namesakes: [String]) throws -> String? {
            let list = namesakes.map { "\"\($0)\"" }.joined(separator: ", ")
            let source = "set namesakesBefore to {\"AAAA\"}\nset namesakes to {\(list)}\n\(search)\nreturn \"kept\""
            return try AppleEventMusicAppScriptRunner.executeAppleScript(source)
        }

        XCTAssertEqual(try run(["AAAA", "BBBB"]), "deleted BBBB")
        XCTAssertEqual(try run(["AAAA"]), "kept", "the make never happened")
        XCTAssertThrowsError(try run(["AAAA", "BBBB", "CCCC"])) { error in
            XCTAssertEqual(error as? AppleMusicLibraryEditError, .ambiguousPlaylist)
        }
    }

    func testAPlaylistRemovalThatAnswersLateDeletesTheEntriesItPicked() async throws {
        runner.lateProgress = "4021,4022"

        try await editor.removeFromPlaylist(
            playlistID: playlistID, removals: [(songID: rowID, positions: [0, 3])], shownCounts: [2]
        )

        XCTAssertEqual(runner.settled.first?.contains("delete (every track of pl whose id is 4021)\ndelete (every track of pl whose id is 4022)"), true)
        XCTAssertTrue(pending.hasPendingTracks(playlistID: playlistID), "the page shows the removal")
    }

    func testARenameOrDeleteThatAnswersLateIsFinished() async throws {
        runner.lateProgress = ""
        try await editor.renamePlaylist(playlistID: playlistID, name: "Renamed")
        try await editor.deletePlaylist(playlistID: playlistID)

        XCTAssertEqual(runner.settled.count, 2)
        XCTAssertTrue(runner.settled[0].contains("set name of pl to \"Renamed\""))
        XCTAssertTrue(runner.settled[1].hasPrefix(
            "tell application \"Music\"\nif (count of (every user playlist whose persistent ID is \"FE82FB07F4D3B511\")) is 0 then return"
        ), "a playlist the late delete took is done")
    }

    func testARenameByNameIsDoneOnceTheNewNameIsThere() {
        let settle = MusicAppScripts.finishRenaming(.name("Spotiglass test"), to: "Renamed")

        XCTAssertTrue(settle.contains(
            "if (count of (every user playlist whose name is \"Spotiglass test\")) is 0 and (count of (every user playlist whose name is \"Renamed\")) is greater than 0 then return"
        ))
    }

    /// An unlike timed out, Music carried the delete out, then quit before the settle got an
    /// answer: the song may be gone, so "Music didn't respond, try again" would be untrue.
    func testASettleThatFailsAnyOtherWaySaysTheChangeMayStillHappen() async {
        runner.lateProgress = ""
        runner.settleError = AppleMusicLibraryEditError.musicUnavailable

        await XCTAssertThrowsEditError(.musicStillBusy) {
            try await self.editor.removeSongs(ids: [self.rowID])
        }
        runner.settleError = AppleMusicLibraryEditError.notInMusicYet
        await XCTAssertThrowsEditError(.musicStillBusy) {
            try await self.editor.removeSongs(ids: [self.rowID])
        }
        runner.settleError = AppleMusicLibraryEditError.ambiguousSong
        // Two songs that match alike is a state worth naming as it is.
        await XCTAssertThrowsEditError(.ambiguousSong) {
            try await self.editor.removeSongs(ids: [self.rowID])
        }
    }

    func testAMusicThatStaysBusySaysTheChangeMayStillHappen() async {
        runner.lateProgress = ""
        runner.settleError = AppleMusicLibraryEditError.musicStillBusy

        await XCTAssertThrowsEditError(.musicStillBusy) {
            try await self.editor.removeSongs(ids: [self.rowID])
        }
        XCTAssertFalse(pending.isRemoved([rowID]), "nothing is shown as done while it is unknown")
        XCTAssertEqual(AppleMusicLibraryEditError.musicStillBusy.errorDescription?.isEmpty, false)
    }

    // The AppleScript parts, run for real (no Music needed: `error … number -1712` is exactly
    // what a change that timed out raises).

    func testAChangeThatTimesOutReportsItsProgress() throws {
        let source = (
            ["set targetIDs to {4021, 4022}"]
                + MusicAppScripts.changes(["error \"Music got a time out.\" number -1712"], progress: "(targetIDs as text)")
        ).joined(separator: "\n")

        XCTAssertThrowsError(try AppleEventMusicAppScriptRunner.executeAppleScript(source)) { error in
            XCTAssertEqual(error as? MusicAppLateChange, MusicAppLateChange(progress: "4021,4022"))
        }
    }

    func testAnAddThatTimesOutReportsWhatItAdded() throws {
        // The add script's change part up to its timeout branch (the rollback after it needs
        // Music's dictionary), with Music's add replaced by the timeout it answered with.
        let script = MusicAppScripts.addToPlaylist(.persistentID("FE82FB07F4D3B511"), tracks: [.persistentID(rowPersistentID)])
        let start = try XCTUnwrap(script.range(of: "set countBefore to (count of tracks of pl)"))
        let branch = try XCTUnwrap(script.range(of: "number \(MusicAppScripts.lateChangeError)\nend if", range: start.upperBound..<script.endIndex))
        var part = (String(script[start.lowerBound..<branch.upperBound]) + "\nerror errorMessage number errorNumber\nend try")
            .replacingOccurrences(of: "set countBefore to (count of tracks of pl)", with: "set countBefore to 5")
            .replacingOccurrences(of: "repeat with songItem in pickedSongs", with: "repeat with songItem in {\"A1\", \"B2\"}")
            .replacingOccurrences(of: "set songID to (persistent ID of (contents of songItem))", with: "set songID to (contents of songItem)")
        part = part.replacingOccurrences(
            of: "duplicate (contents of songItem) to pl",
            with: "if songID is \"B2\" then error \"Music got a time out.\" number -1712"
        )

        XCTAssertThrowsError(try AppleEventMusicAppScriptRunner.executeAppleScript(part)) { error in
            XCTAssertEqual(error as? MusicAppLateChange, MusicAppLateChange(progress: "5|A1|B2"))
        }
    }

    /// Adding C failed, and taking back B then timed out: Music still deletes B, but the
    /// rollback stopped before A. The edit must take back what is left once Music answers.
    func testARollbackThatTimesOutHalfwayIsFinishedAfterwards() throws {
        let rollback = ["if \"B2\" is not \"\" then error \"Music got a time out.\" number -1712"]
        let part = (["set countBefore to 5", "set addedIDs to {\"A1\", \"B2\"}"]
            + MusicAppScripts.cleanup(rollback, progress: "(countBefore as text) & \"|\" & (addedIDs as text) & \"|\""))
            .joined(separator: "\n")

        XCTAssertThrowsError(try AppleEventMusicAppScriptRunner.executeAppleScript(part)) { error in
            XCTAssertEqual(error as? MusicAppLateChange, MusicAppLateChange(progress: "5|A1,B2|"))
        }
        let add = MusicAppScripts.addToPlaylist(.persistentID("FE82FB07F4D3B511"), tracks: [.persistentID(rowPersistentID)])
        XCTAssertTrue(add.contains("on error cleanupMessage number cleanupNumber"), "the add's rollback can end late")
        let create = MusicAppScripts.createPlaylist(name: "Spotiglass test", tracks: [.persistentID(rowPersistentID)])
        XCTAssertTrue(create.contains("try\nif newID is not \"\" then delete pl\non error cleanupMessage"), "so can the new playlist's delete")
    }

    func testALookupThatTimesOutChangedNothing() throws {
        XCTAssertThrowsError(try AppleEventMusicAppScriptRunner.executeAppleScript("error \"Music got a time out.\" number -1712")) { error in
            XCTAssertEqual(error as? AppleMusicLibraryEditError, .musicUnavailable)
        }
    }

    func testWaitingForMusicThatNeverAnswersEndsAsStillBusy() throws {
        let source = MusicAppScripts.settling("error \"Music got a time out.\" number -1712", seconds: 600)

        XCTAssertTrue(source.hasPrefix("with timeout of 600 seconds\n"))
        XCTAssertThrowsError(try AppleEventMusicAppScriptRunner.executeAppleScript(source)) { error in
            XCTAssertEqual(error as? AppleMusicLibraryEditError, .musicStillBusy)
        }
    }

    func testTheRunnerWaitsLongerOnlyWhenSettling() async throws {
        let seen = PathRecorder()
        let queues = PathRecorder()
        let runner = AppleEventMusicAppScriptRunner(prepare: {}, execute: { source in
            seen.append(source)
            queues.append(String(cString: __dispatch_queue_get_label(nil)))
            return nil
        })

        try await runner.run("get name")
        try await runner.settle("get name")

        // One at a time on Music's own queue, waiting or not.
        XCTAssertEqual(queues.values, Array(repeating: "com.isaaclins.spotiglass.music-scripts", count: 2))
        XCTAssertTrue(seen.values[0].hasPrefix("with timeout of \(AppleEventMusicAppScriptRunner.eventTimeoutSeconds) seconds"))
        XCTAssertTrue(seen.values[1].hasPrefix("with timeout of \(AppleEventMusicAppScriptRunner.settleTimeoutSeconds) seconds"))
        XCTAssertGreaterThan(AppleEventMusicAppScriptRunner.settleTimeoutSeconds, AppleEventMusicAppScriptRunner.eventTimeoutSeconds)
    }
}

/// A Music whose change answers after the timeout: the edit script throws `MusicAppLateChange`
/// with `lateProgress`, and every settle script is recorded.
private final class LateChangeRunner: MusicAppScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var settledScripts: [String] = []
    var lateProgress: String?
    var settleError: Error?
    var settled: [String] { lock.withLock { settledScripts } }

    func run(_ source: String) async throws -> String? {
        if let lateProgress { throw MusicAppLateChange(progress: lateProgress) }
        return "FE82FB07F4D3B512"
    }

    func settle(_ source: String) async throws -> String? {
        lock.withLock { settledScripts.append(source) }
        if let settleError { throw settleError }
        return nil
    }
}

// MARK: - Songs that are only in a playlist (#401)

/// 18P1's "Don't Stop The Music" and "S&M" are Apple Music songs in the playlist but not in the
/// library: the Music app finds 0 tracks with their persistent IDs in `library playlist 1`.
/// MusicKit lists them like library songs, without the date they were added.
final class AppleMusicPlaylistOnlySongTests: XCTestCase {
    private var lookup: MockLibraryLookup!
    private var cloud: MockCloudLibrary!
    private var musicApp: MockMusicApp!
    private var pending: AppleMusicPendingLibraryEdits!
    private var registry: AppleMusicSongReferenceRegistry!
    private var editor: AppleMusicLibraryEditor!

    private let rowID = "-1192152853020385209"
    private let rowPersistentID = "EF749F4BE5C06047"
    private let playlistID = "-7585332124925747685"

    override func setUp() {
        super.setUp()
        lookup = MockLibraryLookup()
        cloud = MockCloudLibrary()
        musicApp = MockMusicApp()
        pending = AppleMusicPendingLibraryEdits()
        registry = AppleMusicSongReferenceRegistry(addedDate: { _ in nil })
        editor = AppleMusicLibraryEditor(
            lookup: RegistryBackedLookup(registry: registry, base: lookup),
            cloud: cloud, musicApp: musicApp, pending: pending, songReferences: registry
        )
        // Its library entry, as MusicKit encodes it under the cloud library ID.
        lookup.libraryIdentitiesByPersistentID[rowID] = AppleMusicSongIdentity(
            encoded: Data(#"{"id":"i.aJGod6dt36dmrrA","type":"library-songs","attributes":{"name":"Don't Stop The Music","playParams":{"catalogId":"1441154439","musicKit_persistentID":"-1192152853020385209","kind":"song","isLibrary":true,"id":"i.aJGod6dt36dmrrA","musicKit_libraryID":"i.aJGod6dt36dmrrA"}}}"#.utf8)
        )
    }

    /// The row exactly as MusicKit listed it in 18P1 (its `libraryAddedDate` was nil).
    private func row() throws -> Song {
        let attributes = #""artistName":"Rihanna","albumName":"Good Girl Gone Bad: Reloaded","name":"Don't Stop The Music","durationInMillis":267080,"playParams":{"musicKit_persistentID":"-1192152853020385209","id":"-1192152853020385209","kind":"song","musicKit_databaseID":"785BA2D7E82AE547","isLibrary":true}"#
        let json = #"{"id":"-1192152853020385209","type":"songs","attributes":{\#(attributes)},"meta":{"musicKit_identifierSet":{"isLibrary":true,"dataSources":["localLibrary","legacyModel"],"deviceLocalID":{"databaseID":"785BA2D7E82AE547","value":"-1192152853020385209"},"type":"Song","id":"-1192152853020385209"}}}"#
        return try AppleMusicFixtures.decode(Song.self, json)
    }

    func testAPlaylistRowWithoutAnAddedDateIsNotLiked() async throws {
        registry.remember([.song(try row())], playlistID: playlistID)

        XCTAssertEqual(editor.knownSongStatus(id: rowID), false, "the menu offers Add to Liked Songs at once")
        let statuses = try await editor.songStatuses(ids: [rowID])
        XCTAssertEqual(statuses, [false])
    }

    func testAPlaylistRowThatIsInTheLibraryIsLiked() async throws {
        // "Poker Face" in 18P1 is in the library: MusicKit gives it the date it was added.
        let added = AppleMusicSongReferenceRegistry(addedDate: { _ in Date(timeIntervalSince1970: 1_742_253_902) })
        editor = AppleMusicLibraryEditor(
            lookup: RegistryBackedLookup(registry: added, base: lookup),
            cloud: cloud, musicApp: musicApp, pending: pending, songReferences: added
        )
        added.remember([.song(try row())], playlistID: playlistID)

        XCTAssertEqual(editor.knownSongStatus(id: rowID), true)
        let statuses = try await editor.songStatuses(ids: [rowID])
        XCTAssertEqual(statuses, [true])
    }

    func testLikingAPlaylistOnlySongSavesItByItsCatalogID() async throws {
        registry.remember([.song(try row())], playlistID: playlistID)

        try await editor.saveSongs(ids: [rowID])

        XCTAssertEqual(cloud.calls, [
            "addToLibrary(songs:1441154439 albums:)",
            "rate(love,1441154439,catalog)",
        ])
        XCTAssertEqual(editor.knownSongStatus(id: rowID), true, "the menu now offers Remove")
        let statuses = try await editor.songStatuses(ids: [rowID])
        XCTAssertEqual(statuses, [true])
    }

    func testUnlikingItAgainRemovesItFromTheLibraryThroughMusic() async throws {
        registry.remember([.song(try row())], playlistID: playlistID)
        try await editor.saveSongs(ids: [rowID])

        try await editor.removeSongs(ids: [rowID])

        XCTAssertEqual(musicApp.calls, ["removeFromLibrary([persistentID(\"\(rowPersistentID)\")])"])
        XCTAssertEqual(cloud.calls.last, "rate(clear,1441154439,catalog)", "the like's love comes off again")
        XCTAssertTrue(pending.isRemoved(["1441154439"]), "Liked Songs and search know it under its catalog ID")
        XCTAssertEqual(editor.knownSongStatus(id: rowID), false)
        let statuses = try await editor.songStatuses(ids: [rowID])
        XCTAssertEqual(statuses, [false])
    }

    /// The pending like ends as soon as Liked Songs shows the song, long before 18P1 is read
    /// again: the row must not fall back to what its first read said.
    func testALikedRowStaysLikedOnceThePendingLikeEnds() async throws {
        registry.remember([.song(try row())], playlistID: playlistID)
        try await editor.saveSongs(ids: [rowID])

        _ = pending.applied(
            toLibrarySongs: [(track: AppleMusicLibraryEditorTests.track(id: "i.aJGod6dt36dmrrA", name: "Don't Stop The Music"), keys: Set(["i.aJGod6dt36dmrrA", "1441154439", rowID]))],
            isComplete: true
        )

        XCTAssertFalse(pending.isSaved([rowID]), "the library shows the like")
        XCTAssertEqual(editor.knownSongStatus(id: rowID), true)
    }

    /// Liked from search, the song comes by its catalog ID; its 18P1 row, remembered under the
    /// persistent ID, must follow once the pending like ends.
    func testALikeFromSearchReachesThePlaylistRow() async throws {
        registry.remember([.song(try row())], playlistID: playlistID)
        lookup.songsByID["1441154439"] = AppleMusicSongReference(
            itemID: "1441154439", catalogID: "1441154439", cloudLibraryID: "i.aJGod6dt36dmrrA",
            musicAppPersistentID: rowPersistentID, isInLibrary: false,
            title: "Don't Stop The Music", artistName: "Rihanna", albumTitle: nil
        )

        try await editor.saveSongs(ids: ["1441154439"])
        _ = pending.applied(
            toLibrarySongs: [(track: AppleMusicLibraryEditorTests.track(id: "i.aJGod6dt36dmrrA", name: "Don't Stop The Music"), keys: Set(["i.aJGod6dt36dmrrA", "1441154439", rowID]))],
            isComplete: true
        )

        XCTAssertEqual(editor.knownSongStatus(id: rowID), true)
    }

    /// Removing the album takes the song out of the library; its remembered row follows, so
    /// it doesn't read as liked once the pending removal ends.
    func testRemovingAnAlbumReachesItsRememberedRows() async throws {
        let librarySong = AppleMusicSongReference(
            itemID: "-5", catalogID: "51", musicAppPersistentID: "FFFFFFFFFFFFFFFB", isInLibrary: true,
            title: "Kept", artistName: "Rihanna", albumTitle: "Good Girl Gone Bad: Reloaded"
        )
        registry.remember(librarySong)
        lookup.albumsByID["-7"] = AppleMusicAlbumReference(itemID: "-7", catalogID: "70", isInLibrary: true, librarySongs: [librarySong])

        try await editor.removeAlbums(ids: ["-7"])

        XCTAssertEqual(registry.reference(for: "-5")?.isInLibrary, false)
    }

    func testAPlaylistOnlySongWithoutALibraryEntryIsNotLikedBlindly() async throws {
        lookup.libraryIdentitiesByPersistentID = [:]
        registry.remember([.song(try row())], playlistID: playlistID)

        await XCTAssertThrowsEditError(.notEditable) {
            try await self.editor.saveSongs(ids: [self.rowID])
        }
        XCTAssertEqual(cloud.calls, [])
    }

    func testRemovingAnAlbumLeavesOutItsSongsThatAreOnlyInAPlaylist() async throws {
        lookup.albumsByID["l.album"] = AppleMusicAlbumReference(
            itemID: "l.album", catalogID: nil, isInLibrary: true,
            librarySongs: [
                AppleMusicSongReference(itemID: "1", musicAppPersistentID: "0000000000000001", isInLibrary: true),
                AppleMusicSongReference(itemID: rowID, musicAppPersistentID: rowPersistentID, isInLibrary: false),
            ]
        )

        try await editor.removeAlbums(ids: ["l.album"])

        XCTAssertEqual(musicApp.calls, ["removeFromLibrary([persistentID(\"0000000000000001\")])"])
    }
}

/// The live lookup's order for a row it can't find by ID: what the playlist read remembered.
private final class RegistryBackedLookup: AppleMusicLibraryLookup, @unchecked Sendable {
    let registry: AppleMusicSongReferenceRegistry
    let base: MockLibraryLookup

    init(registry: AppleMusicSongReferenceRegistry, base: MockLibraryLookup) {
        self.registry = registry
        self.base = base
    }

    func songs(ids: [String]) async throws -> [AppleMusicSongReference] {
        let fallback = try await base.songs(ids: ids)
        return zip(ids, fallback).map { registry.reference(for: $0) ?? $1 }
    }

    func catalogTracks(ids: [String]) async throws -> [MusicTrack] { try await base.catalogTracks(ids: ids) }
    func catalogAlbumTracks(albumIDs: [String]) async throws -> [MusicTrack] { try await base.catalogAlbumTracks(albumIDs: albumIDs) }
    func albums(ids: [String]) async throws -> [AppleMusicAlbumReference] { try await base.albums(ids: ids) }
    func playlist(id: String) async throws -> AppleMusicPlaylistReference? { try await base.playlist(id: id) }
    func libraryIdentity(of reference: AppleMusicSongReference) async throws -> AppleMusicSongIdentity? {
        try await base.libraryIdentity(of: reference)
    }
}
