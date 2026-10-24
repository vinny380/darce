import AppKit
import Foundation

/// Mini window contract: opens on the main window's signed-in profile, and "Open in D'arce" moves the page into
/// the main window as the selected tab and closes the mini window.
@MainActor
func runMiniWindowSmoke(model: BrowserModel) -> [String: Bool] {
    let url = URL(string: "https://mini-window-fixture.invalid/page")!
    let before = MiniWindows.shared.count
    let mini = MiniWindows.shared.open(url: url, model: model)
    var checks = ["mini_window_opens": MiniWindows.shared.count == before + 1]
    checks["mini_window_uses_main_profile_data"] = mini?.page?.webView.configuration.websiteDataStore
        === model.dataStore(for: model.state.selectedProfileID)
    mini?.openInMain()
    checks["mini_open_in_main_adds_selected_tab"] = model.state.selectedTab?.url == url
    checks["mini_window_closes_after_moving"] = MiniWindows.shared.count == before
    return checks
}
