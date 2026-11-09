import Foundation

extension PlaylistBrowserViewModel {
    /// When viewing an artist page (no playlist selection), refresh reloads that artist.
    var artistIDForRefreshingDetail: String? {
        switch detailState {
        case let .loaded(content), let .staleCache(content, _), let .refreshing(content):
            if case let .artist(vm) = content {
                return vm.artist.id
            }
            return nil
        case .loading, .empty, .error:
            return nil
        }
    }

    func navigateBack() async {
        guard let target = popPreviousNavigationTarget() else {
            syncCanNavigateBack()
            return
        }
        if !breadcrumbPath.isEmpty {
            breadcrumbPath.removeLast()
        }
        isPerformingBackNavigation = true
        defer {
            isPerformingBackNavigation = false
            syncCanNavigateBack()
        }
        currentNavigationTarget = target
        switch target {
        case let .sidebar(selection):
            await selectSidebar(selection, origin: .backStackReplay)
        case let .artist(id):
            await selectArtist(id: id, forceRefresh: false, origin: .backStackReplay, displayName: nil)
        case let .album(id, title, subtitle, artworkURL):
            await selectAlbum(
                id: id,
                displayTitle: title,
                displaySubtitle: subtitle,
                artworkURL: artworkURL,
                origin: .backStackReplay
            )
        }
        reconcileBreadcrumbAfterNavigateBack(to: target)
    }

    func registerNavigationTransition(to target: BrowserNavigationTarget) {
        if isPerformingBackNavigation {
            currentNavigationTarget = target
            syncCanNavigateBack()
            return
        }
        if currentNavigationTarget == nil {
            currentNavigationTarget = navigationTargetFromCurrentState()
        }
        guard currentNavigationTarget != target else {
            syncCanNavigateBack()
            return
        }
        if let currentNavigationTarget {
            backNavigationStack.append(currentNavigationTarget)
            if backNavigationStack.count > maxBackNavigationDepth {
                backNavigationStack.removeFirst(backNavigationStack.count - maxBackNavigationDepth)
            }
        }
        currentNavigationTarget = target
        syncCanNavigateBack()
    }

    /// Where ``navigateBack()`` goes next, without going there. The toolbar's
    /// back button names it, so the label always matches what a click does.
    var backDestination: BrowserNavigationTarget? {
        backNavigationStack.last { $0 != currentNavigationTarget }
    }

    /// The name of a place the browser can go back to, in the words the
    /// sidebar and the window title use for it (#443).
    func displayName(
        for target: BrowserNavigationTarget,
        locale: Locale = SpotiglassL10n.locale
    ) -> String {
        switch target {
        case .sidebar(.home):
            return SpotiglassL10n.string("browser.home", locale: locale)
        case .sidebar(.search):
            return SpotiglassL10n.string("browser.search", locale: locale)
        case .sidebar(.likedSongs):
            return SpotiglassL10n.string("browser.likedSongs.title", locale: locale)
        case let .sidebar(.playlist(id)):
            return (playlistsByID[id] ?? knownPlaylistSummariesByID[id])?.name
                ?? SpotiglassL10n.string("browser.breadcrumb.playlistFallback", locale: locale)
        case .sidebar(.pinnedItem):
            // Pinned rows open an artist or album, which is what gets recorded,
            // so this target never lands on the back stack.
            return SpotiglassL10n.string("browser.home", locale: locale)
        case let .artist(id):
            if let crumb = breadcrumbPath.last(where: { $0.kind == .artist(id: id) }) {
                return crumb.label
            }
            return cachedArtistSnapshots[id]?.snapshot.artistDetail.name
                ?? backNavigationArtistNames[id]
                ?? SpotiglassL10n.string("browser.breadcrumb.artistFallback", locale: locale)
        case let .album(_, title, _, _):
            return title
        }
    }

    private func popPreviousNavigationTarget() -> BrowserNavigationTarget? {
        while let previous = backNavigationStack.popLast() {
            if previous != currentNavigationTarget {
                return previous
            }
        }
        return nil
    }

