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
        let locale = DispatchQueue.global().sync { SpotiglassL10n.locale }
        XCTAssertEqual(locale.identifier, "en")
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
}
