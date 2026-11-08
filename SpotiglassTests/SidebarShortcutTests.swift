import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import Spotiglass

/// ⌘S shows and hides the sidebar (#436). Before, only the system's ⌃⌘S existed, and it only
/// reached the sidebar while focus sat inside the split view.
@MainActor
final class SidebarShortcutTests: XCTestCase {
    private func keyDown(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private var commandS: NSEvent { keyDown("s", keyCode: 1, modifiers: [.command]) }
    private var controlCommandS: NSEvent { keyDown("s", keyCode: 1, modifiers: [.control, .command]) }

    private func makeManager() -> (CommandPaletteManager, () -> Int) {
        let keymap = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let manager = CommandPaletteManager(keymapStore: keymap)
        manager.isSignedIn = true
        var toggles = 0
        manager.toggleSidebar = { toggles += 1 }
        return (manager, { toggles })
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        addTeardownBlock { @MainActor in AppKitTestSupport.closeWindowSafely(window) }
        return window
    }

    // MARK: - The keymap

    func testCommandSIsTheSidebarDefaultAndNoOtherCommandUsesIt() throws {
        let commandS = try CommandShortcut(keystroke: "cmd-s")
        let spec = try XCTUnwrap(
            CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.toggleSidebar }
        )
        XCTAssertEqual(spec.defaultKeystroke, "cmd-s")
        XCTAssertEqual(spec.defaultWhen, .signedIn)

        let others = CommandPaletteCommandCatalog.editable.filter {
            $0.commandID != CommandPaletteCommandID.toggleSidebar
        }
        for other in others {
            guard let keystroke = other.defaultKeystroke else { continue }
            XCTAssertNotEqual(try CommandShortcut(keystroke: keystroke), commandS, "\(other.commandID) also defaults to ⌘S")
        }
        XCTAssertNil(CommandPaletteReservedShortcuts.reservingMenuItem(for: commandS), "a menu item hardcodes ⌘S")

        let store = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        XCTAssertEqual(
            store.commandBindings(for: self.commandS, context: .signedIn).map(\.command),
            [CommandPaletteCommandID.toggleSidebar]
        )
        let menuShortcut = try XCTUnwrap(store.menuShortcut(for: CommandPaletteCommandID.toggleSidebar))
        XCTAssertEqual(menuShortcut.key.character, "s")
        XCTAssertEqual(menuShortcut.modifiers, [.command])
    }

    /// Installs from before #436 already have a keymap: they get ⌘S once, unless it is taken.
    func testExistingInstallsGetCommandSUnlessTheyBoundItThemselves() throws {
        func load(keybinds: [CommandPaletteKeyBinding]) throws -> SpotiglassSettingsFile {
            var file = SpotiglassSettingsStore.bootstrapDefaults()
            file.keybinds = keybinds
            file.seededKeybindCommands.removeAll { $0 == CommandPaletteCommandID.toggleSidebar }
            let url = makeCommandPaletteTestsTempSettingsURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url)
            return SpotiglassSettingsStore(fileURL: url).settings
        }

        let oldDefaults = SpotiglassSettingsStore.defaultKeybinds().filter {
            $0.command != CommandPaletteCommandID.toggleSidebar
        }
        let upgraded = try load(keybinds: oldDefaults)
        XCTAssertEqual(
            upgraded.keybinds.first { $0.command == CommandPaletteCommandID.toggleSidebar }?.keystrokes,
            ["cmd-s"]
        )

