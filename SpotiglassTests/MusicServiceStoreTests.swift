import Combine
import AppKit
import ViewInspector
import XCTest
@testable import Spotiglass

/// The service switcher (#373): which services are added, which one is on screen, how existing
/// Spotify setups carry over, and the palette commands and ⌃1 / ⌃2 that switch between them.
@MainActor
final class MusicServiceStoreTests: XCTestCase {
    override func tearDown() {
        ViewTestHost.tearDownAll()
        super.tearDown()
    }

    private func makeKeymapStore() -> CommandPaletteKeymapStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicServiceStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return CommandPaletteKeymapStore(fileURL: url)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "MusicServiceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - First launch of this version

    /// An existing Spotify user (a saved client ID) lands straight in Spotify. Pins and caches are
    /// keyed by the Spotify account, not by the service list, so nothing else has to move.
    func testExistingSpotifySetupBecomesTheSpotifySpace() {
        let defaults = makeDefaults()
        defaults.set("my-client-id", forKey: MusicServiceStore.legacySpotifyClientIDKey)

        let store = MusicServiceStore(storage: defaults)

        XCTAssertEqual(store.services, [.spotify])
        XCTAssertEqual(store.active, .spotify)
        XCTAssertEqual(defaults.stringArray(forKey: MusicServiceStore.servicesKey), ["spotify"])
        XCTAssertEqual(defaults.string(forKey: MusicServiceStore.activeKey), "spotify")
        // The client ID itself is Spotify's and stays where it was.
        XCTAssertEqual(defaults.string(forKey: MusicServiceStore.legacySpotifyClientIDKey), "my-client-id")
    }

    /// A fresh install has nothing set up and shows the welcome screen.
    func testFreshInstallStartsOnTheWelcomeScreen() {
        let defaults = makeDefaults()
        defaults.set("", forKey: MusicServiceStore.legacySpotifyClientIDKey)

        let store = MusicServiceStore(storage: defaults)

        XCTAssertEqual(store.services, [])
        XCTAssertNil(store.active)
        XCTAssertEqual(store.addableServices, [.appleMusic, .spotify])
    }

    /// The old hidden developer switch carries over as an added Apple Music, next to Spotify.
    func testHiddenDeveloperSwitchCarriesOver() {
        let defaults = makeDefaults()
        defaults.set("my-client-id", forKey: MusicServiceStore.legacySpotifyClientIDKey)
        defaults.set("appleMusic", forKey: MusicServiceStore.legacyDeveloperSwitchKey)

        let store = MusicServiceStore(storage: defaults)

        XCTAssertEqual(store.orderedServices, [.appleMusic, .spotify])
        XCTAssertEqual(store.active, .appleMusic)
    }

    /// Once saved, the list wins over the derivation, even when it says nothing is added.
    func testSavedChoiceIsRestored() {
        let defaults = makeDefaults()
        defaults.set("my-client-id", forKey: MusicServiceStore.legacySpotifyClientIDKey)
        defaults.set(["appleMusic", "spotify"], forKey: MusicServiceStore.servicesKey)
        defaults.set("spotify", forKey: MusicServiceStore.activeKey)
        XCTAssertEqual(MusicServiceStore(storage: defaults).active, .spotify)

        defaults.set([String](), forKey: MusicServiceStore.servicesKey)
        defaults.removeObject(forKey: MusicServiceStore.activeKey)
        let empty = MusicServiceStore(storage: defaults)
        XCTAssertEqual(empty.services, [])
        XCTAssertNil(empty.active)
    }

    /// Unknown, duplicate and unavailable entries are dropped; a stale active falls back.
    func testRestoreDropsWhatItCannotShow() {
        let storage = InMemoryMusicServiceSelectionStorage()
        storage.set(["spotify", "tidal", "spotify", "appleMusic"], forKey: MusicServiceStore.servicesKey)
        storage.set("appleMusic", forKey: MusicServiceStore.activeKey)

        let store = MusicServiceStore(storage: storage, availableServices: [.spotify])

        XCTAssertEqual(store.services, [.spotify])
        XCTAssertEqual(store.active, .spotify)
        XCTAssertEqual(store.addableServices, [])
    }

    // MARK: - Switching

