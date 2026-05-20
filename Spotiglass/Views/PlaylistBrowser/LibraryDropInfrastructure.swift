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
        Self.trackInsertion(at: info.location, update: updateInsertionIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        Self.trackInsertion(at: info.location, update: updateInsertionIndex)
        return Self.dropProposal
    }

    func dropExited(info: DropInfo) {
        Self.clearInsertion(update: clearInsertionIndex)
    }

    static let dropProposal = DropProposal(operation: .copy)

    static func trackInsertion(at location: CGPoint, update: (CGPoint) -> Void) {
        update(location)
    }

    static func clearInsertion(update: () -> Void) {
        update()
    }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        clearInsertionIndex()
        if let provider = info.itemProviders(for: [UTType.spotiglassPinnedItem]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassPinnedItem.identifier) { data, _ in
                Task { @MainActor in
                    Self.handlePinnedPayload(
                        data: data,
                        location: location,
                        performPinnedDrop: performPinnedDrop,
                        clearDragPreview: clearDragPreview
                    )
                }
            }
            return true
        }
        if let provider = info.itemProviders(for: [UTType.spotiglassLibrarySidebarRow]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.spotiglassLibrarySidebarRow.identifier) { data, _ in
                Task { @MainActor in
                    Self.handleLibraryRowPayload(
                        data: data,
                        location: location,
                        performLibraryRowDrop: performLibraryRowDrop,
                        clearDragPreview: clearDragPreview
                    )
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
                    Task { @MainActor in
                        Self.handleTextPayload(
                            data: data,
                            location: location,
                            performPinnedDrop: performPinnedDrop,
                            performLibraryRowDrop: performLibraryRowDrop,
                            clearDragPreview: clearDragPreview
                        )
                    }
                }
                return true
            }
        }
        clearDragPreview()
        return false
    }

    /// Decodes a pinned-item transfer from drop payload bytes (unit-tested).
    static func decodePinnedTransfer(from data: Data) -> PinnedItemTransfer? {
        try? JSONDecoder().decode(PinnedItemTransfer.self, from: data)
    }

    /// Decodes a library-row transfer from drop payload bytes (unit-tested).
    static func decodeLibraryRowTransfer(from data: Data) -> LibrarySidebarRowTransfer? {
        try? JSONDecoder().decode(LibrarySidebarRowTransfer.self, from: data)
    }

    @MainActor
    static func handlePinnedPayload(
        data: Data?,
        location: CGPoint,
        performPinnedDrop: (PinnedItemTransfer, CGPoint) -> Bool,
        clearDragPreview: () -> Void
    ) {
        guard let data, let transfer = decodePinnedTransfer(from: data) else {
            clearDragPreview()
            return
        }
        if !performPinnedDrop(transfer, location) {
            clearDragPreview()
        }
    }

    @MainActor
    static func handleLibraryRowPayload(
        data: Data?,
        location: CGPoint,
        performLibraryRowDrop: (LibrarySidebarRowTransfer, CGPoint) -> Bool,
        clearDragPreview: () -> Void
    ) {
        guard let data, let transfer = decodeLibraryRowTransfer(from: data) else {
            clearDragPreview()
            return
        }
        if !performLibraryRowDrop(transfer, location) {
            clearDragPreview()
        }
    }

    @MainActor
    static func handleTextPayload(
        data: Data?,
        location: CGPoint,
        performPinnedDrop: (PinnedItemTransfer, CGPoint) -> Bool,
        performLibraryRowDrop: (LibrarySidebarRowTransfer, CGPoint) -> Bool,
        clearDragPreview: () -> Void
    ) {
        guard let data else {
            clearDragPreview()
            return
        }
        if let transfer = decodePinnedTransfer(from: data) {
            if !performPinnedDrop(transfer, location) {
                clearDragPreview()
            }
            return
        }
        if let transfer = decodeLibraryRowTransfer(from: data) {
            if !performLibraryRowDrop(transfer, location) {
                clearDragPreview()
            }
            return
        }
        clearDragPreview()
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
