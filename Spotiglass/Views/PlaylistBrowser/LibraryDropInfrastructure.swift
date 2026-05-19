import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct LibraryPinnedItemDropDelegate: DropDelegate {
    static let acceptedTypeIdentifiers: [String] = [
        UTType.spotiglassPinnedItem.identifier,
        UTType.spotiglassLibrarySidebarRow.identifier,
        UTType.plainText.identifier,
        "public.utf8-plain-text",
        UTType.text.identifier
    ]

    let updateInsertionIndex: (CGPoint) -> Void
    let clearInsertionIndex: () -> Void
    let performPinnedDrop: (PinnedItemTransfer, CGPoint) -> Bool
    let performLibraryRowDrop: (LibrarySidebarRowTransfer, CGPoint) -> Bool
    let clearDragPreview: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        Self.acceptsDrop(
            hasPinned: !info.itemProviders(for: [UTType.spotiglassPinnedItem]).isEmpty,
            hasLibraryRow: !info.itemProviders(for: [UTType.spotiglassLibrarySidebarRow]).isEmpty,
            hasPlainText: !info.itemProviders(for: [UTType.plainText]).isEmpty,
            hasText: !info.itemProviders(for: [UTType.text]).isEmpty
        )
    }

    static func acceptsDrop(
        hasPinned: Bool,
        hasLibraryRow: Bool,
        hasPlainText: Bool,
        hasText: Bool
    ) -> Bool {
        hasPinned || hasLibraryRow || hasPlainText || hasText
    }

    func dropEntered(info: DropInfo) {
        updateInsertionIndex(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertionIndex(info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        clearInsertionIndex()
    }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        clearInsertionIndex()
        if let provider = info.itemProviders(for: [UTType.spotiglassPinnedItem]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassPinnedItem.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(PinnedItemTransfer.self, from: data)
                else {
                    Task { @MainActor in clearDragPreview() }
                    return
                }
                Task { @MainActor in
                    if !performPinnedDrop(transfer, location) {
                        clearDragPreview()
                    }
                }
            }
            return true
        }
        if let provider = info.itemProviders(for: [UTType.spotiglassLibrarySidebarRow]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassLibrarySidebarRow.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data)
                else {
                    Task { @MainActor in clearDragPreview() }
                    return
                }
                Task { @MainActor in
                    if !performLibraryRowDrop(transfer, location) {
                        clearDragPreview()
                    }
                }
            }
            return true
        }
        let textProviders = info.itemProviders(for: [UTType.plainText]) + info.itemProviders(for: [UTType.text])
        if let provider = textProviders.first {
            let candidates = [UTType.plainText.identifier, "public.utf8-plain-text", UTType.text.identifier]
            for typeIdentifier in candidates {
                if !provider.hasItemConformingToTypeIdentifier(typeIdentifier) { continue }
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    guard let data else {
                        Task { @MainActor in clearDragPreview() }
                        return
                    }
                    if let transfer = try? JSONDecoder().decode(PinnedItemTransfer.self, from: data) {
                        Task { @MainActor in
                            if !performPinnedDrop(transfer, location) {
                                clearDragPreview()
                            }
                        }
                        return
                    }
                    if let transfer = try? JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data) {
                        Task { @MainActor in
                            if !performLibraryRowDrop(transfer, location) {
                                clearDragPreview()
                            }
                        }
                        return
                    }
                    Task { @MainActor in clearDragPreview() }
                }
                return true
            }
        }
        clearDragPreview()
        return false
    }
}

struct LibraryRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct LibrarySidebarRowTransfer: Codable, Equatable, Hashable, Transferable {
    let rowToken: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .spotiglassLibrarySidebarRow)
    }

    /// macOS drag source provider used by `onDrop`/`DropDelegate` targets.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = (try? JSONEncoder().encode(self)) ?? Data()
        if let jsonString = String(data: encoded, encoding: .utf8) {
            provider.registerObject(jsonString as NSString, visibility: .all)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.spotiglassLibrarySidebarRow.identifier,
            visibility: .all
        ) { completion in
            completion(encoded, nil)
            return nil
        }
        return provider
    }
}
