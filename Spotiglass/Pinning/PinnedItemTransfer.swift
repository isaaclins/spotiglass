import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import AppKit

extension UTType {
    /// In-app drag payload type for pinned-item transfers. Not registered in
    /// `Info.plist`: only Spotiglass advertises and accepts it, so cross-app
    /// drops never see this type.
    static let spotiglassPinnedItem = UTType(exportedAs: "com.spotiglass.pinned-item")
    /// In-app drag payload type for reorder-only library chrome rows (Home).
    static let spotiglassLibrarySidebarRow = UTType(exportedAs: "com.spotiglass.library-sidebar-row")
}

/// Drag payload for pinned-item interactions.
///
/// The ``originScopeID`` distinguishes a reorder (drag started from the pinned
/// area) from a new pin (drag started from a track row, album card, …) so the
/// drop destination can dispatch to the correct ``PinnedItemsStore`` mutation.
struct PinnedItemTransfer: Codable, Equatable, Hashable, Transferable {
    /// Sentinel scope value used by the pinned-area drag source. Anything else
    /// is treated as "new pin".
    static let pinnedSidebarScopeID = "sidebarPinned"

    let item: PinnedItem
    let originScopeID: String

    init(item: PinnedItem, originScopeID: String) {
        self.item = item
        self.originScopeID = originScopeID
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .spotiglassPinnedItem)
    }

    var isFromPinnedSidebar: Bool {
        originScopeID == Self.pinnedSidebarScopeID
    }
}

extension PinnedItemTransfer {
    /// macOS drag source provider used by `onDrop`/`DropDelegate` targets.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = (try? JSONEncoder().encode(self)) ?? Data()
        if let jsonString = String(data: encoded, encoding: .utf8) {
            provider.registerObject(jsonString as NSString, visibility: .all)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.spotiglassPinnedItem.identifier,
            visibility: .all
        ) { completion in
            completion(encoded, nil)
            return nil
        }
        return provider
    }
}
