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
}
