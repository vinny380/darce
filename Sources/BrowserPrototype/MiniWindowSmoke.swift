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

/// Launcher contract (⌥⌘N, like Little Arc's command bar): with nothing typed it offers your Favorites and pins
/// first, one row per site; typed text goes straight to that site or search; choosing opens a mini window, or
/// navigates the mini window that summoned it.
@MainActor
func runMiniLauncherSmoke(model: BrowserModel) -> [String: Bool] {
    let favorite = URL(string: "https://launcher-favorite.invalid/home")!
    model.open(favorite)
    if let id = model.state.selectedTabID { model.pin(id, kind: .favorite) }
    model.open(URL(string: "https://launcher-favorite.invalid/other-page")!)
    let suggestions = MiniLauncher.items(for: "", model: model)
    var checks = ["launcher_offers_favorites_first": suggestions.first?.url.host == favorite.host]
    checks["launcher_lists_each_site_once"] = Set(suggestions.compactMap(\.url.host)).count == suggestions.count
    checks["launcher_caps_suggestions"] = suggestions.count <= 6
    let typed = MiniLauncher.items(for: "example.com", model: model)
    checks["launcher_typed_site_comes_first"] = typed.first?.url == URL(string: "https://example.com")
    let before = MiniWindows.shared.count
    if let first = typed.first { MiniLauncher.choose(first, target: nil, model: model) }
    checks["launcher_choice_opens_mini_window"] = MiniWindows.shared.count == before + 1
    if let mini = MiniWindows.shared.newest, let first = suggestions.first {
        MiniLauncher.choose(first, target: mini, model: model)
        checks["launcher_from_mini_window_navigates_it"] = MiniWindows.shared.count == before + 1 && mini.currentURL?.host == favorite.host
    }
    MiniWindows.shared.closeAll()
    return checks
}
