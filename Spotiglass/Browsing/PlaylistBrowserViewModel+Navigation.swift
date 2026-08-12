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

    func jumpToHome() async {
        breadcrumbPath = []
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        isPerformingBackNavigation = true
        defer { isPerformingBackNavigation = false }
        await selectSidebar(.home, origin: .backStackReplay)
    }

    func jumpToBreadcrumb(at index: Int) async {
        guard index >= 0, index < breadcrumbPath.count else { return }
        breadcrumbPath = Array(breadcrumbPath.prefix(index + 1))
        let crumb = breadcrumbPath[index]
        backNavigationStack = []
        currentNavigationTarget = nil
        canNavigateBack = false
        isPerformingBackNavigation = true
        defer { isPerformingBackNavigation = false }
        switch crumb.kind {
        case .search:
            await selectSidebar(.search, origin: .backStackReplay)
        case .likedSongs:
            await selectSidebar(.likedSongs, origin: .backStackReplay)
        case let .playlist(id):
            await selectSidebar(.playlist(id), origin: .backStackReplay)
        case let .artist(id):
            await selectArtist(id: id, forceRefresh: false, origin: .backStackReplay, displayName: crumb.label)
        case let .album(id, title, subtitle, artworkURL):
            await selectAlbum(
                id: id,
                displayTitle: title,
                displaySubtitle: subtitle,
                artworkURL: artworkURL,
                origin: .backStackReplay
            )
        }
        syncCanNavigateBack()
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

    private func popPreviousNavigationTarget() -> BrowserNavigationTarget? {
        while let previous = backNavigationStack.popLast() {
            if previous != currentNavigationTarget {
                return previous
            }
        }
        return nil
    }

    func syncCanNavigateBack() {
        canNavigateBack = !backNavigationStack.isEmpty
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
                let title = playlistsByID[id]?.name ?? SpotiglassL10n.string("browser.breadcrumb.playlistFallback")
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
        return SpotiglassL10n.string("browser.breadcrumb.artistFallback")
    }

    func refineLastBreadcrumbArtistLabelIfNeeded(artistID: String, resolvedName: String) {
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
              detail.playlist.snapshotID.hasPrefix("album-") else {
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
