import AppKit
import BrowserCore
import SwiftUI
import WebKit

/* Failure plan, recorded before implementation:
 1. Tab cycling must never select archived tabs or tabs owned by another Space/profile:
    use visibleTabs, preserve its order, and check wrap/no-selection/profile cases below.
 2. Navigation controls can become stale while loading: observe BrowserPage directly,
    and invoke actual WKWebView navigation APIs rather than changing saved URLs.
 3. Duplication must preserve pin metadata without replacing the original: call the
    existing core duplicateTab inside the model's atomic state transaction.
 4. URL copying must preserve the actual URL: copy the renderer URL verbatim, with
    the selected tab URL as fallback; no tracking removal and no automated clipboard test.
 5. A private key window must never dispatch navigation into the normal model: observe
    its session and recheck active window context when invoking actions. Space actions
    are unavailable in private windows. No clipboard automation touches user contents.
 6. Shortcuts must not steal Escape or system desktop navigation: only requested
    bindings are added; Space cycling has menu actions without global arrow bindings.
 */
struct BrowserNavigationCommands: Commands {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var privateWindows = PrivateBrowserWindows.shared

    private func cycleTab(backwards: Bool) {
        if let session = privateWindows.activeSession { session.cycleTab(backwards: backwards); return }
        model.stateUpdate { BrowserOrderedNavigation.cycleTab(&$0, backwards: backwards) }
    }

    private func copyURL(_ format: (URL, String) -> String) {
        guard privateWindows.activeSession == nil, let tab = model.state.selectedTab else { return }
        let page = model.page(for: tab.id)
        let url = page?.webView.url ?? tab.url
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format(url, page?.webView.title ?? tab.title), forType: .string)
    }

    var body: some Commands {
        CommandMenu("Navigate") {
            if let session = privateWindows.activeSession {
                PrivateNavigationButtons(session: session)
            } else {
                if let id = model.state.selectedTabID, let page = model.page(for: id) {
                    BrowserPageNavigationButtons(page: page, isActive: { PrivateBrowserWindows.shared.activeSession == nil })
                    Divider()
                }
                Button("Duplicate Current Tab") {
                    if let session = privateWindows.activeSession { session.duplicateSelectedTab(); return }
                    guard let id = model.state.selectedTabID else { return }
                    model.stateUpdate { _ = $0.duplicateTab(id) }
                }.disabled(model.state.selectedTabID == nil)
                Button("Copy Current URL") { copyURL { url, _ in url.absoluteString } }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.state.selectedTabID == nil)
                Button("Copy URL as Markdown") { copyURL { url, title in "[\(title)](\(url.absoluteString))" } }
                    .keyboardShortcut("c", modifiers: [.command, .option, .shift]).disabled(model.state.selectedTabID == nil)
                Divider()
                Button("Next Tab") { cycleTab(backwards: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(model.state.visibleTabs.isEmpty)
                Button("Previous Tab") { cycleTab(backwards: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(model.state.visibleTabs.isEmpty)
                Button("Cycle Tab Forward") { cycleTab(backwards: false) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control]).disabled(model.state.visibleTabs.isEmpty)
                Button("Cycle Tab Backward") { cycleTab(backwards: true) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control]).disabled(model.state.visibleTabs.isEmpty)
                Button("Switch to Recent Tab") {
                    if let session = privateWindows.activeSession { session.cycleTab(backwards: false) } else { model.cycleRecentTab(backwards: false) }
                }.keyboardShortcut(.tab, modifiers: [.control]).disabled(model.state.visibleTabs.count < 2)
                Button("Switch to Previous Recent Tab") {
                    if let session = privateWindows.activeSession { session.cycleTab(backwards: true) } else { model.cycleRecentTab(backwards: true) }
                }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(model.state.visibleTabs.count < 2)
                Menu("Go to Tab") {
                    ForEach(1...9, id: \.self) { number in
                        Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                            let tabs = model.state.visibleTabs
                            guard privateWindows.activeSession == nil, !tabs.isEmpty else { return }
                            if number == 9 { model.select(tabs[tabs.count - 1].id) }
                            else if number <= tabs.count { model.select(tabs[number - 1].id) }
                        }.keyboardShortcut(KeyEquivalent(Character(String(number))))
                    }
                }
                Button("Clear Today Tabs") { if privateWindows.activeSession == nil { model.clearTodayTabs() } }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!model.state.visibleTabs.contains { $0.kind == .today })
            }
        }
    }
}

