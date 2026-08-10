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
        let formatted = SpotiglassL10n.format("auth.accessToken.validUntil", "12:00 PM")
        XCTAssertFalse(formatted.isEmpty)
    }
}
