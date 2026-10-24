import AppKit
import BrowserCore
import SwiftUI

struct BrowserCommandBar: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selected = 0

    init(model: BrowserModel) {
        self.model = model
        _query = State(initialValue: model.commandMode == .location ? model.state.selectedTab?.url.absoluteString ?? "" : "")
    }

    private struct Suggestion: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let action: () -> Void
    }

    private var suggestions: [Suggestion] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [Suggestion] = []
        if !search.isEmpty, BrowserModel.destination(search) != nil {
            results.append(Suggestion(id: "navigate", title: search, detail: search.contains(".") ? "Go to website" : "Search \(model.settings.state.searchEngine.name)", icon: "magnifyingglass") {
                if model.commandMode == .split, let url = model.destination(search) { model.openInSplit(url) }
                else { model.submit(search, newTab: model.commandMode == .newTab) }
            })
        }
        let tabs = model.state.tabs.filter { tab in
            tab.kind != .archived && model.state.profileID(forTab: tab.id) == model.state.selectedProfileID &&
                (search.isEmpty || tab.title.localizedCaseInsensitiveContains(search) || tab.url.absoluteString.localizedCaseInsensitiveContains(search))
        }
        for tab in tabs.prefix(6) {
            results.append(Suggestion(id: tab.id.uuidString, title: tab.title, detail: "Switch to Tab", icon: "rectangle.on.rectangle") {
                if model.commandMode == .split { model.split(tab.id) } else { model.select(tab.id) }
            })
        }
        if !search.isEmpty {
            let openURLs = Set(tabs.map(\.url))
            for visit in model.history?.search(search, profileID: model.state.selectedProfileID, limit: 4) ?? [] where !openURLs.contains(visit.url) {
                results.append(Suggestion(id: "history-" + visit.id.uuidString, title: visit.title, detail: "History · \(visit.url.host ?? "")", icon: "clock") { model.open(visit.url) })
            }
        }
        for space in model.state.spaces where !search.isEmpty && space.name.localizedCaseInsensitiveContains(search) {
            results.append(Suggestion(id: space.id.uuidString, title: space.name, detail: "Switch to Space", icon: "square.grid.2x2") { model.selectSpace(space.id) })
        }
        let actions: [Suggestion] = [
            Suggestion(id: "sidebar", title: model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", detail: "⌘S", icon: "sidebar.left") { model.sidebarVisible.toggle() },
            Suggestion(id: "folder", title: "New Folder", detail: "Create in this Space", icon: "folder.badge.plus") { model.addFolder("New Folder") },
            Suggestion(id: "history", title: "History", detail: "Search this profile's visits", icon: "clock") { model.panel = .history },
            Suggestion(id: "downloads", title: "Downloads", detail: "View downloaded files", icon: "arrow.down.circle") { model.panel = .downloads },
            Suggestion(id: "documents", title: "Notes & Easels", detail: "Local notes and page captures", icon: "note.text") { model.panel = .documents },
            Suggestion(id: "settings", title: "Settings", detail: "Search, tabs and websites", icon: "gearshape") { model.panel = .settings },
            Suggestion(id: "appearance", title: "Customize Space", detail: "Color, icon and layout", icon: "paintpalette") { model.panel = .appearance },
            Suggestion(id: "profiles", title: "Profiles", detail: "Separate website sign-ins", icon: "person.crop.circle") { model.panel = .profiles },
            Suggestion(id: "split-separate", title: "Separate Tab", detail: "Show this page on its own", icon: "arrow.up.right.square") {
                if let group = model.state.selectedSplitGroup, let id = model.state.selectedTabID { model.separatePane(id, from: group.id) }
            },
            Suggestion(id: "split-separate-all", title: "Separate All Tabs", detail: "Keep all pages open", icon: "rectangle.on.rectangle") { model.separateAllPanes() },
            Suggestion(id: "reset", title: "Reset Pinned Tab", detail: "Return to its original URL", icon: "arrow.uturn.backward") {
                if let id = model.state.selectedTabID { model.resetPin(id) }
            }
        ]
        results += actions.filter { action in
            (action.id != "documents" || model.supportsDocuments) && (!action.id.hasPrefix("split-") || model.state.selectedSplitGroup != nil) && (action.id != "reset" || model.state.selectedTab?.homeURL != nil) && (search.isEmpty || action.title.localizedCaseInsensitiveContains(search))
        }
        return Array(results.prefix(10))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.14).contentShape(Rectangle()).onTapGesture { model.commandMode = nil }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .regular)).frame(width: 24).foregroundStyle(.secondary)
                        CommandInput(text: $query, scheme: scheme, submit: { choose() },
                                     move: { delta in selected = min(max(0, selected + delta), max(0, suggestions.count - 1)) },
                                     cancel: { model.commandMode = nil })
                            .frame(height: 32)
                        Text("esc").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 20).frame(height: 64)
                    Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5).padding(.horizontal, 11)
                    ScrollViewReader { proxy in
                    ScrollView {
                    VStack(spacing: 0) {
                        if suggestions.isEmpty {
                            Text("Enter a website or search above").font(.system(size: 13)).foregroundStyle(.secondary).frame(height: 50)
                        }
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                            Button { choose(index) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.icon).font(.system(size: 16)).frame(width: 24, height: 24)
                                    Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1).layoutPriority(1)
                                    Spacer(minLength: 12)
                                    Text(item.detail).font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Palette.color("CommandBarTextSecondary", scheme: scheme)).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .medium))
                                        .frame(width: 24, height: 24)
                                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                                }.padding(.horizontal, 12).frame(height: 50).frame(maxWidth: .infinity, alignment: .leading)
                                    // The row layer uses bounds inset by 2 points.
                                    .background {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selected == index ? Palette.color("CommandBarRowHover", scheme: scheme) : .clear)
                                            .padding(2)
                                    }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index).onHover { if $0 { selected = index } }
                        }
                    }
                    }.scrollIndicators(.hidden)
                        .frame(height: min(CGFloat(max(1, suggestions.count)) * 50, max(50, geometry.size.height - 140)))
                        .onChange(of: selected) { _, index in proxy.scrollTo(index) }
                        .onChange(of: query) { _, _ in proxy.scrollTo(0, anchor: .top) }
                    }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 10)
                }
                .foregroundStyle(Palette.color("CommandBarTextPrimary", scheme: scheme))
                .background {
                    if scheme == .dark {
                        // Composited dark reference sample, not a recovered reusable material token.
                        RoundedRectangle(cornerRadius: 13).fill(Color(.sRGB, red: 23 / 255, green: 23 / 255, blue: 24 / 255))
                    } else {
                        RoundedRectangle(cornerRadius: 13).fill(.regularMaterial)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(scheme == .dark ? 0.23 : 0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 35, y: 15)
                .frame(width: min(765, max(0, geometry.size.width - 80)))
                .offset(y: -5)
            }
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onExitCommand { model.commandMode = nil }
    }

    private func choose(_ index: Int? = nil) {
        let items = suggestions
        let index = index ?? selected
        guard items.indices.contains(index) else { return }
        items[index].action()
        model.commandMode = nil
    }
}

/// Claim the field editor as the overlay attaches, before a deferred SwiftUI focus task.
private struct CommandInput: NSViewRepresentable {
    @Binding var text: String
    let scheme: ColorScheme
    let submit: () -> Void
    let move: (Int) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusField {
        let field = FocusField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .medium)
        field.placeholderString = "Search or Enter URL…"
        field.setAccessibilityLabel("Command Bar")
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: FocusField, context: Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        field.textColor = .labelColor
        if field.stringValue != text { field.stringValue = text }
        field.claimInitialFocus()
    }

    final class FocusField: NSTextField {
        private var didClaimFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            claimInitialFocus()
        }
        func claimInitialFocus() {
            guard !didClaimFocus, let window else { return }
            if window.makeFirstResponder(self) {
                didClaimFocus = true
                selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandInput
        init(_ parent: CommandInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
