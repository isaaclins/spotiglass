import AppKit
import Foundation

enum KeymapValidationError: LocalizedError, Equatable {
    case emptyKeystroke
    case unsupportedToken(String)
    case missingCommand

    var errorDescription: String? {
        switch self {
        case .emptyKeystroke:
            SpotiglassL10n.string("keymap.error.emptyKeystroke")
        case let .unsupportedToken(token):
            SpotiglassL10n.format("keymap.error.unsupportedToken", token)
        case .missingCommand:
            SpotiglassL10n.string("keymap.error.missingCommand")
        }
    }
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array((try? container.decode([JSONValue].self)) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct CommandPaletteKeymapFile: Codable, Equatable {
    var bindings: [CommandPaletteKeyBinding]
}

struct CommandPaletteKeyBinding: Codable, Equatable {
    var keystrokes: [String]
    var command: String
    var when: CommandPaletteContext?
    var args: [String: JSONValue]?

    func validate() throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeymapValidationError.missingCommand
        }
        if keystrokes.isEmpty {
            throw KeymapValidationError.emptyKeystroke
        }
        for keystroke in keystrokes {
            _ = try CommandShortcut(keystroke: keystroke)
        }
    }
}

struct CommandShortcut: Hashable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    static func == (lhs: CommandShortcut, rhs: CommandShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    init(keystroke: String) throws {
        let normalized = keystroke
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            throw KeymapValidationError.emptyKeystroke
        }

        var flags = NSEvent.ModifierFlags()
        var finalKey: String?
        for token in normalized.split(separator: "-").map(String.init) {
            switch token {
            case "cmd", "command":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "alt", "option":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            case "space":
                finalKey = " "
            case "enter", "return":
                finalKey = "\r"
            case "tab":
                finalKey = "\t"
            case "up":
                finalKey = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case "down":
                finalKey = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case "left":
                finalKey = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case "right":
                finalKey = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case "esc", "escape":
                finalKey = String(Character(UnicodeScalar(0x1B)!))
            default:
                if token.count == 1 {
                    finalKey = token
                } else {
                    throw KeymapValidationError.unsupportedToken(token)
                }
            }
        }

        guard let finalKey else {
            throw KeymapValidationError.emptyKeystroke
        }
        key = finalKey
        modifiers = flags.intersection([.command, .control, .option, .shift])
    }

    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        key = characters.lowercased()
        modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    }

    /// Builds a shortcut from a key-down event while recording in Settings (handles arrow keys, etc.).
    init?(recordingKeyDown event: NSEvent) {
        if Self.modifierOnlyKeyCodes.contains(event.keyCode) {
            return nil
        }
        modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Prefer physical key identity (ANSI virtual key code) over localized characters so
        // shortcuts like cmd-k record consistently on non-US keyboard layouts.
        if let recordingKey = Self.recordingKeyFromANSIKeyCode(event.keyCode) {
            key = recordingKey
            return
        }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            key = Self.normalizedRecordingKey(from: chars)
            return
        }
        guard let fallback = Self.keyString(forSpecialKeyCode: event.keyCode) else {
            return nil
        }
        key = fallback
    }

    /// Keystroke string as stored in `keymap.json` (e.g. `shift-cmd-k`, `cmd-,`).
    func canonicalToken() throws -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(try Self.keystrokeKeyToken(from: key))
        return parts.joined(separator: "-")
    }

    /// Symbols for UI chips in Mac modifier order: ⌃ ⌥ ⇧ ⌘ then key label.
    var displayChips: [String] {
        var chips: [String] = []
        if modifiers.contains(.control) { chips.append("⌃") }
        if modifiers.contains(.option) { chips.append("⌥") }
        if modifiers.contains(.shift) { chips.append("⇧") }
        if modifiers.contains(.command) { chips.append("⌘") }
        chips.append(Self.displayKeyLabel(for: key))
        return chips
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    ]

    /// Maps macOS ANSI virtual key codes (same values as Carbon `kVK_ANSI_*`) to recording keys.
    private static func recordingKeyFromANSIKeyCode(_ keyCode: UInt16) -> String? {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let letterCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6, 18, 19, 20, 21, 23]
        if let index = letterCodes.firstIndex(of: keyCode) {
            let i = letters.index(letters.startIndex, offsetBy: index)
            return String(letters[i])
        }
        let digits = "0123456789"
        let digitCodes: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        if let index = digitCodes.firstIndex(of: keyCode) {
            let i = digits.index(digits.startIndex, offsetBy: index)
            return String(digits[i])
        }
        return nil
    }

    private static func normalizedRecordingKey(from characters: String) -> String {
        let first = String(characters.prefix(1))
        guard let ch = first.first else { return "" }
        if ch.isLetter {
            return first.lowercased()
        }
        return first
    }

    private static func keyString(forSpecialKeyCode keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case 123:
            return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 124:
            return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 125:
            return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case 126:
            return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        default:
            return nil
        }
    }

    private static func keystrokeKeyToken(from key: String) throws -> String {
        switch key {
        case " ":
            return "space"
        case "\r", "\n":
            return "return"
        case "\t":
            return "tab"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)):
            return "up"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)):
            return "down"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)):
            return "left"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)):
            return "right"
        case "\u{1B}":
            return "esc"
        default:
            if key.count == 1, let scalar = key.unicodeScalars.first, scalar.value < 128 {
                return String(Character(UnicodeScalar(scalar.value)!)).lowercased()
            }
            throw KeymapValidationError.unsupportedToken(key)
        }
    }

    private static func displayKeyLabel(for key: String) -> String {
        switch key {
        case " ":
            return "Space"
        case "\r", "\n":
            return "↩"
        case "\t":
            return "⇥"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)):
            return "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)):
            return "↓"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)):
            return "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)):
            return "→"
        case "\u{1B}":
            return "esc"
        default:
            if key.count == 1, let ch = key.first, ch.isLetter {
                return String(ch).uppercased()
            }
            return key
        }
    }
}

enum KeymapConflictError: LocalizedError, Equatable {
    case conflict(existingCommandID: String)
    /// The chord belongs to a menu item that claims it outside the keymap, so
    /// binding it here would shadow a menu item that keeps advertising it (#129).
    case reservedByMenuItem(menuItemTitle: String)

    var errorDescription: String? {
        switch self {
        case let .conflict(id):
            SpotiglassL10n.format("keymap.conflict.command", id)
        case let .reservedByMenuItem(title):
            SpotiglassL10n.format("keymap.conflict.menuItem", title)
        }
    }
}

extension CommandPaletteContext {
    /// Context values passed from `CommandPaletteManager.handleKeyEvent` into `commandBindings`.
    static let conflictCheckContexts: [CommandPaletteContext] = [.signedIn, .signedOut, .paletteOpen]

    /// Mirrors `commandBindings(for:context:)` `when` filtering.
    static func runtimeFilterMatchesBinding(when: CommandPaletteContext?, context: CommandPaletteContext) -> Bool {
        guard let when else { return true }
        return when == .always || when == context
    }

    static func bindingsOverlapInRuntime(_ a: CommandPaletteContext?, _ b: CommandPaletteContext?) -> Bool {
        conflictCheckContexts.contains { ctx in
            runtimeFilterMatchesBinding(when: a, context: ctx) && runtimeFilterMatchesBinding(when: b, context: ctx)
        }
    }
}
