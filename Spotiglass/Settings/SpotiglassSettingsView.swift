import SwiftUI

enum SpotiglassSettingsSection: String, CaseIterable, Identifiable {
    case playback
    case equalizer
    case appearance
    case account
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: SpotiglassL10n.string("settings.section.playback")
        case .equalizer: SpotiglassL10n.string("settings.section.equalizer")
        case .appearance: SpotiglassL10n.string("settings.section.appearance")
        case .account: SpotiglassL10n.string("settings.section.account")
        case .keyboard: SpotiglassL10n.string("settings.section.keyboard")
        }
    }

    var systemImage: String {
        switch self {
        case .playback: "play.circle.fill"
        case .equalizer: "slider.horizontal.3"
        case .appearance: "paintpalette.fill"
        case .account: "person.crop.circle.fill"
        case .keyboard: "keyboard.fill"
        }
    }

    /// Lowercased keywords for sidebar search so typing the name of a control
    /// that lives *inside* a pane (e.g. "language") surfaces the right section,
    /// not just matches against the localized section title. English-only;
    /// the localized title is matched separately.
    var searchTerms: [String] {
        switch self {
        case .playback: ["playback", "premium", "web", "device", "reconnect", "sessions", "connect"]
        case .equalizer: ["equalizer", "eq", "bands", "preamp", "gain", "preset", "output", "device"]
        case .appearance:
            ["appearance", "language", "theme", "color", "scheme", "dark", "light", "lyrics", "text size", "command palette", "blur", "offset"]
        case .account: ["account", "spotify", "client id", "token", "sign in", "sign out", "disconnect", "log", "diagnostics"]
        case .keyboard: ["keyboard", "shortcuts", "hotkey", "keymap", "bindings", "command palette"]
        }
    }

    func matches(searchQuery query: String) -> Bool {
        if title.lowercased().contains(query) { return true }
        return searchTerms.contains { $0.contains(query) }
    }

    /// Accent applied to the small rounded icon tile on the left rail —
    /// mirrors macOS Tahoe System Settings.
    var iconAccent: Color {
        switch self {
        case .playback: .green
        case .equalizer: .orange
        case .appearance: .purple
        case .account: .blue
        case .keyboard: .pink
        }
    }
}

