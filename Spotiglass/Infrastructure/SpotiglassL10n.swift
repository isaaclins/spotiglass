import Foundation

/// Resolves UI strings from ``Localizable.xcstrings`` using the language in ``SpotiglassSettingsStore``.
enum SpotiglassL10n {
    nonisolated(unsafe) static weak var settingsStore: SpotiglassSettingsStore?

    static var locale: Locale {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                settingsStore?.appLocale ?? Locale(identifier: "en")
            }
        }
        return Locale(identifier: "en")
    }

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, locale: locale)
    }

    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
