import SwiftUI

extension PlaylistBrowserView {
    /// A cold launch can race the network, so the account lookup gets a few
    /// tries before the sidebar admits defeat.
    static let pinnedBindingAttempts = 3
    static let pinnedBindingRetryDelaySeconds: Double = 2

    func handleSidebarSelectionChange(oldValue: SidebarSelection?, newValue: SidebarSelection?) {
        Task { @MainActor in
            switch PlaylistBrowserSidebarSelectionHandling.selectionChangeAction(
                oldValue: oldValue,
                newValue: newValue,
                pinnedItems: pinnedStore.items
            ) {
            case .none:
                break
            case let .activatePinned(item):
                await activatePinnedItem(item, previousSelection: oldValue)
            case let .selectSidebar(selection):
                lastNonPinnedSelection = PlaylistBrowserSidebarSelectionHandling.lastNonPinnedSelection(
                    afterSelecting: selection
                )
                await viewModel.selectSidebar(selection)
            }
        }
    }

    @MainActor
    func activatePinnedItem(_ item: PinnedItem, previousSelection: SidebarSelection?) async {
        let browserVM = viewModel
        let playbackVM = playbackViewModel
        let store = pinnedStore
        await PlaylistBrowserSidebarSelectionHandling.activatePinnedItem(
            item,
            previousSelection: previousSelection,
            lastNonPinnedSelection: lastNonPinnedSelection,
            callbacks: .init(
                setSidebarSelection: { browserVM.sidebarSelection = $0 },
                selectSidebarPlaylist: { id in await browserVM.selectSidebar(.playlist(id)) },
                selectArtist: { id, origin, name in
                    await browserVM.selectArtist(id: id, origin: origin, displayName: name)
                },
                selectAlbum: { id, title, subtitle, artwork, origin in
                    await browserVM.selectAlbum(
                        id: id,
                        displayTitle: title,
                        displaySubtitle: subtitle,
                        artworkURL: artwork,
                        origin: origin
                    )
                },
                playURI: { uri in await playbackVM.play(uri: uri) },
                markStale: { id, stale in store.markStale(id: id, stale) },
                detailState: { browserVM.detailState }
            )
        )
    }

    /// Binds the pinned store to the signed-in account, retrying a failed
    /// profile lookup.
    ///
    /// This used to be a single `try?` in a `.task` that never re-ran, so one
    /// failed profile call at launch left the pinned sidebar empty for the whole
    /// session, with no error and no way back short of relaunching (#133).
    func bindPinnedStoreToCurrentUser() async {
        let bindingGeneration = pinnedStore.bindingGeneration
        for attempt in 0..<Self.pinnedBindingAttempts {
            guard !Task.isCancelled else { return }
            do {
                let profile = try await spotifySearchClient.currentUserProfile()
                guard !Task.isCancelled else { return }
                guard let userID = profile.id as String? else { return }
                if pinnedStore.boundUserID == userID { return }
                pinnedStore.bind(userID: userID, bindingGeneration: bindingGeneration)
                return
            } catch is CancellationError {
                return
            } catch {
                SpotiglassLog.error(
                    SpotiglassLog.pinning,
                    "Current-user lookup failed (attempt \(attempt + 1)): \(error.localizedDescription)"
                )
                guard attempt + 1 < Self.pinnedBindingAttempts else { break }
                try? await Task.sleep(for: .seconds(Self.pinnedBindingRetryDelaySeconds))
            }
        }
        guard !Task.isCancelled else { return }
        pinnedStore.reportBindingFailure()
    }
}
