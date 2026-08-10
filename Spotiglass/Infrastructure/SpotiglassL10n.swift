import Foundation

/// Resolves UI strings from ``Localizable.xcstrings`` using the language in ``SpotiglassSettingsStore``.
///
/// The lookup always goes through the `.lproj` bundle that matches the user's
/// `appLocale`, NOT through `String(localized:locale:)`. `String(localized:)`'s
/// `locale:` parameter only formats numbers/dates within the resolved string —
/// it does not pick which translation Bundle returns. That's chosen by
/// `Bundle.preferredLocalizations`, which derives from the SYSTEM locale.
/// So routing through `.lproj` bundles directly is what makes Spotiglass's
/// in-app language picker actually swap UI copy.
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

    /// Resolves a localization key (literal or runtime-built) against the
    /// `.lproj` bundle for the current app locale.
    static func string(_ key: String) -> String {
        bundleForCurrentLocale().localizedString(forKey: key, value: key, table: nil)
    }

    /// Backwards-compatible alias retained for callers added by the original
    /// palette key-lookup fix.
    static func string(forKey key: String) -> String {
        string(key)
    }

    /// `printf`-style formatting on top of ``string(_:)``. Arguments are
    /// substituted into `%@` / `%lld` / etc. placeholders in the localized
    /// template.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    private static func bundleForCurrentLocale() -> Bundle {
        let loc = locale
        if let path = Bundle.main.path(forResource: loc.identifier, ofType: "lproj"),
            let bundle = Bundle(path: path)
        {
            return bundle
        }
        if let lang = loc.language.languageCode?.identifier,
            let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
            let bundle = Bundle(path: path)
        {
            return bundle
        }
        return .main
    }
}
