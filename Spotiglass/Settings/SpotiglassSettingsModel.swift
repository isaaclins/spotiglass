import Foundation
import SwiftUI

/// In-app UI language persisted in ``AppearanceSettings``.
enum AppLanguage: String, Codable, CaseIterable, Equatable {
    case english = "en"
    case spanish = "es"
    case german = "de"

    /// Fixed native label so users can find their language in the picker.
    var nativeDisplayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        }
    }

    /// macOS preferred language when it is en/es/de; otherwise English.
    static func resolvedDefault() -> AppLanguage {
        let code = Locale.preferredLanguages.first?
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"
        switch code {
        case "es": return .spanish
        case "de": return .german
        default: return .english
        }
    }
}

/// App-wide light/dark appearance override persisted in ``SpotiglassSettingsFile``.
enum AppearanceColorScheme: String, Codable, CaseIterable, Equatable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: SpotiglassL10n.string("settings.appearance.scheme.system")
        case .light: SpotiglassL10n.string("settings.appearance.scheme.light")
        case .dark: SpotiglassL10n.string("settings.appearance.scheme.dark")
        }
    }

    /// `nil` follows macOS; otherwise forces the chosen scheme for Spotiglass windows.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Sizing preset for the immersive lyrics view. Three steps so users can tune for
/// reading distance / display size.
enum LyricsTextSize: String, Codable, CaseIterable, Equatable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small: SpotiglassL10n.string("settings.appearance.lyricsSize.small")
        case .medium: SpotiglassL10n.string("settings.appearance.lyricsSize.medium")
        case .large: SpotiglassL10n.string("settings.appearance.lyricsSize.large")
        }
    }

    /// Point size for the active (currently playing) line.
    var activeFontSize: CGFloat {
        switch self {
        case .small: 17
        case .medium: 22
        case .large: 30
        }
    }

    /// Point size for non-active lines.
    var inactiveFontSize: CGFloat {
        switch self {
        case .small: 14
        case .medium: 18
        case .large: 23
        }
    }

    /// Vertical spacing between lines in the timed-lyrics layout.
    var timedLineSpacing: CGFloat {
        switch self {
        case .small: 12
        case .medium: 18
        case .large: 24
        }
    }

    /// Vertical spacing between lines in the plain-lyrics layout.
    var plainLineSpacing: CGFloat {
        switch self {
        case .small: 10
        case .medium: 16
        case .large: 22
        }
    }

    /// Soft halo radius behind the active line. Scales with size for visual balance.
    var activeGlowRadius: CGFloat {
        switch self {
        case .small: 10
        case .medium: 14
        case .large: 20
        }
    }
}

/// Shell appearance preferences persisted in ``SpotiglassSettingsFile``.
struct AppearanceSettings: Codable, Equatable {
    var language: AppLanguage
    var colorScheme: AppearanceColorScheme
    var lyricsTextSize: LyricsTextSize

    init(
        language: AppLanguage = AppLanguage.resolvedDefault(),
        colorScheme: AppearanceColorScheme = .system,
        lyricsTextSize: LyricsTextSize = .medium
    ) {
        self.language = language
        self.colorScheme = colorScheme
        self.lyricsTextSize = lyricsTextSize
    }

    /// Backward-compatible decode for older `settings.json` files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? AppLanguage.resolvedDefault()
        colorScheme = try container.decodeIfPresent(AppearanceColorScheme.self, forKey: .colorScheme) ?? .system
        lyricsTextSize = try container.decodeIfPresent(LyricsTextSize.self, forKey: .lyricsTextSize) ?? .medium
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case colorScheme
        case lyricsTextSize
    }
}

/// Command palette appearance preferences persisted in ``SpotiglassSettingsFile``.
struct CommandPaletteSettings: Codable, Equatable {
    /// When true, the full-window scrim behind the palette uses a material blur.
    var backdropBlur: Bool

    init(backdropBlur: Bool = true) {
        self.backdropBlur = backdropBlur
    }
}

/// Top-level shape of `~/.config/spotiglass/settings.json`.
///
/// Keeps every user-editable Spotiglass setting in one file so the user has a single
/// source of truth that plays nicely with dotfile management.
struct SpotiglassSettingsFile: Codable, Equatable {
    static let currentVersion = 1

    /// Persisted schema marker; compared against ``currentVersion`` during migrations.
    // periphery:ignore
    var version: Int
    var keybinds: [CommandPaletteKeyBinding]
    var appearance: AppearanceSettings
    var commandPalette: CommandPaletteSettings

    init(
        version: Int = SpotiglassSettingsFile.currentVersion,
        keybinds: [CommandPaletteKeyBinding],
        appearance: AppearanceSettings = AppearanceSettings(),
        commandPalette: CommandPaletteSettings = CommandPaletteSettings()
    ) {
        self.version = version
        self.keybinds = keybinds
        self.appearance = appearance
        self.commandPalette = commandPalette
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SpotiglassSettingsFile.currentVersion
        keybinds = try container.decodeIfPresent([CommandPaletteKeyBinding].self, forKey: .keybinds) ?? []
        appearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
        commandPalette = try container.decodeIfPresent(CommandPaletteSettings.self, forKey: .commandPalette)
            ?? CommandPaletteSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case keybinds
        case appearance
        case commandPalette
    }
}
