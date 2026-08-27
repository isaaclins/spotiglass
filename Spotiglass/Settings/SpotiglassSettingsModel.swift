import Foundation
import SwiftUI

/// Tracks recoverable type/shape errors while decoding a settings document.
///
/// The tracker is passed through ``Decoder/userInfo`` so nested settings values can
/// repair themselves without making the whole document fail. The store uses the
/// flag to persist the repaired document after a successful load.
final class SpotiglassSettingsDecodeTracker {
    var didRepair = false
}

extension CodingUserInfoKey {
    static let spotiglassSettingsDecodeTracker = CodingUserInfoKey(
        rawValue: "com.isaaclins.spotiglass.settingsDecodeTracker"
    )!
}

extension KeyedDecodingContainer {
    fileprivate func decodeRepairing<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: T,
        tracker: SpotiglassSettingsDecodeTracker?
    ) -> T {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return defaultValue
        }
        do {
            return try decode(T.self, forKey: key)
        } catch {
            tracker?.didRepair = true
            return defaultValue
        }
    }

    fileprivate func decodeRepairingOptional<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        tracker: SpotiglassSettingsDecodeTracker?
    ) -> T? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return nil
        }
        do {
            return try decode(T.self, forKey: key)
        } catch {
            tracker?.didRepair = true
            return nil
        }
    }

    /// Decodes each array element independently so one malformed row/preset does
    /// not discard the valid values beside it.
    fileprivate func decodeRepairingArray<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: [T],
        tracker: SpotiglassSettingsDecodeTracker?
    ) -> [T] {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return defaultValue
        }
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else {
            tracker?.didRepair = true
            return defaultValue
        }

        var values: [T] = []
        while !nested.isAtEnd {
            guard let itemDecoder = try? nested.superDecoder() else {
                tracker?.didRepair = true
                break
            }
            do {
                values.append(try T(from: itemDecoder))
            } catch {
                tracker?.didRepair = true
            }
        }
        return values
    }
}

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

    /// The preset whose active line size is nearest an effective size.
    ///
    /// The preset and the continuous scale multiply, so the preset alone does
    /// not describe what is on screen: a segmented control reading Small beside
    /// a slider reading 300% gave one question three answers. Deriving the
    /// selection from the effective size keeps the picker honest (#165).
    static func nearest(activeFontSize: CGFloat) -> LyricsTextSize {
        allCases.min {
            abs($0.activeFontSize - activeFontSize) < abs($1.activeFontSize - activeFontSize)
        } ?? .medium
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

    /// Resolves this preset into concrete metrics, multiplied by the user's
    /// continuous ``AppearanceSettings/lyricsTextScale``.
    func metrics(scale: Double = 1.0) -> LyricsTextMetrics {
        let factor = CGFloat(AppearanceSettings.clampedLyricsTextScale(scale))
        return LyricsTextMetrics(
            activeFontSize: activeFontSize * factor,
            inactiveFontSize: inactiveFontSize * factor,
            timedLineSpacing: timedLineSpacing * factor,
            plainLineSpacing: plainLineSpacing * factor,
            activeGlowRadius: activeGlowRadius * factor
        )
    }
}

/// Concrete font/spacing values for the immersive lyrics view: a ``LyricsTextSize``
/// preset combined with the continuous scale slider.
struct LyricsTextMetrics: Equatable {
    var activeFontSize: CGFloat
    var inactiveFontSize: CGFloat
    var timedLineSpacing: CGFloat
    var plainLineSpacing: CGFloat
    var activeGlowRadius: CGFloat

    /// Preset shorthands so call sites (and tests) can keep writing `.medium`
    /// where a `LyricsTextMetrics` is expected.
    static let small = LyricsTextSize.small.metrics()
    static let medium = LyricsTextSize.medium.metrics()
    static let large = LyricsTextSize.large.metrics()
}

/// Shell appearance preferences persisted in ``SpotiglassSettingsFile``.
struct AppearanceSettings: Codable, Equatable {
    /// Largest lyric sync nudge the UI offers, in milliseconds, in either direction.
    /// Positive values pull lyric lines *earlier* to compensate for the typical
    /// fetch/playback-report lag; negative values push them later.
    static let lyricsOffsetLimitMs = 2_000

    /// Allowed range for ``lyricsTextScale``. The upper bound is generous so the
    /// lyrics can get dramatically larger than the biggest preset.
    static let lyricsTextScaleRange: ClosedRange<Double> = 0.7...3.0

