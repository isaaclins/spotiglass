import SwiftUI

enum CatalogSearchCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case tracks = "Tracks"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"

    var id: String { rawValue }
}

struct CatalogSearchView: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel

    let currentPlaybackURI: String?
    let isPlaying: Bool
    let hasPlaybackDevice: Bool

    @State private var selectedFilter: CatalogSearchCategoryFilter = .all
    @EnvironmentObject private var pinnedStore: PinnedItemsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            searchHeader
                .padding(.horizontal, SpotiglassDesign.spacingL)
                .padding(.top, SpotiglassDesign.spacingM)

            if viewModel.searchCatalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                initialPromptView
            } else if viewModel.isSearchingCatalog {
                ProgressView(SpotiglassL10n.string("browser.search.searching"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isResultsEmpty {
                EmptyStateView(
                    title: SpotiglassL10n.string("browser.search.noResults.title"),
                    message: SpotiglassL10n.string("browser.search.noResults.message")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                        if selectedFilter == .all || selectedFilter == .tracks {
                            if !trackRows.isEmpty {
                                tracksSection
                            }
                        }
                        if selectedFilter == .all || selectedFilter == .artists {
                            if !viewModel.searchCatalogResults.artists.isEmpty {
                                artistsSection
                            }
                        }
                        if selectedFilter == .all || selectedFilter == .albums {
                            if !viewModel.searchCatalogResults.albums.isEmpty {
                                albumsSection
                            }
                        }
                        if selectedFilter == .all || selectedFilter == .playlists {
                            if !viewModel.searchCatalogResults.playlists.isEmpty {
                                playlistsSection
                            }
                        }
                    }
                    .padding(.vertical, SpotiglassDesign.spacingS)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isResultsEmpty: Bool {
        viewModel.searchCatalogResults.tracks.isEmpty && viewModel.searchCatalogResults.artists.isEmpty
            && viewModel.searchCatalogResults.albums.isEmpty && viewModel.searchCatalogResults.playlists.isEmpty
    }

    private var trackRows: [TrackRowViewModel] {
        TrackRowViewModel.numberedTopTracks(viewModel.searchCatalogResults.tracks)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HStack(spacing: SpotiglassDesign.spacingS) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    SpotiglassL10n.string("browser.search.placeholder"),
                    text: Binding(
                        get: { viewModel.searchCatalogQuery },
                        set: { viewModel.performCatalogSearch(query: $0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.title3)

                if !viewModel.searchCatalogQuery.isEmpty {
                    Button {
                        viewModel.performCatalogSearch(query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SpotiglassDesign.spacingM)
            .padding(.vertical, SpotiglassDesign.spacingS)
            .background(
                .ultraThinMaterial, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: SpotiglassDesign.spacingXS) {
                ForEach(CatalogSearchCategoryFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selectedFilter == filter
                                    ? SpotiglassDesign.controlAccent.opacity(0.85)
                                    : Color.primary.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedFilter == filter ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var initialPromptView: some View {
        VStack(spacing: SpotiglassDesign.spacingM) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(SpotiglassDesign.controlAccent.opacity(0.8))

            Text(SpotiglassL10n.string("browser.search.prompt.title"))
                .font(.title2.weight(.semibold))

            Text(SpotiglassL10n.string("browser.search.prompt.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("browser.tracks"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, SpotiglassDesign.spacingL)

            LazyVStack(spacing: 0) {
                ForEach(trackRows) { track in
                    TrackListRow(
                        trackNumber: track.listPosition,
                        track: track,
                        playURI: { uri in
                            Task { await playbackViewModel.play(uri: uri) }
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
                        },
                        trackOpsMenuItems: {
                            AnyView(
                                UniversalTrackOpsMenu(
                                    track: track,
                                    viewModel: viewModel,
                                    playbackViewModel: playbackViewModel
                                )
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, SpotiglassDesign.spacingS)
        }
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("browser.artists"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, SpotiglassDesign.spacingL)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpotiglassDesign.spacingM) {
                    ForEach(viewModel.searchCatalogResults.artists) { artist in
                        artistCard(artist)
                    }
                }
                .padding(.horizontal, SpotiglassDesign.spacingL)
                .padding(.bottom, SpotiglassDesign.spacingS)
            }
        }
    }

    private func artistCard(_ artist: SpotifyArtist) -> some View {
        let isPinned = pinnedStore.isPinned(spotifyID: artist.id, kind: .artist)
        return VStack(spacing: SpotiglassDesign.spacingS) {
            ArtworkView(url: artist.imageURL, size: 104)
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                            .padding(4)
                            .background(
                                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme)))
                    }
                }

            Text(artist.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name) }
        }
        .contextMenu {
            Button(SpotiglassL10n.string("browser.artist.startRadio")) {
                Task {
                    await viewModel.startArtistRadio(
                        artistID: artist.id,
                        artistName: artist.name,
                        playbackViewModel: playbackViewModel
                    )
                }
            }
            Divider()
            if isPinned {
                Button(SpotiglassL10n.string("browser.unpin")) {
                    pinnedStore.unpin(id: PinnedItem.id(forKind: .artist, spotifyID: artist.id))
                }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) {
                    pinnedStore.pin(.artist(artist))
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("browser.albums"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, SpotiglassDesign.spacingL)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpotiglassDesign.spacingM) {
                    ForEach(viewModel.searchCatalogResults.albums) { album in
                        albumCard(album)
                    }
                }
                .padding(.horizontal, SpotiglassDesign.spacingL)
                .padding(.bottom, SpotiglassDesign.spacingS)
            }
        }
    }

    private func albumCard(_ album: SpotifyAlbum) -> some View {
        let pinnedItem = PinnedItem.album(
            SpotifyArtistAlbum(
                id: album.id,
                name: album.name,
                imageURL: album.imageURL,
                releaseYear: nil,
                totalTracks: 0,
                group: .album,
                uri: album.uri
            )
        )
        let isPinned = pinnedStore.isPinned(id: pinnedItem.id)

        return VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            ArtworkView(url: album.imageURL, size: 128)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SpotiglassDesign.mediaBadgeForegroundColor(colorScheme: colorScheme))
                            .padding(4)
                            .background(
                                Circle().fill(SpotiglassDesign.mediaBadgeBackgroundColor(colorScheme: colorScheme)))
                    }
                }

            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(album.artists.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 128)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task {
                await viewModel.selectAlbum(
                    id: album.id,
                    displayTitle: album.name,
                    displaySubtitle: album.artists.joined(separator: ", "),
                    artworkURL: album.imageURL,
                    origin: .extend
                )
                await playbackViewModel.play(contextURI: album.uri)
            }
        }
        .onTapGesture {
            Task {
                await viewModel.selectAlbum(
                    id: album.id,
                    displayTitle: album.name,
                    displaySubtitle: album.artists.joined(separator: ", "),
                    artworkURL: album.imageURL,
                    origin: .extend
                )
            }
        }
        .contextMenu {
            Button(SpotiglassL10n.string("browser.album.play")) {
                Task { await playbackViewModel.play(contextURI: album.uri) }
            }
            Divider()
            if isPinned {
                Button(SpotiglassL10n.string("browser.unpin")) { pinnedStore.unpin(id: pinnedItem.id) }
            } else {
                Button(SpotiglassL10n.string("browser.pin")) { pinnedStore.pin(pinnedItem) }
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            Text(SpotiglassL10n.string("browser.playlists"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, SpotiglassDesign.spacingL)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpotiglassDesign.spacingM) {
                    ForEach(viewModel.searchCatalogResults.playlists) { playlist in
                        playlistCard(playlist)
                    }
                }
                .padding(.horizontal, SpotiglassDesign.spacingL)
                .padding(.bottom, SpotiglassDesign.spacingS)
            }
        }
    }

    private func playlistCard(_ playlist: SpotifyPlaylistSummary) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingXS) {
            ArtworkView(url: playlist.imageURL, size: 128)
                .clipShape(RoundedRectangle(cornerRadius: SpotiglassDesign.cornerS, style: .continuous))

            Text(playlist.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(playlist.ownerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 128)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await viewModel.selectPlaylist(id: playlist.id, origin: .extend) }
        }
    }
}