    func syncCanNavigateBack() {
        // The same test ``navigateBack()`` uses: entries equal to the current
        // place are skipped, so they alone give back nowhere to go.
        canNavigateBack = backDestination != nil
    }

    /// Keeps an artist's name for the back button once the breadcrumb that
    /// held it is gone. Only artists still in the history are kept.
    func rememberArtistNameForBack(_ name: String?, artistID: String) {
        if let name, !name.isEmpty {
            backNavigationArtistNames[artistID] = name
        }
        let inHistory = Set((backNavigationStack + [currentNavigationTarget].compactMap { $0 }).compactMap { target in
            if case let .artist(id) = target { return id }
            return nil
        })
        backNavigationArtistNames = backNavigationArtistNames.filter { inHistory.contains($0.key) }
    }

    /// Takes a deleted playlist out of the history and out of the title's
    /// trail, so back neither names it nor opens an empty page, and going back
    /// from a page opened in it doesn't leave its name in the title.
    func forgetDeletedPlaylist(id: String) {
        backNavigationStack.removeAll { $0 == .sidebar(.playlist(id)) }
        breadcrumbPath.removeAll { $0.kind == .playlist(id: id) }
        syncCanNavigateBack()
    }

    func applyBreadcrumbForSidebar(_ selection: SidebarSelection, origin: BrowserNavigationOrigin) {
        switch origin {
        case .backStackReplay:
            return
        case .reset, .extend:
            switch selection {
            case .home:
                breadcrumbPath = []
            case .search:
                breadcrumbPath = [
                    BrowserBreadcrumb(
                        id: UUID(),
                        label: SpotiglassL10n.string("browser.search"),
                        systemImage: "magnifyingglass",
                        kind: .search
                    )
                ]
            case .likedSongs:
                breadcrumbPath = [
                    BrowserBreadcrumb(
                        id: UUID(),
                        label: SpotiglassL10n.string("browser.likedSongs.title"),
                        systemImage: "heart.fill",
                        kind: .likedSongs
                    )
                ]
            case let .playlist(id):
                let title = (playlistsByID[id] ?? knownPlaylistSummariesByID[id])?.name
                    ?? SpotiglassL10n.string("browser.breadcrumb.playlistFallback")
                breadcrumbPath = [
                    BrowserBreadcrumb(
                        id: UUID(),
                        label: title,
                        systemImage: "music.note.list",
                        kind: .playlist(id: id)
                    )
                ]
            case .pinnedItem:
                break
            }
        }
    }

    func applyBreadcrumbForArtist(id: String, displayName: String?, origin: BrowserNavigationOrigin) {
        switch origin {
        case .backStackReplay:
            return
        case .reset:
            let label = resolvedArtistLabel(id: id, displayName: displayName)
            breadcrumbPath = [
                BrowserBreadcrumb(
                    id: UUID(),
                    label: label,
                    systemImage: "person.wave.2",
                    kind: .artist(id: id)
                )
            ]
        case .extend:
            let label = resolvedArtistLabel(id: id, displayName: displayName)
            appendOrTrimBreadcrumb(
                BrowserBreadcrumb(
                    id: UUID(),
                    label: label,
                    systemImage: "person.wave.2",
                    kind: .artist(id: id)
                )
            )
        }
    }

    func applyBreadcrumbForAlbum(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        origin: BrowserNavigationOrigin
    ) {
        switch origin {
        case .backStackReplay:
            return
        case .reset:
            breadcrumbPath = [
                BrowserBreadcrumb(
                    id: UUID(),
                    label: title,
                    systemImage: "opticaldisc",
                    kind: .album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
                )
            ]
        case .extend:
            appendOrTrimBreadcrumb(
                BrowserBreadcrumb(
                    id: UUID(),
                    label: title,
                    systemImage: "opticaldisc",
                    kind: .album(id: id, title: title, subtitle: subtitle, artworkURL: artworkURL)
                )
            )
        }
    }