private struct PrivateNavigationButtons: View {
    @ObservedObject var session: PrivateBrowserSession

    private var isActive: Bool { PrivateBrowserWindows.shared.activeSession === session }

    var body: some View {
        if let page = session.selectedPage {
            BrowserPageNavigationButtons(page: page, isActive: { isActive && session.selectedPage === page })
            Divider()
        }
        Button("Duplicate Current Tab") {
            guard isActive else { return }
            session.duplicateSelectedTab()
        }.disabled(session.selectedTabID == nil)
        Button("Copy Current URL") {
            guard isActive, let tab = session.tabs.first(where: { $0.id == session.selectedTabID }) else { return }
            let url = session.selectedPage?.webView.url ?? tab.url
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(session.selectedTabID == nil)
        Divider()
        Button("Next Visible Tab") { if isActive { session.cycleTab(backwards: false) } }
            .keyboardShortcut(.tab, modifiers: [.control]).disabled(session.tabs.isEmpty)
        Button("Previous Visible Tab") { if isActive { session.cycleTab(backwards: true) } }
            .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(session.tabs.isEmpty)
    }
}

private struct BrowserPageNavigationButtons: View {
    @ObservedObject var page: BrowserPage
    let isActive: () -> Bool

    var body: some View {
        Button("Back") { if isActive() { page.webView.goBack() } }
            .keyboardShortcut("[").disabled(!page.canGoBack)
        Button("Forward") { if isActive() { page.webView.goForward() } }
            .keyboardShortcut("]").disabled(!page.canGoForward)
        Button("Reload") { if isActive() { page.webView.reload() } }.keyboardShortcut("r")
        Button("Reload from Origin") { if isActive() { page.webView.reloadFromOrigin() } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Stop Loading") { if isActive() { page.webView.stopLoading() } }
            .keyboardShortcut(".").disabled(!page.loading)
    }
}

/// Model visible-tab order, not recency order. Archived and foreign-profile tabs stay excluded.
enum BrowserOrderedNavigation {
    static func cycleTab(_ state: inout BrowserState, backwards: Bool) {
        let ids = state.visibleTabs.map(\.id)
        guard let id = next(ids, current: state.selectedTabID, backwards: backwards) else { return }
        state.selectTab(id)
    }

    static func cycleSpace(_ state: inout BrowserState, backwards: Bool) {
        guard let id = next(state.spaces.map(\.id), current: state.selectedSpaceID, backwards: backwards) else { return }
        state.selectSpace(id)
    }

    private static func next(_ ids: [UUID], current: UUID?, backwards: Bool) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return backwards ? ids.last : ids.first }
        return ids[(index + (backwards ? ids.count - 1 : 1)) % ids.count]
    }
}

/// Recent-tab order frozen at the first Control+Tab, so holding Control walks further back.
struct RecentTabSwitch {
    let order: [UUID]
    private var index = 0

    init?(recent: [UUID], visible: [UUID], current: UUID?) {
        var order = recent.filter { visible.contains($0) && $0 != current }
        if let current, visible.contains(current) { order.insert(current, at: 0) }
        order += visible.filter { !order.contains($0) }
        guard order.count > 1 else { return nil }
        self.order = order
    }

    mutating func step(backwards: Bool) -> UUID {
        index = (index + (backwards ? order.count - 1 : 1)) % order.count
        return order[index]
    }
}

