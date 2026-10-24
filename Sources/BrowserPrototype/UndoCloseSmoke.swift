import AppKit
import Foundation

/// ⌘Z contract: closing a tab registers "Undo Close Tab" on the window, and undoing it brings the tab back selected.
@MainActor
func runUndoCloseSmoke(model: BrowserModel) -> [String: Bool] {
    let url = URL(string: "https://undo-close-fixture.invalid/")!
    model.open(url)
    guard let id = model.state.selectedTabID, let manager = BrowserWindows.shared.window(for: model)?.undoManager else {
        return ["undo_close_has_window_undo_manager": false]
    }
    model.archive(id)
    var checks = ["undo_close_archives_tab": model.state.tabs.first { $0.id == id }?.kind == .archived]
    checks["undo_close_is_offered"] = manager.canUndo && manager.undoActionName == "Close Tab"
    manager.undo()
    checks["undo_close_brings_tab_back_selected"] = model.state.tabs.first { $0.id == id }?.kind == .today && model.state.selectedTabID == id
    return checks
}

/// Developer Mode contract: ⌃D toggles the current site only, and WebKit's inspector is reachable for the buttons.
@MainActor
func runDeveloperModeSmoke(model: BrowserModel) -> [String: Bool] {
    model.open(URL(string: "https://developer-mode-fixture.invalid/")!)
    guard let page = model.selectedPage else { return ["developer_mode_has_page": false] }
    var checks = ["developer_mode_starts_off": !model.isDeveloperModeOn]
    model.toggleDeveloperMode()
    checks["developer_mode_toggles_on_for_site"] = model.isDeveloperModeOn
    checks["developer_tab_is_marked"] = model.state.selectedTab.map(model.isDeveloperTab) == true
    model.toggleDeveloperMode()
    checks["developer_mode_toggles_off"] = !model.isDeveloperModeOn
    checks["web_inspector_reachable"] = WebInspector.isAvailable(page.webView)
    return checks
}
