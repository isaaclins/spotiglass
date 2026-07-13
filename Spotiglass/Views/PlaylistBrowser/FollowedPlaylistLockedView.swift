import AppKit
import SwiftUI

/// Shown when Spotify refuses to list the tracks of a followed (non-owned)
/// playlist with HTTP 403. The listing is gone, but the user can still play the
/// whole playlist in-app or open it in Spotify.
struct FollowedPlaylistLockedView: View {
    let info: LockedPlaylistInfo
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Image(systemName: "lock")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(SpotiglassL10n.string("error.browsing.followedPlaylistLocked.title"))
                .font(.title3.weight(.semibold))

            Text(SpotiglassL10n.string("error.browsing.followedPlaylistLocked.message"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: SpotiglassDesign.spacingM) {
                Button {
                    Task { await playbackViewModel.play(contextURI: info.contextURI) }
                } label: {
                    Label(SpotiglassL10n.string("browser.playPlaylist"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    guard let url = info.externalURL else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(SpotiglassL10n.string("browser.openInSpotify"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
