import XCTest
@testable import Spotiglass

/// Exercises every surface that was localized for the i18n initiative and
/// confirms the rendered strings come back in the user-selected locale.
///
/// Doubles as the "rigorous proof" fallback specified in the i18n goal: when
/// screenshot automation isn't available, running this test prints the full
/// localized inventory to the test log for human review.
@MainActor
final class LocalizationCoverageTests: XCTestCase {
    private var store: SpotiglassSettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-coverage-\(UUID().uuidString).json")
        store = SpotiglassSettingsStore(fileURL: url)
        SpotiglassL10n.settingsStore = store
    }

    override func tearDown() async throws {
        SpotiglassL10n.settingsStore = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Expected values

    /// One representative string per localized surface, with the expected
    /// rendering in each locale. Adding a surface requires adding a row here.
    private static let expectations: [(name: String, key: String, en: String, es: String, de: String)] = [
        // CommandPalette
        ("palette.section.thisPlaylist", "palette.section.thisPlaylist", "Here", "Aquí", "Hier"),
        ("palette.searchCategory.all", "palette.searchCategory.all", "All", "Todo", "Alle"),
        ("palette.searchPlaceholder.commands", "palette.searchPlaceholder.commands", "Run a command", "Ejecutar un comando", "Befehl ausführen"),
        ("palette.hotkeyRecorder.clickToRecord", "palette.hotkeyRecorder.clickToRecord", "Click to record", "Haz clic para grabar", "Zum Aufzeichnen klicken"),

        // Browsing
        ("browser.likedSongs.title", "browser.likedSongs.title", "Liked Songs", "Canciones que te gustan", "Lieblingssongs"),
        ("browser.trackBadge.unavailable", "browser.trackBadge.unavailable", "Unavailable", "No disponible", "Nicht verfügbar"),
        ("browser.trackBadge.explicit", "browser.trackBadge.explicit", "Explicit", "Explícito", "Explizit"),
        ("browser.breadcrumb.artistFallback", "browser.breadcrumb.artistFallback", "Artist", "Artista", "Künstler"),

        // Catalog search
        ("browser.search", "browser.search", "Search", "Buscar", "Suchen"),
        ("search.category.tracks", "search.category.tracks", "Tracks", "Canciones", "Titel"),
        ("search.field.placeholder", "search.field.placeholder", "Search Spotify", "Buscar en Spotify", "Spotify durchsuchen"),
        ("palette.showAllResults.subtitle", "palette.showAllResults.subtitle", "Open the Search view", "Abrir la vista de búsqueda", "Suchansicht öffnen"),

        // Playback
        ("playback.controls.state.ready.title", "playback.controls.state.ready.title", "Ready to play", "Listo para reproducir", "Bereit zur Wiedergabe"),
        ("playback.nowPlaying.unknownArtist", "playback.nowPlaying.unknownArtist", "Unknown artist", "Artista desconocido", "Unbekannter Künstler"),

        // Appearance
        ("settings.appearance.lyricsSize.large", "settings.appearance.lyricsSize.large", "Large", "Grande", "Gross"),
        ("settings.appearance.lyricsSize.medium", "settings.appearance.lyricsSize.medium", "Medium", "Mediano", "Mittel"),
        ("settings.appearance.lyricsSize.small", "settings.appearance.lyricsSize.small", "Small", "Pequeño", "Klein"),
        ("settings.appearance.scheme.dark", "settings.appearance.scheme.dark", "Dark", "Oscuro", "Dunkel"),
        ("settings.appearance.scheme.light", "settings.appearance.scheme.light", "Light", "Claro", "Hell"),
        ("settings.appearance.scheme.system", "settings.appearance.scheme.system", "System", "Sistema", "System"),

        // Authentication
        ("auth.clientID.hint", "auth.clientID.hint", "Paste the client ID from your Spotify Developer Dashboard app. This public identifier is always visible so you can verify it before signing in.", "Pega el ID de cliente de tu app en el Spotify Developer Dashboard. Este identificador público siempre está visible para que puedas verificarlo antes de iniciar sesión.", "Fügen Sie die Client-ID aus Ihrer App im Spotify Developer Dashboard ein. Diese öffentliche Kennung ist immer sichtbar, damit Sie sie vor der Anmeldung prüfen können."),
        ("auth.callback.response.invalidRequest", "auth.callback.response.invalidRequest", "Invalid Spotify callback.", "Respuesta de Spotify no válida.", "Ungültiger Spotify-Rückruf."),
        ("auth.callback.response.success", "auth.callback.response.success", "Spotify sign-in is complete. You can return to Spotiglass.", "El inicio de sesión de Spotify se completó. Puedes volver a Spotiglass.", "Die Spotify-Anmeldung ist abgeschlossen. Sie können zu Spotiglass zurückkehren."),
        ("auth.callback.response.failure", "auth.callback.response.failure", "Spotify sign-in could not be completed.", "No se pudo completar el inicio de sesión de Spotify.", "Die Spotify-Anmeldung konnte nicht abgeschlossen werden."),

        // Breadcrumb / Account
        ("breadcrumb.back", "breadcrumb.back", "Back", "Atrás", "Zurück"),
        ("settings.account.diagnostics.header", "settings.account.diagnostics.header", "Diagnostics", "Diagnóstico", "Diagnose")
    ]

    // MARK: - Tests

    func testEveryLocaleResolvesEverySurface() throws {
        for language in [AppLanguage.english, .spanish, .german] {
            try store.mutate { $0.appearance.language = language }
            XCTAssertEqual(SpotiglassL10n.locale.identifier, language.rawValue)

            print("--- locale: \(language.rawValue) ---")
            for row in Self.expectations {
                let actual = SpotiglassL10n.string(.init(stringLiteral: row.key))
                let expected: String
                switch language {
                case .english: expected = row.en
                case .spanish: expected = row.es
                case .german:  expected = row.de
                }
                XCTAssertEqual(actual, expected, "[\(language.rawValue)] \(row.name)")
                print("  \(row.name) -> \(actual)")
            }
        }
    }

    /// The listener receives a pre-resolved copy because its socket worker runs
    /// off the main thread, where SpotiglassL10n intentionally falls back to English.
    func testOAuthCallbackResponseCopyUsesActiveLocale() throws {
        for language in [AppLanguage.english, .spanish, .german] {
            try store.mutate { $0.appearance.language = language }
            let copy = LoopbackOAuthResponseCopy.localized
            XCTAssertEqual(
                copy.invalidRequest,
                SpotiglassL10n.string("auth.callback.response.invalidRequest"),
                "invalid-request browser copy in \(language.rawValue)"
            )
            XCTAssertEqual(
                copy.success,
                SpotiglassL10n.string("auth.callback.response.success"),
                "success browser copy in \(language.rawValue)"
            )
            XCTAssertEqual(
                copy.failure,
                SpotiglassL10n.string("auth.callback.response.failure"),
                "failure browser copy in \(language.rawValue)"
            )
        }
    }

    func testPlaylistMutationToastCopyFollowsSelectedLocale() throws {
        let expected: [AppLanguage: String] = [
            .english: "Added 1 track to Mix",
            .spanish: "Se añadió 1 canción a Mix",
            .german: "1 Titel zu Mix hinzugefügt"
        ]
        for language in [AppLanguage.english, .spanish, .german] {
            try store.mutate { $0.appearance.language = language }
            XCTAssertEqual(
                SpotiglassL10n.format("playlist.mutation.addedToPlaylist", Int64(1), "Mix"),
                expected[language],
                "playlist mutation toast in \(language.rawValue)"
            )
        }
    }

    /// Confirms runtime-built palette keys (`palette.command.\(commandID).{title,subtitle}`)
    /// also resolve per locale, exercising `SpotiglassL10n.string(forKey:)`.
    func testRuntimePaletteCommandKeysResolvePerLocale() throws {
        let spec = CommandPaletteCommandCatalog.editable.first { $0.commandID == CommandPaletteCommandID.openSettings }!

        let expected: [AppLanguage: String] = [
            .english: "Open Settings",
            .spanish: "Abrir ajustes",
            .german:  "Einstellungen öffnen"
        ]
        for language in [AppLanguage.english, .spanish, .german] {
            try store.mutate { $0.appearance.language = language }
            let title = spec.title
            XCTAssertEqual(title, expected[language], "openSettings.title in \(language.rawValue)")
            print("[\(language.rawValue)] openSettings.title -> \(title)")
        }
    }

    /// TrackRowViewModel routes badge text through SpotiglassL10n, so changing
    /// the active locale should change the badge string emitted by the row.
    func testTrackRowBadgesFollowSelectedLocale() throws {
        let explicit = SpotifyTrack(
            id: "t",
            name: "Song",
            artists: ["A"],
            albumArtworkURL: nil,
            durationMilliseconds: 60_000,
            isExplicit: true,
            isPlayable: true,
            linkedFromID: nil,
            uri: "spotify:track:t"
        )
        let item = SpotifyPlaylistTrackItem(id: "t", content: .track(explicit))

        let expected: [AppLanguage: String] = [.english: "Explicit", .spanish: "Explícito", .german: "Explizit"]
        for language in [AppLanguage.english, .spanish, .german] {
            try store.mutate { $0.appearance.language = language }
            let row = TrackRowViewModel(item, listPosition: 1)
            XCTAssertEqual(row.badgeText, expected[language], "badge in \(language.rawValue)")
        }
    }

    /// One word per concept per language (#158).
    ///
    /// German said Song in one key and Titel in another, Spanish said canción
    /// and pista, and these render side by side: the queue panel sits next to
    /// the sidebar rows in the same window. Reading the catalog directly is what
    /// keeps the glossary from drifting back one string at a time.
    func testCatalogUsesOneNounPerConceptPerLanguage() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        /// Every translated value for a locale, including each plural case.
        func values(_ entry: Any, _ locale: String) -> [String] {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let localization = localizations[locale] as? [String: Any] else { return [] }
            var out: [String] = []
            if let unit = localization["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                out.append(value)
            }
            if let variations = localization["variations"] as? [String: Any],
               let plural = variations["plural"] as? [String: Any] {
                for case let form as [String: Any] in plural.values {
                    if let unit = form["stringUnit"] as? [String: Any],
                       let value = unit["value"] as? String {
                        out.append(value)
                    }
                }
            }
            return out
        }

        // "Liked Songs" is Spotify's own name for the library section, in both
        // English and the German "Lieblingssongs", and "Songtext" is the German
        // word for lyrics. None of those are the track noun.
        let germanExemptKeys: Set<String> = ["pin.likedSongs"]
        let banned: [(locale: String, pattern: String, use: String)] = [
            ("de", #"\bSongs?\b"#, "Titel"),
            ("es", #"\bpistas?\b"#, "canción/canciones"),
            ("es", #"\bplaylists?\b"#, "lista/listas"),
        ]

        for (locale, pattern, use) in banned {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            for (key, entry) in strings {
                if locale == "de", germanExemptKeys.contains(key) { continue }
                for value in values(entry, locale) {
                    if locale == "de", value.contains("Songtext") || value.contains("Lieblingssong") {
                        continue
                    }
                    let range = NSRange(value.startIndex..., in: value)
                    XCTAssertNil(
                        regex.firstMatch(in: value, range: range),
                        "\(locale) \(key) uses a second noun for the concept; use \(use). Value: \(value)"
                    )
                }
            }
        }
    }

    /// The equalizer exposes one gain fader per fixed centre frequency and no
    /// control over Q or centre frequency, which is a graphic equalizer. The
    /// AVAudioUnitEQ bands underneath are parametric filters, but that is an
    /// implementation detail: to a user the word promises knobs that are not
    /// there. This is the acceptance criterion from #169 as a guard, so the
    /// claim cannot come back through any locale.
    func testNoLocaleClaimsParametricEqualizerControl() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Spotiglass/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        // "parametric" is spelled the same in en, and is "parametrisch" /
        // "paramétrico" in the two translations, so one stem covers all three.
        let forbidden = "parametr"
        var offenders: [String] = []
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            for (locale, localization) in localizations {
                guard let localization = localization as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }
                if value.lowercased().contains(forbidden) {
                    offenders.append("\(key) [\(locale)]: \(value)")
                }
            }
        }
        XCTAssertEqual(
            offenders, [],
            "these strings promise parametric control the equalizer does not offer"
        )
    }

}
