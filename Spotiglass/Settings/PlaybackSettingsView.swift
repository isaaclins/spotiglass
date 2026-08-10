import SwiftUI

struct PlaybackSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
            // Playback is driven entirely by Spotify's Web Playback SDK, so this
            // pane is informational rather than a set of controls. The intro line
            // makes that explicit so the tab doesn't read as empty settings.
            Text(SpotiglassL10n.string("settings.playback.intro"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            playbackSection(
                title: SpotiglassL10n.string("settings.playback.premium.title"),
                items: [
                    SpotiglassL10n.string("settings.playback.premium.item1"),
                    SpotiglassL10n.string("settings.playback.premium.item2"),
                ]
            )

            playbackSection(
                title: SpotiglassL10n.string("settings.playback.whenDrops.title"),
                items: [
                    SpotiglassL10n.string("settings.playback.whenDrops.item")
                ]
            )

            playbackSection(
                title: SpotiglassL10n.string("settings.playback.sessions.title"),
                items: [
                    SpotiglassL10n.string("settings.playback.sessions.item")
                ]
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}
