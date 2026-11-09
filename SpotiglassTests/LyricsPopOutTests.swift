import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Spotiglass

/// The pop-out lyrics window (#439).
@MainActor
final class LyricsPopOutTests: XCTestCase {
    private func makeManager() -> (CommandPaletteManager, CommandPaletteKeymapStore) {
        let settings = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        return (manager, keymap)
    }

    private func makeWindow() -> OffscreenTestWindow {
        AppKitTestSupport.activateAppIfNeeded()
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func keyDown(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// A Spotify player that is playing, as the app-wide host holds it.
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

    /// Play / pause on a playing Spotify asks its in-app player to pause (#437), never toggles it.
    private func pauses(_ commander: MockWebPlaybackCommander) -> Int {
        XCTAssertFalse(commander.commands.contains { $0.command == .togglePlay }, "Spotify was toggled, not paused")
        return commander.commands.filter { $0.command == .pause }.count
    }

    // MARK: Opening it

    func testPopOutHasAPaletteRowAMenuChordAndARebindableDefault() throws {
        let spec = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.popOutLyrics }
        )
        XCTAssertEqual(spec.defaultKeystroke, "shift-alt-cmd-l")
        XCTAssertTrue(CommandPaletteCommandCatalog.defaultKeymapJSON.contains(CommandPaletteCommandID.popOutLyrics))

        let (manager, keymap) = makeManager()
        let shortcut = try XCTUnwrap(keymap.menuShortcut(for: CommandPaletteCommandID.popOutLyrics))
        XCTAssertEqual(shortcut.key.character, "l")
        XCTAssertEqual(shortcut.modifiers, [.command, .option, .shift])

        // Listed only once something can open the window.
        XCTAssertFalse(manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.popOutLyrics })
        manager.popOutLyrics = {}
        XCTAssertTrue(manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.popOutLyrics })
    }

    func testThePopOutChordOpensTheWindow() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }

        XCTAssertTrue(
            manager.handleKeyEvent(
                keyDown(keyCode: 37, characters: "l", modifiers: [.command, .option, .shift], window: window)
            )
        )
        XCTAssertEqual(opened, 1)
    }

    /// Choosing it in the palette closes the palette: the window it opens is where to look.
    func testChoosingItInThePaletteClosesThePalette() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        manager.viewModel.show()
        manager.execute(commandID: CommandPaletteCommandID.popOutLyrics)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    /// Signing out or switching service detaches the browser's commands; the pop-out shows the
    /// app-wide player, so its command stays.
    func testDetachKeepsThePopOutCommand() {
        let (manager, _) = makeManager()
        var opened = 0
        manager.popOutLyrics = { opened += 1 }
        manager.detach()
        manager.execute(commandID: CommandPaletteCommandID.popOutLyrics)
        XCTAssertEqual(opened, 1)
    }

    // MARK: Keys pressed in the pop-out

    /// The key monitor is app-wide and runs the main window's commands. Escape in the pop-out
    /// used to reach the main window and close its lyrics view (and its palette).
    func testEscapeInThePopOutLeavesTheMainWindowAlone() {
        let (manager, _) = makeManager()
        var dismissedLyrics = false
        manager.dismissLyricsOverlayIfPresented = {
            dismissedLyrics = true
            return true
        }
        manager.viewModel.show()
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }

        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 53, characters: "\u{1b}", window: popOut)))
        XCTAssertFalse(dismissedLyrics)
        XCTAssertTrue(manager.viewModel.isPresented)

        // The same key in a main window still closes the palette.
        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53, characters: "\u{1b}", window: main)))
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    /// The main windows' key handling leaves the pop-out alone entirely, Space included: the
    /// pop-out answers its own keys, so they work with no main window open.
    func testMainWindowKeyHandlingIgnoresEveryKeyInThePopOut() {
        let (manager, _) = makeManager()
        var toggled = 0
        manager.togglePlayback = { toggled += 1 }
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }

        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 49, characters: " ", window: popOut)))
        // ⌘K would open the palette in the main window, out of sight behind this one.
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 40, characters: "k", modifiers: [.command], window: popOut)))
        XCTAssertEqual(toggled, 0)
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    /// Space in the pop-out plays or pauses the player it shows, through its own key monitor and
    /// with no main window or palette manager involved. Escape and ⌘K mean nothing there.
    func testThePopOutAnswersItsOwnTransportKeysWithoutAMainWindow() async throws {
        let (_, keymap) = makeManager()
        let (spotify, commander) = playingSpotify()
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        let monitor = LyricsPopOutKeyMonitor.Coordinator(keymapStore: keymap, player: spotify.playbackViewModel)

        XCTAssertFalse(monitor.handle(keyDown(keyCode: 53, characters: "\u{1b}", window: popOut)))
        XCTAssertFalse(monitor.handle(keyDown(keyCode: 40, characters: "k", modifiers: [.command], window: popOut)))
        XCTAssertTrue(monitor.handle(keyDown(keyCode: 49, characters: " ", window: popOut)))
        for _ in 0..<20 where pauses(commander) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(pauses(commander), 1, "Space pauses what the pop-out shows")

        // The same key in another window is not the pop-out's to answer.
        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        XCTAssertFalse(monitor.handle(keyDown(keyCode: 49, characters: " ", window: main)))
    }

    /// A menu command chosen while the pop-out has focus: the music commands act in place, every
    /// other one brings the main window forward first instead of changing it out of sight.
    func testMenuCommandsFromThePopOutBringTheMainWindowForward() {
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }

        for commandID in [
            CommandPaletteCommandID.openPalette,
            CommandPaletteCommandID.openSearch,
            CommandPaletteCommandID.toggleQueue,
            CommandPaletteCommandID.toggleLyrics,
            CommandPaletteCommandID.navigateBack,
        ] {
            XCTAssertTrue(LyricsPopOutWindow.bringsMainWindowForward(for: commandID, keyWindow: popOut), commandID)
            XCTAssertFalse(LyricsPopOutWindow.bringsMainWindowForward(for: commandID, keyWindow: main), commandID)
        }
        for commandID in [
            CommandPaletteCommandID.togglePlayback,
            CommandPaletteCommandID.nextTrack,
            CommandPaletteCommandID.previousTrack,
            CommandPaletteCommandID.popOutLyrics,
        ] {
            XCTAssertFalse(LyricsPopOutWindow.bringsMainWindowForward(for: commandID, keyWindow: popOut), commandID)
        }

        // The scene still runs the command.
        let (manager, _) = makeManager()
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        scene.window = main
        var searched = 0
        manager.openSearch = { searched += 1 }
        scene.performMenuCommand(CommandPaletteCommandID.openSearch, keyWindow: popOut)
        XCTAssertEqual(searched, 1)
        XCTAssertTrue(main.isVisible)
    }

    /// With every main window closed (only the pop-out open), the menu has no window to act on:
    /// its items dim instead of doing nothing.
    func testMenuItemsDimWithNoMainWindow() {
        let (manager, keymap) = makeManager()
        manager.setPlaybackToggleAvailability(true)
        let registry = SpotiglassSceneRegistry()
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: keymap,
            settingsStore: SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL()),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true,
            isQueueVisible: false
        )
        XCTAssertFalse(commands.isAvailable)
        XCTAssertFalse(commands.isRefreshEnabled)
        XCTAssertFalse(commands.isPlaybackToggleEnabled)

        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        registry.activate(scene)
        XCTAssertTrue(commands.isAvailable)
        XCTAssertTrue(commands.isRefreshEnabled)
        XCTAssertTrue(commands.isPlaybackToggleEnabled)

        registry.deactivate(scene)
        XCTAssertFalse(commands.isAvailable)
    }

    /// ⌘S in the pop-out: it has no sidebar, so the item works only through a main window, and
    /// dims when there is none.
    func testShowHideSidebarFromThePopOutNeedsAMainWindow() {
        let (manager, keymap) = makeManager()
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        let registry = SpotiglassSceneRegistry()
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: keymap,
            settingsStore: SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL()),
            serviceStore: MusicServiceStore(
                storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
            ),
            isSignedIn: true,
            isQueueVisible: false
        )
        XCTAssertFalse(commands.isSidebarItemEnabled(keyWindow: popOut), "no main window to show a sidebar in")

        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        scene.window = main
        registry.activate(scene)
        registry.mainWindowResignedKey()
        XCTAssertTrue(commands.isSidebarItemEnabled(keyWindow: popOut))
        XCTAssertTrue(LyricsPopOutWindow.bringsMainWindowForward(for: CommandPaletteCommandID.toggleSidebar, keyWindow: popOut))
    }

    /// Popping out from the main window closes its lyrics view; asking again from the pop-out only
    /// brings the pop-out forward and leaves the lyrics view behind it alone.
    func testPoppingOutAgainFromThePopOutLeavesTheMainWindowsLyricsAlone() {
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        XCTAssertTrue(LyricsPopOutWindow.popOutClosesLyricsView(keyWindow: main))
        XCTAssertFalse(LyricsPopOutWindow.popOutClosesLyricsView(keyWindow: popOut))
    }

    /// Clicking the Dock icon with only the pop-out open brings a main window back through File ›
    /// New Window; with a main window open the system handles it as before.
    func testReopeningTheAppWithOnlyThePopOutOpenOpensANewMainWindow() {
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        popOut.setIsVisible(true)
        XCTAssertTrue(SpotiglassApplicationDelegate.onlyThePopOutIsOpen([popOut]))

        let main = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(main) }
        main.setIsVisible(true)
        XCTAssertFalse(SpotiglassApplicationDelegate.onlyThePopOutIsOpen([popOut, main]))
        XCTAssertFalse(SpotiglassApplicationDelegate.onlyThePopOutIsOpen([]))

        final class Target: NSObject {
            var opened = 0
            @objc func newWindow(_ sender: Any?) { opened += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        let newWindow = NSMenuItem(title: "New Window", action: #selector(Target.newWindow(_:)), keyEquivalent: "n")
        newWindow.keyEquivalentModifierMask = [.command]
        newWindow.target = target
        file.submenu?.addItem(newWindow)
        menu.addItem(file)

        XCTAssertTrue(SpotiglassApplicationDelegate.performNewWindow(in: menu))
        XCTAssertEqual(target.opened, 1)
        XCTAssertFalse(SpotiglassApplicationDelegate.performNewWindow(in: NSMenu()))
    }

    // MARK: Playback without a main window

    /// With every main window closed the pop-out keeps Spotify's page alive, so signing out of
    /// Spotify (from Settings) must stop its player without a main window to notice.
    func testSpotifySignOutStopsItsPlayerWithNoMainWindow() async throws {
        let (spotify, _) = playingSpotify()
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }
        let session = AuthenticatedSession(
            accessToken: "token",
            tokenType: "Bearer",
            scope: "streaming",
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        )
        let states = CurrentValueSubject<AppConnectionState, Never>(.signedIn(session))
        hosts.followSpotifySession(states)

        // A token refresh keeps the session: the music plays on.
        states.send(.refreshing(session))
        states.send(.signedIn(session))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(spotify.playbackViewModel.connectionState.hasReadyDevice)

        states.send(.signedOut)
        for _ in 0..<20 where spotify.playbackViewModel.connectionState != .disconnected {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(spotify.playbackViewModel.connectionState, .disconnected)
    }

    // MARK: The window

    func testPinKeepsTheWindowAboveOtherAppsAndUnpinMakesItOrdinary() {
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }

        LyricsPopOutWindow.apply(isPinned: true, to: window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))

        LyricsPopOutWindow.apply(isPinned: false, to: window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    /// The tests run inside the app, and AppKit saves window frames in the app's real preferences:
    /// a test window must never save one, or the real pop-out would open at a test window's frame.
    func testTestWindowsNeverSaveAFrame() {
        XCTAssertFalse(LyricsPopOutWindow.savesFrame)
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }
        LyricsPopOutWindow.adopt(window)
        XCTAssertEqual(window.frameAutosaveName, "")
    }

    func testTheAdoptedWindowIsThePopOutAndPinnedByDefault() {
        let window = makeWindow()
        defer { AppKitTestSupport.closeWindowSafely(window) }
        LyricsPopOutWindow.adopt(window)
        XCTAssertTrue(LyricsPopOutWindow.isPopOut(window))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertTrue(LyricsPopOutWindow.isPinnedByDefault)
    }

    func testLayoutShrinksToAStripAndDropsSkipButtonsWhenNarrow() {
        XCTAssertEqual(LyricsPopOutLayout.layout(for: LyricsPopOutWindow.defaultSize), .full)
        XCTAssertEqual(LyricsPopOutLayout.layout(for: LyricsPopOutWindow.minimumSize), .strip)
        XCTAssertEqual(LyricsPopOutLayout.layout(for: CGSize(width: 600, height: 120)), .strip)
        XCTAssertTrue(LyricsPopOutLayout.showsSkipButtons(width: LyricsPopOutWindow.defaultSize.width))
        XCTAssertFalse(LyricsPopOutLayout.showsSkipButtons(width: LyricsPopOutWindow.minimumSize.width))
    }

    // MARK: The strip's line

    /// Real LRC text through the parser: the title shows during the intro, then each line as it is
    /// sung. A blank timestamp line is dropped by the parser, so the line before it stays up, the
    /// same as in the lyrics view.
    func testStripShowsTheLineBeingSungAndTheTitleDuringTheIntro() {
        let lines = LrcLineParser.parseSyncedLines("""
        [00:20.00]First line
        [00:25.00]
        [00:30.00]Third line
        """)
        func text(_ phase: ImmersiveLyricsViewModel.Phase, at ms: Int) -> String {
            // The strip shows the title whenever there is no line to show.
            LyricsPopOutStripText.lyric(phase: phase, trackDurationMs: 60_000, positionMs: ms) ?? "Song"
        }
        XCTAssertEqual(text(.ready(.synced(lines)), at: 5_000), "Song")
        XCTAssertEqual(text(.ready(.synced(lines)), at: 20_000), "First line")
        XCTAssertEqual(text(.ready(.synced(lines)), at: 26_000), "First line")
        XCTAssertEqual(text(.ready(.synced(lines)), at: 31_000), "Third line")
        XCTAssertEqual(text(.ready(.unsyncedPlain(["One", "Two"])), at: 45_000), "Two")
        XCTAssertEqual(text(.ready(.synced([])), at: 0), "Song")
        XCTAssertEqual(text(.loading, at: 0), "Song")
        XCTAssertEqual(text(.failed("No lyrics"), at: 0), "Song")
        XCTAssertEqual(text(.ready(.instrumental), at: 0), SpotiglassL10n.string("lyrics.instrumental"))

    }

    // MARK: The window as it runs

    private let lyricsLRC = """
    [00:00.00]First line
    [00:30.00]Second line
    """

    /// A playing Spotify player with an artist, its mocks, and a lyrics model that answers from
    /// `lyricsLRC` instead of LRCLIB.
    private func playingWithLyrics() -> (PlaybackSessionViewModel, MockPlaybackAPI, MockWebPlaybackCommander, ImmersiveLyricsViewModel) {
        _ = NSApplication.shared
        let api = MockPlaybackAPI()
        let commander = MockWebPlaybackCommander()
        let host = SpotiglassPlaybackHost(provider: SpotifyPlaybackProvider(playbackAPI: api, webCommander: commander))
        let playback = host.playbackViewModel
        playback.deviceID = "device-1"
        playback.hasTransferredPlaybackToCurrentDevice = true
        playback.setTransportStateKnown(true)
        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "Midnight City", artists: ["M83"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 240_000, positionMilliseconds: 5_000, uri: "spotify:track:popout-\(UUID().uuidString)"
        )))
        let lines = LrcLineParser.parseSyncedLines(lyricsLRC)
        let lyrics = ImmersiveLyricsViewModel(fetchLyrics: { _ in .synced(lines) })
        return (playback, api, commander, lyrics)
    }

    /// Hosts the pop-out's content the way the app does and lets it settle. The content adopts
    /// its window as the pop-out (the configurator in its background).
    private func hostPopOut(_ view: some View, size: CGSize) throws -> NSWindow {
        let settings = try ViewTestHost.makeSettingsStore()
        let controller = ViewTestHost.host(view.environmentObject(settings), size: size)
        let window = try XCTUnwrap(controller.view.window)
        // The size under test, as a user dragged it: not the content's smallest fitting size.
        controller.sizingOptions = []
        window.setContentSize(size)
        for _ in 0..<20 where !LyricsPopOutWindow.isPopOut(window) {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.1)
        XCTAssertEqual(controller.view.frame.size, size)
        return window
    }

    private func waitUntilReady(_ lyrics: ImmersiveLyricsViewModel) {
        for _ in 0..<40 {
            if case .ready = lyrics.phase { return }
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }
    }

    /// At every size the content loads the playing song's lyrics and makes its window the pinned
    /// pop-out, above other windows.
    func testAtEverySizeTheWindowLoadsTheSongsLyricsAndBecomesThePinnedPopOut() throws {
        let (_, keymap) = makeManager()
        defer { ViewTestHost.tearDownAll() }
        for size in [
            LyricsPopOutWindow.defaultSize,
            CGSize(width: 360, height: LyricsPopOutWindow.minimumSize.height),
            LyricsPopOutWindow.minimumSize,
        ] {
            let (playback, _, _, lyrics) = playingWithLyrics()
            let window = try hostPopOut(
                LyricsPopOutView(player: playback, keymapStore: keymap, makeLyricsModel: { lyrics }),
                size: size
            )
            waitUntilReady(lyrics)
            guard case let .ready(.synced(lines)) = lyrics.phase else {
                return XCTFail("lyrics never loaded at \(size): \(lyrics.phase)")
            }
            XCTAssertEqual(lines.map(\.words), ["First line", "Second line"])
            XCTAssertTrue(LyricsPopOutWindow.isPopOut(window), "\(size)")
            XCTAssertEqual(window.level, .floating, "pinned by default at \(size)")
            // What the strip says at this moment of the song.
            XCTAssertEqual(
                LyricsPopOutStripText.lyric(phase: lyrics.phase, trackDurationMs: 240_000, positionMs: 5_000),
                "First line"
            )
            ViewTestHost.tearDownAll()
        }
    }

    /// A real Space key press in the hosted pop-out reaches its player through the window's own
    /// key monitor, with no main window or palette in the app.
    func testSpacePressedInTheHostedPopOutPausesItsPlayer() async throws {
        let (_, keymap) = makeManager()
        let (playback, _, commander, lyrics) = playingWithLyrics()
        defer { ViewTestHost.tearDownAll() }
        let window = try hostPopOut(
            LyricsPopOutView(player: playback, keymapStore: keymap, makeLyricsModel: { lyrics }),
            size: LyricsPopOutWindow.defaultSize
        )
        XCTAssertTrue(LyricsPopOutWindow.isPopOut(window))

        NSApp.postEvent(keyDown(keyCode: 49, characters: " ", window: window), atStart: false)
        for _ in 0..<40 where pauses(commander) == 0 {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pauses(commander), 1, "Space in the pop-out pauses what it shows")
    }

    /// With no service signed in the window has no player to follow and shows its empty state;
    /// signed in to Spotify it follows Spotify's app-wide player.
    func testTheWindowFollowsTheOnScreenServicesPlayerOrShowsNothingPlaying() throws {
        let (_, keymap) = makeManager()
        let (spotify, _) = playingSpotify()
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }
        defer { ViewTestHost.tearDownAll() }
        let lines = LrcLineParser.parseSyncedLines(lyricsLRC)
        var made: [ImmersiveLyricsViewModel] = []
        let makeLyrics: @MainActor () -> ImmersiveLyricsViewModel = {
            let model = ImmersiveLyricsViewModel(fetchLyrics: { _ in .synced(lines) })
            made.append(model)
            return model
        }

        let signedOut = MusicServiceStore(storage: InMemoryMusicServiceSelectionStorage(services: [], active: nil))
        let empty = try hostPopOut(
            LyricsPopOutRoot(playbackHosts: hosts, serviceStore: signedOut, keymapStore: keymap, makeLyricsModel: makeLyrics),
            size: LyricsPopOutWindow.defaultSize
        )
        XCTAssertTrue(LyricsPopOutWindow.isPopOut(empty))
        XCTAssertTrue(made.isEmpty, "no player, so no lyrics are loaded")

        let spotifyOnScreen = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify], active: .spotify)
        )
        _ = try hostPopOut(
            LyricsPopOutRoot(playbackHosts: hosts, serviceStore: spotifyOnScreen, keymapStore: keymap, makeLyricsModel: makeLyrics),
            size: LyricsPopOutWindow.defaultSize
        )
        let lyrics = try XCTUnwrap(made.first)
        waitUntilReady(lyrics)
        guard case .ready = lyrics.phase else { return XCTFail("\(lyrics.phase)") }
        XCTAssertEqual(spotify.playbackViewModel.currentLyricTrack?.name, "Midnight City")
    }

    /// Next and Previous from the pop-out reach the player, the same as the bar's buttons.
    func testNextAndPreviousFromThePopOutReachThePlayer() async throws {
        let (playback, api, _, _) = playingWithLyrics()
        XCTAssertTrue(LyricsPopOutTransport.canRun(CommandPaletteCommandID.nextTrack, on: playback))
        LyricsPopOutTransport.run(CommandPaletteCommandID.nextTrack, on: playback)
        for _ in 0..<40 where !api.actions.contains(where: { $0.hasPrefix("next") }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(api.actions.contains { $0.hasPrefix("next") }, "\(api.actions)")

        // A fresh player: right after a skip the player holds further skips for a moment.
        let (fresh, freshAPI, _, _) = playingWithLyrics()
        XCTAssertTrue(LyricsPopOutTransport.canRun(CommandPaletteCommandID.previousTrack, on: fresh))
        LyricsPopOutTransport.run(CommandPaletteCommandID.previousTrack, on: fresh)
        for _ in 0..<40 where !freshAPI.actions.contains(where: { $0.hasPrefix("previous") }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(freshAPI.actions.contains { $0.hasPrefix("previous") }, "\(freshAPI.actions)")
        XCTAssertFalse(LyricsPopOutTransport.canRun(CommandPaletteCommandID.openSearch, on: playback))
    }

    /// Paused, or between progress anchors, the lyrics hold the player's last known position.
    func testTheLyricsPositionHoldsStillWhenThereIsNoProgressToFollow() {
        let song = PlaybackNowPlaying(
            name: "Midnight City", artists: ["M83"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 240_000, positionMilliseconds: 42_000, uri: "spotify:track:1"
        )
        XCTAssertEqual(LyricsPositionReader<EmptyView>.staticPositionMs(anchor: nil, connectionState: .playing(song)), 42_000)
        XCTAssertEqual(LyricsPositionReader<EmptyView>.staticPositionMs(anchor: nil, connectionState: .paused(song)), 42_000)
        XCTAssertEqual(LyricsPositionReader<EmptyView>.staticPositionMs(anchor: nil, connectionState: .paused(nil)), 0)
        XCTAssertEqual(LyricsPositionReader<EmptyView>.staticPositionMs(anchor: nil, connectionState: .disconnected), 0)
    }

    // MARK: What it shows for what plays

    /// A podcast episode or a local file plays but has no lyrics: the window shows it (title,
    /// artwork, controls) and says there are no lyrics, never "Nothing playing".
    func testSomethingWithoutLyricsIsShownAsPlayingNotAsNothing() {
        func item(_ uri: String?) -> PlaybackNowPlaying {
            PlaybackNowPlaying(
                name: "The Daily", artists: ["NYT"], albumName: nil, albumID: nil, albumArtURL: nil,
                durationMilliseconds: 1_800_000, positionMilliseconds: 60_000, uri: uri
            )
        }
        let episode = item("spotify:episode:4rOoJ6Egrf8K2IrywzwOMk")
        XCTAssertEqual(LyricsPopOutContent.of(.playing(episode)), .noLyrics(episode))
        XCTAssertEqual(LyricsPopOutContent.of(.paused(item(nil))), .noLyrics(item(nil)))
        let song = item("spotify:track:1")
        XCTAssertEqual(LyricsPopOutContent.of(.playing(song)), .lyrics(song))
        XCTAssertEqual(LyricsPopOutContent.of(.paused(nil)), .nothingPlaying)
        XCTAssertEqual(LyricsPopOutContent.of(.disconnected), .nothingPlaying)
        XCTAssertEqual(LyricsPopOutContent.of(.playing(episode)).track, episode)
    }

    /// Hosted with an episode playing, the window never looks lyrics up for it.
    func testTheWindowLooksUpNoLyricsForAnEpisode() throws {
        let (_, keymap) = makeManager()
        let (playback, _, _, _) = playingWithLyrics()
        playback.setConnectionState(.playing(PlaybackNowPlaying(
            name: "The Daily", artists: ["NYT"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 1_800_000, positionMilliseconds: 60_000, uri: "spotify:episode:1"
        )))
        var lookups = 0
        let lyrics = ImmersiveLyricsViewModel(fetchLyrics: { _ in
            lookups += 1
            return .instrumental
        })
        defer { ViewTestHost.tearDownAll() }
        for size in [LyricsPopOutWindow.defaultSize, LyricsPopOutWindow.minimumSize] {
            _ = try hostPopOut(
                LyricsPopOutView(player: playback, keymapStore: keymap, makeLyricsModel: { lyrics }),
                size: size
            )
            AppKitTestSupport.pumpRunLoop(for: 0.2)
        }
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(lyrics.phase, .idle)
    }

    /// With Apple Music on screen and Spotify's song the one you hear, the window follows Spotify's
    /// song: it looks up lyrics for what you hear, like the player bar's controls act on it.
    func testWithTheOtherServicePlayingTheWindowFollowsWhatYouHear() throws {
        let (_, keymap) = makeManager()
        let (spotify, _) = playingSpotify()
        // A song of its own: the lyrics cache is app-wide, and other tests already loaded track 1.
        spotify.playbackViewModel.setConnectionState(.playing(PlaybackNowPlaying(
            name: "Midnight City", artists: ["M83"], albumName: nil, albumID: nil, albumArtURL: nil,
            durationMilliseconds: 240_000, positionMilliseconds: 1_000, uri: "spotify:track:follow-\(UUID().uuidString)"
        )))
        let hosts = SpotiglassPlaybackHosts(spotify: spotify) {
            SpotiglassPlaybackHost(provider: AppleMusicPlaybackProvider(player: ScriptedAppleMusicPlayer()))
        }
        hosts.gate(activeService: .appleMusic)
        let appleMusic = hosts.appleMusic.playbackViewModel
        appleMusic.handle(.ready(deviceID: AppleMusicPlaybackProvider.deviceID))
        for _ in 0..<20 where !appleMusic.isOtherServicePlaying {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }
        XCTAssertTrue(appleMusic.audiblePlayer === spotify.playbackViewModel)

        var looked: [String] = []
        let lines = LrcLineParser.parseSyncedLines(lyricsLRC)
        let services = MusicServiceStore(
            storage: InMemoryMusicServiceSelectionStorage(services: [.spotify, .appleMusic], active: .appleMusic)
        )
        defer { ViewTestHost.tearDownAll() }
        _ = try hostPopOut(
            LyricsPopOutRoot(
                playbackHosts: hosts,
                serviceStore: services,
                keymapStore: keymap,
                makeLyricsModel: {
                    ImmersiveLyricsViewModel(fetchLyrics: { track in
                        looked.append(track.name)
                        return .synced(lines)
                    })
                }
            ),
            size: LyricsPopOutWindow.defaultSize
        )
        for _ in 0..<40 where looked.isEmpty {
            AppKitTestSupport.pumpRunLoop(for: 0.05)
        }
        XCTAssertEqual(looked, ["Midnight City"])
    }

    /// A main window in the Dock comes back on a Dock click instead of a second one being made.
    func testADockClickBringsBackAMinimisedMainWindow() {
        final class MinimizedWindow: OffscreenTestWindow {
            override var isMiniaturized: Bool { true }
        }
        let popOut = makeWindow()
        LyricsPopOutWindow.adopt(popOut)
        defer { AppKitTestSupport.closeWindowSafely(popOut) }
        let minimized = MinimizedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        minimized.isReleasedWhenClosed = false
        defer { AppKitTestSupport.closeWindowSafely(minimized) }
        XCTAssertTrue(SpotiglassApplicationDelegate.minimizedMainWindow([popOut, minimized]) === minimized)
        XCTAssertNil(SpotiglassApplicationDelegate.minimizedMainWindow([popOut]))
    }
}

