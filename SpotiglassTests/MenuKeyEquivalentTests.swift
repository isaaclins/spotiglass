import AppKit
import SwiftUI
import XCTest
@testable import Spotiglass

@MainActor
final class MenuKeyEquivalentTests: XCTestCase {
    private func makeStore() -> CommandPaletteKeymapStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassMenuKeyEquivalent-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        return CommandPaletteKeymapStore(fileURL: url)
    }

    private func makeSettingsStore() -> SpotiglassSettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotiglassMenuLocalization-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        return SpotiglassSettingsStore(fileURL: url)
    }

    private func makeCommands(manager: CommandPaletteManager) -> SpotiglassMenuCommands {
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        return SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            isSignedIn: true,
            isQueueVisible: false
        )
    }

    func testModifierBearingChordBecomesMenuKeyEquivalent() throws {
        let shortcut = try XCTUnwrap(try CommandShortcut(keystroke: "shift-cmd-right").menuKeyboardShortcut)

        XCTAssertEqual(shortcut.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    /// A menu key equivalent is matched before the key reaches the focused view,
    /// so the bare Space binding for Play/Pause must never reach the menu bar.
    func testBareAndShiftOnlyChordsAreRefusedAsMenuKeyEquivalents() throws {
        XCTAssertNil(try CommandShortcut(keystroke: "space").menuKeyboardShortcut)
        XCTAssertNil(try CommandShortcut(keystroke: "shift-return").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "ctrl-space").menuKeyboardShortcut)
        XCTAssertNotNil(try CommandShortcut(keystroke: "alt-cmd-q").menuKeyboardShortcut)
    }

    func testDefaultKeymapDrivesTheMenuBarShortcuts() throws {
        let store = makeStore()

        let next = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(next.key.character, KeyEquivalent.rightArrow.character)
        XCTAssertEqual(next.modifiers, [.command, .shift])

        let queue = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
        XCTAssertEqual(queue.key.character, "q")
        XCTAssertEqual(queue.modifiers, [.command, .option])

        let lyrics = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleLyrics))
        XCTAssertEqual(lyrics.key.character, "l")
        XCTAssertEqual(lyrics.modifiers, [.command, .option])

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.togglePlayback))
        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleShuffle))
    }

    /// Rebinding a command in Settings → Keyboard has to move its menu shortcut,
    /// otherwise the menu bar would keep firing the abandoned chord.
    func testRebindingACommandMovesItsMenuShortcut() throws {
        let store = makeStore()
        try store.setBinding(
            commandID: CommandPaletteCommandID.nextTrack,
            shortcut: try CommandShortcut(keystroke: "ctrl-alt-n"),
            replaceConflicting: true
        )

        let rebound = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.nextTrack))
        XCTAssertEqual(rebound.key.character, "n")
        XCTAssertEqual(rebound.modifiers, [.control, .option])
    }

    func testClearingABindingRemovesTheMenuShortcut() throws {
        let store = makeStore()
        try store.clearBinding(commandID: CommandPaletteCommandID.toggleQueue)

        XCTAssertNil(store.menuShortcut(for: CommandPaletteCommandID.toggleQueue))
    }

    /// The menu bar dispatches through the same manager the palette and the keymap
    /// use, so shuffle and repeat must land on the wired playback closures.
    func testMenuOnlyShuffleAndRepeatDispatchThroughTheManager() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        var shuffled = 0
        var repeated = 0
        manager.toggleShuffle = { shuffled += 1 }
        manager.cycleRepeat = { repeated += 1 }
        manager.playbackTransportMutationPrerequisite = { true }

        manager.execute(commandID: CommandPaletteCommandID.toggleShuffle)
        manager.execute(commandID: CommandPaletteCommandID.cycleRepeat)

        let expectation = expectation(description: "playback closures ran")
        Task { @MainActor in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(shuffled, 1)
        XCTAssertEqual(repeated, 1)
    }

    func testMenuKeyEquivalentsAreUniqueAcrossMenuTree() throws {
        AppKitTestSupport.activateAppIfNeeded()
        AppKitTestSupport.pumpRunLoop(for: 0.25)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let keyedItems = menuKeyEquivalentItems(in: menu)
        XCTAssertFalse(keyedItems.isEmpty, "Expected the application menu to expose key equivalents")

        let grouped = Dictionary(grouping: keyedItems) { item in
            "\(item.key.lowercased())|\(item.modifiers.rawValue)"
        }
        let duplicates = grouped.values.filter { $0.count > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "Every menu key equivalent must be unique; duplicates: \(duplicates.map { $0.map(\.path) })"
        )
    }

    func testRepeatCycleCommandAdvancesThroughAllModes() async {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        manager.playbackTransportMutationPrerequisite = { true }
        var mode = SpotifyRepeatMode.off

        for expectedMode in [SpotifyRepeatMode.context, .track, .off] {
            let advanced = expectation(description: "repeat advanced to \(expectedMode.rawValue)")
            manager.cycleRepeat = {
                mode = mode.next
                advanced.fulfill()
            }

            manager.execute(commandID: CommandPaletteCommandID.cycleRepeat)
            await fulfillment(of: [advanced], timeout: 2)
            XCTAssertEqual(mode, expectedMode)
        }
    }

    func testPlaybackMenuUsesEffectiveToggleReadiness() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let commands = makeCommands(manager: manager)
        XCTAssertFalse(commands.isPlaybackToggleEnabled)

        manager.setPlaybackToggleAvailability(true)
        XCTAssertTrue(commands.isPlaybackToggleEnabled)
    }

    func testPlaybackMenuMirrorsLiveShuffleAndRepeatState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        manager.bindPlaybackReadiness(to: playback)
        let commands = makeCommands(manager: manager)

        playback.deviceID = "device-1"
        playback.setConnectionState(.ready(deviceID: "device-1"))
        playback.setTransportStateKnown(true)
        playback.shuffleEnabled = true
        playback.repeatMode = .track

        XCTAssertTrue(commands.isShuffleEnabled)
        XCTAssertEqual(commands.selectedRepeatMode, .track)
        XCTAssertTrue(commands.isPlaybackTransportMutationEnabled)
    }

    func testPlaybackMenuCanSelectSpecificRepeatMode() async {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        manager.playbackTransportMutationPrerequisite = { true }
        let selected = expectation(description: "specific repeat mode selected")
        var selectedMode: SpotifyRepeatMode?
        manager.setRepeatModeAction = { mode in
            selectedMode = mode
            selected.fulfill()
        }

        manager.requestRepeatMode(.track)
        await fulfillment(of: [selected], timeout: 2)

        XCTAssertEqual(selectedMode, .track)
    }

    func testPrefetchMenuTitleReflectsInFlightState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let commands = makeCommands(manager: manager)

        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.loadAllSongs"))
        manager.setPrefetchProgress(
            PrefetchAllPlaylistsProgress(
                phase: .running, total: 4, completed: 1, skipped: 0, failed: 0
            )
        )
        XCTAssertTrue(commands.isPrefetchInFlight)
        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.stopLoadingSongs"))

        manager.setPrefetchProgress(
            PrefetchAllPlaylistsProgress(
                phase: .finished, total: 4, completed: 4, skipped: 0, failed: 0
            )
        )
        XCTAssertFalse(commands.isPrefetchInFlight)
        XCTAssertEqual(commands.prefetchItemTitle, SpotiglassL10n.string("menu.file.loadAllSongs"))
    }

    func testPrefetchProgressSurvivesOpeningAndClosingPalette() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let progress = PrefetchAllPlaylistsProgress(
            phase: .running, total: 4, completed: 1, skipped: 0, failed: 0
        )
        manager.setPrefetchProgress(progress)

        manager.viewModel.show()
        XCTAssertEqual(manager.prefetchProgress, progress)
        XCTAssertEqual(manager.viewModel.prefetchProgress, progress)
        manager.viewModel.hide()
        XCTAssertEqual(manager.viewModel.prefetchProgress, progress)
    }

    func testLyricsMenuRequiresCurrentMusicTrack() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let playback = PlaybackSessionViewModel(
            playbackAPI: MockPlaybackAPI(),
            webCommander: MockWebPlaybackCommander()
        )
        manager.bindPlaybackReadiness(to: playback)
        let commands = makeCommands(manager: manager)

        XCTAssertFalse(commands.isLyricsToggleEnabled)
        playback.setConnectionState(.playing(
            PlaybackNowPlaying(
                name: "Episode",
                artists: ["Host"],
                albumName: nil,
                albumID: nil,
                albumArtURL: nil,
                durationMilliseconds: 100,
                positionMilliseconds: 0,
                uri: "spotify:episode:1"
            )
        ))
        XCTAssertFalse(commands.isLyricsToggleEnabled)

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
        XCTAssertTrue(commands.isLyricsToggleEnabled)

        playback.setConnectionState(.ready(deviceID: "device-1"))
        XCTAssertFalse(commands.isLyricsToggleEnabled)
    }

    func testLyricsMenuTitleReflectsPresentedState() {
        let manager = CommandPaletteManager(keymapStore: makeStore())
        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
        let commands = SpotiglassMenuCommands(
            sceneRegistry: registry,
            keymapStore: manager.keymapStore,
            settingsStore: makeSettingsStore(),
            isSignedIn: true,
            isQueueVisible: false
        )

        XCTAssertEqual(commands.lyricsItemTitle, SpotiglassL10n.string("menu.view.showLyrics"))
        scene.lyricsOverlayController.isPresented = true
        XCTAssertEqual(commands.lyricsItemTitle, SpotiglassL10n.string("menu.view.hideLyrics"))
    }

    private struct MenuKeyEquivalentItem {
        let path: String
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    private func menuKeyEquivalentItems(
        in menu: NSMenu,
        parentPath: String = ""
    ) -> [MenuKeyEquivalentItem] {
        menu.items.flatMap { item in
            let path = parentPath.isEmpty ? item.title : "\(parentPath) > \(item.title)"
            let current = item.keyEquivalent.isEmpty
                ? []
                : [
                    MenuKeyEquivalentItem(
                        path: path,
                        key: item.keyEquivalent,
                        modifiers: item.keyEquivalentModifierMask
                    )
                ]
            let children = item.submenu.map {
                menuKeyEquivalentItems(in: $0, parentPath: path)
            } ?? []
            return current + children
        }
    }

    // MARK: - Help menu (#177)

    /// The default Help item was a silent no-op: the bundle declares no
    /// CFBundleHelpBookName, so choosing it did nothing at all. These are the
    /// destinations that replaced it, and a typo in either one would ship a
    /// Help menu that fails exactly as quietly as the old one did.
    @MainActor
    func testHelpMenuPointsAtRealDestinations() {
        XCTAssertEqual(
            SpotiglassMenuCommands.readmeURL.absoluteString,
            "https://github.com/isaaclins/spotiglass#readme"
        )
        XCTAssertEqual(
            SpotiglassMenuCommands.newIssueURL.absoluteString,
            "https://github.com/isaaclins/spotiglass/issues/new"
        )
        for url in [SpotiglassMenuCommands.readmeURL, SpotiglassMenuCommands.newIssueURL] {
            XCTAssertEqual(url.scheme, "https", "help destinations must not be plain http")
            XCTAssertNotNil(url.host, "a hostless URL opens nothing")
        }
    }

}