    static func clampedLyricsTextScale(_ value: Double) -> Double {
        min(max(value, lyricsTextScaleRange.lowerBound), lyricsTextScaleRange.upperBound)
    }

    var language: AppLanguage
    var colorScheme: AppearanceColorScheme
    var lyricsTextSize: LyricsTextSize
    /// Manual lyric timing nudge in milliseconds (see ``lyricsOffsetLimitMs``).
    var lyricsOffsetMilliseconds: Int
    /// Continuous multiplier applied on top of the ``lyricsTextSize`` preset (1.0 = preset as-is).
    var lyricsTextScale: Double

    /// The preset and scale combined — what the immersive lyrics view renders with.
    var lyricsTextMetrics: LyricsTextMetrics {
        lyricsTextSize.metrics(scale: lyricsTextScale)
    }

    init(
        language: AppLanguage = AppLanguage.resolvedDefault(),
        colorScheme: AppearanceColorScheme = .system,
        lyricsTextSize: LyricsTextSize = .medium,
        lyricsOffsetMilliseconds: Int = 0,
        lyricsTextScale: Double = 1.0
    ) {
        self.language = language
        self.colorScheme = colorScheme
        self.lyricsTextSize = lyricsTextSize
        self.lyricsOffsetMilliseconds = Self.clampOffset(lyricsOffsetMilliseconds)
        self.lyricsTextScale = Self.clampedLyricsTextScale(lyricsTextScale)
    }

    /// Backward-compatible and repairable decode for older `settings.json` files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tracker = decoder.userInfo[.spotiglassSettingsDecodeTracker] as? SpotiglassSettingsDecodeTracker
        language = container.decodeRepairing(
            AppLanguage.self,
            forKey: .language,
            default: AppLanguage.resolvedDefault(),
            tracker: tracker
        )
        colorScheme = container.decodeRepairing(
            AppearanceColorScheme.self,
            forKey: .colorScheme,
            default: .system,
            tracker: tracker
        )
        lyricsTextSize = container.decodeRepairing(
            LyricsTextSize.self,
            forKey: .lyricsTextSize,
            default: .medium,
            tracker: tracker
        )
        let rawOffset = container.decodeRepairing(
            Int.self,
            forKey: .lyricsOffsetMilliseconds,
            default: 0,
            tracker: tracker
        )
        lyricsOffsetMilliseconds = Self.clampOffset(rawOffset)
        if rawOffset != lyricsOffsetMilliseconds {
            tracker?.didRepair = true
        }
        let rawScale = container.decodeRepairing(
            Double.self,
            forKey: .lyricsTextScale,
            default: 1.0,
            tracker: tracker
        )
        lyricsTextScale = Self.clampedLyricsTextScale(rawScale)
        if rawScale != lyricsTextScale {
            tracker?.didRepair = true
        }
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
        case lyricsTextScale
    }
}

/// Command palette appearance preferences persisted in ``SpotiglassSettingsFile``.
struct CommandPaletteSettings: Codable, Equatable {
    /// When true, the full-window scrim behind the palette uses a material blur.
    var backdropBlur: Bool

    init(backdropBlur: Bool = true) {
        self.backdropBlur = backdropBlur
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tracker = decoder.userInfo[.spotiglassSettingsDecodeTracker] as? SpotiglassSettingsDecodeTracker
        backdropBlur = container.decodeRepairing(
            Bool.self,
            forKey: .backdropBlur,
            default: true,
            tracker: tracker
        )
    }

    private enum CodingKeys: String, CodingKey {
        case backdropBlur
    }
}

/// Top-level shape of `~/Library/Application Support/Spotiglass/settings.json`.
///
/// Keeps every user-editable Spotiglass setting in one file so the user has a single
/// source of truth under the app's Application Support directory.
struct SpotiglassSettingsFile: Codable, Equatable {
    static let currentVersion = 1

    /// Persisted schema marker; compared against ``currentVersion`` during migrations.
    // periphery:ignore
    var version: Int
    var keybinds: [CommandPaletteKeyBinding]
    /// Command IDs whose default keystroke has already been written into ``keybinds``
    /// (or deliberately cleared by the user). Commands added to the catalog after this
    /// file was created are absent here, which lets the load-time migration seed their
    /// default binding exactly once without resurrecting bindings the user removed.
    var seededKeybindCommands: [String]
    var appearance: AppearanceSettings
    var commandPalette: CommandPaletteSettings
    var equalizer: EqualizerSettings

