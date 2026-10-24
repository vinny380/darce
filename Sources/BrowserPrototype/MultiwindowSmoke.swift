import BrowserCore
import Foundation

@MainActor
func runMultiwindowSmoke(directory: URL) throws -> [String: Bool] {
    let folder = directory.appendingPathComponent("multiwindow-" + UUID().uuidString)
    let first = BrowserModel(directory: folder, ephemeralWebsiteData: true)
    let second = BrowserModel(workspace: first.workspace)
    defer { first.suspendWindow(); second.suspendWindow() }
    let url = URL(string: "https://multiwindow-fixture.invalid/first")!
    first.open(url)
    let a = first.state.selectedTabID!
    let firstPage = first.page(for: a)!
    firstPage.webView.stopLoading()
    second.open(url.appendingPathComponent("second"))
    let b = second.state.selectedTabID!
    second.select(a)
    let secondPage = second.page(for: a)!
    secondPage.webView.stopLoading()
    second.select(b)
    var checks = [
        "normal_windows_have_independent_selection": first.state.selectedTabID == a && second.state.selectedTabID == b,
        "normal_windows_share_canonical_tabs": first.state.tabs == second.state.tabs && first.state.tabs.count == 2,
        "normal_windows_share_services": first.downloads === second.downloads && first.settings === second.settings && first.boosts === second.boosts && first.appearance === second.appearance && first.documents === second.documents && first.browsingData === second.browsingData,
        "normal_windows_share_profile_store_not_renderer": first.dataStore(for: first.state.selectedProfileID) === second.dataStore(for: second.state.selectedProfileID) && firstPage !== secondPage
    ]
    first.recordVisit(url: url, title: "First", profileID: first.state.selectedProfileID)
    second.recordVisit(url: url.appendingPathComponent("second"), title: "Second", profileID: second.state.selectedProfileID)
    checks["normal_windows_share_history_writer"] = first.history?.search(profileID: first.state.selectedProfileID).count == 2 && second.history?.search(profileID: second.state.selectedProfileID).count == 2
    let replacement = url.appendingPathComponent("changed")
    _ = first.stateUpdate { $0.updateTab(a, url: replacement) }
    checks["normal_remote_url_discards_stale_renderer"] = second.page(for: a) !== secondPage && secondPage.onNavigate == nil && second.state.tabs.first(where: { $0.id == a })?.url == replacement
    first.archive(a)
    checks["normal_archive_discards_renderer_in_every_window"] = first.page(for: a) == nil && second.page(for: a) == nil
    checks["normal_shared_session_round_trip"] = try BrowserStateFile.read(from: first.sessionURL).tabs == first.state.tabs
    checks["normal_shared_history_round_trip"] = try HistoryStore(fileURL: folder.appendingPathComponent("history.json")).search(profileID: first.state.selectedProfileID).count == 2
    second.suspendWindow()
    checks["normal_closed_window_cannot_mutate_workspace"] = !second.stateUpdate { _ = $0.addSpace(name: "Closed") }
    second.activateWindow()
    second.open(url.appendingPathComponent("reopened"))
    checks["normal_reopened_window_reattaches_owner"] = first.state.tabs == second.state.tabs && first.state.tabs.count == 3
    return checks
}
