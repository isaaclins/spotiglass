import AppKit
import Foundation

enum KeymapValidationError: LocalizedError, Equatable {
    case emptyKeystroke
    case unsupportedToken(String)
    case missingCommand

    var errorDescription: String? {
        switch self {
        case .emptyKeystroke:
            "Keystroke cannot be empty."
        case let .unsupportedToken(token):
            "Unsupported keystroke token '\(token)'."
        case .missingCommand:
            "Key binding command cannot be empty."
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
}