    func testSwitchingKeepsBothServicesAndPersists() {
        let defaults = makeDefaults()
        defaults.set(["spotify", "appleMusic"], forKey: MusicServiceStore.servicesKey)
        defaults.set("spotify", forKey: MusicServiceStore.activeKey)
        let store = MusicServiceStore(storage: defaults)
        XCTAssertEqual(store.switchTargets, [.appleMusic])

        XCTAssertTrue(store.activate(.appleMusic))

        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertEqual(store.orderedServices, [.appleMusic, .spotify])
        XCTAssertEqual(store.switchTargets, [.spotify])
        XCTAssertEqual(MusicServiceStore(storage: defaults).active, .appleMusic)
        // Switching to what is already on screen, or to a service that isn't added, does nothing.
        XCTAssertFalse(store.activate(.appleMusic))
        let spotifyOnly = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        XCTAssertFalse(spotifyOnly.activate(.appleMusic))
        XCTAssertEqual(spotifyOnly.active, .spotify)
    }

    // MARK: - Adding a service

    func testAddingAServiceShowsItsSignInUntilItSucceeds() {
        let storage = InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        let store = MusicServiceStore(storage: storage)

        store.beginAddition(of: .appleMusic)
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertEqual(store.pendingAddition, .appleMusic)
        XCTAssertEqual(store.services, [.spotify], "not added before access is granted")
        XCTAssertEqual(storage.string(forKey: MusicServiceStore.activeKey), "spotify",
                       "a relaunch mid-sign-in comes back to the space that was signed in")

        store.completeAddition(of: .appleMusic)
        XCTAssertEqual(store.services, [.spotify, .appleMusic])
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertNil(store.pendingAddition)
        XCTAssertEqual(storage.string(forKey: MusicServiceStore.activeKey), "appleMusic")
        XCTAssertEqual(store.addableServices, [])
    }

