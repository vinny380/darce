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

    // Modified clicks on a page link: ⌥⌘ opens a mini window, ⇧ opens a Peek, and each can be turned off.
    guard let id = model.state.selectedTabID, let page = model.page(for: id) else { checks["modified_click_page"] = false; return checks }
    let link = URL(string: "https://modified-click-fixture.invalid/")!
    checks["option_command_click_opens_mini_window"] = page.onModifiedLink?(link, [.option, .command]) == true
        && MiniWindows.shared.count == before + 1
    MiniWindows.shared.closeAll()
    checks["shift_click_opens_peek"] = page.onModifiedLink?(link, [.shift]) == true && model.peekPage != nil
    model.closePeek()
    model.settings.update { $0.shiftClickOpensPeek = false }
    checks["shift_click_peek_can_be_turned_off"] = page.onModifiedLink?(link, [.shift]) == false && model.peekPage == nil
    model.settings.update { $0.shiftClickOpensPeek = true }
    checks["plain_command_click_is_left_to_webkit"] = page.onModifiedLink?(link, [.command]) == false
    return checks
}