        let ownCommandS = CommandPaletteKeyBinding(
            keystrokes: ["cmd-s"],
            command: CommandPaletteCommandID.refreshPlaylists,
            when: .signedIn,
            args: nil
        )
        let kept = try load(keybinds: oldDefaults + [ownCommandS])
        XCTAssertFalse(kept.keybinds.contains { $0.command == CommandPaletteCommandID.toggleSidebar })
        XCTAssertTrue(kept.keybinds.contains(ownCommandS))
    }

    /// ⌃⌘S stays with the sidebar: rebinding the sidebar may use it, nothing else may take it.
    func testSystemChordBelongsToTheSidebar() throws {
        let store = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let controlCommandS = try CommandShortcut(keystroke: "ctrl-cmd-s")
        XCTAssertThrowsError(
            try store.setBinding(
                commandID: CommandPaletteCommandID.openSettings,
                shortcut: controlCommandS,
                replaceConflicting: true
            )
        )
        XCTAssertNoThrow(
            try store.setBinding(
                commandID: CommandPaletteCommandID.toggleSidebar,
                shortcut: controlCommandS,
                replaceConflicting: false
            )
        )
    }

    // MARK: - Key presses

    func testCommandSAndControlCommandSToggleTheSidebar() {
        let (manager, toggles) = makeManager()
        XCTAssertTrue(manager.handleKeyEvent(commandS))
        XCTAssertEqual(toggles(), 1)
        XCTAssertTrue(manager.handleKeyEvent(controlCommandS))
        XCTAssertEqual(toggles(), 2)
    }

    /// After rebinding, ⌘S is free again and ⌃⌘S still works.
    func testRebindingMovesCommandSButKeepsTheSystemChord() throws {
        let (manager, toggles) = makeManager()
        try manager.keymapStore.setBinding(
            commandID: CommandPaletteCommandID.toggleSidebar,
            shortcut: try CommandShortcut(keystroke: "alt-cmd-b"),
            replaceConflicting: false
        )
        XCTAssertFalse(manager.handleKeyEvent(commandS))
        XCTAssertTrue(manager.handleKeyEvent(keyDown("b", keyCode: 11, modifiers: [.option, .command])))
        XCTAssertTrue(manager.handleKeyEvent(controlCommandS))
        XCTAssertEqual(toggles(), 2)
    }

    func testSidebarShortcutsNeedTheBrowser() {
        let (manager, toggles) = makeManager()
        manager.detach()
        XCTAssertFalse(manager.handleKeyEvent(commandS))
        XCTAssertFalse(manager.handleKeyEvent(controlCommandS))
        XCTAssertEqual(toggles(), 0)
    }

    /// Typing in search or a playlist name never moves the sidebar.
    func testSidebarShortcutsDoNotFireWhileTyping() {
        let (manager, toggles) = makeManager()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        container.addSubview(field)
        let window = makeWindow(content: container)
        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(field, in: window))
        XCTAssertTrue(window.firstResponder is NSTextView, "the field editor should hold focus")

        let typedCommandS = keyDown("s", keyCode: 1, modifiers: [.command], window: window)
        let typedControlCommandS = keyDown("s", keyCode: 1, modifiers: [.control, .command], window: window)
        XCTAssertTrue(CommandPaletteSidebarShortcut.isTypingKeyPress(typedCommandS))
        XCTAssertFalse(manager.handleKeyEvent(typedCommandS))
        XCTAssertFalse(manager.handleKeyEvent(typedControlCommandS))
        XCTAssertEqual(toggles(), 0)

        // The same chord outside a text field does toggle.
        XCTAssertTrue(window.makeFirstResponder(container))
        XCTAssertFalse(CommandPaletteSidebarShortcut.isTypingKeyPress(typedCommandS))
        XCTAssertTrue(manager.handleKeyEvent(typedCommandS))
        XCTAssertEqual(toggles(), 1)
    }

    /// The lyrics view claims every key it doesn't pass on, so it has to let both chords through.
    func testLyricsOverlayLetsTheSidebarShortcutsThrough() throws {
        let (manager, toggles) = makeManager()
        let focusContainer = LyricsOverlayFocusContainerView(
            content: EmptyView(),
            isActive: true,
            keymapStore: manager.keymapStore
        )
        let window = makeWindow(content: focusContainer)
        defer { focusContainer.deactivate() }
        XCTAssertTrue(AppKitTestSupport.makeFirstResponder(focusContainer, in: window))

        let lyricsCommandS = keyDown("s", keyCode: 1, modifiers: [.command], window: window)
        let lyricsControlCommandS = keyDown("s", keyCode: 1, modifiers: [.control, .command], window: window)
        XCTAssertFalse(focusContainer.ownsKeyEvent(lyricsCommandS))
        XCTAssertFalse(focusContainer.ownsKeyEvent(lyricsControlCommandS))
        XCTAssertTrue(manager.handleKeyEvent(lyricsCommandS))
        XCTAssertTrue(manager.handleKeyEvent(lyricsControlCommandS))
        XCTAssertEqual(toggles(), 2)
    }

    // MARK: - Browser, palette and menu

    func testTheBrowserTogglesItsSidebarAndTheMenuTitleFollows() {
        let viewModel = PlaylistBrowserViewModel(
            api: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
            cache: MockBrowsingCache()
        )
        let playback = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander())
        )
        let keymap = CommandPaletteKeymapStore(fileURL: makeCommandPaletteTestsTempSettingsURL())
        let manager = CommandPaletteManager(keymapStore: keymap)
        var sidebarVisible = true
        PlaylistBrowserCommandPaletteConfiguration.apply(
            to: manager,
            dependencies: .init(
                viewModel: viewModel,
                playbackViewModel: playback,
                queueViewModel: QueueViewModel(
                    provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI()),
                    playbackSession: playback
                ),
                commandPaletteManager: manager,
                pinnedStore: PinnedItemsStore(cache: InMemoryPinnedItemsCache()),
                catalogProvider: MockBrowsingAPI(playlistResults: [], trackResults: [:]),
                signOut: {},
                syncUnifiedRefreshRouting: {}
            ),
            queueVisible: .constant(false),
            lyricsPresented: .constant(false),
            sidebarVisible: Binding(get: { sidebarVisible }, set: { sidebarVisible = $0 })
        )

        let scene = SpotiglassSceneHost(commandPaletteManager: manager)
        let registry = SpotiglassSceneRegistry()
        registry.activate(scene)
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

        XCTAssertEqual(commands.sidebarItemTitle, SpotiglassL10n.string("menu.view.hideSidebar"))
        XCTAssertTrue(manager.handleKeyEvent(commandS))
        XCTAssertFalse(sidebarVisible)
        XCTAssertEqual(commands.sidebarItemTitle, SpotiglassL10n.string("menu.view.showSidebar"))

        // The palette lists it, and running it from there shows the sidebar again.
        let item = manager.viewModel.staticItemsProvider().first { $0.id == CommandPaletteCommandID.toggleSidebar }
        XCTAssertEqual(item?.title, SpotiglassL10n.string("palette.command.view.sidebar.toggle.title"))
        // Searching "sidebar" puts it first; Toggle Queue used to carry a "sidebar" keyword.
        let commandItems = manager.viewModel.staticItemsProvider()
        let best = commandItems.min { $0.score(for: "sidebar") < $1.score(for: "sidebar") }
        XCTAssertEqual(best?.id, CommandPaletteCommandID.toggleSidebar)
        let queue = commandItems.first { $0.id == CommandPaletteCommandID.toggleQueue }
        XCTAssertEqual(queue?.score(for: "sidebar"), 100, "the queue panel is not the sidebar")
        manager.execute(commandID: CommandPaletteCommandID.toggleSidebar)
        XCTAssertTrue(sidebarVisible)
        XCTAssertEqual(commands.sidebarItemTitle, SpotiglassL10n.string("menu.view.hideSidebar"))
    }

    /// The title-bar button runs the same command as ⌘S. It used to be the system toggle,
    /// which squeezed the sidebar in and cut it off in a narrow window.
    func testTitleBarButtonRunsTheSidebarCommand() throws {
        let (manager, toggles) = makeManager()
        let shown = PlaylistBrowserSidebarToggleButton(isSidebarVisible: true, commandPaletteManager: manager)
        XCTAssertNoThrow(try shown.inspect().find(text: SpotiglassL10n.string("menu.view.hideSidebar")))
        try shown.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(toggles(), 1)

        let hidden = PlaylistBrowserSidebarToggleButton(isSidebarVisible: false, commandPaletteManager: manager)
        XCTAssertNoThrow(try hidden.inspect().find(text: SpotiglassL10n.string("menu.view.showSidebar")))
        try hidden.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(toggles(), 2)
    }
}
