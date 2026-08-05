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
            "https://isaaclins.com/spotiglass/appcast.xml"
        )
        XCTAssertEqual(
            SparkleConfiguration.publicEDKey,
            "HknEj0Snyq5WsrWwAxj89njv+qkdMASLlzKMFrlog8Y="
        )
    }

    /// The feed must be plain HTTPS. App Transport Security cancels any http:// hop, and the
    /// `isaaclins.github.io` alias 301s to `http://isaaclins.com/...`, which made every update
    /// check fail with "An error occurred in retrieving update information."
    func testSparkleFeedURLUsesHTTPSWithoutRedirectingAlias() throws {
        let feedURL = try XCTUnwrap(URL(string: SparkleConfiguration.feedURL))

        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(feedURL.host, "isaaclins.com")
    }

    /// Sparkle reads `SUFeedURL` from the plist while the app code reads `SparkleConfiguration`,
    /// so the two sources of truth must not drift apart.
    func testSparkleInfoPlistMatchesSparkleConfiguration() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let plistURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/App/SparkleInfo.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["SUFeedURL"] as? String, SparkleConfiguration.feedURL)
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, SparkleConfiguration.publicEDKey)
    }

}
