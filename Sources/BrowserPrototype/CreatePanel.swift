import SwiftUI

/// Arc's create panel from the sidebar "+": the six things you can make, with their shortcuts.
struct CreatePanel: View {
    @ObservedObject var model: BrowserModel
    let close: () -> Void
    let newSpace: () -> Void
    let newFolder: () -> Void
    @State private var hovered: String? = "tab"

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var keys = ""
        var enabled = true
        let action: () -> Void
    }

    private var groups: [[Item]] {
        let hasSite = model.state.selectedTab?.url.host != nil
        return [
            [Item(id: "space", title: "New Space", symbol: "rectangle.stack.badge.plus", action: newSpace),
             Item(id: "folder", title: "New Folder", symbol: "folder", action: newFolder)],
            [Item(id: "easel", title: "New Easel", symbol: "scribble.variable", keys: "⌃⇧E") { model.newEasel() },
             Item(id: "boost", title: "New Boost", symbol: "wand.and.sparkles", enabled: hasSite) { model.boostPanelOpen = true }],
            [Item(id: "split", title: "New Split", symbol: "rectangle.split.2x1", keys: "⌃⇧=", enabled: model.state.selectedTab != nil) { model.commandMode = .split },
             Item(id: "tab", title: "New Tab", symbol: "plus.square", keys: "⌘T") { model.commandMode = .newTab }],
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().padding(.horizontal, 12).padding(.vertical, 5) }
                ForEach(group) { row($0) }
            }
        }
        .padding(8).frame(width: 260)
    }

    private func row(_ item: Item) -> some View {
        let lit = hovered == item.id && item.enabled
        return HStack(spacing: 14) {
            Image(systemName: item.symbol).font(.system(size: 17, weight: .regular)).frame(width: 24)
            Text(item.title).font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(item.keys).font(.system(size: 13, weight: .medium)).opacity(0.5)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .foregroundStyle(lit ? Color.white : Color.primary)
        .background(lit ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(item.enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { if $0 { hovered = item.id } }
        .onTapGesture {
            guard item.enabled else { return }
            close()
            item.action()
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityAction { if item.enabled { close(); item.action() } }
    }
}
