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
            SpacesMenu(model: activeModel, privateWindows: privateWindows)
            CommandGroup(replacing: .appTermination) {
                Button("Quit D'arce") { QuitConfirmation.request(primary: model) }.keyboardShortcut("q")
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
                Button("New Mini Window") { MiniWindows.shared.openLauncher() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Reopen Last Archived Tab") { activeModel.reopenLastArchived() }.keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(privateWindows.isPrivateWindowActive || activeModel.archivedTabs.isEmpty)
                Button("Open Location") {
                    if let mini = MiniWindows.shared.active { MiniWindows.shared.openLauncher(for: mini) }
                    else if let session = privateWindows.activeSession { session.focusAddress() }
                    else { activeModel.commandMode = .location }
                }.keyboardShortcut("l")
                // Arc's ⌘O (openInCurrentSpace:): a focused mini window or an open Peek becomes a tab in the main window.
                Button("Open Mini Window or Peek in D'arce") {
                    if let mini = MiniWindows.shared.active { mini.openInMain() }
                    else if activeModel.peekPage != nil { activeModel.promotePeek() }
                }.keyboardShortcut("o")
                Divider()
                Button("Import Bookmarks…") { activeModel.importBookmarks() }.disabled(privateWindows.isPrivateWindowActive)
                Button("Export Bookmarks…") { activeModel.exportBookmarks() }.disabled(privateWindows.isPrivateWindowActive)
                Divider()
                Button("Print…") { activePage?.printPage() }.keyboardShortcut("p").disabled(activePage == nil)
                Button("Save as PDF…") { activePage?.savePDF() }.disabled(activePage == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button(privateWindows.isPrivateWindowActive ? "Close Private Tab" : "Close Tab") {
                    if let mini = MiniWindows.shared.active { mini.onClose?() }
                    else if let session = privateWindows.activeSession { session.closeSelectedTab() }
                    else if activeModel.state.selectedTab != nil { activeModel.closeCurrentTab() }
                    else { NSApplication.shared.keyWindow?.performClose(nil) }  // nothing open: ⌘W closes the window
                }.keyboardShortcut("w")
                Button("Close Browser Window") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Menu("Developer") {
                    Button(activeModel.isDeveloperModeOn ? "Turn Off Developer Mode for This Site" : "Turn On Developer Mode for This Site") {
                        activeModel.toggleDeveloperMode()
                    }.keyboardShortcut("d", modifiers: .control)
                    Divider()
                    Button("Developer Tools") { activeModel.openInspector(.tools) }.keyboardShortcut("i", modifiers: [.command, .option])
                    Button("JavaScript Console") { activeModel.openInspector(.console) }.keyboardShortcut("j", modifiers: [.command, .option])
                    Button("Inspect Elements") { activeModel.openInspector(.pickElement) }.keyboardShortcut("c", modifiers: [.command, .option])
                    Button("Network and Resources") { activeModel.openInspector(.resources) }
                }.disabled(privateWindows.isPrivateWindowActive || activeModel.state.selectedTab == nil)
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
                Button("Edit Boost") { activeModel.boostPanelOpen = true }.disabled(activeModel.state.selectedTab?.url.host == nil)
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
            }
            }
}
