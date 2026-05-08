import SwiftUI

// MARK: - Search card

struct CommandPaletteSearchCardView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    var focusedField: FocusState<CommandPaletteSearchFocusField?>.Binding
    var paletteGlass: Namespace.ID

    var body: some View {
        HStack(spacing: SpotiglassDesign.spacingS) {
            Image(systemName: CommandPaletteScopePresentation.iconName(
                scope: viewModel.currentScope,
                category: viewModel.searchCategoryFilter
            ))
            .foregroundStyle(CommandPaletteScopePresentation.iconColor(
                scope: viewModel.currentScope,
                category: viewModel.searchCategoryFilter
            ))
            TextField(
                CommandPaletteScopePresentation.searchPlaceholder(
                    scope: viewModel.currentScope,
                    category: viewModel.searchCategoryFilter
                ),
                text: $viewModel.query
            )
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused(focusedField, equals: .query)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.queryDidChangeFromTextField()
                }
                .onSubmit {
                    Task { await viewModel.executeSelection() }
                }
        }
        .padding(SpotiglassDesign.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SpotiglassDesign.cornerM, style: .continuous))
        .glassEffectID("palette.search", in: paletteGlass)
    }
}

// MARK: - Scope presentation (icon + placeholder)

enum CommandPaletteScopePresentation {
    static func iconName(
        scope: CommandPaletteScope,
        category: CommandPaletteSearchCategory
    ) -> String {
        switch scope {
        case .commands:
            "command"
        case .songs:
            switch category {
            case .all: "magnifyingglass"
            case .tracks: "music.note"
            case .artists: "person.wave.2"
            case .thisPlaylist: "music.note.list"
            case .myPlaylists: "books.vertical"
            }
        }
    }

    static func iconColor(
        scope: CommandPaletteScope,
        category: CommandPaletteSearchCategory
    ) -> Color {
        switch scope {
        case .commands:
            .accentColor
        case .songs:
            switch category {
            case .all, .tracks, .artists, .thisPlaylist, .myPlaylists:
                .secondary
            }
        }
    }

    static func searchPlaceholder(
        scope: CommandPaletteScope,
        category: CommandPaletteSearchCategory
    ) -> String {
        switch scope {
        case .commands:
            "Run a command"
        case .songs:
            switch category {
            case .all:
                "Search Spotify"
            case .tracks:
                "Search tracks"
            case .artists:
                "Search artists"
            case .thisPlaylist:
                "Search in this playlist"
            case .myPlaylists:
                "Search your playlists"
            }
        }
    }
}
