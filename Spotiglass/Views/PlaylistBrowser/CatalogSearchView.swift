import SwiftUI

/// Full-window catalog search surface: a query field, category pills, and result
/// sections built from the same rows and cards the rest of the browser uses.
///
/// The command palette remains the keyboard-only jump layer; this is the
/// browsable counterpart it hands off to.
struct CatalogSearchView: View {
    @ObservedObject var viewModel: PlaylistBrowserViewModel
    @ObservedObject var searchViewModel: CatalogSearchViewModel
    @ObservedObject var playbackViewModel: PlaybackSessionViewModel
    @ObservedObject var queueViewModel: QueueViewModel

    let currentPlaybackURI: String?
    let isPlaying: Bool
    let hasPlaybackDevice: Bool

    @FocusState private var isQueryFieldFocused: Bool

    private let cardColumns = [
        GridItem(.adaptive(minimum: 150), spacing: SpotiglassDesign.spacingM, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingM) {
            queryField
            categoryPills
            resultsBody
        }
        .padding(SpotiglassDesign.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onAppear {
            isQueryFieldFocused = true
        }
    }

    // MARK: - Query field

    private var queryField: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                SpotiglassL10n.string("search.field.placeholder"),
                text: $searchViewModel.query
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isQueryFieldFocused)
            .onChange(of: searchViewModel.query) { _, _ in
                searchViewModel.queryDidChange()
            }
            .accessibilityLabel(SpotiglassL10n.string("search.field.placeholder"))

            if !searchViewModel.query.isEmpty {
                Button {
                    searchViewModel.clearQuery()
                    isQueryFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(SpotiglassL10n.string("search.field.clear"))
                .accessibilityLabel(SpotiglassL10n.string("search.field.clear"))
            }
        }
        .padding(.horizontal, SpotiglassDesign.spacingM)
        .padding(.vertical, SpotiglassDesign.spacingS)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: - Category pills

    private var categoryPills: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            ForEach(CatalogSearchCategory.allCases) { pill in
                Button(pill.pillLabel) {
                    searchViewModel.selectCategory(pill)
                }
                .buttonStyle(
                    SpotiglassPillStyle(
                        variant: searchViewModel.category == pill ? .accent : .glass,
                        horizontalPadding: SpotiglassDesign.spacingM,
                        verticalPadding: SpotiglassDesign.spacingXS
                    )
                )
                .accessibilityAddTraits(searchViewModel.category == pill ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsBody: some View {
        switch searchViewModel.state {
        case .loading:
            ProgressView(SpotiglassL10n.string("search.state.searching"))
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .empty(message):
            EmptyStateView(
                title: SpotiglassL10n.string("search.empty.title"),
                message: message
            )
        case let .error(error):
            ErrorStateView(error: error)
        case let .loaded(results), let .refreshing(results), let .staleCache(results, _):
            resultSections(results.filtered(to: searchViewModel.category))
        }
    }

    @ViewBuilder
    private func resultSections(_ results: CatalogSearchResults) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpotiglassDesign.spacingL) {
                if !results.tracks.isEmpty {
                    trackSection(results.tracks)
                }
                if !results.artists.isEmpty {
                    artistSection(results.artists)
                }
                if !results.albums.isEmpty {
                    albumSection(results.albums)
                }
                if !results.playlists.isEmpty {
                    playlistSection(results.playlists)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func trackSection(_ tracks: [TrackRowViewModel]) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: CatalogSearchCategory.tracks.pillLabel)
            let playableURIs = tracks.compactMap(\.playableURI)
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

    private func artistSection(_ artists: [SpotifyArtist]) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: CatalogSearchCategory.artists.pillLabel)
            cardLayout(isFocused: searchViewModel.category == .artists) {
                ForEach(artists) { artist in
                    CatalogSearchArtistCard(artist: artist) {
                        Task { await viewModel.selectArtist(id: artist.id, origin: .extend, displayName: artist.name) }
                    }
                }
            }
        }
    }

    private func albumSection(_ albums: [SpotifyAlbum]) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: CatalogSearchCategory.albums.pillLabel)
            cardLayout(isFocused: searchViewModel.category == .albums) {
                ForEach(albums) { album in
                    let subtitle = album.artists.joined(separator: ", ")
                    HomeMediaCardView(
                        card: HomeMediaCard(
                            id: album.id,
                            title: album.name,
                            subtitle: subtitle,
                            artworkURL: album.imageURL,
                            destination: .album(
                                id: album.id,
                                title: album.name,
                                subtitle: subtitle,
                                artworkURL: album.imageURL
                            )
                        )
                    ) {
                        Task {
                            await viewModel.selectAlbum(
                                id: album.id,
                                displayTitle: album.name,
                                displaySubtitle: subtitle,
                                artworkURL: album.imageURL,
                                origin: .extend
                            )
                        }
                    }
                }
            }
        }
    }

    private func playlistSection(_ playlists: [SpotifyPlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: SpotiglassDesign.spacingS) {
            HomeSectionHeader(title: CatalogSearchCategory.playlists.pillLabel)
            cardLayout(isFocused: searchViewModel.category == .playlists) {
                ForEach(playlists) { playlist in
                    HomeMediaCardView(
                        card: HomeMediaCard(
                            id: playlist.id,
                            title: playlist.name,
                            subtitle: playlist.ownerName,
                            artworkURL: playlist.imageURL,
                            destination: .playlist(id: playlist.id)
                        )
                    ) {
                        Task { await viewModel.selectPlaylist(id: playlist.id, origin: .extend) }
                    }
                }
            }
        }
    }

    /// `all` previews each type in a horizontal row; a focused pill spreads the
    /// same cards over a wrapping grid so the full page is browsable.
    @ViewBuilder
    private func cardLayout(isFocused: Bool, @ViewBuilder content: () -> some View) -> some View {
        if isFocused {
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: SpotiglassDesign.spacingM) {
                content()
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: SpotiglassDesign.spacingM) {
                    content()
                }
                .padding(.vertical, SpotiglassDesign.spacingXS)
            }
        }
    }
}

/// Circular artist tile. Albums and playlists reuse ``HomeMediaCardView``, but
/// artists render round artwork and have no ``HomeMediaCard/Destination`` case.
struct CatalogSearchArtistCard: View {
    let artist: SpotifyArtist
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: SpotiglassDesign.spacingXS) {
                ArtworkView(url: artist.imageURL, size: 120)
                    .clipShape(Circle())
                Text(artist.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(SpotiglassL10n.string("browser.palette.subtitle.artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPressable(hoverScale: 1.03, pressScale: 0.97)
        .accessibilityLabel(artist.name)
    }
}