    init(
        version: Int = SpotiglassSettingsFile.currentVersion,
        keybinds: [CommandPaletteKeyBinding],
        seededKeybindCommands: [String] = [],
        appearance: AppearanceSettings = AppearanceSettings(),
        commandPalette: CommandPaletteSettings = CommandPaletteSettings(),
        equalizer: EqualizerSettings = EqualizerSettings()
    ) {
        self.version = version
        self.keybinds = keybinds
        self.seededKeybindCommands = seededKeybindCommands
        self.appearance = appearance
        self.commandPalette = commandPalette
        self.equalizer = equalizer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tracker = decoder.userInfo[.spotiglassSettingsDecodeTracker] as? SpotiglassSettingsDecodeTracker
        version = container.decodeRepairing(
            Int.self,
            forKey: .version,
            default: SpotiglassSettingsFile.currentVersion,
            tracker: tracker
        )
        keybinds = container.decodeRepairingArray(
            CommandPaletteKeyBinding.self,
            forKey: .keybinds,
            default: [],
            tracker: tracker
        )
        seededKeybindCommands = container.decodeRepairingArray(
            String.self,
            forKey: .seededKeybindCommands,
            default: [],
            tracker: tracker
        )
        appearance = container.decodeRepairing(
            AppearanceSettings.self,
            forKey: .appearance,
            default: AppearanceSettings(),
            tracker: tracker
        )
        commandPalette = container.decodeRepairing(
            CommandPaletteSettings.self,
            forKey: .commandPalette,
            default: CommandPaletteSettings(),
            tracker: tracker
        )
        equalizer = container.decodeRepairing(
            EqualizerSettings.self,
            forKey: .equalizer,
            default: EqualizerSettings(),
            tracker: tracker
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case keybinds
        case seededKeybindCommands
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
    /// Global pre-amp in dB applied before the band gains.
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
        self.preamp = EqualizerSettings.clampPreamp(preamp)
        self.bands = EqualizerSettings.normalizedBands(bands)
        self.activePresetName = activePresetName
        self.userPresets = userPresets
        self.forwardingTargetUID = forwardingTargetUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tracker = decoder.userInfo[.spotiglassSettingsDecodeTracker] as? SpotiglassSettingsDecodeTracker
        enabled = container.decodeRepairing(
            Bool.self,
            forKey: .enabled,
            default: false,
            tracker: tracker
        )
        // Both fixes apply here and are complementary: #278 repairs a malformed
        // field instead of failing the whole document, and #249 clamps whatever
        // survives to the declared dB range. Repair first, then clamp — otherwise
        // a repaired-to-default value would still bypass the range contract.
        preamp = EqualizerSettings.clampPreamp(
            container.decodeRepairing(
                Double.self,
                forKey: .preamp,
                default: 0,
                tracker: tracker
            )
        )
        let defaultBands = Array(repeating: 0.0, count: EqualizerSettings.bandCount)
        let raw = container.decodeRepairingArray(
            Double.self,
            forKey: .bands,
            default: defaultBands,
            tracker: tracker
        )
        bands = EqualizerSettings.normalizedBands(raw)
        if raw != bands {
            tracker?.didRepair = true
        }
        activePresetName = container.decodeRepairingOptional(
            String.self,
            forKey: .activePresetName,
            tracker: tracker
        )
        userPresets = container.decodeRepairingArray(
            EqualizerPreset.self,
            forKey: .userPresets,
            default: [],
            tracker: tracker
        )
        forwardingTargetUID = container.decodeRepairingOptional(
            String.self,
            forKey: .forwardingTargetUID,
            tracker: tracker
        )
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
        let tracker = decoder.userInfo[.spotiglassSettingsDecodeTracker] as? SpotiglassSettingsDecodeTracker
        // A preset without a usable name has no stable identity, so let the
        // enclosing lossy array decoder discard that one preset while retaining
        // its valid siblings.
        name = try container.decode(String.self, forKey: .name)
        preamp = container.decodeRepairing(
            Double.self,
            forKey: .preamp,
            default: 0,
            tracker: tracker
        )
        let defaultBands = Array(repeating: 0.0, count: EqualizerSettings.bandCount)
        let raw = container.decodeRepairingArray(
            Double.self,
            forKey: .bands,
            default: defaultBands,
            tracker: tracker
        )
        bands = EqualizerSettings.normalizedBands(raw)
        if raw != bands {
            tracker?.didRepair = true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case preamp
        case bands
    }

    static let flatName = "Flat"
}