    func testCancellingAnAdditionGoesBack() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )
        store.beginAddition(of: .spotify)
        XCTAssertTrue(store.canCancelAddition)

        store.cancelAddition()

        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertNil(store.pendingAddition)
        XCTAssertEqual(store.services, [.appleMusic])
    }

    func testCancellingTheFirstServiceGoesBackToTheWelcomeScreen() {
        let store = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(services: [], active: nil))
        store.beginAddition(of: .spotify)
        XCTAssertEqual(store.active, .spotify)

        store.cancelAddition()

        XCTAssertNil(store.active)
    }

    /// A Spotify sign-in started in Settings while Apple Music is on screen adds Spotify to the
    /// menu without moving the window.
    func testSignInOutsideAnAdditionAddsWithoutSwitching() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )

        store.completeAddition(of: .spotify)

        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertEqual(store.switchTargets, [.spotify])
    }

    func testAddingAnAddedServiceJustSwitches() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .spotify)
        )
        store.beginAddition(of: .appleMusic)
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertNil(store.pendingAddition)
    }

    // MARK: - Signing out

    func testSigningOutHandsTheWindowToTheOtherService() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify, .appleMusic], active: .spotify)
        )
        store.lastPinnedUserID[.spotify] = "spotify-user"

        store.signOutRemoving(.spotify)

        XCTAssertEqual(store.services, [.appleMusic])
        XCTAssertEqual(store.active, .appleMusic)
        XCTAssertNil(store.lastPinnedUserID[.spotify])
    }

    /// Signing out of Spotify as the only service keeps today's behaviour: Spotify's sign-in.
    func testSigningOutOfTheOnlySpotifyKeepsItsSignInScreen() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )

        store.signOutRemoving(.spotify)

        XCTAssertEqual(store.services, [.spotify])
        XCTAssertEqual(store.active, .spotify)
    }

    /// A lapsed Spotify session keeps Spotify in the menu, so Disconnect must be able to remove it
    /// without a live session (#399). Only the lone Spotify keeps its sign-in screen instead, and
    /// a service that is only being added is left to Cancel.
    func testSignOutRemovesFromMenuOnlyWhenSomethingIsLeft() {
        let both = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .appleMusic)
        )
        XCTAssertTrue(both.signOutRemovesFromMenu(.spotify))
        XCTAssertTrue(both.signOutRemovesFromMenu(.appleMusic))

        let spotifyOnly = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        XCTAssertFalse(spotifyOnly.signOutRemovesFromMenu(.spotify))

        let addingSpotify = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )
        addingSpotify.beginAddition(of: .spotify)
        XCTAssertFalse(addingSpotify.signOutRemovesFromMenu(.spotify))
    }

    /// Apple Music has no sign-in screen of its own: signing out of the last one shows the
    /// welcome screen.
    func testSigningOutOfTheOnlyAppleMusicShowsTheWelcomeScreen() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )

        store.signOutRemoving(.appleMusic)

        XCTAssertEqual(store.services, [])
        XCTAssertNil(store.active)
    }

    // MARK: - Screenshot mode and names

    func testCommandIDsMapBothWays() {
        for service in MusicService.allCases {
            XCTAssertEqual(MusicService(switchCommandID: service.switchCommandID), service)
        }
        XCTAssertNil(MusicService(switchCommandID: CommandPaletteCommandID.openSettings))
        XCTAssertEqual(MusicService.spotify.displayName, "Spotify")
        XCTAssertEqual(MusicService.appleMusic.displayName, "Apple Music")
    }

    func testLogosAreBundledTemplateImages() throws {
        for service in MusicService.allCases {
            let icon = try XCTUnwrap(service.menuIcon(pointSize: 16), "\(service) logo missing")
            XCTAssertEqual(icon.size.height, 16)
            XCTAssertTrue(icon.isTemplate)
        }
    }

    // MARK: - Palette and ⌃1 / ⌃2

    func testDefaultShortcutsFollowTheMenuOrder() {
        let appleMusic = CommandPaletteCommandCatalog.editable.first {
            $0.commandID == CommandPaletteCommandID.switchToAppleMusic
        }
        let spotify = CommandPaletteCommandCatalog.editable.first {
            $0.commandID == CommandPaletteCommandID.switchToSpotify
        }
        XCTAssertEqual(appleMusic?.defaultKeystroke, "ctrl-1")
        XCTAssertEqual(spotify?.defaultKeystroke, "ctrl-2")
        XCTAssertEqual(appleMusic?.defaultWhen, .always)
        XCTAssertEqual(MusicService.switcherOrder, [.appleMusic, .spotify])
    }

    func testPaletteOffersOnlyTheOtherAddedService() {
        let manager = CommandPaletteManager()
        var switched: [MusicService] = []
        manager.switchService = { switched.append($0) }
        manager.switchableServices = [.appleMusic]

        let ids = Set(manager.viewModel.staticItemsProvider().map(\.id))
        XCTAssertTrue(ids.contains(CommandPaletteCommandID.switchToAppleMusic))
        XCTAssertFalse(ids.contains(CommandPaletteCommandID.switchToSpotify))

        manager.execute(commandID: CommandPaletteCommandID.switchToSpotify)
        manager.execute(commandID: CommandPaletteCommandID.switchToAppleMusic)
        XCTAssertEqual(switched, [], "the switch waits until the palette has closed")
        drainMainQueue()
        XCTAssertEqual(switched, [.appleMusic])

        manager.switchableServices = []
        let none = Set(manager.viewModel.staticItemsProvider().map(\.id))
        XCTAssertFalse(none.contains(CommandPaletteCommandID.switchToAppleMusic))
    }

    /// Detaching a scene (sign-out, switching) keeps the switch wired: ⌃1 / ⌃2 also work from a
    /// sign-in screen.
    func testDetachKeepsSwitching() {
        let manager = CommandPaletteManager()
        var switched: [MusicService] = []
        manager.switchService = { switched.append($0) }
        manager.switchableServices = [.spotify]

        manager.detach()
        manager.execute(commandID: CommandPaletteCommandID.switchToSpotify)
        drainMainQueue()

        XCTAssertEqual(switched, [.spotify])
    }

    func testControlTwoSwitchesThroughTheKeymap() throws {
        let manager = CommandPaletteManager(keymapStore: makeKeymapStore())
        var switched: [MusicService] = []
        manager.switchService = { switched.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "2",
            charactersIgnoringModifiers: "2",
            isARepeat: false,
            keyCode: 19
        ))

        // Not added: the chord passes through untouched.
        manager.switchableServices = []
        XCTAssertFalse(manager.handleKeyEvent(event))

        manager.switchableServices = [.spotify]
        XCTAssertTrue(manager.handleKeyEvent(event))
        drainMainQueue()
        XCTAssertEqual(switched, [.spotify])
    }

    // MARK: - Views

    func testSwitcherShowsTheActiveService() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .spotify)
        )
        let view = MusicServiceSwitcher(
            store: store,
            keymapStore: makeKeymapStore(),
            switchTo: { _ in },
            add: { _ in }
        )
        ViewTestHost.host(view)
        XCTAssertNoThrow(try view.inspect().find(text: "Spotify"))
    }

    /// The menu lists every added service in ⌃ order with a checkmark on the active one, shows
    /// each service's shortcut, and "Add a service…" is only enabled while one is left to add.
    func testMenuListsServicesWithCheckmarkShortcutsAndAdd() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify, .appleMusic], active: .spotify)
        )
        var switched: [MusicService] = []
        let switcher = MusicServiceSwitcher(
            store: store,
            keymapStore: makeKeymapStore(),
            switchTo: { switched.append($0) },
            add: { _ in XCTFail("nothing left to add") }
        )
        let anchor = MusicServiceMenuAnchor()
        let menu = anchor.makeMenu(items: switcher.menuItems())

        XCTAssertEqual(menu.items.map(\.title), ["Apple Music", "Spotify", "", "Add a service…"])
        XCTAssertEqual(menu.items[0].state, .off)
        XCTAssertEqual(menu.items[1].state, .on)
        XCTAssertEqual(menu.items[0].keyEquivalent, "1")
        XCTAssertEqual(menu.items[1].keyEquivalent, "2")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.control])
        XCTAssertNotNil(menu.items[0].image)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertFalse(menu.items[3].isEnabled)

        let item = menu.items[0]
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        let ran = expectation(description: "menu action runs after the menu closes")
        DispatchQueue.main.async { ran.fulfill() }
        wait(for: [ran], timeout: 1)
        XCTAssertEqual(switched, [.appleMusic])
    }

    func testMenuAddsTheMissingService() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        var added: [MusicService] = []
        let switcher = MusicServiceSwitcher(
            store: store,
            keymapStore: makeKeymapStore(),
            switchTo: { _ in },
            add: { added.append($0) }
        )
        let anchor = MusicServiceMenuAnchor()
        let menu = anchor.makeMenu(items: switcher.menuItems())
        let addItem = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(addItem.isEnabled)
        XCTAssertEqual(addItem.title, SpotiglassL10n.string("switcher.addService"))

        _ = (addItem.target as? NSObject)?.perform(addItem.action, with: addItem)
        let ran = expectation(description: "add runs")
        DispatchQueue.main.async { ran.fulfill() }
        wait(for: [ran], timeout: 1)
        XCTAssertEqual(added, [.appleMusic])
        XCTAssertNil(MusicServiceMenuItem.separator.title)
        withExtendedLifetime(anchor) {}
    }

    func testWelcomeChoiceStartsThatService() throws {
        var chosen: [MusicService] = []
        let view = MusicServiceWelcomeView(services: [.appleMusic, .spotify]) { chosen.append($0) }
        ViewTestHost.host(view)
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 2)
        try buttons[1].tap()
        try buttons[0].tap()
        XCTAssertEqual(chosen, [.spotify, .appleMusic])
        ViewTestHost.assertFindLocalizedText("welcome.service.appleMusic.detail", in: view)
        ViewTestHost.assertFindLocalizedText("welcome.service.spotify.detail", in: view)
    }

    func testSignInFooterSwitchesToAnAddedService() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify, .appleMusic], active: .spotify)
        )
        var switched: [MusicService] = []
        let view = MusicServiceSignInFooter(store: store, switchTo: { switched.append($0) }, add: { _ in })
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.format("switcher.switchTo", "Apple Music")).tap()

        XCTAssertEqual(switched, [.appleMusic])
    }

    func testSwitcherLogoUsesTheServiceAsset() throws {
        let logo = MusicServiceLogo(service: .appleMusic, size: 30)
        ViewTestHost.host(logo)
        XCTAssertNoThrow(try logo.inspect().find(ViewType.Image.self))
        XCTAssertEqual(MusicService.spotify.logoAssetName, "SpotifyIcon")
        XCTAssertEqual(MusicService.appleMusic.logoAssetName, "AppleMusicIcon")
    }

    func testWelcomeOffersEveryService() throws {
        var chosen: [MusicService] = []
        let view = MusicServiceWelcomeView(services: [.appleMusic, .spotify]) { chosen.append($0) }
        ViewTestHost.host(view)
        ViewTestHost.assertFindLocalizedText("welcome.service.message", in: view)
        XCTAssertNoThrow(try view.inspect().find(text: "Apple Music"))
        XCTAssertNoThrow(try view.inspect().find(text: "Spotify"))
    }

    func testSignInFooterCancelsAnAddition() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        store.beginAddition(of: .appleMusic)
        let view = MusicServiceSignInFooter(store: store, switchTo: { _ in }, add: { _ in })
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.string("switcher.cancelAddition")).tap()

        XCTAssertEqual(store.active, .spotify)
    }

    func testSignInFooterOffersTheOtherService() throws {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        var added: [MusicService] = []
        let view = MusicServiceSignInFooter(store: store, switchTo: { _ in }, add: { added.append($0) })
        ViewTestHost.host(view)

        try view.inspect().find(button: SpotiglassL10n.format("switcher.useInstead", "Apple Music")).tap()

        XCTAssertEqual(added, [.appleMusic])
    }

    // MARK: - Spotify sign-in from anywhere

    /// Connecting Spotify in Settings while every main window is closed: no window is there to see
    /// the sign-in, so the app-wide store has to add Spotify itself. It used to stay out of the
    /// service menu, ⌃2 and the palette, and the next launch skipped restoring it.
    func testSpotifySignInWithNoWindowAddsSpotify() async throws {
        let defaults = makeDefaults()
        defaults.set("client", forKey: MusicServiceStore.legacySpotifyClientIDKey)
        let http = QueueHTTPClient([.json("""
            {"access_token":"test-access","token_type":"Bearer","expires_in":3600,
             "refresh_token":"test-refresh",
             "scope":"playlist-read-private playlist-read-collaborative user-library-read streaming"}
            """)])
        let auth = AuthViewModel(
            settings: SpotifyAuthSettings(defaults: defaults),
            authorizationFlow: ImmediateSpotifyAuthorizationFlow(),
            tokenClient: SpotifyTokenClient(httpClient: http),
            refreshTokenStore: MemoryOnlyRefreshTokenStore(),
            signOutDataCleaner: {},
            artworkCacheClearer: {}
        )
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )
        store.followSpotifySignIn(auth.$state)
        XCTAssertFalse(store.isAdded(.spotify))

        await auth.signIn()

        guard case .signedIn = auth.state else { return XCTFail("Sign-in fixture failed: \(auth.state)") }
        XCTAssertTrue(store.isAdded(.spotify))
        XCTAssertEqual(store.switchTargets, [.spotify])
        // Connecting from Settings never moves the window.
        XCTAssertEqual(store.active, .appleMusic)
    }

    /// Signing out again doesn't add anything back, and a failed or cancelled sign-in adds nothing.
    func testOnlyASuccessfulSpotifySignInAddsSpotify() {
        let states = PassthroughSubject<AppConnectionState, Never>()
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic], active: .appleMusic)
        )
        store.followSpotifySignIn(states)

        states.send(.signingIn)
        states.send(.failed(AuthDisplayError(message: "nope")))
        states.send(.signedOut)
        states.send(.refreshing(nil))

        XCTAssertEqual(store.services, [.appleMusic])
    }

    /// A token refresh that finishes just as Spotify is signed out must not put it back: only a
    /// real sign-in (signed out → signed in) adds Spotify.
    func testTokenRefreshAfterSignOutDoesNotReaddSpotify() {
        let session = AuthenticatedSession(
            accessToken: "a", tokenType: "Bearer", scope: "", expiresAt: .distantFuture
        )
        let states = CurrentValueSubject<AppConnectionState, Never>(.signedIn(session))
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .appleMusic)
        )
        store.followSpotifySignIn(states)

        store.signOutRemoving(.spotify)
        states.send(.refreshing(session))
        states.send(.signedIn(session))

        XCTAssertEqual(store.services, [.appleMusic])
    }

    /// With Apple Music added, Disconnect Spotify promised "the sign-in screen" but the window
    /// went to Apple Music (#397). The alert now says where it goes.
    func testDisconnectAlertSaysWhereTheWindowGoes() {
        let store = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.appleMusic, .spotify], active: .spotify)
        )
        let next = store.orderedServices.first { $0 != .spotify }
        XCTAssertEqual(
            PlaylistBrowserView.disconnectConfirmationMessage(switchingTo: next),
            "Spotify is removed from Spotiglass and the window switches to Apple Music. The saved session is cleared."
        )
        XCTAssertEqual(PlaylistBrowserView.disconnectHint(switchingTo: next), "Disconnects Spotify and switches to Apple Music.")

        store.signOutRemoving(.spotify)
        XCTAssertEqual(store.active, next)

        // Spotify alone: Disconnect shows Spotify's sign-in again, as the old text says.
        XCTAssertEqual(
            PlaylistBrowserView.disconnectConfirmationMessage(switchingTo: nil),
            SpotiglassL10n.string("browser.disconnect.confirm.message")
        )
    }
}

