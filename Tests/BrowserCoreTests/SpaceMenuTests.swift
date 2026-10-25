import Foundation
import Testing
@testable import BrowserCore

/// The Space "…" menu's Export into Folder and Delete Space. Each test names the bug it catches.
private func spaceWithContents() -> (state: BrowserState, source: UUID, destination: UUID, outer: UUID, inner: UUID,
                                     loosePin: UUID, folderedPin: UUID, today: UUID) {
    var state = BrowserState()
    let source = state.spaces[0].id, destination = state.spaces[1].id
    state.selectSpace(source)
    let outer = state.createFolder(name: "Outer", spaceID: source)!
    let inner = state.createFolder(name: "Inner", spaceID: source, parentID: outer)!
    let loosePin = state.openTab(url: URL(string: "https://loose.invalid/")!)
    state.setKind(loosePin, kind: .pinned)
    let folderedPin = state.openTab(url: URL(string: "https://foldered.invalid/")!)
    _ = state.moveTab(folderedPin, into: inner)
    let today = state.openTab(url: URL(string: "https://today.invalid/")!)
    return (state, source, destination, outer, inner, loosePin, folderedPin, today)
}

@Test func exportKeepsFolderNestingUnderTheNewFolder() throws {
    var s = spaceWithContents()
    let changed = s.state.exportSpaceIntoFolder(s.source, to: s.destination)
    #expect(changed)
    let exported = try #require(s.state.folders.first { $0.name == "Personal" && $0.spaceID == s.destination })
    #expect(exported.parentID == nil)
    #expect(s.state.folders.first { $0.id == s.outer }?.parentID == exported.id)
    #expect(s.state.folders.first { $0.id == s.inner }?.parentID == s.outer)
    try s.state.validate()
}

@Test func exportPutsLoosePinsInTheNewFolderAndLeavesFolderedPinsWhereTheyAre() throws {
    var s = spaceWithContents()
    let changed = s.state.exportSpaceIntoFolder(s.source, to: s.destination)
    #expect(changed)
    let exported = try #require(s.state.folders.first { $0.name == "Personal" && $0.spaceID == s.destination })
    #expect(s.state.tabs.first { $0.id == s.loosePin }?.folderID == exported.id)
    #expect(s.state.tabs.first { $0.id == s.folderedPin }?.folderID == s.inner)
    let today = try #require(s.state.tabs.first { $0.id == s.today })
    #expect(today.spaceID == s.destination && today.kind == .today)
    #expect(!s.state.spaces.contains { $0.id == s.source })
}

@Test func exportToAnotherProfileIsRefusedAndChangesNothing() {
    var s = spaceWithContents()
    let other = s.state.addProfile(name: "Other")
    _ = s.state.assignSpaceProfile(s.destination, profileID: other)
    let before = s.state
    let changed = s.state.exportSpaceIntoFolder(s.source, to: s.destination)
    #expect(!changed)
    #expect(s.state == before)
}

@Test func deleteArchivesPinsAndTodayInsteadOfLosingThem() throws {
    var s = spaceWithContents()
    let changed = s.state.deleteSpace(s.source)
    #expect(changed)
    for id in [s.loosePin, s.folderedPin, s.today] {
        let tab = try #require(s.state.tabs.first { $0.id == id })
        #expect(tab.kind == .archived && tab.spaceID == s.destination && tab.folderID == nil)
    }
    #expect(!s.state.folders.contains { $0.id == s.outer || $0.id == s.inner })
    try s.state.validate()
}

@Test func deleteKeepsTheProfilesFavorites() throws {
    var s = spaceWithContents()
    let favorite = s.state.openTab(url: URL(string: "https://favorite.invalid/")!)
    s.state.setKind(favorite, kind: .favorite)
    let changed = s.state.deleteSpace(s.source)
    #expect(changed)
    let kept = try #require(s.state.tabs.first { $0.id == favorite })
    #expect(kept.kind == .favorite && kept.spaceID == s.destination)
}

@Test func deletingAProfilesLastSpaceTakesItsTabsAndStillValidates() throws {
    var s = spaceWithContents()
    let other = s.state.addProfile(name: "Other")
    _ = s.state.assignSpaceProfile(s.source, profileID: other)
    let changed = s.state.deleteSpace(s.source)
    #expect(changed)
    #expect(!s.state.tabs.contains { [s.loosePin, s.folderedPin, s.today].contains($0.id) })
    try s.state.validate()
}

@Test func theOnlySpaceCannotBeDeleted() {
    var state = BrowserState()
    let changed = state.deleteSpace(state.spaces[1].id)
    #expect(changed)
    let before = state
    let refused = !state.deleteSpace(state.spaces[0].id)
    #expect(refused)
    #expect(state == before)
}
