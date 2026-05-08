import Foundation

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
    var equalizer: EqualizerSettings
    var commandPalette: CommandPaletteSettings

    init(
        version: Int = SpotiglassSettingsFile.currentVersion,
        keybinds: [CommandPaletteKeyBinding],
        equalizer: EqualizerSettings,
        commandPalette: CommandPaletteSettings = CommandPaletteSettings()
    ) {
        self.version = version
        self.keybinds = keybinds
        self.equalizer = equalizer
        self.commandPalette = commandPalette
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? SpotiglassSettingsFile.currentVersion
        keybinds = try container.decodeIfPresent([CommandPaletteKeyBinding].self, forKey: .keybinds) ?? []
        equalizer = try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer) ?? EqualizerSettings()
        commandPalette = try container.decodeIfPresent(CommandPaletteSettings.self, forKey: .commandPalette)
            ?? CommandPaletteSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case keybinds
        case equalizer
        case commandPalette
    }
}

/// Persistent equalizer state. Gains are stored in dB; the slider range is
/// `EqualizerSettings.gainRangeDB`.
struct EqualizerSettings: Codable, Equatable {
    /// 10 fixed center frequencies (Hz). Indexes line up with `bands`.
    static let bandFrequenciesHz: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = bandFrequenciesHz.count
    static let gainRangeDB: ClosedRange<Double> = -12.0...12.0
    static let preampRangeDB: ClosedRange<Double> = -12.0...12.0

    var enabled: Bool
    /// Global pre-amp in dB applied before the parametric bands.
    var preamp: Double
    /// Per-band gain in dB. Always exactly `EqualizerSettings.bandCount` long.
    var bands: [Double]
    /// Name of the preset currently displayed in the picker, or `nil` for "Custom".
    var activePresetName: String?
    /// User-defined presets stored alongside the built-ins.
    var userPresets: [EqualizerPreset]

    init(
        enabled: Bool = false,
        preamp: Double = 0,
        bands: [Double] = Array(repeating: 0, count: EqualizerSettings.bandCount),
        activePresetName: String? = EqualizerPreset.flatName,
        userPresets: [EqualizerPreset] = []
    ) {
        self.enabled = enabled
        self.preamp = preamp
        self.bands = EqualizerSettings.normalizedBands(bands)
        self.activePresetName = activePresetName
        self.userPresets = userPresets
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
    }
}

/// Named EQ curve. The same struct represents both built-in and user-saved presets.
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
