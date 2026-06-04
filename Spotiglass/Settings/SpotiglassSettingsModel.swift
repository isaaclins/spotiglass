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
    /// Largest lyric sync nudge the UI offers, in milliseconds, in either direction.
    /// Positive values pull lyric lines *earlier* to compensate for the typical
    /// fetch/playback-report lag; negative values push them later.
    static let lyricsOffsetLimitMs = 2_000

    var language: AppLanguage
    var colorScheme: AppearanceColorScheme
    var lyricsTextSize: LyricsTextSize
    /// Manual lyric timing nudge in milliseconds (see ``lyricsOffsetLimitMs``).
    var lyricsOffsetMilliseconds: Int

    init(
        language: AppLanguage = AppLanguage.resolvedDefault(),
        colorScheme: AppearanceColorScheme = .system,
        lyricsTextSize: LyricsTextSize = .medium,
        lyricsOffsetMilliseconds: Int = 0
    ) {
        self.language = language
        self.colorScheme = colorScheme
        self.lyricsTextSize = lyricsTextSize
        self.lyricsOffsetMilliseconds = Self.clampOffset(lyricsOffsetMilliseconds)
    }

    /// Backward-compatible decode for older `settings.json` files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? AppLanguage.resolvedDefault()
        colorScheme = try container.decodeIfPresent(AppearanceColorScheme.self, forKey: .colorScheme) ?? .system
        lyricsTextSize = try container.decodeIfPresent(LyricsTextSize.self, forKey: .lyricsTextSize) ?? .medium
        let rawOffset = try container.decodeIfPresent(Int.self, forKey: .lyricsOffsetMilliseconds) ?? 0
        lyricsOffsetMilliseconds = Self.clampOffset(rawOffset)
    }

    /// Keeps a (possibly hand-edited or future-version) offset within the supported range.
    static func clampOffset(_ value: Int) -> Int {
        min(max(value, -lyricsOffsetLimitMs), lyricsOffsetLimitMs)
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case colorScheme
        case lyricsTextSize
        case lyricsOffsetMilliseconds
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

/// Top-level shape of `~/Library/Application Support/Spotiglass/settings.json`.
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
    var equalizer: EqualizerSettings

    init(
        version: Int = SpotiglassSettingsFile.currentVersion,
        keybinds: [CommandPaletteKeyBinding],
        appearance: AppearanceSettings = AppearanceSettings(),
        commandPalette: CommandPaletteSettings = CommandPaletteSettings(),
        equalizer: EqualizerSettings = EqualizerSettings()
    ) {
        self.version = version
        self.keybinds = keybinds
        self.appearance = appearance
        self.commandPalette = commandPalette
        self.equalizer = equalizer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SpotiglassSettingsFile.currentVersion
        keybinds = try container.decodeIfPresent([CommandPaletteKeyBinding].self, forKey: .keybinds) ?? []
        appearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
        commandPalette = try container.decodeIfPresent(CommandPaletteSettings.self, forKey: .commandPalette)
            ?? CommandPaletteSettings()
        equalizer = try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer) ?? EqualizerSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case keybinds
        case appearance
        case commandPalette
        case equalizer
    }
}

/// Persistent equalizer state. Gains are stored in dB; the slider range is
/// ``EqualizerSettings/gainRangeDB``. Resurrected verbatim from commit
/// `2fdd179` so saved `settings.json` files from that era continue to load.
struct EqualizerSettings: Codable, Equatable {
    /// 10 fixed center frequencies (Hz). Indexes line up with `bands`.
    static let bandFrequenciesHz: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = bandFrequenciesHz.count
    static let gainRangeDB: ClosedRange<Double> = -12.0...12.0
    static let preampRangeDB: ClosedRange<Double> = -12.0...12.0

    var enabled: Bool
    /// Global pre-amp in dB applied before the parametric bands.
    var preamp: Double
    /// Per-band gain in dB. Always exactly ``EqualizerSettings/bandCount`` long.
    var bands: [Double]
    /// Name of the preset currently displayed in the picker, or `nil` for "Custom".
    var activePresetName: String?
    /// User-defined presets stored alongside the built-ins.
    var userPresets: [EqualizerPreset]
    /// Persistent UID of the hardware output device the EQ should forward
    /// processed audio to. `nil` means the controller picks a sensible
    /// default at enable time (the previous default before EQ activation,
    /// falling back to `BuiltInSpeakerDevice`).
    var forwardingTargetUID: String?

    init(
        enabled: Bool = false,
        preamp: Double = 0,
        bands: [Double] = Array(repeating: 0, count: EqualizerSettings.bandCount),
        activePresetName: String? = EqualizerPreset.flatName,
        userPresets: [EqualizerPreset] = [],
        forwardingTargetUID: String? = nil
    ) {
        self.enabled = enabled
        self.preamp = preamp
        self.bands = EqualizerSettings.normalizedBands(bands)
        self.activePresetName = activePresetName
        self.userPresets = userPresets
        self.forwardingTargetUID = forwardingTargetUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        let raw = try container.decodeIfPresent([Double].self, forKey: .bands)
            ?? Array(repeating: 0, count: EqualizerSettings.bandCount)
        bands = EqualizerSettings.normalizedBands(raw)
        activePresetName = try container.decodeIfPresent(String.self, forKey: .activePresetName)
        userPresets = try container.decodeIfPresent([EqualizerPreset].self, forKey: .userPresets) ?? []
        forwardingTargetUID = try container.decodeIfPresent(String.self, forKey: .forwardingTargetUID)
    }

    /// Pads/truncates raw band arrays so the in-memory shape stays consistent.
    static func normalizedBands(_ raw: [Double]) -> [Double] {
        var bands = raw
        if bands.count < bandCount {
            bands.append(contentsOf: Array(repeating: 0, count: bandCount - bands.count))
        } else if bands.count > bandCount {
            bands = Array(bands.prefix(bandCount))
        }
        return bands.map { Self.clampGain($0) }
    }

    static func clampGain(_ value: Double) -> Double {
        min(max(value, gainRangeDB.lowerBound), gainRangeDB.upperBound)
    }

    static func clampPreamp(_ value: Double) -> Double {
        min(max(value, preampRangeDB.lowerBound), preampRangeDB.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case preamp
        case bands
        case activePresetName
        case userPresets
        case forwardingTargetUID
    }
}

/// Named EQ curve. The same struct represents both built-in and user-saved presets.
/// Resurrected verbatim from `2fdd179`.
struct EqualizerPreset: Codable, Equatable, Identifiable, Hashable {
    var name: String
    var preamp: Double
    var bands: [Double]

    var id: String { name }

    init(name: String, preamp: Double = 0, bands: [Double]) {
        self.name = name
        self.preamp = preamp
        self.bands = EqualizerSettings.normalizedBands(bands)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        let raw = try container.decodeIfPresent([Double].self, forKey: .bands)
            ?? Array(repeating: 0, count: EqualizerSettings.bandCount)
        bands = EqualizerSettings.normalizedBands(raw)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case preamp
        case bands
    }

    static let flatName = "Flat"
}
