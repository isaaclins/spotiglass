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

    /// Resolves a key that's constructed at runtime. `String.LocalizationValue`'s
    /// interpolation can't be used here because `\(value)` becomes a `%@` argument
    /// rather than part of the key, so the lookup misses and falls back to the
    /// raw template.
    static func string(forKey key: String) -> String {
        let locale = self.locale
        let bundle: Bundle = {
            if let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
               let b = Bundle(path: path) { return b }
            if let lang = locale.language.languageCode?.identifier,
               let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
               let b = Bundle(path: path) { return b }
            return .main
        }()
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
