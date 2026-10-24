import Foundation
import Testing
@testable import BrowserCore

@Test func archiveIsRecoverableAndProtectsFavoritesAndPins() {
    var state = BrowserState()
    let originalURL = URL(string: "https://example.com/article")!
    let archivedID = state.openTab(url: originalURL, title: "Article")
    state.archiveTab(archivedID)
    #expect(state.selectedTabID == nil)
    #expect(state.visibleTabs.isEmpty)
    #expect(state.tabs.first?.kind == .archived)
    state.restoreTab(archivedID)
    #expect(state.selectedTab?.id == archivedID)
    #expect(state.selectedTab?.url == originalURL)
    #expect(state.tabs.count == 1)

    for kind in [TabKind.favorite, .pinned] {
        state.setKind(archivedID, kind: kind)
        state.archiveTab(archivedID)
        #expect(state.selectedTab?.kind == kind)
    }
}

@Test func selectionStaysVisibleAcrossSpacesAndMoves() {
    var state = BrowserState()
    let personal = state.selectedSpaceID
    let work = state.spaces[1].id
    let favorite = state.openTab(url: URL(string: "https://example.com/favorite")!)
    state.setKind(favorite, kind: .favorite)
    let local = state.openTab(url: URL(string: "https://example.com/local")!)
    state.setKind(local, kind: .pinned)
    state.selectSpace(work)
    #expect(state.visibleTabs.map(\.id) == [favorite])
    #expect(state.selectedTabID == favorite)
    state.selectTab(local)
    #expect(state.selectedSpaceID == personal)
    #expect(state.selectedTabID == local)
    state.moveTab(local, to: work)
    #expect(state.selectedTabID == favorite)
    state.setKind(favorite, kind: .today)
    state.selectSpace(work)
    #expect(state.selectedTabID == local)
    state.setKind(local, kind: .today)
    state.archiveTab(local)
    #expect(state.selectedTabID == nil)
    state.selectTab(local)
    #expect(state.selectedTabID == nil)

    let before = state
    let missing = UUID()
    state.selectSpace(missing)
    state.selectTab(missing)
    state.moveTab(favorite, to: missing)
    state.moveTab(missing, to: personal)
    state.updateTab(missing, title: "Missing")
    state.setKind(missing, kind: .favorite)
    state.archiveTab(missing)
    state.restoreTab(missing)
    #expect(state == before)
}

@Test func diskRoundTripPreservesCompleteStateAndReplacesAtomically() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("nested/state.json")
    let initial = try BrowserStateFile.read(from: path)
    #expect(initial.spaces.map(\.name) == ["Personal", "Work"])
    #expect(initial.tabs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: path.path))

    var state = initial
    let research = state.addSpace(name: "Research")
    state.selectSpace(research)
    let first = state.openTab(url: URL(string: "https://example.com")!)
    state.setKind(first, kind: .favorite)
    let second = state.openTab(url: URL(string: "https://example.com/second")!)
    state.archiveTab(second)
    try BrowserStateFile.write(state, to: path)
    #expect(try BrowserStateFile.read(from: path) == state)

    state.updateTab(first, url: URL(string: "https://example.com/redirected")!, title: "Changed")
    state.restoreTab(second)
    state.setKind(second, kind: .pinned)
    try BrowserStateFile.write(state, to: path)
    #expect(try BrowserStateFile.read(from: path) == state)
}

@Test func invalidStateFilesAreRejectedWithoutChangingTheirBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.json")
    var state = BrowserState()
    _ = state.openTab(url: URL(string: "https://example.com")!)
    let valid = try JSONEncoder().encode(state)
    let original = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    var cases: [Data] = [Data("{broken".utf8)]
    var future = original
    future["schemaVersion"] = 99
    cases.append(try JSONSerialization.data(withJSONObject: future))
    var duplicateSpaces = original
    let spaces = try #require(original["spaces"] as? [[String: Any]])
    duplicateSpaces["spaces"] = spaces + [spaces[0]]
    cases.append(try JSONSerialization.data(withJSONObject: duplicateSpaces))
    var duplicateTabs = original
    var tabs = try #require(original["tabs"] as? [[String: Any]])
    duplicateTabs["tabs"] = tabs + tabs
    cases.append(try JSONSerialization.data(withJSONObject: duplicateTabs))
    var danglingTab = original
    tabs[0]["spaceID"] = UUID().uuidString
    danglingTab["tabs"] = tabs
    cases.append(try JSONSerialization.data(withJSONObject: danglingTab))
    var danglingSelection = original
    danglingSelection["selectedTabID"] = UUID().uuidString
    cases.append(try JSONSerialization.data(withJSONObject: danglingSelection))
    var invisibleSelection = original
    invisibleSelection["selectedSpaceID"] = spaces[1]["id"]
    cases.append(try JSONSerialization.data(withJSONObject: invisibleSelection))

    for bytes in cases {
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try BrowserStateFile.read(from: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