struct SpotiglassSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @ObservedObject var commandPaletteManager: CommandPaletteManager
    @ObservedObject var settingsStore: SpotiglassSettingsStore
    @ObservedObject var equalizerEngine: AudioEqualizerEngine

    @State private var section: SpotiglassSettingsSection? = .playback
    @State private var searchText: String = ""
    /// Opening the window always starts with the navigation list on screen.
    /// AppKit autosaves the split view's collapsed flag per window identifier,
    /// so without an explicit binding a single "Hide Sidebar" click keeps the
    /// navigation list hidden on every later launch.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearching: Bool { !searchQuery.isEmpty }

    /// Sections that match the current search (all of them when not searching).
    private var visibleSections: [SpotiglassSettingsSection] {
        guard isSearching else { return SpotiglassSettingsSection.allCases }
        return SpotiglassSettingsSection.allCases.filter { $0.matches(searchQuery: searchQuery) }
    }

    /// Sidebar rows. Account is reached through the profile card, so it is not
    /// repeated as a nav row (#30).
    private var navigationSections: [SpotiglassSettingsSection] {
        visibleSections.filter { $0 != .account }
    }

    /// The profile card doubles as the Account entry, so hide it while searching
    /// unless Account itself matches — otherwise it survives a filter it does
    /// not match (#52).
    private var showsProfileChip: Bool {
        !isSearching || visibleSections.contains(.account)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .background(SettingsWindowChrome().frame(width: 0, height: 0))
        // Keep the content proposal stable while switching panes (#23): a fixed
        // width stops an intrinsically wide pane from resizing the window, and
        // it also pulls a stale autosaved frame back to the same size. The
        // Settings scene's window is not user-resizable, so this width is what
        // every pane shows; only the height grows with the content.
        .frame(width: 980)
        .frame(minHeight: 660)
    }

    // MARK: - Sidebar (left pane)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if showsProfileChip {
                profileChip
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if isSearching, visibleSections.isEmpty {
                noSearchResults
            } else {
                List(selection: $section) {
                    ForEach(navigationSections) { sec in
                        SettingsSidebarRow(section: sec, isSelected: section == sec)
                            .tag(sec)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.regularMaterial)
        // Keep a valid pane selected as the search narrows results (#52): if the
        // active section is filtered out, jump to the first remaining match. When
        // nothing matches, keep the current selection so clearing the search lands
        // back on a populated pane instead of an empty detail view.
        .onChange(of: searchText) { _, _ in
            if isSearching, let current = section, !visibleSections.contains(current),
                let firstMatch = visibleSections.first {
                section = firstMatch
            }
        }
    }

    private var noSearchResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(SpotiglassL10n.string("settings.search.noResults"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(SpotiglassL10n.string("settings.section.account"), text: $searchText, prompt: Text("Search"))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
    }

    private var profileChip: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 34, height: 34)
                .foregroundStyle(.tint, .quaternary)
                .symbolRenderingMode(.palette)
            VStack(alignment: .leading, spacing: 1) {
                Text(SpotiglassL10n.string("settings.account.maintainer"))
                    .font(.callout.weight(.semibold))
                Text(SpotiglassL10n.string("settings.account.section"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .onTapGesture { section = .account }
        .contentShape(Rectangle())
    }

    // MARK: - Detail (right pane)

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader

            Divider()
                .padding(.horizontal, 24)

            ScrollView {
                SettingsPaneContainer {
                    switch section ?? .playback {
                    case .playback:
                        PlaybackSettingsView()
                    case .equalizer:
                        EqualizerSettingsView(
                            settingsStore: settingsStore,
                            engine: equalizerEngine
                        )
                    case .appearance:
                        AppearanceSettingsView(settingsStore: settingsStore)
                    case .account:
                        AccountSettingsView(viewModel: authViewModel)
                    case .keyboard:
                        CommandPaletteSettingsView(
                            keymapStore: commandPaletteManager.keymapStore,
                            commandPaletteManager: commandPaletteManager,
                            presentation: .settingsTabs
                        )
                    }
                }
                // Keep every pane's first control the same distance below the
                // divider. Pane views provide content only; the shell owns the
                // scroll insets so nested scrolling cannot slide controls under
                // the fixed header.
                .padding(.horizontal, SpotiglassDesign.spacingL)
                .padding(.top, SpotiglassDesign.spacingL)
                .padding(.bottom, SpotiglassDesign.spacingL)
            }
            .contentMargins(.top, SpotiglassDesign.spacingS, for: .scrollContent)
        }
    }

    private var detailHeader: some View {
        let active = section ?? .playback
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active.iconAccent.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: active.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: active.iconAccent.opacity(0.35), radius: 6, x: 0, y: 2)

            Text(active.title)
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

/// Gives every settings pane the same finite width proposal and leading
/// alignment, so switching panes cannot change the window's content width.
private struct SettingsPaneContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Sidebar row matching macOS Tahoe System Settings style: a tinted square
/// icon tile, the section title, and an optional pill badge on the right.
private struct SettingsSidebarRow: View {
    let section: SpotiglassSettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(section.iconAccent.gradient)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(section.title)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if let badge = pillBadge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(section.iconAccent.opacity(0.18))
                    )
                    .foregroundStyle(section.iconAccent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Short status badge shown on the right of a sidebar row. Only the
    /// account row uses one for now — extend per-section as state becomes
    /// available without re-architecting the row.
    private var pillBadge: String? {
        switch section {
        case .account: return "Live"
        default: return nil
        }
    }
}
