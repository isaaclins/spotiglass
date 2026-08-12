import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag payload type for pinned-item transfers. Not registered in
    /// `Info.plist`: only Spotiglass advertises and accepts it, so cross-app
    /// drops never see this type.
    static let spotiglassPinnedItem = UTType(exportedAs: "com.spotiglass.pinned-item")
}

/// Drag payload for drag-to-pin: any pin-capable surface (track row, album
/// card, artist header, playlist row) drags one of these onto the sidebar's
/// `dropDestination(for: PinnedItemTransfer.self)`.
struct PinnedItemTransfer: Codable, Equatable, Hashable, Transferable {
    let item: PinnedItem

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .spotiglassPinnedItem)
    }
}
