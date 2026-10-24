import Foundation
import Testing
@testable import BrowserCore

// Failure plan, written before implementation:
// 1. Page-title callbacks or restart erase a renamed tab. Keep an explicit custom title across both.
// 2. Duplicating a pin loses its home/folder or crosses cookie ownership. Preserve those fields,
//    create one fresh identity beside its source, and reject archived/missing records unchanged.
// 3. Removing a folder deletes tabs or orphans a descendant. Promote only direct children and
//    pins into its parent; descendants, URLs, identities and selection survive a disk round-trip.
// 4. Removing a Space loses archived/global-favorite records or dangling remembered selections.
//    Move the whole tree to a caller-selected same-profile Space without changing IDs or URLs.
// 5. Invalid destinations, profile mismatch or removing the final Space mutate state anyway.
//    Reject each action before any record changes.

@Test func userTabNamesSurviveNavigationAndPersistence() throws {
    var state = BrowserState()
    let tab = state.openTab(url: URL(string: "https://example.com/start")!, title: "Page title")
    let renamed = state.renameTab(tab, title: "  My research  ")
    #expect(renamed)
    state.updateTab(tab, url: URL(string: "https://example.com/next")!, title: "Server title")
    #expect(state.selectedTab?.title == "My research")
    #expect(state.selectedTab?.customTitle == "My research")
    state = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
    state.updateTab(tab, title: "Later server title")
    #expect(state.selectedTab?.title == "My research")
    let before = state
    let missing = state.renameTab(UUID(), title: "Missing")
    let blank = state.renameTab(tab, title: "  \n ")
    #expect(!missing && !blank)
    #expect(state == before)
    try state.validate()
}

@Test func duplicatedTabsPreservePinFolderProfileAndIndependentIdentity() throws {
    var state = BrowserState()
    let sourceSpace = state.selectedSpaceID
    let home = URL(string: "https://example.com/home")!
    let folderResult = state.createFolder(name: "Research", spaceID: sourceSpace)
    let folder = try #require(folderResult)
    let tab = state.openTab(url: home)
    _ = state.moveTab(tab, into: folder)
    _ = state.renameTab(tab, title: "Pinned research")
    state.updateTab(tab, url: URL(string: "https://example.com/article")!)
    let original = try #require(state.tabs.first { $0.id == tab })
    let profile = state.addProfile(name: "Separate")
    _ = state.assignSpaceProfile(state.spaces[1].id, profileID: profile)
    state.selectSpace(state.spaces[1].id)
    let copiedResult = state.duplicateTab(tab, now: Date(timeIntervalSince1970: 1234))
    let copied = try #require(copiedResult)
    let copy = try #require(state.tabs.first { $0.id == copied })
    #expect(copy.id != original.id)
    #expect(copy.url == original.url && copy.title == original.title)
    #expect(copy.kind == .pinned && copy.homeURL == home && copy.folderID == folder)
    #expect(copy.customTitle == original.customTitle && copy.spaceID == sourceSpace)
    #expect(state.selectedTabID == copied && state.selectedSpaceID == sourceSpace)
    #expect(state.profileID(forTab: copied) == state.profileID(forTab: tab))
    #expect(state.tabs.first { $0.id == tab } == original)
    #expect(state.tabs.map(\.id) == [tab, copied])
    state.resetPinnedTab(copied)
    #expect(state.tabs.first { $0.id == copied }?.url == home)
    #expect(state.tabs.first { $0.id == tab }?.url == original.url)

    state.setKind(tab, kind: .favorite)
    let sameProfileSpace = state.addSpace(name: "Same profile")
    state.selectSpace(sameProfileSpace)
    let favoriteCopyResult = state.duplicateTab(tab)
    let favoriteCopy = try #require(favoriteCopyResult)
    #expect(state.selectedSpaceID == sameProfileSpace)
    #expect(state.selectedTabID == favoriteCopy && state.selectedTab?.kind == .favorite)
    #expect(state.selectedTab?.folderID == nil && state.selectedTab?.homeURL == home)
    let today = state.openTab(url: home)
    let todayCopyResult = state.duplicateTab(today)
    let todayCopy = try #require(todayCopyResult)
    #expect(state.tabs.first { $0.id == todayCopy }?.kind == .today)
    state.archiveTab(today)
    let before = state
    let archivedResult = state.duplicateTab(today)
    let missingResult = state.duplicateTab(UUID())
    #expect(archivedResult == nil && missingResult == nil)
    #expect(state == before)
    try state.validate()
}

