import Foundation
@testable import Spotiglass

extension PlaylistBrowserViewModel {
    /// Test helper mirroring former `selectedPlaylistID` on the view model.
    var selectedPlaylistID: String? {
        if case let .playlist(id) = sidebarSelection { return id }
        return nil
    }
}
