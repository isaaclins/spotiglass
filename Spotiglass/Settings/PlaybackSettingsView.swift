import SwiftUI

struct PlaybackSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                playbackSection(
                    title: "Premium and Web Playback",
                    items: [
                        "Playback uses Spotify’s Web Playback SDK in a hidden web view. Spotify reports an account error for non-Premium accounts; playlist browsing may still work.",
                        "After you sign in, Spotiglass registers this Mac as a Spotify Connect device automatically.",
                    ]
                )

                playbackSection(
                    title: "When something drops",
                    items: [
                        "Use Reconnect in the playback bar or run “Connect Playback” from the Command Palette if playback stops or shows an error.",
                    ]
                )

                playbackSection(
                    title: "Sessions",
                    items: [
                        "Only one Spotify account is signed in at a time. Disconnect in Account settings to switch accounts or clear the stored session.",
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
