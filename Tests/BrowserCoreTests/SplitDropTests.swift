import Foundation
import Testing
@testable import BrowserCore

/// Dropping one sidebar tab onto another splits them, like Arc. Each test names the bug it catches.
private func todayTabs(_ count: Int) -> (BrowserState, [UUID]) {
    var state = BrowserState()
    let ids = (0..<count).map { state.openTab(url: URL(string: "https://split.invalid/\($0)")!) }
    return (state, ids)
}

private func group(_ state: BrowserState, containing id: UUID) -> [UUID]? {
    state.splitGroups.first { $0.tabIDs.contains(id) }?.tabIDs
}

@Test func droppingOnATabSplitsAndFocusesTheDroppedTab() {
    var (state, t) = todayTabs(2)
    let split = state.splitTab(t[1], onto: t[0])
    #expect(split)
    #expect(group(state, containing: t[0]) == [t[0], t[1]])
    #expect(state.selectedTabID == t[1])
}

@Test func droppingOnASplitAddsAPane() {
    var (state, t) = todayTabs(3)
    _ = state.splitTab(t[1], onto: t[0])
    let split = state.splitTab(t[2], onto: t[0])
    #expect(split)
    #expect(group(state, containing: t[0]) == [t[0], t[1], t[2]])
}

@Test func fifthPaneIsRejectedWithoutSideEffects() {
    var (state, t) = todayTabs(5)
    for i in 1...3 { _ = state.splitTab(t[i], onto: t[0]) }
    let before = state
    let split = state.splitTab(t[4], onto: t[0])
    #expect(!split)
    #expect(state == before)
}

@Test func paneDraggedToAnotherTabLeavesItsOldSplit() {
    var (state, t) = todayTabs(3)
    _ = state.splitTab(t[1], onto: t[0])
    let split = state.splitTab(t[1], onto: t[2])
    #expect(split)
    #expect(group(state, containing: t[0]) == nil)  // a one-pane split is dissolved
    #expect(group(state, containing: t[2]) == [t[2], t[1]])
}

@Test func droppingOnItselfOrFromArchiveDoesNothing() {
    var (state, t) = todayTabs(2)
    state.archiveTab(t[1])
    let before = state
    let ontoSelf = state.splitTab(t[0], onto: t[0])
    let archived = state.splitTab(t[1], onto: t[0])
    #expect(!ontoSelf && !archived)
    #expect(state == before)
}

@Test func draggingAPaneIntoAnotherSectionSeparatesIt() {
    var (state, t) = todayTabs(2)
    _ = state.splitTab(t[1], onto: t[0])
    let placed = state.placeTab(t[1], kind: .pinned, folderID: nil, before: nil)
    #expect(placed)
    #expect(state.splitGroups.isEmpty)
}
