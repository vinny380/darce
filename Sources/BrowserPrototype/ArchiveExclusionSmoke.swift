import BrowserCore
import Foundation

@MainActor
func runArchiveExclusionSmoke(directory: URL) throws -> [String: Bool] {
    let first = BrowserModel(directory: directory.appendingPathComponent("archive-exclusions-" + UUID().uuidString), ephemeralWebsiteData: true)
    let second = BrowserModel(workspace: first.workspace)
    defer { first.suspendWindow(); second.suspendWindow() }
    first.settings.update { $0.autoArchiveAge = .twelveHours }
    let old = Date(timeIntervalSince1970: 10), now = old.addingTimeInterval(43_201)
    first.archiveExpired(now: old)
    var secondary: UUID!, undisplayed: UUID!, primary: UUID!
    _ = first.stateUpdate {
        secondary = $0.openTab(url: URL(string: "about:blank#split")!, now: old)
        undisplayed = $0.openTab(url: URL(string: "about:blank#undisplayed")!, now: old)
        primary = $0.openTab(url: URL(string: "about:blank#primary")!, now: old)
    }
    _ = second.stateUpdate { _ = $0.openTab(url: URL(string: "about:blank#other-window")!, now: old) }
    first.split(secondary)
    let renderer = first.page(for: secondary)!
    second.archiveExpired(now: now)
    var checks = [
        "archive_preserves_other_window_split": first.secondaryTabID == secondary && first.state.tabs.first(where: { $0.id == secondary })?.kind == .today,
        "archive_preserves_split_renderer": first.page(for: secondary) === renderer && renderer.onNavigate != nil,
        "archive_removes_undisplayed_expired_tab": first.state.tabs.first(where: { $0.id == undisplayed })?.kind == .archived
    ]
    first.separateAllPanes()
    second.archiveExpired(now: now)
    checks["archive_releases_closed_split"] = first.state.tabs.first(where: { $0.id == secondary })?.kind == .archived
    var closingSplit: UUID!
    _ = first.stateUpdate {
        closingSplit = $0.openTab(url: URL(string: "about:blank#closing-window")!, now: old)
        $0.selectTab(primary, now: old)
    }
    first.split(closingSplit)
    first.suspendWindow()
    second.archiveExpired(now: now)
    checks["archive_releases_closed_window_split"] = try BrowserStateFile.read(from: second.sessionURL).tabs.first(where: { $0.id == closingSplit })?.kind == .archived
    return checks
}
