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
        case .playback: "play.circle"
        case .equalizer: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .account: "person.crop.circle"
        case .keyboard: "keyboard"
        }
    }
}

struct SpotiglassSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @ObservedObject var commandPaletteManager: CommandPaletteManager
    @ObservedObject var settingsStore: SpotiglassSettingsStore
    @ObservedObject var equalizerEngine: AudioEqualizerEngine

    @State private var section: SpotiglassSettingsSection = .playback

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SpotiglassDesign.spacingS) {
                ForEach(SpotiglassSettingsSection.allCases) { tab in
                    SettingsTabButton(
                        title: tab.title,
                        systemImage: tab.systemImage,
                        isSelected: section == tab
                    ) {
                        section = tab
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SpotiglassDesign.spacingL)
            .padding(.vertical, SpotiglassDesign.spacingM)

            Divider()

            Group {
                switch section {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct SettingsTabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: SpotiglassDesign.spacingXS) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .frame(minWidth: 72)
            .padding(.horizontal, SpotiglassDesign.spacingS)
            .padding(.vertical, SpotiglassDesign.spacingXS)
            .foregroundStyle(isSelected ? SpotiglassDesign.controlAccent : .secondary)
            .spotiglassSurface(
                corner: .s,
                fill: Color.clear,
                stroke: isSelected ? SpotiglassDesign.controlAccent : Color.secondary.opacity(0.35),
                strokeWidth: isSelected ? 2 : 1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPressable()
        .animation(SpotiglassMotion.controlSpring, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(title)
    }
}
