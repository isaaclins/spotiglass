import Foundation

/// Built-in EQ presets shipped with Spotiglass. Gain values are in dB and follow the
/// same band order as ``EqualizerSettings/bandFrequenciesHz`` (32 Hz first, 16 kHz last).
extension EqualizerPreset {
    static let builtIns: [EqualizerPreset] = [
        EqualizerPreset(
            name: flatName,
            preamp: 0,
            bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Bass Boost",
            preamp: -2,
            bands: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        ),
        EqualizerPreset(
            name: "Vocal",
            preamp: 0,
            bands: [-3, -3, -1, 1, 3, 3, 2, 0, -1, -2]
        ),
        EqualizerPreset(
            name: "Treble Boost",
            preamp: -1,
            bands: [0, 0, 0, 0, 0, 1, 3, 4, 5, 6]
        ),
        EqualizerPreset(
            name: "Acoustic",
            preamp: -1,
            bands: [4, 4, 3, 1, 2, 2, 3, 4, 3, 2]
        ),
        EqualizerPreset(
            name: "Electronic",
            preamp: -1,
            bands: [4, 3, 1, 0, -2, 2, 1, 1, 3, 4]
        ),
        EqualizerPreset(
            name: "Loudness",
            preamp: -2,
            bands: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        ),
    ]

    static let flat: EqualizerPreset = builtIns.first { $0.name == flatName }!

    /// Returns whichever preset (built-in or user) matches `name`, if any.
    static func find(named name: String, userPresets: [EqualizerPreset]) -> EqualizerPreset? {
        if let built = builtIns.first(where: { $0.name == name }) {
            return built
        }
        return userPresets.first { $0.name == name }
    }
}

extension EqualizerSettings {
    /// Whether `bands`/`preamp` exactly match the named preset.
    func matches(_ preset: EqualizerPreset) -> Bool {
        guard preset.bands.count == bands.count else { return false }
        if abs(preset.preamp - preamp) > 0.0001 { return false }
        for (a, b) in zip(preset.bands, bands) where abs(a - b) > 0.0001 {
            return false
        }
        return true
    }

    /// Replaces `bands`/`preamp` with the preset and records its name.
    mutating func apply(preset: EqualizerPreset) {
        preamp = EqualizerSettings.clampPreamp(preset.preamp)
        bands = EqualizerSettings.normalizedBands(preset.bands)
        activePresetName = preset.name
    }
}
