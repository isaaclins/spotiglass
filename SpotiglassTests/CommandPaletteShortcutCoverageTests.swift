import AppKit
import XCTest
@testable import Spotiglass

final class CommandPaletteShortcutCoverageTests: XCTestCase {
    func testValidationErrorsDescribeFailures() {
        XCTAssertEqual(
            KeymapValidationError.emptyKeystroke.errorDescription,
            SpotiglassL10n.string("keymap.error.emptyKeystroke")
        )
        XCTAssertEqual(
            KeymapValidationError.unsupportedToken("foo").errorDescription,
            SpotiglassL10n.format("keymap.error.unsupportedToken", "foo")
        )
        XCTAssertEqual(
            KeymapValidationError.missingCommand.errorDescription,
            SpotiglassL10n.string("keymap.error.missingCommand")
        )
        // Conflict copy is localized now, so assert against the catalog rather
        // than pinning one language's punctuation here.
        XCTAssertEqual(
            KeymapConflictError.conflict(existingCommandID: "palette.open").errorDescription,
            SpotiglassL10n.format("keymap.conflict.command", "palette.open")
        )
        XCTAssertEqual(
            KeymapConflictError.reservedByMenuItem(menuItemTitle: "Shuffle").errorDescription,
            SpotiglassL10n.format("keymap.conflict.menuItem", "Shuffle")
        )
    }

    func testBindingValidateRejectsEmptyCommand() {
        let binding = CommandPaletteKeyBinding(keystrokes: ["cmd-k"], command: "  ", when: nil, args: nil)
        XCTAssertThrowsError(try binding.validate()) { error in
            XCTAssertEqual(error as? KeymapValidationError, .missingCommand)
        }
    }

    func testShortcutFromEventAndRecording() throws {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "K",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        )!
        let fromEvent = try XCTUnwrap(CommandShortcut(event: event))
        XCTAssertEqual(fromEvent.key, "k")
        XCTAssertTrue(fromEvent.modifiers.contains(.command))

        let arrow = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 126
        )!
        let fromRecording = try XCTUnwrap(CommandShortcut(recordingKeyDown: arrow))
        XCTAssertFalse(fromRecording.displayChips.isEmpty)

        let modifierOnly = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        )!
        XCTAssertNil(CommandShortcut(recordingKeyDown: modifierOnly))
    }

    func testDisplayChipsAndContextOverlapHelpers() throws {
        let shortcut = try CommandShortcut(keystroke: "shift-cmd-k")
        XCTAssertTrue(shortcut.displayChips.contains("⇧"))
        XCTAssertTrue(shortcut.displayChips.contains("⌘"))

        XCTAssertTrue(CommandPaletteContext.runtimeFilterMatchesBinding(when: .always, context: .signedIn))
        XCTAssertTrue(CommandPaletteContext.bindingsOverlapInRuntime(.always, .signedIn))
        XCTAssertFalse(CommandPaletteContext.bindingsOverlapInRuntime(.signedIn, .paletteOpen))
    }

    func testJSONValueRoundTrip() throws {
        let values: [JSONValue] = [
            .string("s"),
            .number(1.5),
            .boolean(true),
            .object(["k": .string("v")]),
            .array([.null]),
            .null,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(JSONValue.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }
}
