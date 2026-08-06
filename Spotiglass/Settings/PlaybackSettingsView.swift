import SwiftUI

struct PlaybackSettingsView: View {
    var body: some View {
        // Playback is driven entirely by Spotify's Web Playback SDK, so this pane
        // is informational rather than a set of controls. Grouped Form sections
        // keep it consistent with the panes that do have controls, and the intro
        // sits in the first section's footer the way System Settings explains a
        // group rather than opening with a loose paragraph.
        Form {
            Section {
                playbackSection(
                    title: SpotiglassL10n.string("settings.playback.premium.title"),
                    items: [
                        SpotiglassL10n.string("settings.playback.premium.item1"),
                        SpotiglassL10n.string("settings.playback.premium.item2"),
                    ]
                )
            } footer: {
                Text(SpotiglassL10n.string("settings.playback.intro"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                playbackSection(
                    title: SpotiglassL10n.string("settings.playback.whenDrops.title"),
                    items: [
                        SpotiglassL10n.string("settings.playback.whenDrops.item"),
                    ]
                )
            }

            Section {
                playbackSection(
                    title: SpotiglassL10n.string("settings.playback.sessions.title"),
                    items: [
                        SpotiglassL10n.string("settings.playback.sessions.item"),
                    ]
                )
            }
        }
        .formStyle(.grouped)
    }

    private func playbackSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
