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
}
