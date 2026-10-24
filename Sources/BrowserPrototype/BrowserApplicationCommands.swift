import AppKit
import BrowserCore
import SwiftUI

/// Observe window/session changes where SwiftUI owns menu validation, not in a captured App scene closure.
struct BrowserApplicationCommands: Commands {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var privateWindows = PrivateBrowserWindows.shared
    @ObservedObject private var normalWindows = BrowserWindows.shared

    private var activeModel: BrowserModel { normalWindows.activeModel ?? model }
    private var activePage: BrowserPage? {
        if let session = privateWindows.activeSession { return session.selectedPage }
        return activeModel.state.selectedTabID.flatMap { activeModel.page(for: $0) }
    }

    var body: some Commands {
            BrowserNavigationCommands(model: activeModel)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { activeModel.panel = .settings }.keyboardShortcut(",")
                    .disabled(privateWindows.isPrivateWindowActive)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    normalWindows.open(workspace: activeModel.workspace, selection: BrowserWindowSelection(state: activeModel.state))
                }.keyboardShortcut("n")
                Button("New Tab") {
                    if let session = privateWindows.activeSession { session.newTab() }
                    else { activeModel.commandMode = .newTab }
                }.keyboardShortcut("t")
                Button("New Private Window") { privateWindows.open() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Reopen Last Archived Tab") { activeModel.reopenLastArchived() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(privateWindows.isPrivateWindowActive || activeModel.archivedTabs.isEmpty)
                Button("Open Location") {
                    if let session = privateWindows.activeSession { session.focusAddress() }
                    else { activeModel.commandMode = .location }
                }.keyboardShortcut("l")
                Divider()
                Button("Import Bookmarks…") { activeModel.importBookmarks() }.disabled(privateWindows.isPrivateWindowActive)
                Button("Export Bookmarks…") { activeModel.exportBookmarks() }.disabled(privateWindows.isPrivateWindowActive)
                Divider()
                Button("Print…") { activePage?.printPage() }.keyboardShortcut("p").disabled(activePage == nil)
                Button("Save as PDF…") { activePage?.savePDF() }.disabled(activePage == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button(privateWindows.isPrivateWindowActive ? "Close Private Tab" : "Archive Current Tab") {
                    if let session = privateWindows.activeSession { session.closeSelectedTab() }
                    else if let id = activeModel.state.selectedTabID { activeModel.archive(id) }
                }.keyboardShortcut("w").disabled(privateWindows.isPrivateWindowActive ? privateWindows.activeSession?.selectedTabID == nil : activeModel.state.selectedTab?.kind != .today)
                Button("Close Browser Window") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowArrangement) {
                Group {
                Button("Pin / Unpin Tab") {
                    if let tab = activeModel.state.selectedTab { activeModel.pin(tab.id, kind: tab.kind == .pinned ? .today : .pinned) }
                }.keyboardShortcut("d").disabled(activeModel.state.selectedTab == nil)
                Button("Reset Pinned Tab") {
                    if let id = activeModel.state.selectedTabID { activeModel.resetPin(id) }
                }.disabled(activeModel.state.selectedTab?.homeURL == nil)
                Divider()
                Button("Toggle Sidebar") { activeModel.sidebarVisible.toggle() }.keyboardShortcut("s")
                Button("Add Split View") { activeModel.commandMode = .split }
                    .keyboardShortcut("=", modifiers: [.control, .shift])
                    .disabled(activeModel.state.selectedTab == nil || (activeModel.state.selectedSplitGroup?.tabIDs.count ?? 0) >= 4)
                Button("Close Split View Pane") { activeModel.closeSelectedPane() }
                    .keyboardShortcut("-", modifiers: [.control, .shift]).disabled(activeModel.state.selectedSplitGroup == nil)
                Button("Separate Tab") {
                    if let group = activeModel.state.selectedSplitGroup, let id = activeModel.state.selectedTabID {
                        activeModel.separatePane(id, from: group.id)
                    }
                }.disabled(activeModel.state.selectedSplitGroup == nil)
                Button("Separate All Tabs") { activeModel.separateAllPanes() }.disabled(activeModel.state.selectedSplitGroup == nil)
                Divider()
                Button("History") { activeModel.panel = .history }.keyboardShortcut("y")
                Button("Clear Browsing Data…") { activeModel.panel = .browsingData }
                Button("Downloads") { activeModel.panel = .downloads }.keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Profiles") { activeModel.panel = .profiles }
                Button("Notes & Easels") { activeModel.panel = .documents }
                Button("Customize Space…") { activeModel.panel = .appearance }
                Button("Boosts…") { activeModel.panel = .boosts }.disabled(activeModel.state.selectedTab?.url.host == nil)
                Button("Hide Element with Boost") { activeModel.pickBoostElement() }.disabled(activeModel.state.selectedTab?.url.host == nil)
                }.disabled(privateWindows.isPrivateWindowActive)
                Divider()
                Button("Find in Page") {
                    if let session = privateWindows.activeSession { session.showFind = true }
                    else { activeModel.showFind = true }
                }.keyboardShortcut("f").disabled(activePage == nil)
                Button("Zoom In") {
                    if let page = activePage { page.webView.pageZoom = min(3, page.webView.pageZoom + 0.1) }
                }.keyboardShortcut("+")
                Button("Zoom Out") {
                    if let page = activePage { page.webView.pageZoom = max(0.25, page.webView.pageZoom - 0.1) }
                }.keyboardShortcut("-")
                Button("Actual Size") {
                    activePage?.webView.pageZoom = 1
                }.keyboardShortcut("0")
                ForEach(Array(activeModel.state.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button("Switch to \(space.name)") { activeModel.selectSpace(space.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                        .disabled(privateWindows.isPrivateWindowActive)
                }
            }
            }
}
