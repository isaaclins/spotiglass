import AppKit
import XCTest
@testable import Spotiglass

@MainActor
final class CommandPaletteManagerKeyEventTests: XCTestCase {
    private func keyDown(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
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

    func testDismissLyricsOverlayConsumesEscape() {
        let manager = CommandPaletteManager()
        manager.dismissLyricsOverlayIfPresented = { true }
        XCTAssertTrue(manager.handleKeyEvent(keyDown(keyCode: 53)))
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
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
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
        manager.openArtist = { id in
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
