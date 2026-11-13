import Foundation
import os
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

extension View {
    /// Puts the app language into a window's content. A switch only changes text: the
    /// content keeps its identity, so its page, scroll position, selection and open panels
    /// stay as they were (#548). Never key the content on the language with `.id`.
    func spotiglassLanguage(_ settingsStore: SpotiglassSettingsStore) -> some View {
        modifier(SpotiglassLanguageEnvironment(settingsStore: settingsStore))
    }
}

/// Observes the store itself, so the locale follows a switch wherever the content is hosted.
private struct SpotiglassLanguageEnvironment: ViewModifier {
    @ObservedObject var settingsStore: SpotiglassSettingsStore

    func body(content: Content) -> some View {
        content
            .environment(\.locale, settingsStore.appLocale)
            .environment(\.spotiglassLocale, settingsStore.appLocale)
    }
}

/// Text a model keeps for later, such as an empty-state message, an error or a badge. It is
/// looked up again each time it is read, so it follows a language switch like text a view
/// resolves itself (#548). Pass the lookup itself, not a string resolved earlier.
///
/// Comparing two of them resolves both, unless both were given what they are made from
/// (``init(_:comparedBy:)``): long lists compare their rows on every refresh, and a lookup per
/// row and side cost a 10,000-song list tens of milliseconds there.
struct LocalizedText: Equatable, ExpressibleByStringLiteral {
    private let resolve: () -> String
    private let source: AnyHashable?

    init(_ resolve: @autoclosure @escaping () -> String) {
        self.resolve = resolve
        self.source = nil
    }

    /// Text that is the same in every language whenever `source` is the same: a localization
    /// key, or a name as the row was built with it. Equal sources compare equal without a lookup.
    init(_ resolve: @autoclosure @escaping () -> String, comparedBy source: AnyHashable) {
        self.resolve = resolve
        self.source = source
    }

    /// A key's text: equal keys compare equal without a lookup. Keys are kept apart from names,
    /// so a name that reads like a key never compares equal to it.
    init(_ resolve: @autoclosure @escaping () -> String, comparedByKey key: String) {
        self.resolve = resolve
        self.source = AnyHashable(Source.key(key))
    }

    private enum Source: Hashable {
        case key(String)
    }

    /// Fixed text that is not translated, such as a song title.
    init(verbatim value: String) {
        self.resolve = { value }
        self.source = value
    }

    init(stringLiteral value: String) {
        self.init(verbatim: value)
    }

    var string: String { resolve() }

    static func == (lhs: LocalizedText, rhs: LocalizedText) -> Bool {
        if let left = lhs.source, let right = rhs.source {
            return left == right
        }
        return lhs.string == rhs.string
    }
}

/// The closures only read values captured when the text was made and look strings up, which
/// works on any thread (``SpotiglassL10n/locale``), so errors that keep one stay `Sendable`.
extension LocalizedText: @unchecked Sendable {}

/// The app language as an observable value. SwiftUI records a read of ``locale`` made while
/// a body runs, so views that resolve strings with ``SpotiglassL10n/string(_:)`` follow a
/// language switch without being rebuilt.
@MainActor
@Observable
final class SpotiglassLanguageSignal {
    private(set) var locale: Locale?

    func observe() {
        _ = locale
    }

