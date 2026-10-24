import Foundation
import WebKit

/// Written before implementation: real WebKit storage checks, no external navigation or dialogs.
@MainActor
func runPrivateBrowsingSmoke() async -> [String: Bool] {
    let first = PrivateBrowserSession()
    let second = PrivateBrowserSession()
    defer { first.shutdown(); second.shutdown() }
    let url = URL(string: "about:blank")!
    first.open(url: url)
    let firstID = first.selectedTabID
    let firstPage = first.selectedPage
    first.open(url: url)
    let secondID = first.selectedTabID
    let secondPage = first.selectedPage
    var checks = [
        "private_store_is_nonpersistent": !first.dataStore.isPersistent && !second.dataStore.isPersistent,
        "private_tabs_share_only_own_window_store": firstPage?.webView.configuration.websiteDataStore === first.dataStore && secondPage?.webView.configuration.websiteDataStore === first.dataStore && first.dataStore !== second.dataStore,
        "private_selection_is_per_window": second.tabs.isEmpty && second.selectedTabID == nil && first.selectedTabID == secondID
    ]
    let cookie = HTTPCookie(properties: [.domain: "private-fixture.invalid", .path: "/", .name: "private-session", .value: UUID().uuidString, .secure: "TRUE"])!
    await first.dataStore.httpCookieStore.setCookie(cookie)
    let ownCookies = await first.dataStore.httpCookieStore.allCookies()
    let otherCookies = await second.dataStore.httpCookieStore.allCookies()
    checks["private_cookie_visible_to_own_tabs"] = ownCookies.contains { $0.name == cookie.name && $0.value == cookie.value }
    checks["private_cookie_not_shared_between_windows"] = !otherCookies.contains { $0.name == cookie.name }
    first.closeSelectedTab()
    checks["private_close_selects_neighbor"] = first.selectedTabID == firstID && first.tabs.count == 1
    checks["private_closed_tab_callbacks_cleared"] = secondPage?.onNavigate == nil && secondPage?.onNewTab == nil && secondPage?.onDownload == nil && secondPage?.webView.navigationDelegate == nil
    var closeRequested = false
    first.onRequestClose = { closeRequested = true }
    first.closeSelectedTab()
    checks["private_last_tab_requests_close"] = closeRequested && first.tabs.isEmpty && first.selectedTabID == nil
    first.shutdown()
    first.open(url: url)
    checks["private_shutdown_rejects_new_tabs"] = first.isClosed && first.tabs.isEmpty && first.selectedPage == nil
    return checks
}
