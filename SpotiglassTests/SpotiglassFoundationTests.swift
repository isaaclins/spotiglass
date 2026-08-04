import XCTest
@testable import Spotiglass

final class SpotiglassFoundationTests: XCTestCase {
    func testNotConfiguredStateCopyIsStable() {
        let state = AppConnectionState.signedOut

        XCTAssertEqual(state.title, "Spotify is not connected")
        XCTAssertEqual(
            state.message,
            "Enter your Spotify client ID, then connect your Spotify account."
        )
    }

    func testAppMetadataMatchesProjectIdentity() {
        XCTAssertEqual(AppMetadata.displayName, "Spotiglass")
        XCTAssertEqual(AppMetadata.bundleIdentifier, "com.isaaclins.spotiglass")
    }

    func testAppMenuKeepsPaletteInStandardApplicationMenu() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/App/SpotiglassApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let standardMenuRange = try XCTUnwrap(source.range(of: "CommandGroup(after: .appInfo) {"))
        let settingsRange = try XCTUnwrap(source.range(of: "Settings {"))
        let standardMenuSource = source[standardMenuRange.lowerBound..<settingsRange.lowerBound]

        XCTAssertTrue(standardMenuSource.contains("app.menu.openPalette"))
        XCTAssertTrue(standardMenuSource.contains(".keyboardShortcut(\"k\", modifiers: [.command])"))
        XCTAssertFalse(source.contains("CommandMenu(SpotiglassL10n.string(\"app.menu.name\"))"))
    }

    func testSparkleConfigurationFeedAndPublicKey() {
        XCTAssertEqual(
            SparkleConfiguration.feedURL,
            "https://isaaclins.github.io/spotiglass/appcast.xml"
        )
        XCTAssertEqual(
            SparkleConfiguration.publicEDKey,
            "HknEj0Snyq5WsrWwAxj89njv+qkdMASLlzKMFrlog8Y="
        )
    }

}
