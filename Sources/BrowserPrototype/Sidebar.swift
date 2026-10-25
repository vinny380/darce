import AppKit
import BrowserCore
import SwiftUI

struct BrowserSidebar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var appearance: AppearanceController
    @Binding var showArchive: Bool
    @Binding var showNewSpace: Bool
    @Binding var showNewFolder: Bool
    var spaceSlide: CGFloat = 0
    var spaceSlideProgress: CGFloat = 0
    /// Shown over the page from the window's left edge while the sidebar is hidden: the window buttons stay put,
    /// and the sidebar button pins it open.
    var floating = false
    @Environment(\.colorScheme) private var scheme
    private enum RenameTarget { case folder(UUID), tab(UUID), space(UUID) }
    private enum RemovalTarget { case folder(UUID), space(UUID) }
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var removalTarget: RemovalTarget?
    /// The drop zone under the pointer during a drag, so it can show where the tab will land.
    @State private var dropTarget: String?
    /// Profiles that closed the empty-Favorites card, comma-separated (Arc keeps this per profile too).
    @AppStorage("favoritesEmptyStateDismissedForProfiles") private var favoritesHintDismissed = ""
    /// The tab being dragged from this sidebar, so drop previews can show it.
    @State private var draggingTab: UUID?
    @State private var headerHovered = false
    @State private var windowControlsVisible = false
    @State private var showCreate = false
    @State private var rowWidth: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func draggedTab(_ values: [String]) -> UUID? { values.first.flatMap(UUID.init(uuidString:)) }
    private func draggedFolder(_ values: [String]) -> UUID? {
        values.first.flatMap { $0.hasPrefix("folder:") ? UUID(uuidString: String($0.dropFirst(7))) : nil }
    }
    private func targeting(_ zone: String) -> (Bool) -> Void {
        { inside in if inside { dropTarget = zone } else if dropTarget == zone { dropTarget = nil } }
    }

    private var pinnedExpanded: Bool { !appearance.state.space(model.state.selectedSpaceID).pinnedCollapsed }
    private var closedFolders: Set<UUID> { appearance.state.space(model.state.selectedSpaceID).collapsedFolderIDs }

    var body: some View {
        VStack(spacing: 8) {
            // Like Arc: the sidebar button sits at the leading edge, and the window buttons fade in (pushing it
            // aside) only while the pointer is on this row.
            HStack(spacing: 0) {
                Color.clear.frame(width: windowControlsVisible || floating ? 64 : 4)
                Button { model.sidebarVisible = floating } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel(floating ? "Keep Sidebar Open" : "Hide Sidebar").help(floating ? "Keep Sidebar Open (⌘S)" : "Hide Sidebar (⌘S)")
                Spacer()
                if let id = model.state.selectedTabID, let page = model.page(for: id) { NavigationControls(page: page, model: model) }
            }.buttonStyle(.plain).font(.system(size: 14, weight: .regular)).foregroundStyle(.secondary).frame(height: 33)
            .background {
                if !floating {
                    PointerRegion { inside in
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { windowControlsVisible = inside }
                    }
                    WindowControlsVisibility(visible: windowControlsVisible)
                }
            }
            AddressBar(model: model)
            favorites
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: appearance.state.space(model.state.selectedSpaceID).icon)
                            .font(.system(size: 11))
                        Text(model.state.spaces.first { $0.id == model.state.selectedSpaceID }?.name ?? "Space")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let space = model.state.spaces.first(where: { $0.id == model.state.selectedSpaceID }) {
                            Menu { spaceActions(space) } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)) }
                                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                                .opacity(headerHovered ? 1 : 0).accessibilityLabel("Space options")
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(pinnedExpanded ? 90 : 0))
                    }.padding(.horizontal, 10).padding(.top, 13).padding(.bottom, 9).foregroundStyle(.primary.opacity(0.65))
                    .background(dropTarget == "pinned" ? Color.accentColor.opacity(0.15)
                                : headerHovered ? Palette.color("SidebarItemHovered", scheme: scheme) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                    // The whole row toggles, like Arc; the arrow is only the indicator.
                    .onTapGesture { togglePinned() }
                    .onHover { headerHovered = $0 }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: pinnedExpanded ? "Collapse Pinned Tabs" : "Expand Pinned Tabs") { togglePinned() }
                    .dropDestination(for: String.self) { values, _ in
                        if let folder = draggedFolder(values) {
                            var moved = false
                            model.stateUpdate { moved = $0.moveFolder(folder, to: nil) }
                            return moved
                        }
                        return draggedTab(values).map { model.place($0, kind: .pinned) } ?? false
                    } isTargeted: { targeting("pinned")($0) }
                    .contextMenu {
                        if let space = model.state.spaces.first(where: { $0.id == model.state.selectedSpaceID }) { spaceActions(space) }
                    }
                    // Pinned tabs slide down from behind the header; everything below glides to make room.
                    VStack(spacing: 0) {
                        if pinnedExpanded { folderContents(parent: nil).transition(revealTransition) }
                    }.clipped()
                    HStack(spacing: 8) {
                        Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
                        if model.state.visibleTabs.contains(where: { $0.kind == .today }) {
                            Button { model.clearTodayTabs() } label: {
                                Label("Clear", systemImage: "arrow.down").font(.system(size: 11, weight: .medium))
                            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Archive all Today tabs (⇧⌘K)")
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 12)
                    Button { model.commandMode = .newTab } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "plus").frame(width: 16)
                            Text("New Tab")
                            Spacer()
                            Text("⌘T").font(.system(size: 11)).opacity(0.6)
                        }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .overlay(alignment: .bottom) { insertionLine(dropTarget == "today-top") }
                    .dropDestination(for: String.self) { values, _ in
                        let first = model.state.visibleTabs.first { $0.kind == .today }?.id
                        return draggedTab(values).map { model.place($0, kind: .today, before: first) } ?? false
                    } isTargeted: { targeting("today-top")($0) }
                    ForEach(model.state.visibleTabs.filter { $0.kind == .today }) { tab in sidebarItem(tab) }
                    // Empty space below Today: drop to add at the end.
                    Color.clear.frame(maxWidth: .infinity, minHeight: 80).contentShape(Rectangle())
                        .overlay(alignment: .top) { insertionLine(dropTarget == "today-end") }
                        .dropDestination(for: String.self) { values, _ in
                            draggedTab(values).map { model.place($0, kind: .today) } ?? false
                        } isTargeted: { targeting("today-end")($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.state.visibleTabs.map(\.id))
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.state.visibleTabs.map(\.folderID))
            }.scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)  // sideways swipes belong to Space switching
            .offset(x: spaceSlide)
            .opacity(1 - 0.75 * spaceSlideProgress)
            .clipped()  // the slide stays inside the sidebar
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
                    .scaleEffect(dropTarget == "space:\(space.id)" ? 1.25 : 1)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: dropTarget)
                    .dropDestination(for: String.self) { values, _ in
                        guard let id = draggedTab(values), model.state.tabs.contains(where: { $0.id == id }) else { return false }
                        model.move(id, to: space.id)
                        return true
                    } isTargeted: { targeting("space:\(space.id)")($0) }
                }
                Spacer(minLength: 4)
                // Like Arc: "+" turns into "×" while its create panel is open.
                Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showCreate.toggle() } } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                        .rotationEffect(.degrees(showCreate ? 45 : 0)).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(showCreate ? "Close" : "Create")
                .popover(isPresented: $showCreate, arrowEdge: .top) {
                    CreatePanel(model: model, close: { showCreate = false },
                                newSpace: { showNewSpace = true }, newFolder: { showNewFolder = true })
                }
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.7)).padding(.top, 4)
        }
        .padding(.horizontal, 8).padding(.bottom, 10)
        .alert(renameTitle, isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { submitRename() }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .onChange(of: removalTarget != nil) { _, asking in
            guard asking else { return }
            let symbol = if case .folder = removalTarget { "folder" } else { "rectangle.stack" }
            DialogCenter.shared.present(DialogRequest(title: removalTitle, message: removalMessage, symbol: symbol, actions: [
                .init(title: "Cancel", role: .cancel) { removalTarget = nil },
                .init(title: removalTarget.map { if case .space = $0 { "Delete" } else { "Remove" } } ?? "Remove", role: .destructive) { submitRemoval() },
            ]), in: model)
        }
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
        case .space(let id): "Delete “\(model.state.spaces.first { $0.id == id }?.name ?? "Space")”?"
        case nil: "Remove Container?"
        }
    }

    private var removalMessage: String {
        switch removalTarget {
        case .folder(let id):
            let parent = model.state.folders.first { $0.id == id }?.parentID
            let location = model.state.folders.first { $0.id == parent }?.name ?? "the top level of this Space"
            return "Its tabs and child folders will move to \(location). No tabs will be deleted."
        case .space(let id):
            let profile = model.state.spaces.first { $0.id == id }?.profileID
            if model.state.spaces.contains(where: { $0.id != id && $0.profileID == profile }) {
                return "Its pinned and open tabs move to the Archive, where ⇧⌘T can bring them back. Its folders are removed."
            }
            return "This is the last Space in its profile, so its tabs, Favorites, and folders will be deleted."
        case nil: return ""
        }
    }

    private func submitRemoval() {
        guard let target = removalTarget else { return }
        var removed = false
        model.stateUpdate { state in
            switch target {
            case .folder(let id): removed = state.deleteFolder(id)
            case .space(let id): removed = state.deleteSpace(id)
            }
        }
        if !removed { model.errorMessage = "This could not be removed. It may have moved, or it's the only Space." }
        removalTarget = nil
    }

    @ViewBuilder private func spaceActions(_ space: BrowserSpace) -> some View {
        // Arc's Space menu, minus Live Folders and Share Space, which D'arce doesn't have.
        Button("Change Space Icon…") { model.selectSpace(space.id); model.panel = .appearance }
        Button("Rename Space…") { renameText = space.name; renameTarget = .space(space.id) }
        Button("Edit Theme Color…") { model.selectSpace(space.id); model.panel = .appearance }
        Menu("Set Profile") {
            ForEach(model.state.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { profile.id == space.profileID },
                                                   set: { if $0 { model.assignProfile(profile.id, to: space.id) } }))
            }
            Divider()
            Button("New Profile…") { model.panel = .profiles }
        }
        Divider()
        Button("New Folder") { model.selectSpace(space.id); showNewFolder = true }
        Divider()
        let destinations = model.state.spaces.filter { $0.id != space.id && $0.profileID == space.profileID }
        Menu("Export “\(space.name)” into Folder") {
            ForEach(destinations) { destination in
                Button(destination.name) {
                    var moved = false
                    model.stateUpdate { moved = $0.exportSpaceIntoFolder(space.id, to: destination.id) }
                    if moved { model.selectSpace(destination.id) }
                }
            }
        }.disabled(destinations.isEmpty)
        Divider()
        Button("Manage Spaces…") { model.panel = .spaces }
        Divider()
        Button("Delete Space", role: .destructive) { removalTarget = .space(space.id) }
            .disabled(model.state.spaces.count < 2)
    }

    private var favorites: some View {
        let tabs = model.state.visibleTabs.filter { $0.kind == .favorite }
        let profile = model.state.selectedProfileID.uuidString
        let showsHint = tabs.isEmpty && !favoritesHintDismissed.split(separator: ",").contains(Substring(profile))
        return Group {
            if showsHint {
                favoritesHint { favoritesHintDismissed = favoritesHintDismissed.isEmpty ? profile : favoritesHintDismissed + "," + profile }
            } else {
                favoritesGrid(tabs)
            }
        }
        .padding(.top, tabs.isEmpty && !showsHint ? 0 : 6)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: tabs.map(\.id))
        .dropDestination(for: String.self) { values, _ in
            draggedTab(values).map { model.place($0, kind: .favorite) } ?? false
        } isTargeted: { targeting("favorites")($0) }
    }

    private func favoritesHint(dismiss: @escaping () -> Void) -> some View {
        let targeted = dropTarget == "favorites"
        return VStack(spacing: 3) {
            Image(systemName: "star.circle.fill").font(.system(size: 17)).padding(.bottom, 3)
            Text("Drag to add Favorites").font(.system(size: 12, weight: .semibold))
            Text("Favorites keep your most used sites and apps close")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(targeted ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(targeted ? Color.accentColor : Color.primary.opacity(0.25))
        }
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).padding(8) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss Favorites tip")
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: targeted)
    }

    private func favoritesGrid(_ tabs: [BrowserTab]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: min(max(tabs.count, 1), 3)), spacing: 7) {
            ForEach(tabs) { tab in
                SiteIcon(controller: model.favicons, url: tab.url, saved: model.state.savedFaviconPNG(forTab: tab.id),
                         profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 24)
                    .foregroundStyle(.primary.opacity(0.75)).frame(maxWidth: .infinity).frame(height: 50)
                    .background(Palette.color(model.state.selectedTabID == tab.id ? "SidebarItemHovered" : "SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle()).onTapGesture { model.select(tab.id) }
                    .help(tab.title).accessibilityElement().accessibilityAddTraits(.isButton)
                    .accessibilityLabel("\(tab.title), favorite").accessibilityAction { model.select(tab.id) }
                    .contextMenu { tabActions(tab) }
                    .tabDragSource(tab.id, dragging: $draggingTab) { dragPreview(tab) }
                    .overlay(alignment: .leading) {
                        if dropTarget == "tab:\(tab.id)" {
                            Capsule().fill(Color.accentColor).frame(width: 3, height: 30).offset(x: -5)
                        }
                    }
                    .dropDestination(for: String.self) { values, _ in
                        draggedTab(values).map { model.place($0, kind: .favorite, before: tab.id) } ?? false
                    } isTargeted: { targeting("tab:\(tab.id)")($0) }
            }
        }
        .frame(minHeight: tabs.isEmpty ? 10 : 0)
        .overlay {
            if tabs.isEmpty, dropTarget == "favorites" {
                Text("Add to Favorites").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func folderContents(parent: UUID?) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 3) {
            ForEach(model.state.folders.filter { $0.spaceID == model.state.selectedSpaceID && $0.parentID == parent }) { folder in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        Image(systemName: closedFolders.contains(folder.id) ? "folder" : "folder.fill").frame(width: 16)
                        Text(folder.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9))
                            .rotationEffect(.degrees(closedFolders.contains(folder.id) ? 0 : 90))
                    }.font(.system(size: 13)).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                    .onTapGesture { toggleFolder(folder.id) }
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleFolder(folder.id) }
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
                        guard let id = UUID(uuidString: raw) else { return false }
                        return model.place(id, kind: .pinned, folder: folder.id)
                    } isTargeted: { targeting("folder:\(folder.id)")($0) }
                    .background(dropTarget == "folder:\(folder.id)" ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    VStack(spacing: 0) {
                        if !closedFolders.contains(folder.id) { folderContents(parent: folder.id).padding(.leading, 14).transition(revealTransition) }
                    }.clipped()
                }
            }
            ForEach(model.state.visibleTabs.filter { $0.kind == .pinned && $0.folderID == parent }) { tab in sidebarItem(tab) }
        })
    }

    private var revealTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    private func togglePinned() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            appearance.update { $0.spaces[model.state.selectedSpaceID, default: SpaceAppearance()].pinnedCollapsed.toggle() }
        }
    }

    private func toggleFolder(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { toggleFolderState(id) }
    }

    private func toggleFolderState(_ id: UUID) {
        appearance.update { preferences in
            var settings = preferences.space(model.state.selectedSpaceID)
            if settings.collapsedFolderIDs.contains(id) { settings.collapsedFolderIDs.remove(id) }
            else { settings.collapsedFolderIDs.insert(id) }
            preferences.spaces[model.state.selectedSpaceID] = settings
        }
    }

    private func isRenamingTab(_ id: UUID) -> Bool {
        if case .tab(let editingID) = renameTarget { return editingID == id }
        return false
    }

    func tabRow(_ tab: BrowserTab) -> some View {
        ZStack {
            if let slot = splitSlot(over: tab.id) {
                splitLayout([tab.id], placeholderAt: slot, displayed: false)
            } else {
                SidebarTabRow(tab: tab, selected: model.state.selectedTabID == tab.id,
                              canReset: model.canResetSidebarTab(tab.id, isEditing: isRenamingTab(tab.id)),
                              contentVisible: model.state.displayedTabIDs.contains(tab.id),
                              semanticPalette: appearance.semanticPalette(forSpace: model.state.selectedSpaceID),
                              icon: SiteIcon(controller: model.favicons, url: tab.url, saved: model.state.savedFaviconPNG(forTab: tab.id),
                                             profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 16,
                                             usesInheritedForeground: true),
                              select: { model.select(tab.id) }, reset: {
                                  guard model.canResetSidebarTab(tab.id, isEditing: isRenamingTab(tab.id)) else { return }
                                  model.resetPin(tab.id)
                              }, close: { model.archive(tab.id) })
                    // Arc marks Developer Mode tabs with a dashed outline.
                    .overlay {
                        if model.isDeveloperTab(tab) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .padding(.vertical, 1).allowsHitTesting(false)
                        }
                    }
                    .contextMenu { tabActions(tab) }
                    .tabDragSource(tab.id, dragging: $draggingTab) { dragPreview(tab) }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: dropTarget)
        .overlay(alignment: .top) { insertionLine(dropTarget == "tab:\(tab.id)").offset(y: -2) }
        .onDrop(of: [.plainText], delegate: dropDelegate(onto: tab, slots: draggingTab == tab.id ? 0 : 1))
    }

    private func dropDelegate(onto tab: BrowserTab, slots: Int) -> TabDropDelegate {
        TabDropDelegate(id: tab.id, width: rowWidth, slots: slots, target: $dropTarget) { [model] dragged, slot in
            if let slot { model.splitTab(dragged, onto: tab.id, at: slot) }
            else { model.place(dragged, kind: tab.kind, folder: tab.folderID, before: tab.id) }
        }
    }

    /// The split slot the pointer is over for this row, if a drop here would split.
    private func splitSlot(over id: UUID) -> Int? {
        guard let target = dropTarget, target.hasPrefix("split:\(id.uuidString):") else { return nil }
        return Int(target.split(separator: ":").last ?? "")
    }

    /// A split shows once in the sidebar, at its first non-Favorite tab; the other panes ride along in that row.
    @ViewBuilder private func sidebarItem(_ tab: BrowserTab) -> some View {
        if let group = model.state.splitGroups.first(where: { $0.tabIDs.contains(tab.id) }) {
            if model.state.visibleTabs.first(where: { $0.kind != .favorite && group.tabIDs.contains($0.id) })?.id == tab.id {
                splitRow(group, leader: tab)
            }
        } else { tabRow(tab) }
    }

    private func splitRow(_ group: BrowserSplitGroup, leader: BrowserTab) -> some View {
        let displayed = group.tabIDs.contains { $0 == model.state.selectedTabID }
        // While hovering, the dragged tab's chip leaves its old slot and a placeholder opens where it would land.
        let others = group.tabIDs.filter { $0 != draggingTab }
        let slots = others.count < group.tabIDs.count || group.tabIDs.count < 4 ? others.count : 0
        let slot = splitSlot(over: leader.id)
        return splitLayout(slot == nil ? group.tabIDs : others, placeholderAt: slot, displayed: displayed)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: dropTarget)
            .overlay(alignment: .top) { insertionLine(dropTarget == "tab:\(leader.id)").offset(y: -2) }
            .onDrop(of: [.plainText], delegate: dropDelegate(onto: leader, slots: slots))
            .accessibilityElement(children: .contain).accessibilityLabel("Split view, \(group.tabIDs.count) tabs")
    }

    private enum SplitChip: Hashable { case tab(UUID), placeholder }

    /// One row of side-by-side chips; with `placeholderAt`, a lighter chip for the dragged tab opens at that slot.
    private func splitLayout(_ ids: [UUID], placeholderAt slot: Int?, displayed: Bool) -> some View {
        var chips = ids.map(SplitChip.tab)
        if let slot { chips.insert(.placeholder, at: max(0, min(slot, chips.count))) }
        return HStack(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                switch chip {
                case .tab(let id):
                    if let tab = model.state.tabs.first(where: { $0.id == id }) { splitChip(tab) }
                case .placeholder:
                    placeholderChip
                }
            }
        }
        .padding(3)
        .background(Palette.color(displayed || slot != nil ? "TabCellBackgroundContentVisible" : "SidebarItemBackground", scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholderChip: some View {
        HStack(spacing: 7) {
            if let id = draggingTab, let tab = model.state.tabs.first(where: { $0.id == id }) {
                SiteIcon(controller: model.favicons, url: tab.url, saved: model.state.savedFaviconPNG(forTab: tab.id),
                         profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 14)
                Text(tab.title).font(.system(size: 13)).lineLimit(1)
            }
        }
        .padding(.horizontal, 9).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
        .background(Palette.color("TabCellBackgroundCurrent", scheme: scheme).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .foregroundStyle(.primary.opacity(0.55))
        .transition(.scale(scale: 0.6, anchor: .center).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func splitChip(_ tab: BrowserTab) -> some View {
        let focused = model.state.selectedTabID == tab.id
        return HStack(spacing: 7) {
                SiteIcon(controller: model.favicons, url: tab.url, saved: model.state.savedFaviconPNG(forTab: tab.id),
                         profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 14)
                Text(tab.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            }
        .padding(.horizontal, 9).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
        .background(Palette.color(focused ? "TabCellBackgroundCurrent" : "SidebarItemBackground", scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle()).onTapGesture { model.select(tab.id) }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction { model.select(tab.id) }
        .foregroundStyle(.primary.opacity(focused ? 0.9 : 0.75)).help(tab.title)
        .contextMenu {
            Button("Separate from Split View") { model.stateUpdate { _ = $0.removeFromSplit(tab.id) } }
            Divider()
            tabActions(tab)
        }
        .tabDragSource(tab.id, dragging: $draggingTab) { dragPreview(tab) }
    }

    /// What follows the pointer: the tab as a lifted sidebar row, like Arc.
    private func dragPreview(_ tab: BrowserTab) -> some View {
        HStack(spacing: 10) {
            SiteIcon(controller: model.favicons, url: tab.url, saved: model.state.savedFaviconPNG(forTab: tab.id),
                     profileID: model.state.profileID(forTab: tab.id) ?? model.state.selectedProfileID, size: 16)
            Text(tab.title).font(.system(size: 14)).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).opacity(0.6)
        }
        .padding(.horizontal, 12).frame(width: max(rowWidth, 160), height: 36)
        .foregroundStyle(.primary.opacity(0.85))
        .background(Palette.color("TabCellBackgroundCurrent", scheme: scheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, scheme)
    }

    /// Where a dragged tab will land: Arc's line with a ring at its start.
    @ViewBuilder private func insertionLine(_ visible: Bool) -> some View {
        if visible {
            HStack(spacing: 0) {
                Circle().strokeBorder(.primary.opacity(0.8), lineWidth: 1.5).frame(width: 7, height: 7)
                Rectangle().fill(.primary.opacity(0.8)).frame(height: 1.5)
            }
            .padding(.leading, 4).padding(.trailing, 8).allowsHitTesting(false)
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
    @ObservedObject var model: BrowserModel
    var body: some View {
        HStack(spacing: 12) {
            Button { page.webView.goBack() } label: { Image(systemName: "arrow.left") }.disabled(!page.canGoBack).accessibilityLabel("Back")
            Button { page.webView.goForward() } label: { Image(systemName: "arrow.right") }.disabled(!page.canGoForward).accessibilityLabel("Forward")
            if model.isDeveloperModeOn && !page.loading {
                // Developer Mode adds Arc's reload options.
                Menu {
                    Button("Refresh (Ignore Cache)") { page.webView.reloadFromOrigin() }
                    Button("Clear Cookies and Refresh") { model.clearCookiesAndReload() }
                } label: { Image(systemName: "arrow.clockwise") } primaryAction: { page.webView.reload() }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.visible).fixedSize().accessibilityLabel("Reload options")
            } else {
                Button { if page.loading { page.webView.stopLoading() } else { page.webView.reload() } } label: {
                    Image(systemName: page.loading ? "xmark" : "arrow.clockwise")
                }.accessibilityLabel(page.loading ? "Stop loading" : "Reload")
            }
        }
    }
}
