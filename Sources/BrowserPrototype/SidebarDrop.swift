import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drops onto a sidebar tab or split row, like Arc: the top edge inserts above it; anywhere else splits with it,
/// at the slot nearest the pointer. `target` names the zone ("tab:<id>" or "split:<id>:<slot>") so the row can
/// preview the result.
struct TabDropDelegate: DropDelegate {
    let id: UUID
    let width: CGFloat
    /// Slots the dragged tab could take in the split (panes it would sit among); 0 means this row can't split.
    let slots: Int
    @Binding var target: String?
    let perform: @MainActor @Sendable (_ dragged: UUID, _ slot: Int?) -> Void

    static let insertEdge: CGFloat = 8

    private func slot(_ info: DropInfo) -> Int? {
        guard slots > 0, info.location.y > Self.insertEdge else { return nil }
        return max(0, min(slots, Int((info.location.x / max(width, 1) * CGFloat(slots)).rounded())))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = slot(info).map { "split:\(id.uuidString):\($0)" } ?? "tab:\(id.uuidString)"
        if target != zone { target = zone }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.contains(id.uuidString) == true { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let slot = slot(info)
        target = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let dragged = UUID(uuidString: text as String) else { return }
            Task { @MainActor in perform(dragged, slot) }
        }
        return true
    }
}

extension View {
    /// Makes a sidebar tab draggable and records which tab is in flight, so drop targets can preview it.
    func tabDragSource<Preview: View>(_ id: UUID, dragging: Binding<UUID?>, @ViewBuilder preview: () -> Preview) -> some View {
        onDrag {
            dragging.wrappedValue = id
            return NSItemProvider(object: id.uuidString as NSString)
        } preview: { preview() }
    }
}
