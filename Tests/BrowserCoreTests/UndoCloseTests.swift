import Foundation
import Testing
@testable import BrowserCore

/// ⌘Z after closing tabs puts them back exactly as they were. Each test names the bug it catches.
private func todayTabs(_ count: Int) -> (BrowserState, [UUID]) {
    var state = BrowserState()
    let ids = (0..<count).map { state.openTab(url: URL(string: "https://undo.invalid/\($0)")!) }
    return (state, ids)
}

private func today(_ state: BrowserState) -> [UUID] { state.visibleTabs.filter { $0.kind == .today }.map(\.id) }

@Test func closedTabComesBackInTheSameSpotAndSelected() {
    var (state, t) = todayTabs(3)
    let snapshot = state.tabs.filter { $0.id == t[1] }
    state.archiveTab(t[1])
    state.undoClose(snapshot)
    #expect(today(state) == t)
    #expect(state.selectedTabID == t[1])
}

@Test func clearedTodayTabsAllComeBackInOrder() {
    var (state, t) = todayTabs(3)
    let snapshot = state.tabs.filter { t.contains($0.id) }
    t.forEach { state.archiveTab($0) }
    state.undoClose(snapshot)
    #expect(today(state) == t)
}

@Test func closedPinnedPaneComesBackPinnedInItsFolder() {
    var (state, t) = todayTabs(2)
    let folder = state.createFolder(name: "Reading", spaceID: state.selectedSpaceID)!
    state.moveTab(t[0], into: folder)
    _ = state.splitTab(t[1], onto: t[0])
    let snapshot = state.tabs.filter { $0.id == t[0] }
    state.closePane(t[0], from: state.selectedSplitGroup!.id)
    state.undoClose(snapshot)
    let restored = state.tabs.first { $0.id == t[0] }
    #expect(restored?.kind == .pinned && restored?.folderID == folder && restored?.homeURL != nil)
}

@Test func tabAlreadyRestoredByHandIsLeftAlone() {
    var (state, t) = todayTabs(2)
    let snapshot = state.tabs.filter { $0.id == t[0] }
    state.archiveTab(t[0])
    state.restoreTab(t[0])
    state.setKind(t[0], kind: .pinned)  // the user did something else with it since
    state.undoClose(snapshot)
    #expect(state.tabs.first { $0.id == t[0] }?.kind == .pinned)
}

@Test func tabWhoseFolderWasDeletedComesBackAtTopLevel() {
    var (state, t) = todayTabs(2)
    let folder = state.createFolder(name: "Gone", spaceID: state.selectedSpaceID)!
    state.moveTab(t[0], into: folder)
    _ = state.splitTab(t[1], onto: t[0])
    let snapshot = state.tabs.filter { $0.id == t[0] }
    state.closePane(t[0], from: state.selectedSplitGroup!.id)
    _ = state.deleteFolder(folder)
    state.undoClose(snapshot)
    let restored = state.tabs.first { $0.id == t[0] }
    #expect(restored?.kind == .pinned && restored?.folderID == nil)  // never pointing at a folder that no longer exists
}
