import Foundation
import Testing
@testable import BrowserCore

/// Drag-and-drop placement. Each test names the bug it catches.
private func fixture() -> (BrowserState, today: [UUID], pinned: [UUID], favorite: UUID) {
    var state = BrowserState()
    let url = { (path: String) in URL(string: "https://place.invalid/\(path)")! }
    let favorite = state.openTab(url: url("fav"))
    state.setKind(favorite, kind: .favorite)
    let pinned = (0..<2).map { i -> UUID in let id = state.openTab(url: url("pin\(i)")); state.setKind(id, kind: .pinned); return id }
    let today = (0..<3).map { state.openTab(url: url("today\($0)")) }
    return (state, today, pinned, favorite)
}

private func order(_ state: BrowserState, _ kind: TabKind) -> [UUID] { state.visibleTabs.filter { $0.kind == kind }.map(\.id) }

@Test func todayTabDroppedAmongPinsBecomesPinnedAtThatSpot() {
    var (state, today, pinned, _) = fixture()
    let placed = state.placeTab(today[1], kind: .pinned, folderID: nil, before: pinned[1])
    #expect(placed)
    #expect(order(state, .pinned) == [pinned[0], today[1], pinned[1]])
    #expect(state.tabs.first { $0.id == today[1] }?.homeURL != nil)  // a pin remembers its home URL
}

@Test func pinnedTabDroppedAtEndOfTodayLosesPinState() {
    var (state, today, pinned, _) = fixture()
    let placed = state.placeTab(pinned[0], kind: .today, folderID: nil, before: nil)
    #expect(placed)
    #expect(order(state, .today) == today + [pinned[0]])
    #expect(state.tabs.first { $0.id == pinned[0] }?.homeURL == nil)
}

@Test func favoriteFromAnotherSpaceDroppedIntoTodayStaysVisible() {
    var (state, _, _, favorite) = fixture()
    let other = state.spaces[1].id
    state.selectSpace(other)  // the favorite still shows here; its owner Space is the first one
    let placed = state.placeTab(favorite, kind: .today, folderID: nil, before: nil)
    #expect(placed)
    #expect(order(state, .today).contains(favorite))
}

@Test func tabDroppedIntoFolderLandsBeforeTarget() {
    var (state, today, pinned, _) = fixture()
    let folder = state.createFolder(name: "Reading", spaceID: state.selectedSpaceID)!
    state.moveTab(pinned[0], into: folder)
    let placed = state.placeTab(today[0], kind: .pinned, folderID: folder, before: pinned[0])
    #expect(placed)
    #expect(state.visibleTabs.filter { $0.folderID == folder }.map(\.id) == [today[0], pinned[0]])
}

@Test func mismatchedTargetChangesNothing() {
    var (state, today, pinned, _) = fixture()
    let before = state
    let placed = state.placeTab(today[0], kind: .pinned, folderID: nil, before: today[1])  // target isn't a pin
    #expect(!placed)
    #expect(state == before)
}

@Test func archivedTabCannotBeDropped() {
    var (state, today, pinned, _) = fixture()
    state.archiveTab(today[0])
    let placed = state.placeTab(today[0], kind: .pinned, folderID: nil, before: pinned[0])
    #expect(!placed)
    #expect(state.tabs.first { $0.id == today[0] }?.kind == .archived)
}

@Test func dropOntoItselfIsANoOp() {
    var (state, today, _, _) = fixture()
    let before = state
    let placed = state.placeTab(today[1], kind: .today, folderID: nil, before: today[1])
    #expect(placed)
    #expect(state == before)
}