/// Exercises the command's state operations without touching any model, renderer, or clipboard.
@MainActor
func runNavigationCommandSmoke() -> [String: Bool] {
    var state = BrowserState()
    let personal = state.selectedSpaceID, work = state.spaces[1].id
    let url = URL(string: "https://navigation-fixture.invalid/")!
    let favorite = state.openTab(url: url)
    state.setKind(favorite, kind: .favorite)
    let pinned = state.openTab(url: url.appendingPathComponent("pinned"))
    state.setKind(pinned, kind: .pinned)
    let today = state.openTab(url: url.appendingPathComponent("today"))
    let archived = state.openTab(url: url.appendingPathComponent("archived"))
    state.archiveTab(archived)
    state.selectSpace(work)
    _ = state.openTab(url: url.appendingPathComponent("work"))
    let profile = state.addProfile(name: "Other Profile")
    let otherSpace = state.addSpace(name: "Other Profile Space")
    _ = state.assignSpaceProfile(otherSpace, profileID: profile)
    state.selectSpace(otherSpace)
    let foreign = state.openTab(url: url.appendingPathComponent("foreign"))
    state.setKind(foreign, kind: .favorite)
    state.selectSpace(personal)
    state.selectTab(favorite)
    BrowserOrderedNavigation.cycleTab(&state, backwards: false)
    var checks = ["ordered_tab_cycle_favorite_to_pin": state.selectedTabID == pinned]
    BrowserOrderedNavigation.cycleTab(&state, backwards: false)
    checks["ordered_tab_cycle_pin_to_today"] = state.selectedTabID == today
    BrowserOrderedNavigation.cycleTab(&state, backwards: false)
    checks["ordered_tab_cycle_wrap_excludes_archive_and_foreign_profile"] = state.selectedTabID == favorite && state.selectedSpaceID == personal
    BrowserOrderedNavigation.cycleTab(&state, backwards: true)
    checks["ordered_tab_cycle_backwards_wrap"] = state.selectedTabID == today
    state.clearSelection()
    BrowserOrderedNavigation.cycleTab(&state, backwards: false)
    checks["ordered_tab_cycle_without_selection"] = state.selectedTabID == favorite
    BrowserOrderedNavigation.cycleSpace(&state, backwards: true)
    checks["ordered_space_cycle_backwards_wrap"] = state.selectedSpaceID == otherSpace
    BrowserOrderedNavigation.cycleSpace(&state, backwards: false)
    checks["ordered_space_cycle_forwards_wrap"] = state.selectedSpaceID == personal
    var empty = BrowserState()
    BrowserOrderedNavigation.cycleTab(&empty, backwards: false)
    checks["ordered_tab_cycle_empty_is_noop"] = empty.selectedTabID == nil && empty.tabs.isEmpty
    // Recent order: current first, then most recent, then never-visited tabs; archived ids drop out.
    if var walk = RecentTabSwitch(recent: [pinned, archived, today], visible: [favorite, pinned, today], current: today) {
        checks["recent_switch_goes_to_previous_tab"] = walk.step(backwards: false) == pinned
        checks["recent_switch_held_control_walks_further"] = walk.step(backwards: false) == favorite
        checks["recent_switch_wraps_to_current"] = walk.step(backwards: false) == today
        checks["recent_switch_backwards_from_current"] = walk.step(backwards: true) == favorite
    } else { checks["recent_switch_builds_order"] = false }
    var swipe = SpaceSwipeTracker()
    checks["swipe_vertical_scroll_stays_scroll"] = swipe.handle(phase: .began, fingerDX: 5, fingerDY: 30) == nil
        && swipe.handle(phase: .changed, fingerDX: 70, fingerDY: 0) == nil
        && swipe.handle(phase: .ended, fingerDX: 0, fingerDY: 0) == nil
    checks["swipe_follows_fingers"] = swipe.handle(phase: .began, fingerDX: -30, fingerDY: 2) == .drag(-30)
        && swipe.handle(phase: .changed, fingerDX: -40, fingerDY: 2) == .drag(-70)
    checks["swipe_end_reports_travel_and_velocity"] = swipe.handle(phase: .ended, fingerDX: 0, fingerDY: 0) == .end(-70, velocity: -40)
    checks["swipe_ignores_events_after_end"] = swipe.handle(phase: .ended, fingerDX: 0, fingerDY: 0) == nil
    checks["swipe_cancel_reports_no_travel"] = swipe.handle(phase: .began, fingerDX: 80, fingerDY: 0) == .drag(80)
        && swipe.handle(phase: .cancelled, fingerDX: 0, fingerDY: 0) == .end(0, velocity: 80)
    checks["recent_switch_needs_two_tabs"] = RecentTabSwitch(recent: [], visible: [today], current: today) == nil
    return checks
}
