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

    private var visibleSections: [SpotiglassSettingsSection] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SpotiglassSettingsSection.allCases }
        return SpotiglassSettingsSection.allCases.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 560)
    }

    // MARK: - Sidebar (left pane)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            profileChip
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            List(selection: $section) {
                ForEach(visibleSections) { sec in
                    SettingsSidebarRow(section: sec, isSelected: section == sec)
                        .tag(sec)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
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
                Text("Isaac Lins")
                    .font(.callout.weight(.semibold))
                Text("Account")
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
                Group {
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
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
