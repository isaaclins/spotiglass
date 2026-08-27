import SwiftUI

/// Top-level Home surface: a time-of-day greeting, a quick-access grid (Liked
/// Songs + playlists), a Recently Played carousel, and a Your Top Tracks list.
/// Sections load independently; quick access is derived from already-loaded
/// library state so it appears instantly.
struct HomeView: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel

    let currentPlaybackURI: String?
    let isPlaying: Bool
    let hasPlaybackDevice: Bool

    private let quickAccessColumns = [
        GridItem(.adaptive(minimum: 220), spacing: SpotiglassDesign.spacingS)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                HomeSectionHeader(title: viewModel.homeGreeting(), style: .pageTitle)

                quickAccessGrid
                recentlyPlayedSection
                topTracksSection
            }
            .padding(SpotiglassDesign.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    // MARK: - Quick access

    private var quickAccessGrid: some View {
        LazyVGrid(columns: quickAccessColumns, spacing: SpotiglassDesign.spacingS) {
            ForEach(viewModel.homeQuickAccessCards) { card in
                HomeQuickAccessTile(card: card) {
                    open(card.destination)
                }
            }
        }
    }

    // MARK: - Recently played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: SpotiglassL10n.string("home.section.recentlyPlayed"))
            switch viewModel.homeRecentlyPlayed {
            case .loading:
                HomeSectionNotice(style: .loading)
            case let .loaded(cards):
                if cards.isEmpty {
                    HomeSectionNotice(style: .message(
                        icon: "clock.arrow.circlepath",
                        text: SpotiglassL10n.string("home.recentlyPlayed.empty")
                    ))
                } else {
                    // The shelf hid its indicator and cut the last card in half,
                    // so nothing said it scrolled (#162). The indicator is back,
                    // and snapping to card boundaries means a card is never left
                    // bisected at rest, whatever the window width.
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                            ForEach(cards) { card in
                                HomeMediaCardView(card: card) {
                                    open(card.destination)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, SpotiglassDesign.spacingXS)
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
            case .unavailable:
                HomeSectionNotice(style: .message(
                    icon: "lock.fill",
                    text: SpotiglassL10n.string("home.section.reconnect")
                ))
            case let .failed(message):
                HomeSectionNotice(style: .message(icon: "exclamationmark.triangle", text: message))
            }
        }
    }

    // MARK: - Top tracks

    @ViewBuilder
    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: SpotiglassL10n.string("home.section.topTracks"))
            switch viewModel.homeTopTracks {
            case .loading:
                HomeSectionNotice(style: .loading)
            case let .loaded(tracks):
                if tracks.isEmpty {
                    HomeSectionNotice(style: .message(
                        icon: "music.note",
                        text: SpotiglassL10n.string("home.topTracks.empty")
                    ))
                } else {
                    topTracksList(tracks)
                }
            case .unavailable:
                HomeSectionNotice(style: .message(
                    icon: "lock.fill",
                    text: SpotiglassL10n.string("home.section.reconnect")
                ))
            case let .failed(message):
                HomeSectionNotice(style: .message(icon: "exclamationmark.triangle", text: message))
            }
        }
    }

    private func topTracksList(_ tracks: [TrackRowViewModel]) -> some View {
        let playableURIs = tracks.compactMap(\.playableURI)
        return VStack(spacing: 0) {
            ForEach(tracks) { track in
                TrackListRow(
                    trackNumber: track.listPosition,
                    track: track,
                    playURI: { uri in
                        Task {
                            await playbackViewModel.playFromPlaylist(
                                clickedURI: uri,
                                playableURIs: playableURIs,
                                playlistID: nil
                            )
                        }
                    },
                    togglePlayPause: {
                        Task { await playbackViewModel.togglePlayPause() }
                    },
                    isCurrent: track.playableURI != nil && track.playableURI == currentPlaybackURI,
                    isPlaying: isPlaying,
                    hasPlaybackDevice: hasPlaybackDevice,
                    addToQueue: { uri in
                        await queueViewModel.addToQueue(uri: uri)
                    },
                    openArtist: { artistID in
                        Task { await viewModel.selectArtist(id: artistID, origin: .extend, displayName: nil) }
                    }
                )
            }
        }
    }

    // MARK: - Navigation

    private func open(_ destination: HomeMediaCard.Destination) {
        switch destination {
        case .likedSongs:
            Task { await viewModel.selectSidebar(.likedSongs) }
        case let .playlist(id):
            Task { await viewModel.selectSidebar(.playlist(id)) }
        case let .album(id, title, subtitle, artworkURL):
            Task {
                await viewModel.selectAlbum(
                    id: id,
                    displayTitle: title,
                    displaySubtitle: subtitle,
                    artworkURL: artworkURL,
                    origin: .extend
                )
            }
        }
    }
}
