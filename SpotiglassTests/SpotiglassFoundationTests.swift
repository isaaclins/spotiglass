import AppKit
import SwiftUI
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
    @MainActor
    func testInstallUpdatesAutomaticallyDefaultsToOn() throws {
        let throwaway = try ThrowawayUpdaterBundle()
        defer { throwaway.remove() }
        let updater = throwaway.makeUpdater()

        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertLessThanOrEqual(updater.updateCheckInterval, 6 * 3600)
        let viewModel = AutomaticUpdatesViewModel(updater: updater)
        XCTAssertTrue(viewModel.installsAutomatically)
        XCTAssertTrue(viewModel.checksAutomatically)
        XCTAssertEqual(viewModel.footerKey, "settings.updates.footer.automatic")
    }

    /// Sparkle's update alert has its own "Automatically download and install updates in the
    /// future" checkbox, which writes `SUAutomaticallyUpdate` straight to user defaults instead of
    /// through the updater. Settings must follow it while it is open.
    @MainActor
    func testUpdatesSwitchFollowsSparklesOwnCheckbox() throws {
        let throwaway = try ThrowawayUpdaterBundle()
        defer { throwaway.remove() }
        let viewModel = AutomaticUpdatesViewModel(updater: throwaway.makeUpdater())
        XCTAssertTrue(viewModel.installsAutomatically)

        throwaway.defaults.set(false, forKey: "SUAutomaticallyUpdate")
        waitUntil { !viewModel.installsAutomatically }
        XCTAssertTrue(viewModel.checksAutomatically)

        throwaway.defaults.set(true, forKey: "SUAutomaticallyUpdate")
        waitUntil { viewModel.installsAutomatically }
    }

    /// Sparkle never downloads without checking, so with automatic checks off the switch is off,
    /// and turning it on turns checks back on.
    @MainActor
    func testUpdatesSwitchIsOffWhileAutomaticChecksAreOff() throws {
        let throwaway = try ThrowawayUpdaterBundle()
        defer { throwaway.remove() }
        throwaway.defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let updater = throwaway.makeUpdater()
        let viewModel = AutomaticUpdatesViewModel(updater: updater)

        XCTAssertFalse(viewModel.checksAutomatically)
        XCTAssertFalse(viewModel.installsAutomatically)
        XCTAssertEqual(viewModel.footerKey, "settings.updates.footer.manual")

        viewModel.setInstallsAutomatically(true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(viewModel.installsAutomatically)

        viewModel.setInstallsAutomatically(false)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(viewModel.installsAutomatically)
        XCTAssertTrue(viewModel.checksAutomatically)
        XCTAssertEqual(viewModel.footerKey, "settings.updates.footer.prompt")
    }

    /// The Updates group draws in each of its three states, in light and dark, and every footer
    /// it can show has a translation in each language the app ships.
    @MainActor
    func testUpdatesSectionRendersEveryState() throws {
        for (checks, downloads) in [(true, true), (true, false), (false, false)] {
            let throwaway = try ThrowawayUpdaterBundle()
            defer { throwaway.remove() }
            throwaway.defaults.set(checks, forKey: "SUEnableAutomaticChecks")
            throwaway.defaults.set(downloads, forKey: "SUAutomaticallyUpdate")
            let updater = throwaway.makeUpdater()
            let footerKey = AutomaticUpdatesViewModel(updater: updater).footerKey
            for language in ["en", "de", "es"] {
                let text = SpotiglassL10n.string(footerKey, locale: Locale(identifier: language))
                XCTAssertNotEqual(text, footerKey, "\(footerKey) has no \(language) text")
            }

            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: Form {
                    UpdatesSettingsSection(updater: updater)
                    CheckForUpdatesView(updater: updater)
                }
                .formStyle(.grouped)
                .environment(\.colorScheme, scheme)
                .frame(width: 560))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                AppKitTestSupport.pumpRunLoop(for: 0.05)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(host.bounds.height, 100)
            }
        }
    }

    /// Spins the main run loop (where the view model receives changes) until `condition` holds,
    /// however long a busy machine takes. A change that never comes runs into the per-test limit.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) {
        while !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Searching Settings for "update" or the group's own title, "updates", finds the pane that
    /// holds the switch.
    func testSettingsSearchForUpdatesFindsAccountPane() {
        XCTAssertTrue(SpotiglassSettingsSection.account.matches(searchQuery: "update"))
        XCTAssertTrue(SpotiglassSettingsSection.account.matches(searchQuery: "updates"))
        XCTAssertTrue(SpotiglassSettingsSection.account.matches(searchQuery: "install automatically"))
    }

}

/// A copy of the shipped Info.plist under a throwaway bundle id, so Sparkle reads the plist's
/// defaults and its own saved choices land in a defaults domain that is deleted afterwards.
private struct ThrowawayUpdaterBundle {
    let bundle: Bundle
    let defaults: UserDefaults
    private let bundleURL: URL
    private let identifier: String

    init() throws {
        identifier = "com.isaaclins.spotiglass.tests.updates-\(UUID().uuidString)"
        var info = try XCTUnwrap(Bundle.main.infoDictionary)
        info["CFBundleIdentifier"] = identifier
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassUpdateDefaults-\(UUID().uuidString).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        bundle = try XCTUnwrap(Bundle(url: bundleURL))
        defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
    }

    func makeUpdater() -> SPUUpdater {
        SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil),
            delegate: nil
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: identifier)
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