@Test func deletingFolderPromotesDirectChildrenWithoutLosingContent() throws {
    var state = BrowserState()
    let space = state.selectedSpaceID
    let parentResult = state.createFolder(name: "Parent", spaceID: space)
    let parent = try #require(parentResult)
    let removedResult = state.createFolder(name: "Remove", spaceID: space, parentID: parent)
    let removed = try #require(removedResult)
    let childResult = state.createFolder(name: "Child", spaceID: space, parentID: removed)
    let child = try #require(childResult)
    let grandchildResult = state.createFolder(name: "Grandchild", spaceID: space, parentID: child)
    let grandchild = try #require(grandchildResult)
    let direct = state.openTab(url: URL(string: "https://example.com/direct")!)
    _ = state.moveTab(direct, into: removed)
    let nested = state.openTab(url: URL(string: "https://example.com/nested")!)
    _ = state.moveTab(nested, into: grandchild)
    let tabIDs = state.tabs.map(\.id), urls = state.tabs.map(\.url)
    let deleted = state.deleteFolder(removed)
    #expect(deleted)
    #expect(state.folders.first { $0.id == child }?.parentID == parent)
    #expect(state.folders.first { $0.id == grandchild }?.parentID == child)
    #expect(state.tabs.first { $0.id == direct }?.folderID == parent)
    #expect(state.tabs.first { $0.id == nested }?.folderID == grandchild)
    #expect(state.tabs.map(\.id) == tabIDs && state.tabs.map(\.url) == urls)
    #expect(state.selectedTabID == nested)
    let parentDeleted = state.deleteFolder(parent)
    #expect(parentDeleted)
    #expect(state.folders.first { $0.id == child }?.parentID == nil)
    #expect(state.tabs.first { $0.id == direct }?.folderID == nil)
    let beforeMissing = state
    let missing = state.deleteFolder(UUID())
    #expect(!missing && state == beforeMissing)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try BrowserStateFile.write(state, to: path)
    #expect(try BrowserStateFile.read(from: path) == state)
}

@Test func removingSpaceRelocatesEveryRecordAndRepairsSelection() throws {
    var state = BrowserState()
    let source = state.selectedSpaceID, target = state.spaces[1].id
    let profile = state.selectedProfileID
    let favorite = state.openTab(url: URL(string: "https://example.com/favorite")!)
    state.setKind(favorite, kind: .favorite)
    let folderResult = state.createFolder(name: "Parent", spaceID: source)
    let folder = try #require(folderResult)
    let childResult = state.createFolder(name: "Child", spaceID: source, parentID: folder)
    let child = try #require(childResult)
    let pin = state.openTab(url: URL(string: "https://example.com/pin")!)
    _ = state.moveTab(pin, into: child)
    let archived = state.openTab(url: URL(string: "https://example.com/archive")!)
    state.archiveTab(archived)
    state.selectSpace(target)
    let existing = state.openTab(url: URL(string: "https://example.com/existing")!)
    let third = state.addSpace(name: "Third")
    state.selectSpace(third)
    state.selectTab(favorite)
    state.selectSpace(source)
    state.selectTab(pin)
    let oldIDs = state.tabs.map(\.id), oldURLs = state.tabs.map(\.url), oldFolders = state.folders.map(\.id)
    let removed = state.removeSpace(source, movingContentsTo: target)
    #expect(removed)
    #expect(state.tabs.map(\.id) == oldIDs && state.tabs.map(\.url) == oldURLs)
    #expect(state.folders.map(\.id) == oldFolders)
    #expect(state.folders.allSatisfy { $0.spaceID == target })
    #expect(state.folders.first { $0.id == child }?.parentID == folder)
    #expect(state.tabs.allSatisfy { $0.spaceID == target })
    #expect(state.tabs.first { $0.id == archived }?.kind == .archived)
    #expect(state.tabs.first { $0.id == pin }?.folderID == child)
    #expect(state.profileID(forTab: favorite) == profile)
    #expect(state.selectedSpaceID == target && state.selectedTabID == pin)
    #expect(state.selectedTabBySpace[source] == nil)
    #expect(state.selectedTabBySpace[third] == favorite)
    #expect(state.tabs.contains { $0.id == existing })
    state.selectSpace(third)
    #expect(state.selectedTabID == favorite)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try BrowserStateFile.write(state, to: path)
    #expect(try BrowserStateFile.read(from: path) == state)
}

@Test func invalidSpaceRemovalPreservesAllState() throws {
    var state = BrowserState()
    let first = state.selectedSpaceID, second = state.spaces[1].id
    let profile = state.addProfile(name: "Other")
    _ = state.assignSpaceProfile(second, profileID: profile)
    let original = state
    let crossProfile = state.removeSpace(first, movingContentsTo: second)
    let same = state.removeSpace(first, movingContentsTo: first)
    let missingSource = state.removeSpace(UUID(), movingContentsTo: second)
    let missingDestination = state.removeSpace(first, movingContentsTo: UUID())
    #expect(!crossProfile && !same && !missingSource && !missingDestination)
    #expect(state == original)
    _ = state.assignSpaceProfile(second, profileID: state.selectedProfileID)
    let removed = state.removeSpace(second, movingContentsTo: first)
    #expect(removed)
    let last = state
    let lastToSelf = state.removeSpace(first, movingContentsTo: first)
    let lastToMissing = state.removeSpace(first, movingContentsTo: UUID())
    #expect(!lastToSelf && !lastToMissing && state == last)
    try state.validate()
}
