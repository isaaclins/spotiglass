import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

/// Changing the language sent the main window back to Home (#548): the window's content was
/// keyed on the language, so a switch replaced it with a new one and every page, scroll
/// position, selection and open panel was lost. These tests host content the way the main
/// window does and switch the language under it, as the Settings picker does.
@MainActor
final class MainWindowLanguageSwitchTests: XCTestCase {
    override func tearDown() {
        SpotiglassL10n.settingsStore = nil
        WindowStateProbe.reset()
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    func testALanguageSwitchKeepsTheWindowStateAndChangesItsText() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }

        let controller = ViewTestHost.host(
            WindowStateProbeView().spotiglassLanguage(store),
            size: CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(WindowStateProbe.created, 1)
        WindowStateProbe.instances.last?.page = "artist"

        for language in [AppLanguage.german, .spanish, .english, .german] {
            try store.mutate { $0.appearance.language = language }
            controller.view.layoutSubtreeIfNeeded()
            AppKitTestSupport.pumpRunLoop()

            let locale = Locale(identifier: language.rawValue)
            XCTAssertEqual(WindowStateProbe.created, 1, "Switching to \(language) rebuilt the window's content")
            XCTAssertEqual(WindowStateProbe.instances.last?.page, "artist", "Switching to \(language) lost the page")
            // A body that looks a string up without a locale argument, like most of the app's
            // views, and one that reads the locale from the environment.
            XCTAssertEqual(
                WindowStateProbe.lastStoreText,
                SpotiglassL10n.string("browser.likedSongs.title", locale: locale),
                "Text looked up through the store stayed in the old language after switching to \(language)"
            )
            XCTAssertEqual(
                WindowStateProbe.lastEnvironmentText,
                SpotiglassL10n.string("browser.home", locale: locale)
            )
        }
    }