    /// Only a real change notifies, so other settings edits redraw nothing.
    func update(_ newLocale: Locale?) {
        guard newLocale?.identifier != locale?.identifier else { return }
        locale = newLocale
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
    /// Set on the main thread only (the app at launch, tests).
    nonisolated(unsafe) static weak var settingsStore: SpotiglassSettingsStore? {
        didSet {
            let locale = MainActor.assumeIsolated {
                let locale = settingsStore?.appLocale
                languageSignal.update(locale)
                return locale
            }
            offMainLocale.withLock { $0 = locale }
        }
    }
    /// Every view whose body looks a string up through ``locale`` reads this, so SwiftUI
    /// redraws it when the language changes. That is what lets a switch keep the window as
    /// it is (page, scroll position, selection, open panels) and only change its text (#548):
    /// the window used to be rebuilt from scratch instead, which sent it back to Home.
    @MainActor static let languageSignal = SpotiglassLanguageSignal()
    private static let catalogKeyCache = NSCache<NSURL, NSSet>()
    /// The app language for code that runs off the main thread: providers build "You" and
    /// "Untitled Playlist" on background tasks, which used to fall back to English (#398).
    /// ``settingsStore`` and ``SpotiglassSettingsStore`` keep it current.
    private static let offMainLocale = OSAllocatedUnfairLock<Locale?>(initialState: nil)
    /// The `.lproj` bundles each language's strings can come from, in lookup order, found once.
    /// Finding them asks every loaded bundle and framework (hundreds) for a folder, which every
    /// lookup used to do again: a track row looks up several strings, so a list of 800 songs
    /// spent most of its layout time here (#442).
    private static let localizationBundles = OSAllocatedUnfairLock<[String: [Bundle]]>(initialState: [:])
    #if DEBUG
    /// How many strings were looked up, for tests.
    static let lookups = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// How often the bundles were looked for, for tests.
    static let localizationBundleSearches = OSAllocatedUnfairLock<Int>(initialState: 0)
    #endif

    static var locale: Locale {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                languageSignal.observe()
                return settingsStore?.appLocale ?? Locale(identifier: "en")
            }
        }
        return offMainLocale.withLock { $0 } ?? Locale(identifier: "en")
    }

    /// Called by the store whenever its settings change, so background lookups follow a language
    /// switch. Only the store ``settingsStore`` points at counts.
    @MainActor
    static func settingsDidChange(in store: SpotiglassSettingsStore) {
        guard settingsStore === store else { return }
        let locale = store.appLocale
        languageSignal.update(locale)
        offMainLocale.withLock { $0 = locale }
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
        #if DEBUG
        lookups.withLock { $0 += 1 }
        #endif
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

    /// Whether `text` is `key`'s text in one of the app's languages: a word the app stored
    /// earlier, which should read in the current language now.
    static func isText(_ text: String, ofKey key: String) -> Bool {
        AppLanguage.allCases.contains { string(key, locale: Locale(identifier: $0.rawValue)) == text }
    }

    /// `text` in the current app language when it is one of the app's own sentences, resolved
    /// earlier in any supported language; any other text comes back unchanged. Only pass whole
    /// sentences: a short label such as "Play" or "Titel" belongs to several keys whose
    /// translations differ, so it could come back as the wrong one. For sentences an
    /// error carries as text, such as a failed request's "Network unavailable": shown again
    /// after a language switch, they follow it like every other string (#548).
    static func inAppLanguage(_ text: String) -> String {
        guard let key = keyForResolvedText(text) else { return text }
        return string(key)
    }

    /// Every supported language's sentences mapped back to their keys, built once. Templates
    /// with placeholders are left out: a filled-in one never equals its template.
    private static let keysByResolvedText: [String: String] = {
        var keys: [String: String] = [:]
        for language in AppLanguage.allCases {
            let locale = Locale(identifier: language.rawValue)
            for bundle in appLocalizationBundles(for: locale) {
                guard let path = bundle.path(forResource: "Localizable", ofType: "strings"),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let table = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                        as? [String: String]
                else { continue }
                for key in table.keys.sorted() {
                    guard let value = table[key], !value.contains("%"), keys[value] == nil else { continue }
                    keys[value] = key
                }
            }
        }
        return keys
    }()

    /// Only the app's own strings: system frameworks bring their own tables, which aren't sentences
    /// this app shows, and searching every loaded framework made the first lookup take ~0.1 s.
    private static func appLocalizationBundles(for locale: Locale) -> [Bundle] {
        var bundles: [Bundle] = []
        for owner in [Bundle.main, Bundle(for: SpotiglassSettingsStore.self)] {
            for name in [locale.identifier, locale.language.languageCode?.identifier].compactMap({ $0 }) {
                if let path = owner.path(forResource: name, ofType: "lproj"),
                   let bundle = Bundle(path: path),
                   !bundles.contains(where: { $0.bundleURL == bundle.bundleURL }) {
                    bundles.append(bundle)
                }
            }
        }
        return bundles
    }

    private static func keyForResolvedText(_ text: String) -> String? {
        keysByResolvedText[text]
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

    /// The first of the language's bundles that has `key`, else the first of them.
    private static func bundle(for loc: Locale, key: String) -> Bundle {
        let bundles = localizationBundles(for: loc)
        return bundles.first { containsKey(key, in: $0) } ?? bundles.first ?? .main
    }

    private static func localizationBundles(for loc: Locale) -> [Bundle] {
        if let known = localizationBundles.withLock({ $0[loc.identifier] }) { return known }
        #if DEBUG
        localizationBundleSearches.withLock { $0 += 1 }
        #endif
        // `Bundle.main` is the app bundle in production. The test host can make
        // it the XCTest bundle, so also search the bundle that owns the app
        // type; this keeps direct localization lookups honest in both targets.
        var candidates = [Bundle.main, Bundle(for: SpotiglassSettingsStore.self)]
        candidates.append(contentsOf: Bundle.allBundles)
        candidates.append(contentsOf: Bundle.allFrameworks)
        var bundles: [Bundle] = []
        var seen: Set<URL> = []
        for candidate in candidates where seen.insert(candidate.bundleURL).inserted {
            var paths = [candidate.path(forResource: loc.identifier, ofType: "lproj")]
            if let language = loc.language.languageCode?.identifier {
                paths.append(candidate.path(forResource: language, ofType: "lproj"))
            }
            bundles += paths.compactMap { $0 }.compactMap(Bundle.init(path:))
        }
        localizationBundles.withLock { $0[loc.identifier] = bundles }
        return bundles
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
