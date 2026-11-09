import os
import XCTest
@testable import Spotiglass

@MainActor
final class SpotiglassL10nTests: XCTestCase {
    override func tearDown() {
        SpotiglassL10n.settingsStore = nil
        super.tearDown()
    }

    func testLocaleUsesSettingsStoreOnMainThread() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store
        XCTAssertEqual(SpotiglassL10n.locale.identifier, "de")
    }

    func testLocaleFallsBackToEnglishOffMainThread() {
        SpotiglassL10n.settingsStore = nil
        let locale = onBackgroundThread { SpotiglassL10n.locale }
        XCTAssertEqual(locale.identifier, "en")
    }

    /// Each lookup used to ask every loaded bundle and framework for the language's folder
    /// again; a track row looks up several strings, so an 800-song list spent most of its
    /// layout there (#442). The folders are found once per language.
    func testTheLanguageBundlesAreFoundOncePerLanguage() {
        let german = Locale(identifier: "de")
        let english = Locale(identifier: "en")
        _ = SpotiglassL10n.string("browser.home", locale: german)
        _ = SpotiglassL10n.string("browser.home", locale: english)
        let searches = SpotiglassL10n.localizationBundleSearches.withLock { $0 }

        for _ in 0..<500 {
            _ = SpotiglassL10n.string("browser.track.play", locale: german)
            _ = SpotiglassL10n.string("playback.pause", locale: english)
        }

        XCTAssertEqual(SpotiglassL10n.localizationBundleSearches.withLock { $0 }, searches)
        XCTAssertNotEqual(SpotiglassL10n.string("browser.home", locale: german),
                          SpotiglassL10n.string("browser.home", locale: english),
                          "each language still gets its own strings")
    }

    func testStringAndFormatResolveKeys() {
        SpotiglassL10n.settingsStore = nil
        let home = SpotiglassL10n.string("browser.home")
        XCTAssertFalse(home.isEmpty)
        let formatted = SpotiglassL10n.format("settings.account.validUntil", "12:00 PM")
        XCTAssertFalse(formatted.isEmpty)
    }

    /// The catalog's first plural entries. This asserts the whole chain works,
    /// not just the JSON: Xcode has to compile the variations into a stringsdict
    /// and the bundle lookup plus String(format:) has to pick the right case
    /// (#156, #151).
    func testPluralKeysResolveThroughTheBundle() {
        SpotiglassL10n.settingsStore = nil

        let one = SpotiglassL10n.format("browser.trackCount", Int64(1))
        let many = SpotiglassL10n.format("browser.trackCount", Int64(4))
        XCTAssertEqual(one, "1 track")
        XCTAssertEqual(many, "4 tracks")

        // Zero takes the plural form, which the old count == 1 branch also did
        // but only by accident.
        XCTAssertEqual(SpotiglassL10n.format("browser.trackCount", Int64(0)), "0 tracks")

        XCTAssertEqual(
            SpotiglassL10n.format("queue.subtitle.upNext", Int64(1)),
            "1 track up next"
        )
        XCTAssertEqual(
            SpotiglassL10n.format("queue.subtitle.upNext", Int64(3)),
            "3 tracks up next"
        )

        // The alert that used to render "canciónes" in Spanish.
        XCTAssertEqual(
            SpotiglassL10n.format("playlist.detail.newPlaylist.withTracks", Int64(1)),
            "Create a new playlist with 1 track added."
        )
        XCTAssertEqual(
            SpotiglassL10n.format("playlist.detail.newPlaylist.withTracks", Int64(2)),
            "Create a new playlist with 2 tracks added."
        )

        // No key resolves to itself, which is what the bundle returns on a miss.
        for key in ["browser.trackCount", "queue.subtitle.upNext", "playlist.detail.newPlaylist.empty"] {
            XCTAssertNotEqual(SpotiglassL10n.string(key), key, "\(key) did not resolve")
        }
    }

    /// Runs `body` on a thread of its own and waits for it. `DispatchQueue.global().sync` would
    /// run it inline on the main thread, where the old main-thread-only lookup already worked.
    private func onBackgroundThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let result = OSAllocatedUnfairLock<(value: T, onMain: Bool)?>(initialState: nil)
        let done = expectation(description: "background lookup")
        Thread.detachNewThread {
            let value = body()
            result.withLock { $0 = (value, Thread.isMainThread) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let outcome = result.withLock { $0 }!
        XCTAssertFalse(outcome.onMain)
        return outcome.value
    }

    /// Providers build "You" and "Untitled Playlist" on background tasks. Off the main thread
    /// the language used to fall back to English whatever the user picked (#398).
    func testLocaleFollowsTheStoreOffTheMainThread() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        try store.mutate { $0.appearance.language = .german }
        SpotiglassL10n.settingsStore = store

        XCTAssertEqual(onBackgroundThread { SpotiglassL10n.locale }.identifier, "de")
        XCTAssertEqual(
            onBackgroundThread { SpotiglassL10n.string("appleMusic.library.owner") },
            "Du"
        )

        // A language switch reaches background lookups too.
        try store.mutate { $0.appearance.language = .spanish }
        XCTAssertEqual(onBackgroundThread { SpotiglassL10n.locale }.identifier, "es")

        SpotiglassL10n.settingsStore = nil
        XCTAssertEqual(onBackgroundThread { SpotiglassL10n.locale }.identifier, "en")
    }

    /// Naming the service in these sentences kept the German Spotify text as it was
    /// ("Spotify-Mediathek"), and Apple Music reads the way Apple writes it in German.
    func testGermanLibrarySentencesKeepTheSpotifyWording() {
        let german = Locale(identifier: "de")
        XCTAssertEqual(
            SpotiglassL10n.format("browser.empty.noPlaylists", locale: german, "Spotify"),
            "Ihre Spotify-Mediathek enthält noch keine Playlists."
        )
        XCTAssertEqual(
            SpotiglassL10n.format("playlist.detail.newPlaylist.empty", locale: german, "Spotify"),
            "Eine leere Playlist in Ihrer Spotify-Mediathek erstellen."
        )
        XCTAssertEqual(
            SpotiglassL10n.format("browser.empty.noPlaylists", locale: german, "Apple Music"),
            "Ihre Apple Music-Mediathek enthält noch keine Playlists."
        )
        XCTAssertEqual(
            SpotiglassL10n.string("error.playback.appleMusic.subscription.title", locale: german),
            "Apple Music-Abo erforderlich"
        )
    }

    /// The Spanish "Like" menu item read "(1 cancion)" (#398).
    func testSpanishSingleTrackLabelSpellsCancion() {
        let spanish = Locale(identifier: "es")
        XCTAssertEqual(SpotiglassL10n.format("playlist.mutation.trackLabel", locale: spanish, Int64(1)), "1 canción")
        XCTAssertEqual(SpotiglassL10n.format("playlist.mutation.trackLabel", locale: spanish, Int64(2)), "2 canciones")
    }

    /// Settings › Keyboard showed "Space" in English in every language (#398).
    func testSpaceKeyIsNamedInTheAppLanguage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-\(UUID().uuidString).json")
        let store = SpotiglassSettingsStore(fileURL: url)
        SpotiglassL10n.settingsStore = store
        let shortcut = try CommandShortcut(keystroke: "space")

        XCTAssertEqual(shortcut.displayChips, ["Space"])
        try store.mutate { $0.appearance.language = .german }
        XCTAssertEqual(shortcut.displayChips, ["Leertaste"])
        try store.mutate { $0.appearance.language = .spanish }
        XCTAssertEqual(shortcut.displayChips, ["Espacio"])
    }

    /// The panel lists at most 20 upcoming tracks. A full list must not claim that only 20
    /// are queued (a 37-song playlist read "20 tracks up next", #400).
    func testQueueCountLineSaysNextWhenTheListIsFull() {
        SpotiglassL10n.settingsStore = nil
        XCTAssertEqual(QueuePanelView.upcomingCountLine(count: 3, limit: 20), "3 tracks up next")
        XCTAssertEqual(QueuePanelView.upcomingCountLine(count: 19, limit: 20), "19 tracks up next")
        XCTAssertEqual(QueuePanelView.upcomingCountLine(count: 20, limit: 20), "Next 20 tracks")
    }
}
