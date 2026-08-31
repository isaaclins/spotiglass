import Foundation
import SwiftUI

private struct SpotiglassLocaleKey: EnvironmentKey {
    static let defaultValue = Locale(identifier: "en")
}

extension EnvironmentValues {
    /// The in-app language, rather than macOS's preferred language.
    var spotiglassLocale: Locale {
        get { self[SpotiglassLocaleKey.self] }
        set { self[SpotiglassLocaleKey.self] = newValue }
    }
}

/// A SwiftUI text view that records the in-app language as a view dependency.
///
/// Unlike a `String` returned by ``SpotiglassL10n/string(_:)``, this view reads
/// `spotiglassLocale` from the environment, so SwiftUI invalidates it when the
/// user changes the language.
struct L10nText: View {
    private let key: String
    private let explicitLocale: Locale?
    @Environment(\.spotiglassLocale) private var locale

    init(_ key: String, locale: Locale? = nil) {
        self.key = key
        self.explicitLocale = locale
    }

    var body: some View {
        Text(SpotiglassL10n.string(key, locale: explicitLocale ?? locale))
    }
}

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
    private static let catalogKeyCache = NSCache<NSURL, NSSet>()

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
        string(key, locale: locale)
    }

    /// Resolves a key against an explicitly supplied locale. Views use this
    /// overload after reading `spotiglassLocale` from the environment; model
    /// and service code can continue to use the current-store overload above.
    static func string(_ key: String, locale: Locale) -> String {
        let localizationBundle = bundle(for: locale, key: key)
        let value = localizationBundle.localizedString(forKey: key, value: key, table: nil)
        #if DEBUG
        assert(
            value != key || containsKey(key, in: localizationBundle),
            "Missing localization key: \(key)"
        )
        #endif
        return value
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

    static func format(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), arguments: arguments)
    }

    private static func bundle(for loc: Locale, key: String) -> Bundle {
        // `Bundle.main` is the app bundle in production. The test host can make
        // it the XCTest bundle, so also search the bundle that owns the app
        // type; this keeps direct localization lookups honest in both targets.
        var candidates = [Bundle.main, Bundle(for: SpotiglassSettingsStore.self)]
        candidates.append(contentsOf: Bundle.allBundles)
        candidates.append(contentsOf: Bundle.allFrameworks)
        var fallback: Bundle?
        var seen: Set<URL> = []
        for candidate in candidates where seen.insert(candidate.bundleURL).inserted {
            var paths = [candidate.path(forResource: loc.identifier, ofType: "lproj")]
            if let language = loc.language.languageCode?.identifier {
                paths.append(candidate.path(forResource: language, ofType: "lproj"))
            }
            for path in paths.compactMap({ $0 }) {
                guard let bundle = Bundle(path: path) else { continue }
                fallback = fallback ?? bundle
                if containsKey(key, in: bundle) {
                    return bundle
                }
            }
        }
        return fallback ?? .main
    }

    private static func containsKey(_ key: String, in bundle: Bundle) -> Bool {
        let cacheKey = bundle.bundleURL as NSURL
        if let cachedKeys = catalogKeyCache.object(forKey: cacheKey) {
            return cachedKeys.contains(key)
        }

        var keys: Set<String> = []
        for fileExtension in ["strings", "stringsdict"] {
            guard let path = bundle.path(forResource: "Localizable", ofType: fileExtension),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let propertyList = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: Any]
            else { continue }
            keys.formUnion(propertyList.keys)
        }
        let cachedKeys = NSSet(array: Array(keys))
        catalogKeyCache.setObject(cachedKeys, forKey: cacheKey)
        return cachedKeys.contains(key)
    }
}
