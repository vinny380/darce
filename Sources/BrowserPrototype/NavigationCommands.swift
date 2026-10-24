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
                Button("Copy Current URL") {
                    guard privateWindows.activeSession == nil else { return }
                    guard let tab = model.state.selectedTab else { return }
                    let url = model.page(for: tab.id)?.webView.url ?? tab.url
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }.keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.state.selectedTabID == nil)
                Divider()
                Button("Next Visible Tab") {
                    if let session = privateWindows.activeSession { session.cycleTab(backwards: false); return }
                    model.stateUpdate { BrowserOrderedNavigation.cycleTab(&$0, backwards: false) }
                }.keyboardShortcut(.tab, modifiers: [.control]).disabled(model.state.visibleTabs.isEmpty)
                Button("Previous Visible Tab") {
                    if let session = privateWindows.activeSession { session.cycleTab(backwards: true); return }
                    model.stateUpdate { BrowserOrderedNavigation.cycleTab(&$0, backwards: true) }
                }.keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(model.state.visibleTabs.isEmpty)
                Divider()
                Button("Next Space") {
                    guard privateWindows.activeSession == nil else { return }
                    model.stateUpdate { BrowserOrderedNavigation.cycleSpace(&$0, backwards: false) }
                }.disabled(model.state.spaces.count < 2)
                Button("Previous Space") {
                    guard privateWindows.activeSession == nil else { return }
                    model.stateUpdate { BrowserOrderedNavigation.cycleSpace(&$0, backwards: true) }
                }.disabled(model.state.spaces.count < 2)
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
        Divider()
        Button("Next Space") {}.disabled(true)
        Button("Previous Space") {}.disabled(true)
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
private enum BrowserOrderedNavigation {
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
    return checks
}