/// One player per service (#373): what's playing keeps playing across a switch, until something
/// starts in the other library.
@MainActor
final class PlaybackHandoverTests: XCTestCase {
    private func playingSpotify() -> (SpotiglassPlaybackHost, MockWebPlaybackCommander) {
        _ = NSApplication.shared
        let commander = MockWebPlaybackCommander()
        let host = SpotiglassPlaybackHost(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: commander)
        )
        let playback = host.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "Midnight City", artists: [], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 240_000, positionMilliseconds: 1_000, uri: "spotify:track:1"
        )))
        return (host, commander)
    }

    /// Spotify's in-app player pauses through its own toggle (the Web Playback SDK).
    private func toggles(_ commander: MockWebPlaybackCommander) -> Int {
        commander.commands.filter { $0.command == .togglePlay }.count
    }

    func testStartingMusicInAppleMusicPausesSpotify() async throws {
        let (spotify, commander) = playingSpotify()
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }

        // Switching to Apple Music alone keeps Spotify playing.
        let appleMusic = hosts.appleMusic
        hosts.gate(activeService: .appleMusic)
        XCTAssertEqual(toggles(commander), 0)

        appleMusic.playbackViewModel.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        await appleMusic.playbackViewModel.play(uri: "applemusic:song:1")
        for _ in 0..<20 where toggles(commander) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(toggles(commander), 1, "Spotify pauses once Apple Music starts something")
    }

    /// Resuming is starting music too: Play on Apple Music's bar while Spotify plays pauses
    /// Spotify, so the two never play at once.
    func testResumingAppleMusicPausesSpotify() async throws {
        let (spotify, commander) = playingSpotify()
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }
        let appleMusic = hosts.appleMusic.playbackViewModel
        hosts.gate(activeService: .appleMusic)
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        appleMusic.setConnectionState(.paused(PlaybackNowPlaying(
            name: "Can't Hold Us", artists: [], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 258_000, positionMilliseconds: 30_000, uri: "applemusic:song:1"
        )))

        await appleMusic.togglePlayPause()
        for _ in 0..<20 where toggles(commander) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(toggles(commander), 1, "Spotify pauses once Apple Music resumes")
    }

    /// A Spotify-only setup never creates Apple Music's player, so it never reaches MusicKit.
    func testSpotifyOnlyNeverCreatesTheAppleMusicPlayer() {
        let (spotify, _) = playingSpotify()
        var created = 0
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            created += 1
            return SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }

        hosts.gate(activeService: .spotify)
        XCTAssertTrue(hosts.spotify === spotify)

        XCTAssertEqual(created, 0)
        XCTAssertNil(hosts.appleMusicIfCreated)
        XCTAssertFalse(spotify.playbackViewModel.refusesNewPlayback)
    }
}

private struct ImmediateSpotifyAuthorizationFlow: SpotifyAuthorizationFlowing {
    func requestAuthorizationCode(clientID: String, timeout: TimeInterval) async throws -> SpotifyAuthorizationCode {
        SpotifyAuthorizationCode(
            code: "test",
            codeVerifier: try PKCE.makeCodeVerifier(),
            redirectURI: URL(string: "http://127.0.0.1:43824/callback")!
        )
    }
}

