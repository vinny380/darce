import AppKit
import BrowserCore
import SwiftUI

struct BrowserSidebar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var appearance: AppearanceController
    @Binding var showArchive: Bool
    @Binding var showNewSpace: Bool
    @Binding var showNewFolder: Bool
    @Environment(\.colorScheme) private var scheme
    private enum RenameTarget { case folder(UUID), tab(UUID), space(UUID) }
    private enum RemovalTarget { case folder(UUID), space(UUID, destination: UUID) }
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var removalTarget: RemovalTarget?

    private var pinnedExpanded: Bool { !appearance.state.space(model.state.selectedSpaceID).pinnedCollapsed }
    private var closedFolders: Set<UUID> { appearance.state.space(model.state.selectedSpaceID).collapsedFolderIDs }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 76)
                Button { model.sidebarVisible = false } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Hide Sidebar").help("Hide Sidebar (⌘S)")
                Spacer()
                if let id = model.state.selectedTabID, let page = model.page(for: id) { NavigationControls(page: page) }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(height: 33)
            Button { model.commandMode = .location } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.state.selectedTab == nil ? "magnifyingglass" : "globe").font(.system(size: 10))
                    Text(model.state.selectedTab?.url.host ?? "Search or Enter URL…").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }.padding(.horizontal, 11).frame(height: 35)
                    .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.65)).accessibilityLabel("Address and search")
            favorites
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: appearance.state.space(model.state.selectedSpaceID).icon)
                            .font(.system(size: 11))
                        Text(model.state.spaces.first { $0.id == model.state.selectedSpaceID }?.name ?? "Space")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button {
                            appearance.update { $0.spaces[model.state.selectedSpaceID, default: SpaceAppearance()].pinnedCollapsed.toggle() }
                        } label: {
                            Image(systemName: pinnedExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        }.buttonStyle(.plain).accessibilityLabel(pinnedExpanded ? "Collapse Pinned Tabs" : "Expand Pinned Tabs")
                    }.padding(.horizontal, 10).padding(.top, 13).padding(.bottom, 9).foregroundStyle(.primary.opacity(0.65))
                    .contextMenu {
                        if let space = model.state.spaces.first(where: { $0.id == model.state.selectedSpaceID }) { spaceActions(space) }
                    }
                    if pinnedExpanded { folderContents(parent: nil) }
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 12)
                    Button { model.commandMode = .newTab } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "plus").frame(width: 16)
                            Text("New Tab")
                            Spacer()
                            Text("⌘T").font(.system(size: 11)).opacity(0.6)
                        }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ForEach(model.state.visibleTabs.filter { $0.kind == .today }) { tab in tabRow(tab) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            HStack(spacing: 4) {
                Button { showArchive = true } label: { Image(systemName: "archivebox").frame(width: 30, height: 30) }
                    .help("Archive").accessibilityLabel("Archive")
                Spacer(minLength: 4)
                ForEach(model.state.spaces) { space in
                    Button { model.selectSpace(space.id) } label: {
                        Image(systemName: appearance.state.space(space.id).icon)
                            .font(.system(size: 11)).frame(width: 29, height: 29)
                            .background(model.state.selectedSpaceID == space.id ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .opacity(model.state.selectedSpaceID == space.id ? 0.9 : 0.4)
                    }.help(space.name).accessibilityLabel("Switch to \(space.name)")
                    .contextMenu { spaceActions(space) }
                }
                Spacer(minLength: 4)
                Menu {
                    Button("New Tab") { model.commandMode = .newTab }
                    Button("New Folder") { showNewFolder = true }
                    Button("New Space") { showNewSpace = true }
                    Divider()
                    Button("Archived Tabs") { showArchive = true }
                    Button("History") { model.panel = .history }
                    Button("Downloads") { model.panel = .downloads }
                    Button("Profiles") { model.panel = .profiles }
                    Button("Notes & Easels") { model.panel = .documents }
                    Button("Customize Space…") { model.panel = .appearance }
                    Button("Boosts…") { model.panel = .boosts }.disabled(model.state.selectedTab?.url.host == nil)
                    Button("Hide Element with Boost") { model.pickBoostElement() }.disabled(model.state.selectedTab?.url.host == nil)
                    Divider()
                    Button("Import Bookmarks…") { model.importBookmarks() }
                    Button("Export Bookmarks…") { model.exportBookmarks() }
                } label: { Image(systemName: "plus").frame(width: 22, height: 30) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Create")
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.7)).padding(.top, 4)
        }
        .padding(.horizontal, 8).padding(.bottom, 10)
        .alert(renameTitle, isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { submitRename() }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { submitRemoval() }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { Text(removalMessage) }
    }

    private var renameTitle: String {
        switch renameTarget {
        case .folder: "Rename Folder"
        case .tab: "Rename Tab"
        case .space: "Rename Space"
        case nil: "Rename"
        }
    }

    private func submitRename() {
        guard let target = renameTarget else { return }
        var changed = false
        model.stateUpdate { state in
            switch target {
            case .folder(let id):
                guard state.folders.contains(where: { $0.id == id }) else { return }
                state.renameFolder(id, name: renameText)
                changed = true
            case .tab(let id): changed = state.renameTab(id, title: renameText)
            case .space(let id):
                guard state.spaces.contains(where: { $0.id == id }) else { return }
                state.renameSpace(id, name: renameText)
                changed = true
            }
        }
        if !changed { model.errorMessage = "This item could not be renamed. It may have moved or been removed." }
        renameTarget = nil
    }

    private var removalTitle: String {
        switch removalTarget {
        case .folder(let id): "Remove “\(model.state.folders.first { $0.id == id }?.name ?? "Folder")”?"
        case .space(let id, _): "Remove “\(model.state.spaces.first { $0.id == id }?.name ?? "Space")”?"
        case nil: "Remove Container?"
        }
    }

    private var removalMessage: String {
        switch removalTarget {
        case .folder(let id):
            let parent = model.state.folders.first { $0.id == id }?.parentID
            let location = model.state.folders.first { $0.id == parent }?.name ?? "the top level of this Space"
            return "Its tabs and child folders will move to \(location). No tabs will be deleted."
        case .space(_, let destination):
            let name = model.state.spaces.first { $0.id == destination }?.name ?? "the selected Space"
            return "All tabs, Favorites, archived tabs, and folders will move to \(name), keeping the same profile. No tabs will be deleted."
        case nil: return ""
        }
    }

    private func submitRemoval() {
        guard let target = removalTarget else { return }
        var removed = false
        model.stateUpdate { state in
            switch target {
            case .folder(let id): removed = state.deleteFolder(id)
            case .space(let id, let destination): removed = state.removeSpace(id, movingContentsTo: destination)
            }
        }
        if !removed { model.errorMessage = "This container could not be removed. Choose an existing destination in the same profile." }
        removalTarget = nil
    }

    @ViewBuilder private func spaceActions(_ space: BrowserSpace) -> some View {
        Button("Rename Space…") { renameText = space.name; renameTarget = .space(space.id) }
        Button("Customize Space…") { model.selectSpace(space.id); model.panel = .appearance }
        let destinations = model.state.spaces.filter { $0.id != space.id && $0.profileID == space.profileID }
        Menu("Remove Space and Move Contents to") {
            ForEach(destinations) { destination in
                Button(destination.name) { removalTarget = .space(space.id, destination: destination.id) }
            }
        }.disabled(destinations.isEmpty)
    }

    private var favorites: some View {
        let tabs = model.state.visibleTabs.filter { $0.kind == .favorite }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(tabs) { tab in
                Button { model.select(tab.id) } label: {
                    SiteIcon(controller: model.favicons, url: tab.url,
                             profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 24)
                        .foregroundStyle(.primary.opacity(0.75)).frame(maxWidth: .infinity).frame(height: 50)
                        .background(Palette.color(model.state.selectedTabID == tab.id ? "SidebarItemHovered" : "SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).help(tab.title).accessibilityLabel("\(tab.title), favorite")
                    .contextMenu { tabActions(tab) }.draggable(tab.id.uuidString)
            }
        }
        .padding(.top, tabs.isEmpty ? 0 : 6)
        .dropDestination(for: String.self) { values, _ in
            guard let id = values.first.flatMap(UUID.init(uuidString:)), model.state.tabs.contains(where: { $0.id == id }) else { return false }
            model.pin(id, kind: .favorite)
            return true
        }
    }

    private func folderContents(parent: UUID?) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 3) {
            ForEach(model.state.folders.filter { $0.spaceID == model.state.selectedSpaceID && $0.parentID == parent }) { folder in
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        appearance.update { preferences in
                            var settings = preferences.space(model.state.selectedSpaceID)
                            if settings.collapsedFolderIDs.contains(folder.id) { settings.collapsedFolderIDs.remove(folder.id) }
                            else { settings.collapsedFolderIDs.insert(folder.id) }
                            preferences.spaces[model.state.selectedSpaceID] = settings
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: closedFolders.contains(folder.id) ? "folder" : "folder.fill").frame(width: 16)
                            Text(folder.name).lineLimit(1)
                            Spacer()
                            Image(systemName: closedFolders.contains(folder.id) ? "chevron.right" : "chevron.down").font(.system(size: 9))
                        }.font(.system(size: 13)).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename") { renameText = folder.name; renameTarget = .folder(folder.id) }
                        Button("New Nested Folder") { model.addFolder("New Folder", parent: folder.id) }
                        Button("Move to Top Level") { model.stateUpdate { _ = $0.moveFolder(folder.id, to: nil) } }.disabled(folder.parentID == nil)
                        Divider()
                        Button("Remove Folder…", role: .destructive) { removalTarget = .folder(folder.id) }
                    }
                    .draggable("folder:\(folder.id.uuidString)")
                    .dropDestination(for: String.self) { values, _ in
                        guard let raw = values.first else { return false }
                        if raw.hasPrefix("folder:"), let id = UUID(uuidString: String(raw.dropFirst(7))) {
                            var moved = false
                            model.stateUpdate { moved = $0.moveFolder(id, to: folder.id) }
                            return moved
                        }
                        guard let id = UUID(uuidString: raw), model.state.tabs.contains(where: { $0.id == id }) else { return false }
                        model.move(id, into: folder.id)
                        return true
                    }
                    if !closedFolders.contains(folder.id) { folderContents(parent: folder.id).padding(.leading, 14) }
                }
            }
            ForEach(model.state.visibleTabs.filter { $0.kind == .pinned && $0.folderID == parent }) { tab in tabRow(tab) }
        })
    }

    private func isRenamingTab(_ id: UUID) -> Bool {
        if case .tab(let editingID) = renameTarget { return editingID == id }
        return false
    }

    func tabRow(_ tab: BrowserTab) -> some View {
        SidebarTabRow(tab: tab, selected: model.state.selectedTabID == tab.id,
                      canReset: model.canResetSidebarTab(tab.id, isEditing: isRenamingTab(tab.id)),
                      contentVisible: model.state.displayedTabIDs.contains(tab.id),
                      semanticPalette: appearance.semanticPalette(forSpace: model.state.selectedSpaceID),
                      icon: SiteIcon(controller: model.favicons, url: tab.url,
                                     profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 16,
                                     usesInheritedForeground: true),
                      select: { model.select(tab.id) }, reset: {
                          guard model.canResetSidebarTab(tab.id, isEditing: isRenamingTab(tab.id)) else { return }
                          model.resetPin(tab.id)
                      }, close: { model.archive(tab.id) })
            .contextMenu { tabActions(tab) }.draggable(tab.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let id = values.first.flatMap(UUID.init(uuidString:)) else { return false }
                return model.reorder(id, before: tab.id)
            }
    }

    @ViewBuilder private func tabActions(_ tab: BrowserTab) -> some View {
        Button("Rename Tab…") { renameText = tab.title; renameTarget = .tab(tab.id) }
        Button("Duplicate Tab") {
            var duplicated: UUID?
            model.stateUpdate { duplicated = $0.duplicateTab(tab.id) }
            if duplicated == nil { model.errorMessage = "This tab could not be duplicated. Restore archived tabs before duplicating them." }
        }
        Divider()
        Button(tab.kind == .pinned ? "Unpin Tab" : "Pin Tab") { model.pin(tab.id, kind: tab.kind == .pinned ? .today : .pinned) }
        Button(tab.kind == .favorite ? "Remove from Favorites" : "Add to Favorites") { model.pin(tab.id, kind: tab.kind == .favorite ? .today : .favorite) }
        if tab.homeURL != nil { Button("Reset to Pinned URL") { model.resetPin(tab.id) } }
        Button("Open in Split View") { model.split(tab.id) }.disabled(tab.id == model.state.selectedTabID)
        Menu("Move to Folder") {
            Button("Top Level") { model.move(tab.id, into: nil) }
            ForEach(model.state.folders.filter { $0.spaceID == model.state.selectedSpaceID }) { folder in
                Button(folder.name) { model.move(tab.id, into: folder.id) }
            }
        }
        Menu("Move to Space") {
            ForEach(model.state.spaces) { space in Button(space.name) { model.move(tab.id, to: space.id) } }
        }
        if tab.kind == .today { Divider(); Button("Archive Tab") { model.archive(tab.id) } }
    }
}

private struct NavigationControls: View {
    @ObservedObject var page: BrowserPage
    var body: some View {
        HStack(spacing: 12) {
            Button { page.webView.goBack() } label: { Image(systemName: "arrow.left") }.disabled(!page.canGoBack).accessibilityLabel("Back")
            Button { page.webView.goForward() } label: { Image(systemName: "arrow.right") }.disabled(!page.canGoForward).accessibilityLabel("Forward")
            Button { if page.loading { page.webView.stopLoading() } else { page.webView.reload() } } label: {
                Image(systemName: page.loading ? "xmark" : "arrow.clockwise")
            }.accessibilityLabel(page.loading ? "Stop loading" : "Reload")
        }
    }
}
