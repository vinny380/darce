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

/// Arc-style dialog contract: shows over the window that asked, and a button runs its action and closes it.
@MainActor
func runDialogSmoke(model: BrowserModel) -> [String: Bool] {
    var cancelled = false
    DialogCenter.shared.present(DialogRequest(title: "Smoke?", actions: [
        .init(title: "Cancel", role: .cancel) { cancelled = true },
        .init(title: "OK", role: .primary) {},
    ]), in: model)
    var checks = ["dialog_shows_over_its_window": DialogCenter.shared.current != nil && DialogCenter.shared.host === model]
    if let cancel = DialogCenter.shared.current?.actions.first(where: { $0.role == .cancel }) { DialogCenter.shared.perform(cancel) }
    checks["dialog_button_runs_and_closes"] = cancelled && DialogCenter.shared.current == nil
    checks["quit_confirmation_off_in_smoke_runs"] = !QuitConfirmation.enabled
    return checks
}

/// ⌘W on a pinned tab or Favorite, like Arc: the page closes, the pin stays in the sidebar, and selection moves on.
@MainActor
func runClosePinnedSmoke(model: BrowserModel) -> [String: Bool] {
    model.open(URL(string: "https://close-other.invalid/")!)
    guard let other = model.state.selectedTabID else { return ["close_pinned_has_tab": false] }
    model.open(URL(string: "https://close-pinned.invalid/")!)
    guard let pinned = model.state.selectedTabID else { return ["close_pinned_has_tab": false] }
    model.pin(pinned, kind: .pinned)
    _ = model.page(for: pinned)
    model.closeCurrentTab()
    var checks = ["close_pinned_keeps_pin": model.state.tabs.first { $0.id == pinned }?.kind == .pinned]
    checks["close_pinned_unloads_page"] = model.loadedPage(pinned) == nil
    checks["close_pinned_selects_previous_tab"] = model.state.selectedTabID == other
    model.closeCurrentTab()
    checks["close_today_still_archives"] = model.state.tabs.first { $0.id == other }?.kind == .archived
    return checks
}

/// Easel contract (Arc's ⌃⇧E): a new Easel opens as a sidebar item that draws a canvas (never a web page),
/// survives being reopened, and closing it keeps the Easel itself.
@MainActor
func runEaselSmoke(model: BrowserModel) -> [String: Bool] {
    let before = model.documents.documents(profileID: model.state.selectedProfileID).count
    model.newEasel()
    guard let tab = model.state.selectedTab, let easel = tab.url.easelID else { return ["easel_opens_as_tab": false] }
    var checks = ["easel_opens_as_tab": tab.title == "Untitled Easel"]
    checks["easel_document_created"] = model.documents.documents(profileID: model.state.selectedProfileID).count == before + 1
    checks["easel_never_loads_a_web_page"] = model.page(for: tab.id) == nil
    let shape = model.documents.addCard(.shape(.rectangle, color: "#FF5A5F"), to: easel, profileID: model.state.selectedProfileID,
                                        frame: CGRect(x: 100, y: 120, width: 200, height: 120))
    checks["easel_drawing_saved"] = shape != nil
    model.closeCurrentTab()
    checks["easel_kept_after_closing_tab"] = model.documents.document(easel, profileID: model.state.selectedProfileID)?.cards.count == 1
    model.openEasel(easel)
    checks["easel_reopens_from_library"] = model.state.selectedTab?.url.easelID == easel
    return checks
}

/// Saved tab icons: once a pinned tab's page shows its icon, the tab keeps it (so Favorites and pins show it before
/// their pages load), and the sidebar icon falls back to it.
@MainActor
func runSavedIconSmoke(model: BrowserModel) async -> [String: Bool] {
    let red = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    model.open(URL(string: "https://saved-icon-fixture.invalid/")!)
    guard let id = model.state.selectedTabID, let page = model.page(for: id) else { return ["saved_icon_has_page": false] }
    model.pin(id, kind: .pinned)
    page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://saved-icon-fixture.invalid/")!),
                                      responseHTML: "<title>Icon</title><link rel='icon' href='data:image/png;base64,\(red)'>")
    var saved: Data?
    for _ in 0..<100 {
        saved = model.state.savedFaviconPNG(forTab: id)
        if saved != nil { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return ["saved_icon_kept_on_tab": saved != nil,
            "saved_icon_is_a_png": saved?.starts(with: [137, 80, 78, 71]) == true]
}
