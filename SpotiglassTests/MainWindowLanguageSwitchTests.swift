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

    /// A queue add refused during its rate-limit cooldown says when to try again. That part
    /// was built when the error was made, so it stayed English inside a German sentence.
    func testAQueueRateLimitErrorFollowsALanguageSwitch() async throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let api = MockPlaybackAPI()
        api.addToQueueErrors = [SpotifyAPIError.rateLimited(retryAfter: 30)]
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: MockWebPlaybackCommander())
        )
        playback.handle(.ready(deviceID: "device-1"))
        let queue = QueueViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: api),
            playbackSession: playback,
            enqueueMinimumRetryDelay: .seconds(0)
        )
        await queue.addToQueue(uri: "spotify:track:rate")
        // The second add hits the cooldown, whose message names the wait.
        await queue.addToQueue(uri: "spotify:track:rate")
        // The wait counts down, so compare the sentence around it and the language of the wait.
        let english = Locale(identifier: AppLanguage.english.rawValue)
        let englishTemplate = SpotiglassL10n.string("error.queue.rateLimited.message", locale: english)
        let englishPrefix = String(englishTemplate.prefix { $0 != "%" })
        let englishMessage = try XCTUnwrap(queue.lastError?.message)
        XCTAssertTrue(englishMessage.hasPrefix(englishPrefix))
        let englishWait = String(englishMessage.dropFirst(englishPrefix.count))
        XCTAssertFalse(englishWait.isEmpty)

        try store.mutate { $0.appearance.language = .german }
        let german = Locale(identifier: AppLanguage.german.rawValue)
        let germanTemplate = SpotiglassL10n.string("error.queue.rateLimited.message", locale: german)
        let germanMessage = try XCTUnwrap(queue.lastError?.message)
        XCTAssertTrue(germanMessage.hasPrefix(String(germanTemplate.prefix { $0 != "%" })))
        XCTAssertFalse(
            germanMessage.hasSuffix(englishWait),
            "The queue's retry clause stayed in the old language: \(germanMessage)"
        )
    }

    /// The palette builds its rows with their names when it opens. Left open across a switch,
    /// it showed the old language's names under headings in the new one.
    func testAnOpenPaletteFollowsALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let viewModel = CommandPaletteViewModel()
        viewModel.staticItemsProvider = {
            [
                CommandPaletteItem(
                    id: CommandPaletteCommandID.togglePlayback,
                    title: SpotiglassL10n.string("browser.home"),
                    subtitle: nil,
                    iconSystemName: "play",
                    section: .commands,
                    keywords: []
                ) {},
                CommandPaletteItem(
                    id: CommandPaletteCommandID.nextTrack,
                    title: SpotiglassL10n.string("browser.likedSongs.title"),
                    subtitle: nil,
                    iconSystemName: "forward",
                    section: .commands,
                    keywords: []
                ) {}
            ]
        }
        viewModel.show()
        let controller = ViewTestHost.host(
            CommandPaletteView(viewModel: viewModel).environmentObject(store),
            size: CGSize(width: 800, height: 600)
        )
        func titles() -> [String] { viewModel.sections.flatMap { $0.items.map(\.title) } }
        func expected(_ language: String) -> [String] {
            ["browser.home", "browser.likedSongs.title"].map {
                SpotiglassL10n.string($0, locale: Locale(identifier: language))
            }
        }
        XCTAssertEqual(titles(), expected("en"))
        viewModel.selectedIndex = 1

        try store.mutate { $0.appearance.language = .german }
        controller.view.layoutSubtreeIfNeeded()
        AppKitTestSupport.pumpRunLoop()
        XCTAssertEqual(titles(), expected("de"), "The open palette kept the old language's names")
        XCTAssertEqual(viewModel.selectedIndex, 1, "A switch moved the highlight off its row")
    }

    /// Lyrics that failed to load say why under "Try again". The view keeps its state across a
    /// switch now, so the reason has to follow it: it stayed English under a German button.
    func testFailedLyricsFollowALanguageSwitch() async throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let lyrics = ImmersiveLyricsViewModel { _ in .instrumental }
        await lyrics.load(track: PlaybackNowPlaying(
            name: "Pod", artists: ["Host"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 60_000, positionMilliseconds: 0, uri: "spotify:episode:abc"
        ))
        guard case let .failed(message) = lyrics.phase else { return XCTFail("Expected failed lyrics") }

        try store.mutate { $0.appearance.language = .german }
        XCTAssertEqual(
            message.string,
            SpotiglassL10n.string("lyrics.error.musicOnly", locale: Locale(identifier: "de")),
            "The lyrics error stayed in the old language"
        )
    }

    /// A Home section that failed to load says why. The browser keeps it across a switch now.
    func testAFailedHomeSectionFollowsALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let failedRequest: HomeSectionState<[TrackRowViewModel]> = PlaylistBrowserViewModel.homeSectionState(
            for: SpotifyAPIError.server(statusCode: 503, message: nil, details: nil)
        )
        guard case let .failed(message) = failedRequest else { return XCTFail("Expected a failed section") }
        let english = message.string

        try store.mutate { $0.appearance.language = .german }
        XCTAssertNotEqual(message.string, english, "The Home section's error stayed in the old language")
        XCTAssertEqual(message.string, SpotiglassL10n.string("error.spotify.serverProblem", locale: Locale(identifier: "de")))
    }

    /// A queued song whose artist has no name shows the stand-in, copied into the queue in
    /// the language of the moment.
    func testAQueueRowsNamelessArtistFollowsALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let item = QueueItem(
            name: "Song",
            subtitle: UnnamedMusicItem.artist.placeholder,
            albumArtURL: nil,
            durationMilliseconds: 60_000,
            uri: "spotify:track:q"
        )
        let row = TrackRowViewModel(queueItem: item)

        try store.mutate { $0.appearance.language = .german }
        let german = UnnamedMusicItem.artist.placeholder(locale: Locale(identifier: "de"))
        XCTAssertEqual(item.subtitleInAppLanguage, german)
        XCTAssertEqual(row.subtitle, german)
    }

    /// Track lists compare their rows on every refresh. Text that knows what it is made from
    /// compares that instead of looking itself up: a lookup per row and side made comparing an
    /// unchanged 10,000-song list cost tens of milliseconds on the main thread.
    func testRowsCompareWithoutLookingTheirTextUp() {
        var lookups = 0
        func counted(_ text: String) -> String {
            lookups += 1
            return text
        }
        let left = LocalizedText(counted("Explicit"), comparedBy: "browser.trackBadge.explicit")
        let right = LocalizedText(counted("Explicit"), comparedBy: "browser.trackBadge.explicit")
        XCTAssertEqual(left, right)
        XCTAssertEqual(lookups, 0, "Comparing looked the text up")
        XCTAssertNotEqual(left, LocalizedText(counted("Explicit"), comparedBy: "browser.trackBadge.unavailable"))
        XCTAssertEqual(lookups, 0)

        let track = MusicTrack(
            id: "t", name: "Song", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 60_000,
            isExplicit: true, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t"
        )
        let item = MusicPlaylistTrackItem(id: "t", content: .track(track))
        XCTAssertEqual(TrackRowViewModel(item, listPosition: 1), TrackRowViewModel(item, listPosition: 1))

        // A refresh that finds a long list unchanged compares every row: no string lookups.
        let items = (0..<2_000).map { index in
            MusicPlaylistTrackItem(id: "t\(index)", content: .track(MusicTrack(
                id: "t\(index)", name: "Song \(index)", artists: ["A", "B"], albumArtworkURL: nil,
                durationMilliseconds: 60_000, isExplicit: index.isMultiple(of: 2), isPlayable: index % 7 != 0,
                linkedFromID: nil, uri: "spotify:track:t\(index)"
            )))
        }
        let shown = TrackRowViewModel.numberedPlaylistRows(items)
        let reloaded = TrackRowViewModel.numberedPlaylistRows(items)
        SpotiglassL10n.lookups.withLock { $0 = 0 }
        XCTAssertEqual(shown, reloaded)
        XCTAssertEqual(SpotiglassL10n.lookups.withLock { $0 }, 0, "Comparing an unchanged list looked strings up")
    }

    /// Palette search results are built by the service search in the language of the moment.
    /// Left open across a switch they kept it, and asking again the same way reused them and
    /// moved the highlight to the first row.
    func testOpenPaletteSearchResultsFollowALanguageSwitch() async throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let viewModel = CommandPaletteViewModel()
        var searches = 0
        viewModel.searchProvider = { _, _ in
            searches += 1
            var results = CommandPaletteSearchResults()
            results.tracks = ["a", "b", "c"].map { id in
                CommandPaletteItem(
                    id: "track-\(id)",
                    title: "Song \(id)",
                    subtitle: SpotiglassL10n.string("browser.likedSongs.title"),
                    iconSystemName: "music.note",
                    section: .tracks,
                    keywords: []
                ) {}
            }
            return results
        }
        viewModel.show()
        viewModel.query = "song"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        viewModel.selectedIndex = 1
        let highlighted = viewModel.visibleItems[1].id

        try store.mutate { $0.appearance.language = .german }
        viewModel.languageDidChange()
        await viewModel.waitForSearchCompletion()
        let german = SpotiglassL10n.string("browser.likedSongs.title", locale: Locale(identifier: "de"))
        XCTAssertEqual(searches, 2, "The open search was not asked for again")
        XCTAssertEqual(viewModel.visibleItems.first { $0.id == highlighted }?.subtitle, german)
        XCTAssertEqual(viewModel.visibleItems[viewModel.selectedIndex].id, highlighted, "A switch moved the highlight")

        // Moving down while the results are on their way again keeps the row moved to.
        try store.mutate { $0.appearance.language = .spanish }
        viewModel.languageDidChange()
        viewModel.moveSelection(delta: 1)
        let movedTo = viewModel.visibleItems[viewModel.selectedIndex].id
        XCTAssertNotEqual(movedTo, highlighted)
        await viewModel.waitForSearchCompletion()
        XCTAssertEqual(
            viewModel.visibleItems[viewModel.selectedIndex].id,
            movedTo,
            "The highlight jumped back when the results came in"
        )
    }

    /// A rate-limited palette search says why it waits. A switch during the wait cleared that
    /// while searching stayed blocked.
    func testAPaletteRateLimitErrorSurvivesALanguageSwitch() async throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let viewModel = CommandPaletteViewModel()
        viewModel.searchProvider = { _, _ in throw SpotifyAPIError.rateLimited(retryAfter: 600) }
        viewModel.show()
        viewModel.query = "song"
        viewModel.refresh()
        await viewModel.waitForSearchCompletion()
        let english = try XCTUnwrap(viewModel.errorText)

        try store.mutate { $0.appearance.language = .german }
        viewModel.languageDidChange()
        await viewModel.waitForSearchCompletion()
        let german = try XCTUnwrap(viewModel.errorText, "The switch hid the rate-limit error")
        XCTAssertNotEqual(german, english, "The palette's error stayed in the old language")
    }

    /// Recently-played cards on Home keep the names they were built with; a nameless album
    /// or artist read "Unknown album" / "Unknown artist" in the old language.
    func testRecentlyPlayedCardsFollowALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let track = MusicTrack(
            id: "t", name: "Song", artists: [""], albumArtworkURL: nil, albumName: nil, albumID: "alb",
            durationMilliseconds: 60_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t"
        )
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: track))

        try store.mutate { $0.appearance.language = .german }
        let german = Locale(identifier: "de")
        XCTAssertEqual(card.title, UnnamedMusicItem.album.placeholder(locale: german))
        XCTAssertEqual(card.subtitle, UnnamedMusicItem.artist.placeholder(locale: german))
        guard case let .album(_, title, _, _) = card.destination else { return XCTFail("Expected an album card") }
        XCTAssertEqual(title, UnnamedMusicItem.album.placeholder(locale: german), "The album opened under the old name")
    }

    /// The queue shows a song's artists as links, made from the names it was queued with, and
    /// an episode without a show as "Podcast" in the language it was queued in.
    func testQueueArtistLinksAndEpisodeFallbackFollowALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let track = MusicTrack(
            id: "t", name: "Song", artists: [""], artistRefs: [MusicArtistRef(id: "a", name: "")],
            albumArtworkURL: nil, durationMilliseconds: 60_000, isExplicit: false, isPlayable: true,
            linkedFromID: nil, uri: "spotify:track:t"
        )
        let queuedTrack = QueueItem.from(track: track)
        let queuedEpisode = QueueItem.from(episode: MusicEpisode(
            id: "e", name: "Episode", showName: nil, artworkURL: nil, durationMilliseconds: 60_000,
            isPlayable: true, uri: "spotify:episode:e"
        ))

        try store.mutate { $0.appearance.language = .spanish }
        let spanish = Locale(identifier: "es")
        XCTAssertEqual(
            queuedTrack.artistTapTargets.map(\.nameInAppLanguage),
            [UnnamedMusicItem.artist.placeholder(locale: spanish)]
        )
        XCTAssertEqual(
            queuedEpisode.subtitleInAppLanguage,
            SpotiglassL10n.string("playback.queue.episodeFallback", locale: spanish)
        )
        // A show that is really called "Podcast" keeps its name.
        let realShow = QueueItem.from(episode: MusicEpisode(
            id: "s", name: "Episode", showName: "Podcast", artworkURL: nil, durationMilliseconds: 60_000,
            isPlayable: true, uri: "spotify:episode:s"
        ))
        XCTAssertEqual(realShow.subtitleInAppLanguage, "Podcast")
    }

    /// A name that reads like a key is still a name: rows compare what their text is made from,
    /// and an episode whose show is literally called a key must not compare equal to one
    /// without a show.
    func testANameThatReadsLikeAKeyIsNotThatKey() {
        let key = "browser.trackBadge.podcastEpisode"
        XCTAssertNotEqual(
            LocalizedText(SpotiglassL10n.string(key), comparedByKey: key),
            LocalizedText(key, comparedBy: key)
        )
        func row(showName: String?) -> TrackRowViewModel {
            TrackRowViewModel(MusicPlaylistTrackItem(id: "e", content: .episode(MusicEpisode(
                id: "e", name: "Episode", showName: showName, artworkURL: nil, durationMilliseconds: 60_000,
                isPlayable: true, uri: "spotify:episode:e"
            ))), listPosition: 1)
        }
        XCTAssertNotEqual(row(showName: nil), row(showName: key))
    }

    /// Search keeps its results across a switch. An Apple Music library playlist's owner is the
    /// app's "You", which stayed in the old language there, and an album page's artist line kept
    /// "Unknown artist".
    func testSearchOwnersAndAlbumHeadersFollowALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let playlist = MusicPlaylistSummary(
            id: "p", name: "Mine", ownerID: AppleMusicBrowsingProvider.libraryUserID,
            ownerName: SpotiglassL10n.string("appleMusic.library.owner"), imageURL: nil, trackCount: 3, snapshotID: "s"
        )
        let header = PlaylistRowViewModel(
            albumDisplayName: "Awake", artistsDisplay: UnnamedMusicItem.artist.placeholder,
            totalTrackCount: 10, artworkURL: nil, albumID: "alb"
        )

        try store.mutate { $0.appearance.language = .german }
        let german = Locale(identifier: "de")
        XCTAssertEqual(playlist.ownerNameInAppLanguage, SpotiglassL10n.string("appleMusic.library.owner", locale: german))
        XCTAssertEqual(header.localizedOwner(), UnnamedMusicItem.artist.placeholder(locale: german))
    }

    /// The window title and the back button name the page by the label it was opened with. A
    /// nameless album's stand-in and the "Artist" fallback are the app's words.
    func testToolbarNamesFollowALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let album = BrowserBreadcrumb(
            id: UUID(), label: UnnamedMusicItem.album.placeholder, systemImage: "opticaldisc",
            kind: .album(id: "a", title: UnnamedMusicItem.album.placeholder, subtitle: "", artworkURL: nil)
        )
        let artist = BrowserBreadcrumb(
            id: UUID(), label: SpotiglassL10n.string("browser.breadcrumb.artistFallback"),
            systemImage: "person", kind: .artist(id: "r")
        )
        let named = BrowserBreadcrumb(id: UUID(), label: "Awake", systemImage: "opticaldisc",
            kind: .album(id: "b", title: "Awake", subtitle: "", artworkURL: nil))

        try store.mutate { $0.appearance.language = .german }
        let german = Locale(identifier: "de")
        XCTAssertEqual(BrowserToolbarPresentation.localizedLabel(for: album), UnnamedMusicItem.album.placeholder(locale: german))
        XCTAssertEqual(
            BrowserToolbarPresentation.localizedLabel(for: artist),
            SpotiglassL10n.string("browser.breadcrumb.artistFallback", locale: german)
        )
        XCTAssertEqual(BrowserToolbarPresentation.localizedLabel(for: named), "Awake")
    }

    /// Home links an artist under a card by matching its name to the service's ID. A nameless
    /// artist's stand-in on the card was taken before a switch and the ID's after it, so the
    /// link turned into plain text.
    func testHomeArtistLinksSurviveALanguageSwitch() throws {
        let store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
        let names = [UnnamedMusicItem.artist.placeholder, "B"]
        let refs = [MusicArtistRef(id: "a", name: "")]

        try store.mutate { $0.appearance.language = .german }
        let credits = HomeArtistCredit.credits(names: names, refs: refs)
        guard case .link = credits.first else { return XCTFail("The nameless artist lost its link: \(credits)") }
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
