import AppKit
import XCTest

@testable import Spotiglass

@MainActor
final class CommandPaletteViewModelPinAndKeyEventsTests: XCTestCase {
    func testExecuteSelectionPinningRunsPinAction() async {
        let vm = CommandPaletteViewModel()
        var didPin = false
        let item = CommandPaletteItem(
            id: "track-x",
            title: "T",
            subtitle: "S",
            iconSystemName: "music.note",
            section: .tracks,
            keywords: [],
            pinAction: { didPin = true },
            unpinAction: nil,
            action: {}
        )
        vm.testingReplaceSections([(.tracks, [item])])
        vm.selectedIndex = 0
        await vm.executeSelectionPinning()
        XCTAssertTrue(didPin)
    }

    func testCanPinSelectedItemFalseWhenNoPinAction() {
        let vm = CommandPaletteViewModel()
        let item = CommandPaletteItem(
            id: "cmd",
            title: "Cmd",
            subtitle: nil,
            iconSystemName: "gear",
            section: .commands,
            keywords: [],
            action: {}
        )
        vm.testingReplaceSections([(.commands, [item])])
        vm.selectedIndex = 0
        XCTAssertFalse(vm.canPinSelectedItem)
    }

    func testHandleKeyEventDropsAutoRepeatedHotkey() async {
        let manager = CommandPaletteManager()
        manager.isSignedIn = true
        var invocations = 0
        manager.previousTrack = { invocations += 1 }

        // shift-cmd-left default binding from CommandPaletteCommandCatalog. The
        // keymap parser normalizes "left" to NSLeftArrowFunctionKey, so the
        // synthetic event must carry that character or `CommandShortcut(event:)`
        // returns nil and the keymap dispatch is skipped.
        let modifiers: NSEvent.ModifierFlags = [.shift, .command]
        let leftArrowCharacter = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        guard
            let firstPress = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: leftArrowCharacter,
                charactersIgnoringModifiers: leftArrowCharacter,
                isARepeat: false,
                keyCode: 123
            ),
            let repeatedPress = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: leftArrowCharacter,
                charactersIgnoringModifiers: leftArrowCharacter,
                isARepeat: true,
                keyCode: 123
            )
        else {
            return XCTFail("Could not synthesize NSEvent for shift-cmd-left.")
        }

        XCTAssertTrue(manager.handleKeyEvent(firstPress), "First press must be consumed by the keymap.")
        for _ in 0..<8 {
            XCTAssertFalse(
                manager.handleKeyEvent(repeatedPress),
                "Auto-repeat events for a transport hotkey must not be consumed; they must fall through to AppKit."
            )
        }

        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(
            invocations,
            1,
            "Only the initial (non-repeat) shift-cmd-left should reach previousTrack; auto-repeats must be dropped."
        )
    }

    func testHandleKeyEventRunsDuplicateMatchedCommandOnlyOnce() {
        let url = makeCommandPaletteTestsTempSettingsURL()
        let settingsStore = SpotiglassSettingsStore(fileURL: url)
        let keymapStore = CommandPaletteKeymapStore(settingsStore: settingsStore)
        keymapStore.editorText = """
            {
              "bindings": [
                { "keystrokes": ["cmd-k"], "command": "\(CommandPaletteCommandID.openPalette)", "when": "always" },
                { "keystrokes": ["cmd-k"], "command": "\(CommandPaletteCommandID.openPalette)", "when": "always" }
              ]
            }
            """
        keymapStore.applyEditorText()

        let manager = CommandPaletteManager(keymapStore: keymapStore)
        manager.viewModel.hide()

        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "k",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40
            )
        else {
            return XCTFail("Could not synthesize NSEvent for cmd-k.")
        }

        XCTAssertTrue(manager.handleKeyEvent(event))
        XCTAssertTrue(manager.viewModel.isPresented)
    }
}
