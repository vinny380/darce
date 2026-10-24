import Foundation
import Testing
@testable import BrowserCore

@Test func v1MigrationPreservesTabsAndPinHome() throws {
    let space = UUID(), pin = UUID(), archive = UUID()
    let json = """
    {"schemaVersion":1,"spaces":[{"id":"\(space)","name":"Old Space"}],
    "selectedSpaceID":"\(space)","selectedTabID":"\(pin)","tabs":[
    {"id":"\(pin)","spaceID":"\(space)","url":"https://example.com/pin","title":"Pin","kind":"pinned"},
    {"id":"\(archive)","spaceID":"\(space)","url":"https://example.com/archive","title":"Archive","kind":"archived"}]}
    """
    let state = try JSONDecoder().decode(BrowserState.self, from: Data(json.utf8))
    try state.validate()
    #expect(state.schemaVersion == 5)
    #expect(state.tabs.map(\.id) == [pin, archive])
    #expect(state.tabs.map(\.title) == ["Pin", "Archive"])
    #expect(state.selectedTabID == pin)
    #expect(state.tabs[0].homeURL == state.tabs[0].url)
    #expect(state.tabs[1].kind == .archived)
    #expect(state.selectedTabBySpace[space] == pin)
    #expect(try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state)) == state)
}

@Test func folderCyclesAndCrossSpaceParentsAreRejected() throws {
    var state = BrowserState()
    let space = state.selectedSpaceID, work = state.spaces[1].id
    let parentResult = state.createFolder(name: "Parent", spaceID: space, parentID: nil)
    let parent = try #require(parentResult)
    let childResult = state.createFolder(name: "Child", spaceID: space, parentID: parent)
    let child = try #require(childResult)
    let descendantMove = state.moveFolder(parent, to: child)
    #expect(!descendantMove)
    let selfMove = state.moveFolder(parent, to: parent)
    #expect(!selfMove)
    let invalidFolder = state.createFolder(name: "Invalid", spaceID: work, parentID: child)
    #expect(invalidFolder == nil)
    let tab = state.openTab(url: URL(string: "https://example.com")!)
    let tabMove = state.moveTab(tab, into: child)
    #expect(tabMove)
    #expect(state.selectedTab?.kind == .pinned)
    #expect(state.selectedTab?.folderID == child)
    state.moveTab(tab, to: work)
    #expect(state.tabs.first?.folderID == nil)
    #expect(state.tabs.first?.spaceID == work)
    let rootMove = state.moveFolder(child, to: nil)
    #expect(rootMove)
    try state.validate()
}

@Test func pinHomeSurvivesNavigationPersistenceAndReset() throws {
    var state = BrowserState()
    let home = URL(string: "https://example.com/home")!
    let tab = state.openTab(url: home)
    state.setKind(tab, kind: .pinned)
    state.updateTab(tab, url: URL(string: "https://example.com/article")!)
    state = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
    #expect(state.selectedTab?.url != home)
    #expect(state.selectedTab?.homeURL == home)
    state.resetPinnedTab(tab)
    #expect(state.selectedTab?.url == home)
    state.setKind(tab, kind: .favorite)
    state.updateTab(tab, url: URL(string: "https://example.com/another")!)
    state.resetPinnedTab(tab)
    #expect(state.selectedTab?.url == home)
}

@Test func perSpaceSelectionAndScopedOrderSurviveRoundTrip() throws {
    var state = BrowserState()
    let personal = state.selectedSpaceID, work = state.spaces[1].id
    let a = state.openTab(url: URL(string: "https://example.com/a")!)
    let b = state.openTab(url: URL(string: "https://example.com/b")!)
    state.selectTab(a)
    state.selectSpace(work)
    let c = state.openTab(url: URL(string: "https://example.com/c")!)
    let d = state.openTab(url: URL(string: "https://example.com/d")!)
    state.selectTab(c)
    let crossSpaceReorder = state.reorderTab(a, before: c)
    #expect(!crossSpaceReorder)
    let workReorder = state.reorderTab(d, before: c)
    #expect(workReorder)
    #expect(state.visibleTabs.map(\.id) == [d, c])
    state.selectSpace(personal)
    #expect(state.selectedTabID == a)
    let personalReorder = state.reorderTab(b, before: a)
    #expect(personalReorder)
    #expect(state.visibleTabs.map(\.id) == [b, a])
    state = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
    state.selectSpace(work)
    #expect(state.selectedTabID == c)
    #expect(Set(state.tabs.map(\.id)).count == 4)
    try state.validate()
}

@Test func autoArchiveUsesActivityAndProtectsSelectionsPinsFavorites() throws {
    var state = BrowserState()
    let old = Date(timeIntervalSince1970: 1_000)
    let now = old.addingTimeInterval(3_600)
    _ = state.autoArchive(olderThan: 1_800, now: old)
    let stale = state.openTab(url: URL(string: "https://example.com/stale")!, now: old)
    let pin = state.openTab(url: URL(string: "https://example.com/pin")!, now: old)
    state.setKind(pin, kind: .pinned)
    let favorite = state.openTab(url: URL(string: "https://example.com/favorite")!, now: old)
    state.setKind(favorite, kind: .favorite)
    let recent = state.openTab(url: URL(string: "https://example.com/recent")!, now: now)
    let active = state.openTab(url: URL(string: "https://example.com/active")!, now: old)
    let expired = state.autoArchive(olderThan: 1_800, now: now)
    #expect(expired == [stale])
    #expect(state.tabs.first { $0.id == stale }?.archivedAt == now)
    #expect(state.tabs.first { $0.id == recent }?.kind == .today)
    #expect(state.selectedTabID == active)
    #expect(state.tabs.first { $0.id == pin }?.kind == .pinned)
    #expect(state.tabs.first { $0.id == favorite }?.kind == .favorite)
    let invalidAge = state.autoArchive(olderThan: -1, now: now)
    #expect(invalidAge.isEmpty)
    state.restoreTab(stale, now: now)
    #expect(state.selectedTabID == stale)
    #expect(state.selectedTab?.archivedAt == nil)
    #expect(state.selectedTab?.lastActiveAt == now)
    #expect(state.tabs.count == 5)
    try state.validate()
}
