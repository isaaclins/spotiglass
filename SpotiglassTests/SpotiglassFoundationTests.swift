import Sparkle
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
        // The item derives its key equivalent from the keymap, so a rebind moves
        // the chord instead of leaving Command-K alive beside it (#131).
        XCTAssertTrue(standardMenuSource.contains("menuShortcut("))
        XCTAssertFalse(source.contains(".keyboardShortcut(\"k\", modifiers: [.command])"))
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

    /// Updates must download and install by themselves (#435). With `SUAllowsAutomaticUpdates`
    /// false Sparkle could only ever prompt, and its once-a-day default check meant a release
    /// took a day or more to arrive.
    func testSparkleInfoPlistInstallsUpdatesAutomatically() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let plistURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/App/SparkleInfo.plist")
        let data = try Data(contentsOf: plistURL)
        let source = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        // The source plist and the Info.plist the built app ships with.
        let shipped = try XCTUnwrap(Bundle.main.infoDictionary)

        for (name, plist) in [("SparkleInfo.plist", source), ("built Info.plist", shipped)] {
            XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true, name)
            XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, true, name)
            XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true, name)
            let interval = try XCTUnwrap((plist["SUScheduledCheckInterval"] as? NSNumber)?.doubleValue, name)
            // Sparkle ignores anything under an hour; over six hours a release can miss the day.
            XCTAssertGreaterThanOrEqual(interval, 3600, name)
            XCTAssertLessThanOrEqual(interval, 6 * 3600, name)
        }
    }

    /// The Settings switch reads Sparkle's own setting, so its default is what Sparkle reports
    /// before anyone has touched it: on. Sparkle is pointed at a copy of the shipped Info.plist
    /// under a throwaway bundle id, so the answer comes from the plist and never from this Mac's
    /// saved choice.
    func testInstallUpdatesAutomaticallyDefaultsToOn() throws {
        var info = try XCTUnwrap(Bundle.main.infoDictionary)
        info["CFBundleIdentifier"] = "com.isaaclins.spotiglass.tests.updates-\(UUID().uuidString)"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassUpdateDefaults-\(UUID().uuidString).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil),
            delegate: nil
        )

        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertLessThanOrEqual(updater.updateCheckInterval, 6 * 3600)
    }

    /// Searching Settings for "update" finds the pane that holds the switch.
    func testSettingsSearchForUpdatesFindsAccountPane() {
        XCTAssertTrue(SpotiglassSettingsSection.account.matches(searchQuery: "update"))
        XCTAssertTrue(SpotiglassSettingsSection.account.matches(searchQuery: "install automatically"))
    }

}