    /// Prevents duplicate loops in the toolbar trail by collapsing to an
    /// already-visited page when users navigate to the same destination again.
    private func appendOrTrimBreadcrumb(_ crumb: BrowserBreadcrumb) {
        if let existingIndex = breadcrumbPath.lastIndex(where: { existing in
            breadcrumbRepresentsSamePage(existing.kind, crumb.kind)
        }) {
            breadcrumbPath = Array(breadcrumbPath.prefix(existingIndex + 1))
            return
        }
        breadcrumbPath.append(crumb)
    }

    /// Matches logical destination identity (IDs), not display metadata.
    private func breadcrumbRepresentsSamePage(_ lhs: BrowserBreadcrumb.Kind, _ rhs: BrowserBreadcrumb.Kind) -> Bool {
        switch (lhs, rhs) {
        case (.search, .search):
            return true
        case (.likedSongs, .likedSongs):
            return true
        case let (.playlist(leftID), .playlist(rightID)):
            return leftID == rightID
        case let (.artist(leftID), .artist(rightID)):
            return leftID == rightID
        case let (.album(leftID, _, _, _), .album(rightID, _, _, _)):
            return leftID == rightID
        default:
            return false
        }
    }

    private func resolvedArtistLabel(id: String, displayName: String?) -> String {
        if let displayName {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let cached = cachedArtistSnapshots[id] {
            return cached.snapshot.artistDetail.name
        }
        // Going back to an artist whose page never loaded still knows the name
        // the link showed, so the title and the next back don't say "Artist".
        if let remembered = backNavigationArtistNames[id] {
            return remembered
        }
        return SpotiglassL10n.string("browser.breadcrumb.artistFallback")
    }

    func refineLastBreadcrumbArtistLabelIfNeeded(artistID: String, resolvedName: String) {
        rememberArtistNameForBack(resolvedName, artistID: artistID)
        guard let idx = breadcrumbPath.indices.last,
              case let .artist(aid) = breadcrumbPath[idx].kind,
              aid == artistID,
              breadcrumbPath[idx].label != resolvedName else { return }
        let old = breadcrumbPath[idx]
        breadcrumbPath[idx] = BrowserBreadcrumb(
            id: old.id,
            label: resolvedName,
            systemImage: old.systemImage,
            kind: old.kind
        )
    }

    /// After ``navigateBack()`` pops the leaf crumb, the path can be empty while the replayed
    /// destination still needs a single segment (e.g. switching playlists resets the trail to one crumb).
    private func reconcileBreadcrumbAfterNavigateBack(to target: BrowserNavigationTarget) {
        guard breadcrumbPath.isEmpty else { return }
        switch target {
        case let .sidebar(selection):
            applyBreadcrumbForSidebar(selection, origin: .reset)
        case let .artist(id):
            applyBreadcrumbForArtist(id: id, displayName: nil, origin: .reset)
        case let .album(id, title, subtitle, artworkURL):
            applyBreadcrumbForAlbum(
                id: id,
                title: title,
                subtitle: subtitle,
                artworkURL: artworkURL,
                origin: .reset
            )
        }
    }

    private func navigationTargetFromCurrentState() -> BrowserNavigationTarget? {
        if let detailAlbumTarget = albumNavigationTargetFromCurrentDetail() {
            return detailAlbumTarget
        }
        if let sidebarSelection {
            if case .pinnedItem = sidebarSelection {
                return nil
            }
            return .sidebar(sidebarSelection)
        }
        if let artistID = artistIDForRefreshingDetail {
            return .artist(artistID)
        }
        return nil
    }

    private func albumNavigationTargetFromCurrentDetail() -> BrowserNavigationTarget? {
        guard let content = detailState.currentValue,
              case let .playlist(detail) = content,
              detail.playlist.isAlbumDetail else {
            return nil
        }
        return .album(
            id: detail.playlist.id,
            title: detail.playlist.title,
            subtitle: detail.playlist.owner,
            artworkURL: detail.playlist.artworkURL
        )
    }
}
