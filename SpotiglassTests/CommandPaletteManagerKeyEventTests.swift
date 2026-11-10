import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteManagerKeyEventTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testPaletteOpenEscapeHidesAndConsumes() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53)))
        XCTAssertFalse(manager.viewModel.isPresented)
    }

    func testPaletteOpenArrowKeysMoveSelection() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.testingReplaceSections([
            (.commands, [
                CommandPaletteItem(id: "a", title: "A", subtitle: nil, iconSystemName: "command", section: .commands, keywords: [], action: {}),
                CommandPaletteItem(id: "b", title: "B", subtitle: nil, iconSystemName: "command", section: .commands, keywords: [], action: {}),
            ]),
        ])
        let start = manager.viewModel.selectedIndex
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 125)))
        XCTAssertEqual(manager.viewModel.selectedIndex, start + 1)
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 126)))
        XCTAssertEqual(manager.viewModel.selectedIndex, start)
    }

    func testTabCyclesSearchCategoryWhenNotCommandsScope() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.query = "query"
        let before = manager.viewModel.searchCategoryFilter
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 48)))
        XCTAssertNotEqual(manager.viewModel.searchCategoryFilter, before)
    }

    /// In `>` scope Tab was passed on, and the field handed focus to the page behind the palette,
    /// so typed letters stopped reaching it (#472).
    func testTabStaysInThePaletteInCommandsScope() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.query = ">set"
        let before = manager.viewModel.searchCategoryFilter
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 48)))
        XCTAssertEqual(manager.viewModel.searchCategoryFilter, before)
    }

    func testDismissLyricsOverlayConsumesEscape() {
        let manager = CommandPaletteManager()
        manager.dismissLyricsOverlayIfPresented = { true }
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53)))
    }

    /// #438: the sidebar stays usable next to the lyrics. Escape while renaming a playlist
    /// there cancelled nothing and closed the lyrics instead; it belongs to the text field.
    func testEscapeInATextFieldNextToTheLyricsLeavesThemOpen() {
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let renameField = NSTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let lyricsArea = LyricsKeyTestResponderView(frame: NSRect(x: 160, y: 0, width: 160, height: 240))
        root.addSubview(renameField)
        root.addSubview(lyricsArea)
        window.contentView = root
        defer { AppKitTestSupport.closeWindowSafely(window) }

        let manager = CommandPaletteManager()
        var dismissals = 0
        manager.dismissLyricsOverlayIfPresented = {
            dismissals += 1
            return true
        }
        let escape = keyDown(keyCode: 53, windowNumber: window.windowNumber)

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(renameField, in: window))
        _ = manager.handleKeyEvent(escape)
        XCTAssertEqual(dismissals, 0, "Escape in the rename field closed the lyrics")

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(lyricsArea, in: window))
        XCTAssertTrue(manager.handleKeyEvent(escape))
        XCTAssertEqual(dismissals, 1)
    }

    func testIsRecordingHotkeyBypassesKeymap() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        manager.isRecordingHotkey = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: try CommandShortcut(keystroke: "cmd-k"),
            replaceConflicting: true
        )
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 40, characters: "k", modifiers: [.command])))
    }

    func testBareSpaceStillDispatchesWithoutFocusedKeyOwner() async throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        let toggled = expectation(description: "toggle playback")
        manager.togglePlayback = { toggled.fulfill() }

        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 49, characters: " ")))
        await fulfillment(of: [toggled], timeout: 2)
    }

    func testFocusedKeyOwnerOnlyDefersEventsItOwns() {
        let owner = TestFocusedKeyEventOwnerView(ownedKeyCode: 49)
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // `NSWindow` created in code defaults to `isReleasedWhenClosed`, so
        // `close()` would release a window ARC still owns here and the test
        // process would segfault popping the autorelease pool at test scope end.
        window.isReleasedWhenClosed = false
        window.contentView = owner
        defer {
            AppKitTestSupport.closeWindowSafely(window)
        }

        AppKitTestSupport.activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        AppKitTestSupport.pumpRunLoop(for: 0.03)
        XCTAssertTrue(window.makeFirstResponder(owner))
        let space = keyDown(
            keyCode: 49,
            characters: " ",
            modifiers: [],
            windowNumber: window.windowNumber
        )
        let command = keyDown(
            keyCode: 40,
            characters: "k",
            modifiers: [.command],
            windowNumber: window.windowNumber
        )

        XCTAssertTrue(FocusedKeyEventDispatcher.shouldDeferGlobalDispatch(for: space))
        XCTAssertFalse(FocusedKeyEventDispatcher.shouldDeferGlobalDispatch(for: command))

        let settings = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        XCTAssertTrue(manager.handleKeyEvent(command))
        XCTAssertTrue(manager.viewModel.isPresented)
    }

    func testLyricsOverlayPassesGlobalCommandsThroughButLeavesEscapeAvailable() throws {
        let settings = SpotiglassSettingsStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let focusContainer = LyricsOverlayFocusContainerView(
            content: EmptyView(),
            isActive: true,
            keymapStore: keymap
        )
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = focusContainer
        defer {
            focusContainer.deactivate()
            AppKitTestSupport.closeWindowSafely(window)
        }

        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(focusContainer, in: window))
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: try CommandShortcut(keystroke: "cmd-k"),
            replaceConflicting: true
        )

        let command = keyDown(
            keyCode: 40,
            characters: "k",
            modifiers: [.command],
            windowNumber: window.windowNumber
        )
        XCTAssertTrue(manager.handleKeyEvent(command))
        XCTAssertTrue(manager.viewModel.isPresented)

        var dismissed = false
        manager.dismissLyricsOverlayIfPresented = {
            dismissed = true
            return true
        }
        manager.viewModel.hide()
        let escape = keyDown(keyCode: 53, windowNumber: window.windowNumber)
        XCTAssertTrue(manager.handleKeyEvent(escape))
        XCTAssertTrue(dismissed)
    }

    /// ⌃1 / ⌃2 switch service from everywhere, the lyrics view included (#399). The lyrics focus
    /// owner used to claim them, so the chord did nothing while lyrics were open.
    func testLyricsOverlayLetsTheServiceSwitchShortcutsThrough() throws {
        let keymap = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let focusContainer = LyricsOverlayFocusContainerView(
            content: EmptyView(),
            isActive: true,
            keymapStore: keymap
        )
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = focusContainer
        defer {
            focusContainer.deactivate()
            AppKitTestSupport.closeWindowSafely(window)
        }
        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(focusContainer, in: window))

        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        var switched: [MusicService] = []
        manager.switchService = { switched.append($0) }

        let controlTwo = keyDown(keyCode: 19, characters: "2", modifiers: [.control], windowNumber: window.windowNumber)
        let controlOne = keyDown(keyCode: 18, characters: "1", modifiers: [.control], windowNumber: window.windowNumber)
        XCTAssertFalse(focusContainer.ownsKeyEvent(controlTwo))
        XCTAssertFalse(focusContainer.ownsKeyEvent(controlOne))

        manager.switchableServices = [.spotify]
        XCTAssertTrue(manager.handleKeyEvent(controlTwo))
        manager.switchableServices = [.appleMusic]
        XCTAssertTrue(manager.handleKeyEvent(controlOne))

        let drained = expectation(description: "switches ran")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(switched, [.spotify, .appleMusic])
    }

    func testAutoRepeatDoesNotFireCommands() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.toggleLyrics,
            shortcut: try CommandShortcut(keystroke: "cmd-l"),
            replaceConflicting: true
        )
        var toggled = 0
        manager.toggleLyrics = { toggled += 1 }
        let repeatEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "l",
            charactersIgnoringModifiers: "l",
            isARepeat: true,
            keyCode: 37
        )!
        XCTAssertFalse(manager.handleKeyEvent(repeatEvent))
        XCTAssertEqual(toggled, 0)
    }

    func testPlaybackTogglePrerequisiteBlocksBinding() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        manager.playbackTogglePrerequisite = { false }
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.togglePlayback,
            shortcut: try CommandShortcut(keystroke: "cmd-p"),
            replaceConflicting: true
        )
        var toggled = false
        manager.togglePlayback = { toggled = true }
        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 35, characters: "p", modifiers: [.command])))
        XCTAssertFalse(toggled)
    }

    /// #500: with nothing loaded the Playback menu greys out Next and Previous; their shortcuts
    /// must not run them either (they did nothing). A pause without a readable item (a podcast
    /// paused on another Spotify device) still skips.
    func testSkipShortcutsNeedSomethingToSkipFrom() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.nextTrack,
            shortcut: try CommandShortcut(keystroke: "cmd-j"),
            replaceConflicting: true
        )
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.previousTrack,
            shortcut: try CommandShortcut(keystroke: "cmd-u"),
            replaceConflicting: true
        )
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        playback.deviceID = "local-device"
        playback.setConnectionState(.ready(deviceID: "local-device"))
        manager.bindPlaybackReadiness(to: playback)
        manager.nextTrack = {}
        manager.previousTrack = {}
        let next = { manager.handleKeyEvent(self.keyDown(keyCode: 38, characters: "j", modifiers: [.command])) }
        let previous = { manager.handleKeyEvent(self.keyDown(keyCode: 32, characters: "u", modifiers: [.command])) }

        XCTAssertFalse(next(), "Ready to play: nothing to skip from")
        XCTAssertFalse(previous())

        playback.setConnectionState(.paused(nil))
        XCTAssertTrue(next(), "a podcast paused on another device still skips")

        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Song", artists: ["Artist"], albumName: nil, albumID: nil, albumArtURL: nil,
                durationMilliseconds: 100, positionMilliseconds: 0, uri: "spotify:track:1"
            )
        ))
        XCTAssertTrue(next())
        XCTAssertTrue(previous())
    }

    func testLyricsShortcutRequiresCurrentMusicTrack() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.toggleLyrics,
            shortcut: try CommandShortcut(keystroke: "cmd-l"),
            replaceConflicting: true
        )
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        manager.bindPlaybackReadiness(to: playback)
        var toggled = 0
        manager.toggleLyrics = { toggled += 1 }

        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 37, characters: "l", modifiers: [.command])))
        XCTAssertEqual(toggled, 0)

        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Song",
                artists: ["Artist"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 100,
                positionMilliseconds: 0,
                uri: "spotify:track:1"
            )
        ))
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 37, characters: "l", modifiers: [.command])))
        XCTAssertEqual(toggled, 1)
    }

    /// #486: starting a song on the service on screen leaves the bar without a song for a moment,
    /// and the lyrics wait for it. Hiding them works meanwhile: the shortcut, running the command
    /// and the palette's list. Showing them still needs a song.
    func testHideLyricsWorksWhileTheLyricsWaitForASong() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.toggleLyrics,
            shortcut: try CommandShortcut(keystroke: "cmd-l"),
            replaceConflicting: true
        )
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()))
        manager.bindPlaybackReadiness(to: playback)
        var presented = false
        manager.isLyricsPresented = { presented }
        var toggled = 0
        manager.toggleLyrics = { toggled += 1 }
        let paletteOffersLyrics = {
            manager.viewModel.staticItemsProvider().contains { $0.id == CommandPaletteCommandID.toggleLyrics }
        }

        XCTAssertFalse(manager.handleKeyEvent(keyDown(keyCode: 37, characters: "l", modifiers: [.command])))
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertEqual(toggled, 0, "Show Lyrics ran with no song in the bar")
        XCTAssertFalse(paletteOffersLyrics())

        presented = true
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 37, characters: "l", modifiers: [.command])), "the shortcut doesn't hide the lyrics")
        XCTAssertEqual(toggled, 1)
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertEqual(toggled, 2, "the command doesn't hide the lyrics")
        XCTAssertTrue(paletteOffersLyrics(), "the palette has no Hide Lyrics")
    }

    func testExecuteWiresPlaybackAndNavigationHandlers() async {
        let manager = CommandPaletteManager()
        let toggle = expectation(description: "toggle")
        manager.togglePlayback = { toggle.fulfill() }
        manager.isSignedIn = true
        manager.execute(commandID: CommandPaletteCommandID.togglePlayback)
        await fulfillment(of: [toggle], timeout: 2)

        let openPlaylist = expectation(description: "playlist")
        manager.openPlaylist = { id in
            XCTAssertEqual(id, "plist-1")
            openPlaylist.fulfill()
        }
        manager.execute(commandID: "navigation.playlist.open", args: ["playlistID": .string("plist-1")])
        await fulfillment(of: [openPlaylist], timeout: 2)
    }

    func testPaletteOpenReturnExecutesSelection() async {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.viewModel.testingReplaceSections([
            (.commands, [
                CommandPaletteItem(
                    id: "run",
                    title: "Run",
                    subtitle: nil,
                    iconSystemName: "command",
                    section: .commands,
                    keywords: [],
                    action: {}
                ),
            ]),
        ])
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 36)))
    }

    func testSignedOutKeymapStillMatchesWhenConfigured() throws {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settings = SpotiglassSettingsStore(fileURL: url)
        let keymap = CommandPaletteKeymapStore(settingsStore: settings)
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = false
        try keymap.setBinding(
            commandID: CommandPaletteCommandID.openPalette,
            shortcut: try CommandShortcut(keystroke: "cmd-k"),
            replaceConflicting: true
        )
        XCTAssertFalse(manager.viewModel.isPresented)
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 40, characters: "k", modifiers: [.command])))
        XCTAssertTrue(manager.viewModel.isPresented)
    }

    func testExecuteRefreshAndPrefetchHooks() async {
        let manager = CommandPaletteManager()
        let refresh = expectation(description: "refresh")
        manager.unifiedRefresh = { refresh.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.refreshPlaylists)
        await fulfillment(of: [refresh], timeout: 2)

        var prefetched = false
        manager.prefetchAllPlaylists = { prefetched = true }
        manager.execute(commandID: CommandPaletteCommandID.prefetchAllPlaylists)
        XCTAssertTrue(prefetched)
    }

    func testExecuteSignOutSettingsAndTransport() async {
        let manager = CommandPaletteManager()
        var signedOut = false
        manager.signOut = { signedOut = true }
        manager.execute(commandID: CommandPaletteCommandID.signOut)
        XCTAssertTrue(signedOut)

        var openedSettings = false
        manager.openSettings = { openedSettings = true }
        manager.execute(commandID: CommandPaletteCommandID.openSettings)
        XCTAssertTrue(openedSettings)

        let next = expectation(description: "next")
        manager.nextTrack = { next.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.nextTrack)
        await fulfillment(of: [next], timeout: 2)

        let previous = expectation(description: "previous")
        manager.previousTrack = { previous.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.previousTrack)
        await fulfillment(of: [previous], timeout: 2)
    }

    func testExecutePlayURIFilterArtistAndQueueLyrics() async {
        let manager = CommandPaletteManager()
        let playURI = expectation(description: "playURI")
        manager.playURI = { uri in
            XCTAssertEqual(uri, "spotify:track:1")
            playURI.fulfill()
        }
        manager.execute(commandID: "playback.playURI", args: ["uri": .string("spotify:track:1")])
        await fulfillment(of: [playURI], timeout: 2)

        var filtered: String?
        manager.filterByArtist = { filtered = $0 }
        manager.execute(commandID: CommandPaletteCommandID.filterByArtist, args: ["name": .string("Kanye")])
        XCTAssertEqual(filtered, "Kanye")

        var queueToggled = false
        manager.toggleQueue = { queueToggled = true }
        manager.execute(commandID: CommandPaletteCommandID.toggleQueue)
        XCTAssertTrue(queueToggled)

        var lyricsToggled = false
        manager.setLyricsToggleAvailability(true)
        manager.toggleLyrics = { lyricsToggled = true }
        manager.execute(commandID: CommandPaletteCommandID.toggleLyrics)
        XCTAssertTrue(lyricsToggled)
    }

    func testExecuteConnectDisconnectAndPlaylistNavigation() async {
        let manager = CommandPaletteManager()
        var connected = false
        manager.connectPlayback = { connected = true }
        manager.execute(commandID: CommandPaletteCommandID.connectPlayback)
        XCTAssertTrue(connected)

        let disconnect = expectation(description: "disconnect")
        manager.disconnectPlayback = { disconnect.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.disconnectPlayback)
        await fulfillment(of: [disconnect], timeout: 2)

        let next = expectation(description: "nextPlaylist")
        manager.selectNextPlaylist = { next.fulfill() }
        manager.execute(commandID: CommandPaletteCommandID.selectNextPlaylist)
        await fulfillment(of: [next], timeout: 2)

        let openArtist = expectation(description: "openArtist")
        manager.openArtist = { id, _ in
            XCTAssertEqual(id, "artist-9")
            openArtist.fulfill()
        }
        manager.execute(commandID: CommandPaletteCommandID.openArtist, args: ["artistID": .string("artist-9")])
        await fulfillment(of: [openArtist], timeout: 2)
    }

    func testExecutePinEnqueueAndOpenPalette() {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        manager.execute(commandID: CommandPaletteCommandID.openPalette)
        XCTAssertTrue(manager.viewModel.isPresented)

        manager.execute(commandID: CommandPaletteCommandID.pinSelected)
        manager.execute(commandID: CommandPaletteCommandID.unpinSelected)
        manager.execute(commandID: CommandPaletteCommandID.enqueueSelected)
    }

    func testPaletteReturnExecutesSelection() async {
        let manager = CommandPaletteManager()
        manager.viewModel.show()
        let executed = expectation(description: "executed")
        manager.viewModel.testingReplaceSections([
            (.commands, [
                CommandPaletteItem(
                    id: "run",
                    title: "Run",
                    subtitle: nil,
                    iconSystemName: "command",
                    section: .commands,
                    keywords: [],
                    action: { executed.fulfill() }
                ),
            ]),
        ])
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 36)))
        await fulfillment(of: [executed], timeout: 2)
    }
}

@MainActor
private final class TestFocusedKeyEventOwnerView: NSView, FocusedKeyEventOwner {
    private let ownedKeyCode: UInt16

    init(ownedKeyCode: UInt16) {
        self.ownedKeyCode = ownedKeyCode
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        event.keyCode == ownedKeyCode
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}

private final class LyricsKeyTestResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
