import SwiftUI

struct PlaybackSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                playbackSection(
                    title: String(localized: "settings.playback.premium.title"),
                    items: [
                        String(localized: "settings.playback.premium.item1"),
                        String(localized: "settings.playback.premium.item2"),
                    ]
                )

                playbackSection(
                    title: String(localized: "settings.playback.whenDrops.title"),
                    items: [
                        String(localized: "settings.playback.whenDrops.item"),
                    ]
                )

                playbackSection(
                    title: String(localized: "settings.playback.sessions.title"),
                    items: [
                        String(localized: "settings.playback.sessions.item"),
                    ]
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SpotiglassDesign.spacingL)
        }
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
