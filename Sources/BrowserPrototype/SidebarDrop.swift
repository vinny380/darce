import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drops onto a sidebar tab or split row. The top edge inserts above it; anywhere else splits with it,
/// like Arc. `target` names the zone under the pointer ("tab:<id>" or "split:<id>") so the row can show it.
struct TabDropDelegate: DropDelegate {
    let id: UUID
    let canSplit: Bool
    @Binding var target: String?
    let perform: @MainActor @Sendable (_ dragged: UUID, _ split: Bool) -> Void

    static let insertEdge: CGFloat = 10

    private func splits(_ info: DropInfo) -> Bool { canSplit && info.location.y > Self.insertEdge }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = (splits(info) ? "split:" : "tab:") + id.uuidString
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.hasSuffix(id.uuidString) == true { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let split = splits(info)
        target = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let dragged = UUID(uuidString: text as String) else { return }
            Task { @MainActor in perform(dragged, split) }
        }
        return true
    }
}
