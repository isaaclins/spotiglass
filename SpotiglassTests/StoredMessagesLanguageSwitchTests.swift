import MusicKit
import XCTest
@testable import Spotiglass

/// Since #548 a language switch keeps the window as it is, so a message already on screen has to
/// change language with everything else. These messages were kept as finished text, looked up once
/// when they appeared, and stayed in the old language (#571). Each test brings one up in English
/// the way the app does, switches to German and reads what the screen shows.
@MainActor
final class StoredMessagesLanguageSwitchTests: XCTestCase {
    private let german = Locale(identifier: AppLanguage.german.rawValue)
    private var store: SpotiglassSettingsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = store
        try store.mutate { $0.appearance.language = .english }
    }

    override func tearDown() {
        SpotiglassL10n.settingsStore = nil
        store = nil
        super.tearDown()
    }

    private func switchToGerman() throws {
        try store.mutate { $0.appearance.language = .german }
    }

    private func inGerman(_ key: String) -> String {
        SpotiglassL10n.string(key, locale: german)
    }

    /// The player bar's line when Spotify's player device goes away.
    func testTheDeviceLostLineFollowsALanguageSwitch() throws {
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        playback.handle(.ready(deviceID: "device-1"))
        playback.handle(.notReady(deviceID: "device-1"))
        func barLines() -> (title: String, subtitle: String)? {
            PlaybackControlsView.statusLines(for: playback.connectionState, playerPushesState: true, service: .spotify)
        }
        XCTAssertEqual(barLines()?.subtitle, SpotiglassL10n.string("error.playback.deviceLost.message", locale: Locale(identifier: "en")))

        try switchToGerman()

        XCTAssertEqual(barLines()?.title, inGerman("playback.controls.state.unavailable.title"))
        XCTAssertEqual(
            barLines()?.subtitle,
            inGerman("error.playback.deviceLost.message"),
            "The device-lost line stayed in the old language"
        )
    }

    /// A failed Spotify sign-in, as Settings › Account and the welcome screen show it.
    func testASpotifySignInErrorFollowsALanguageSwitch() async throws {
        let cases: [(error: Error, key: String)] = [
            (LoopbackOAuthCallbackError.timedOut, "auth.callback.timedOut"),
            (SpotifyAuthorizationFlowError.browserOpenFailed, "auth.flow.browserOpenFailed"),
            (SpotifyTokenClientError.invalidResponse, "auth.token.invalidResponse"),
            (URLError(.notConnectedToInternet), "auth.error.offline"),
        ]
        for (error, key) in cases {
            try store.mutate { $0.appearance.language = .english }
            let auth = AuthViewModel(
                settings: SpotifyAuthSettings(defaults: makeEphemeralDefaults()),
                authorizationFlow: ThrowingAuthorizationFlow(error: error),
                refreshTokenStore: NoRefreshTokenStore()
            )
            auth.clientID = "client-id"
            await auth.signIn()
            guard case .failed = auth.state else { return XCTFail("Sign-in with \(error) did not fail") }
            XCTAssertEqual(auth.state.message, SpotiglassL10n.string(key, locale: Locale(identifier: "en")))

            try switchToGerman()

            XCTAssertEqual(auth.state.title, inGerman("app.connection.failed.title"))
            XCTAssertEqual(auth.state.message, inGerman(key), "The sign-in error for \(error) stayed in the old language")
        }
    }

    /// Apple Music access that is off, or an Apple Music sign-in that lapsed, as the browser and
    /// the player bar say it.
    func testAppleMusicAccessErrorsFollowALanguageSwitch() throws {
        let accessOff = try XCTUnwrap(BrowsingDisplayError.appleMusic(for: MusicTokenRequestError.permissionDenied, service: .appleMusic))
        let signedOut = try XCTUnwrap(BrowsingDisplayError.appleMusic(for: MusicTokenRequestError.userNotSignedIn, service: .appleMusic))
        let playing = PlaybackSessionViewModel.displayError(
            for: MusicPlaybackError(service: .appleMusic, reason: .missingPermission, detail: "denied"),
            service: .appleMusic
        )
        let englishPlaying = playing.message

        try switchToGerman()

        XCTAssertEqual(accessOff.title, inGerman("error.playback.appleMusic.permission.title"))
        XCTAssertEqual(accessOff.message, inGerman("error.playback.appleMusic.permission.message"), "The access error stayed in the old language")
        XCTAssertEqual(signedOut.title, inGerman("appleMusic.error.signIn.title"))
        XCTAssertEqual(signedOut.message, inGerman("appleMusic.error.signIn.message"), "The sign-in error stayed in the old language")
        XCTAssertNotEqual(playing.message, englishPlaying, "The player's Apple Music access error stayed in the old language")
    }

    /// An error whose only fix was Reconnect, shown by a player that can't reconnect (Apple Music).
    /// The bar swaps in "isn't ready yet", which was resolved once and kept.
    func testAReplacedPlaybackErrorFollowsALanguageSwitch() throws {
        let playback = PlaybackSessionViewModel(provider: ReadOnlyStatePlaybackProvider())
        playback.setConnectionState(.error(PlaybackSessionViewModel.playbackDeviceReconnectRequiredError()))
        guard case let .error(shown) = playback.connectionState else { return XCTFail("Expected an error") }
        XCTAssertNil(shown.recoveryAction)

        try switchToGerman()

        XCTAssertEqual(
            shown.message,
            inGerman("error.playback.deviceUnavailable.notReady"),
            "The replaced error line stayed in the old language"
        )
    }

    /// A palette search that failed says so above the results.
    func testAFailedPaletteSearchFollowsALanguageSwitch() async throws {
        let palette = CommandPaletteViewModel()
        palette.searchProvider = { _, _ in throw SpotifyAPIError.server(statusCode: 503, message: nil, details: nil) }
        palette.show()
        palette.query = "abcd"
        palette.refresh()
        await palette.waitForSearchCompletion()
        XCTAssertEqual(palette.errorText, SpotiglassL10n.string("error.spotify.serverProblem", locale: Locale(identifier: "en")))

        try switchToGerman()

        XCTAssertEqual(palette.errorText, inGerman("error.spotify.serverProblem"), "The palette's error stayed in the old language")
    }

    /// Settings › Keyboard: a keymap that didn't apply. A key that can't be recorded is covered by
    /// `ZHotkeyRecorderFieldTests`, which drives the real field.
    func testAKeymapErrorFollowsALanguageSwitch() throws {
        let keymap = CommandPaletteKeymapStore(settingsStore: store)
        keymap.editorText = "{ not json"
        keymap.applyEditorText()
        let english = try XCTUnwrap(keymap.lastError)
        XCTAssertTrue(english.contains(SpotiglassL10n.string("palette.settings.advanced", locale: Locale(identifier: "en"))))

        try switchToGerman()

        let shown = try XCTUnwrap(keymap.lastError)
        XCTAssertNotEqual(shown, english, "The keymap error stayed in the old language")
        XCTAssertTrue(shown.contains(inGerman("palette.settings.advanced")), "The keymap error named its source in the old language")
    }

    /// The note at the bottom of a list after adding, moving or removing tracks.
    func testATrackEditNoteFollowsALanguageSwitch() async throws {
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:])
        let browser = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let track = MusicTrack(
            id: "t", name: "Song", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 60_000,
            isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t"
        )
        await browser.addRowsToPlaylist([TrackRowViewModel(topTrack: track, listPosition: 1)], playlistID: "p", playlistName: "Mix")
        let english = try XCTUnwrap(browser.trackMutationToast)

        try switchToGerman()

        XCTAssertNotEqual(browser.trackMutationToast, english, "The note stayed in the old language")
        XCTAssertEqual(
            browser.trackMutationToast,
            String(format: inGerman("playlist.mutation.addedToPlaylist"), Int64(1), "Mix")
        )
    }

    /// The window title names a playlist or artist whose name isn't known yet with a stand-in.
    func testATitleStandInFollowsALanguageSwitch() throws {
        let browser = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [], trackResults: [:]), cache: MockBrowsingCache())
        browser.applyBreadcrumbForSidebar(.playlist("unknown"), origin: .reset)
        let playlistCrumb = try XCTUnwrap(browser.breadcrumbPath.last)
        browser.applyBreadcrumbForArtist(id: "unknown", displayName: nil, origin: .reset)
        let artistCrumb = try XCTUnwrap(browser.breadcrumbPath.last)

        // "Playlist" is the same word in German, so this one switches to Spanish.
        try store.mutate { $0.appearance.language = .spanish }
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

        XCTAssertEqual(
            BrowserToolbarPresentation.localizedLabel(for: playlistCrumb),
            SpotiglassL10n.string("browser.breadcrumb.playlistFallback", locale: spanish)
        )
        XCTAssertEqual(
            BrowserToolbarPresentation.localizedLabel(for: artistCrumb),
            SpotiglassL10n.string("browser.breadcrumb.artistFallback", locale: spanish)
        )
    }

    /// The window title for a playlist that has loaded without a name, and for an artist or album
    /// opened from a row that named it with the stand-in.
    func testANamelessItemsTitleFollowsALanguageSwitch() throws {
        let browser = PlaylistBrowserViewModel(api: MockBrowsingAPI(playlistResults: [], trackResults: [:]), cache: MockBrowsingCache())
        browser.playlistsByID["blank"] = MusicPlaylistSummary(
            id: "blank", name: " ", ownerID: "me", ownerName: "Me", imageURL: nil, trackCount: 0, snapshotID: "s"
        )
        browser.applyBreadcrumbForSidebar(.playlist("blank"), origin: .reset)
        let playlistCrumb = try XCTUnwrap(browser.breadcrumbPath.last)
        XCTAssertEqual(playlistCrumb.label, "Untitled Playlist")
        browser.applyBreadcrumbForArtist(id: "a", displayName: UnnamedMusicItem.artist.placeholder, origin: .reset)
        let artistCrumb = try XCTUnwrap(browser.breadcrumbPath.last)
        browser.applyBreadcrumbForAlbum(
            id: "al", title: UnnamedMusicItem.album.placeholder, subtitle: "", artworkURL: nil, origin: .reset
        )
        let albumCrumb = try XCTUnwrap(browser.breadcrumbPath.last)

        try switchToGerman()

        XCTAssertEqual(
            BrowserToolbarPresentation.localizedLabel(for: playlistCrumb),
            UnnamedMusicItem.playlist.placeholder(locale: german),
            "A nameless playlist's title stayed in the old language"
        )
        XCTAssertEqual(BrowserToolbarPresentation.localizedLabel(for: artistCrumb), UnnamedMusicItem.artist.placeholder(locale: german))
        XCTAssertEqual(BrowserToolbarPresentation.localizedLabel(for: albumCrumb), UnnamedMusicItem.album.placeholder(locale: german))
    }

    /// The page a yearless album pin opens says "Album" under the title, and the back button names a
    /// nameless album or artist, in the language of the moment.
    func testAnAlbumPagesLineAndTheBackButtonFollowALanguageSwitch() async throws {
        let song = MusicTrack(
            id: "t", name: "Song", artists: ["A"], albumArtworkURL: nil, durationMilliseconds: 60_000,
            isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t"
        )
        let api = MockBrowsingAPI(playlistResults: [], trackResults: [:], albumTracksHandler: { _, _, _ in [song] })
        let browser = PlaylistBrowserViewModel(api: api, cache: MockBrowsingCache())
        let pin = PinnedItem.album(MusicArtistAlbum(
            id: "al", name: " ", imageURL: nil, releaseYear: nil, totalTracks: 1, group: .album, uri: "spotify:album:al"
        ))
        guard case let .selectAlbum(id, title, subtitle, artworkURL)? = PlaylistBrowserPinnedItemActivation.route(
            for: pin, previousSelection: nil
        ) else { return XCTFail("The pin did not open an album") }
        await browser.selectAlbum(id: id, displayTitle: title, displaySubtitle: subtitle, artworkURL: artworkURL)
        guard case let .loaded(.playlist(detail)) = browser.detailState else {
            return XCTFail("The album page did not load: \(String(describing: browser.detailState))")
        }
        XCTAssertTrue(detail.playlist.ownerTracksLine(currentUserID: nil).hasPrefix("Album"))
        let album = BrowserNavigationTarget.album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
        XCTAssertEqual(browser.displayName(for: album), "Unknown album")
        browser.backNavigationArtistNames["a"] = UnnamedMusicItem.artist.placeholder

        // "Album" is the same word in German, so this one switches to Spanish.
        try store.mutate { $0.appearance.language = .spanish }
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

        XCTAssertTrue(
            detail.playlist.ownerTracksLine(currentUserID: nil).hasPrefix(SpotiglassL10n.string("pin.album.default", locale: spanish)),
            "The album page's line stayed in the old language"
        )
        XCTAssertEqual(browser.displayName(for: album), UnnamedMusicItem.album.placeholder(locale: spanish))
        XCTAssertEqual(browser.displayName(for: .artist("a")), UnnamedMusicItem.artist.placeholder(locale: spanish))
    }

    /// An album without a name on an artist page.
    func testANamelessAlbumOnAnArtistPageFollowsALanguageSwitch() throws {
        let card = ArtistAlbumRowViewModel(MusicArtistAlbum(
            id: "al", name: "", imageURL: nil, releaseYear: "2024", totalTracks: 1, group: .album, uri: "spotify:album:al"
        ))
        XCTAssertEqual(card.title, UnnamedMusicItem.album.placeholder(locale: Locale(identifier: "en")))

        try switchToGerman()

        XCTAssertEqual(card.title, UnnamedMusicItem.album.placeholder(locale: german), "The album card stayed in the old language")
    }

    /// Settings › Keyboard: a chord a menu item owns names that menu item, in the language of the
    /// moment.
    func testAMenuOwnedChordsMessageFollowsALanguageSwitch() throws {
        let keymap = CommandPaletteKeymapStore(settingsStore: store)
        let chord = try CommandShortcut(keystroke: "cmd-left")
        var shown: LocalizedText?
        XCTAssertThrowsError(
            try keymap.setBinding(commandID: CommandPaletteCommandID.openSettings, shortcut: chord, replaceConflicting: false)
        ) { error in
            shown = CommandPaletteKeymapErrorPresenter.text(for: error, source: "keymap", operation: "test")
        }
        let message = try XCTUnwrap(shown)
        XCTAssertTrue(message.string.contains("Seek Backward"))

        try switchToGerman()

        XCTAssertTrue(
            message.string.contains(inGerman("menu.playback.seekBackward")),
            "The menu item in \(message.string) stayed in the old language"
        )
    }

    /// An album pinned from an artist page without a release year says "Album" under its name.
    func testAnAlbumPinWithoutAYearFollowsALanguageSwitch() throws {
        let pin = PinnedItem.album(MusicArtistAlbum(
            id: "al", name: "Record", imageURL: nil, releaseYear: nil, totalTracks: 1, group: .album, uri: "spotify:album:al"
        ))
        XCTAssertEqual(pin.localizedSubtitle(), "Album")
        // "Album" is the same word in German, so this one switches to Spanish.
        try store.mutate { $0.appearance.language = .spanish }

        XCTAssertEqual(pin.localizedSubtitle(), SpotiglassL10n.string("pin.album.default", locale: Locale(identifier: AppLanguage.spanish.rawValue)))
    }

    /// Stand-ins kept with a queued episode and a Home card.
    func testStoredStandInsFollowALanguageSwitch() throws {
        let episode = QueueItem.from(episode: MusicEpisode(
            id: "e", name: "Episode", showName: nil, artworkURL: nil,
            durationMilliseconds: 60_000, isPlayable: true, uri: "spotify:episode:e"
        ))
        let card = try XCTUnwrap(HomeMediaCard(recentlyPlayed: MusicTrack(
            id: "t", name: "Song", artists: ["A"], albumArtworkURL: nil, albumName: nil, albumID: "alb",
            durationMilliseconds: 60_000, isExplicit: false, isPlayable: true, linkedFromID: nil, uri: "spotify:track:t"
        )))
        // "Podcast" is the same word in German, so this one switches to Spanish.
        try store.mutate { $0.appearance.language = .spanish }
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)

        XCTAssertEqual(episode.subtitleInAppLanguage, SpotiglassL10n.string("playback.queue.episodeFallback", locale: spanish))
        XCTAssertEqual(card.title, UnnamedMusicItem.album.placeholder(locale: spanish))
    }
}

private struct ThrowingAuthorizationFlow: SpotifyAuthorizationFlowing {
    let error: Error

    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        throw error
    }
}

private final class NoRefreshTokenStore: RefreshTokenStore {
    func loadRefreshToken() throws -> String? { nil }
    func saveRefreshToken(_ refreshToken: String) throws {}
    func deleteRefreshToken() throws {}
}