    /// The window keeps what it loaded across a switch, so text the browser stored with it (track
    /// badges, album track counts, empty states, error panels) has to follow the switch too. The
    /// old rebuild hid this: every page loaded again in the new language. Built in English and
    /// read after switching to German, the way the window keeps them.
    func testStoredBrowserTextFollowsALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }

        let explicitTrack = MusicTrack(
            id: "t",
            name: "Song",
            artists: ["A"],
            albumArtworkURL: nil,
            durationMilliseconds: 60_000,
            isExplicit: true,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t"
        )
        let trackRow = TrackRowViewModel(MusicPlaylistTrackItem(id: "t", content: .track(explicitTrack)), listPosition: 1)
        let unavailableRow = TrackRowViewModel(MusicPlaylistTrackItem(id: "u", content: .unavailable(reason: .track)), listPosition: 2)
        let albumRow = ArtistAlbumRowViewModel(MusicArtistAlbum(
            id: "alb", name: "Awake", imageURL: nil, releaseYear: "2014",
            totalTracks: 10, group: .album, uri: "spotify:album:alb"
        ))
        let emptyState = BrowsingLoadState<BrowsingDetailContent>.empty(
            LocalizedText(SpotiglassL10n.string("browser.empty.signInToBrowse"))
        )
        let error = PlaylistBrowserViewModel.displayError(for: SpotifyAPIError.unauthorized)
        let namelessTrack = MusicTrack(
            id: "n", name: "", artists: [""], albumArtworkURL: nil, durationMilliseconds: 60_000,
            isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:n"
        )
        let namelessRow = TrackRowViewModel(MusicPlaylistTrackItem(id: "n", content: .track(namelessTrack)), listPosition: 3)
        // A failed request keeps its sentence as text, resolved in the language of the moment.
        let networkError = PlaylistBrowserViewModel.displayError(
            for: SpotifyAPIError.network(SpotiglassL10n.string("error.spotify.unexpectedShape"))
        )
        let rateLimitError = PlaybackSessionViewModel.displayError(
            for: SpotifyAPIError.rateLimited(retryAfter: 600), service: .spotify
        )
        let englishRateLimitMessage = rateLimitError.message
        XCTAssertEqual(trackRow.badgeText, "Explicit")
        XCTAssertEqual(albumRow.trackCountText, "10 tracks")

        try store.mutate { $0.appearance.language = .german }
        let german = Locale(identifier: AppLanguage.german.rawValue)

        XCTAssertEqual(trackRow.badgeText, "Explizit")
        XCTAssertEqual(trackRow.title, "Song", "A song's own name is never translated")
        XCTAssertEqual(unavailableRow.title, SpotiglassL10n.string("browser.trackBadge.unavailableItem", locale: german))
        XCTAssertEqual(unavailableRow.badgeText, SpotiglassL10n.string("browser.trackBadge.unavailable", locale: german))
        XCTAssertEqual(unavailableRow.subtitle, SpotiglassL10n.string("browser.unavailableReason.track", locale: german))
        XCTAssertEqual(albumRow.trackCountText, "10 Titel")
        XCTAssertEqual(namelessRow.title, UnnamedMusicItem.track.placeholder(locale: german))
        XCTAssertEqual(namelessRow.subtitle, UnnamedMusicItem.artist.placeholder(locale: german))
        XCTAssertEqual(networkError.message, SpotiglassL10n.string("error.spotify.unexpectedShape", locale: german))
        XCTAssertNotEqual(rateLimitError.message, englishRateLimitMessage)
        XCTAssertEqual(
            rateLimitError.message,
            String(
                format: SpotiglassL10n.string("error.playback.rateLimited.message", locale: german),
                SpotifyRateLimitDisplay.retryAfterClause(seconds: 600)
            ),
            "The retry clause stayed in the old language"
        )
        guard case let .empty(message) = emptyState else { return XCTFail("Expected an empty state") }
        XCTAssertEqual(message.string, SpotiglassL10n.string("browser.empty.signInToBrowse", locale: german))
        XCTAssertEqual(error.title, SpotiglassL10n.string("error.browsing.signInAgain.title", locale: german))
        XCTAssertEqual(error.message, SpotiglassL10n.string("error.browsing.signInAgain.message", locale: german))
    }

    /// The tests above host stand-in content, so they can't see the real windows. The bug was a
    /// window's content keyed on the language (`.id(language)`), which rebuilds it on every
    /// switch: no view in the app may be keyed on the language or the locale again.
    func testNoViewIsRebuiltOnALanguageSwitch() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass", isDirectory: true)
        let keyedOnLanguage = try NSRegularExpression(pattern: #"\.id\([^)]*(?:[Ll]anguage|[Ll]ocale)"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceURL, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if keyedOnLanguage.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                offenders.append(fileURL.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "Keyed on the language, so a switch rebuilds it and loses its state")
    }

    /// Other settings changes (theme, lyrics size) don't redraw text that only depends on the
    /// language.
    func testOtherSettingsChangesDoNotRedrawLanguageOnlyText() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }

        let controller = ViewTestHost.host(StoreTextOnlyView(), size: CGSize(width: 400, height: 200))
        let rendersBefore = WindowStateProbe.storeTextRenders

        try store.mutate { $0.appearance.colorScheme = .dark }
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop()
        XCTAssertEqual(WindowStateProbe.storeTextRenders, rendersBefore)

        try store.mutate { $0.appearance.language = .german }
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop()
        XCTAssertGreaterThan(WindowStateProbe.storeTextRenders, rendersBefore)
    }
}

/// Stands in for the window's state: the page it shows, kept by a `@StateObject` the way the
/// browser keeps its navigation.
@MainActor
private final class WindowStateProbe: ObservableObject {
    static var created = 0
    static var instances: [WindowStateProbe] = []
    static var lastStoreText = ""
    static var lastEnvironmentText = ""
    static var storeTextRenders = 0

    @Published var page = "home"

    init() {
        Self.created += 1
        Self.instances.append(self)
    }

    static func reset() {
        created = 0
        instances = []
        lastStoreText = ""
        lastEnvironmentText = ""
        storeTextRenders = 0
    }
}

private struct WindowStateProbeView: View {
    @StateObject private var probe = WindowStateProbe()
    @Environment(\.spotiglassLocale) private var locale

    var body: some View {
        let environmentText = SpotiglassL10n.string("browser.home", locale: locale)
        WindowStateProbe.lastEnvironmentText = environmentText
        return VStack {
            Text(probe.page)
            Text(environmentText)
            StoreTextLabel()
        }
    }
}

/// A row deeper in the window that reads no environment value: only the language signal
/// can tell SwiftUI it has to redraw.
private struct StoreTextLabel: View {
    var body: some View {
        let text = SpotiglassL10n.string("browser.likedSongs.title")
        WindowStateProbe.lastStoreText = text
        return Text(text)
    }
}

private struct StoreTextOnlyView: View {
    var body: some View {
        WindowStateProbe.storeTextRenders += 1
        return Text(SpotiglassL10n.string("browser.likedSongs.title"))
    }
}
