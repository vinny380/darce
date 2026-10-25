import Foundation
import Testing
@testable import BrowserCore

/// Applying an import to the sidebar and history. Each test names the bug it catches.
private func tab(_ key: String, _ title: String) -> ImportedItem {
    .tab(key: key, title: title, url: URL(string: "https://\(title.lowercased()).example/")!)
}

private func arcProfile() -> ImportedProfile {
    var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
    profile.spaces = [
        ImportedSpace(key: "arc-space:1", name: "Work", icon: "🚀", tint: AppearanceColor(red: 0.2, green: 0.4, blue: 0.6),
                      pinned: [tab("arc:a", "Mail"),
                               .folder(key: "arc:f", title: "Docs", children: [tab("arc:b", "Spec"),
                                       .folder(key: "arc:g", title: "Deep", children: [tab("arc:c", "Note")])]),
                               .split(key: "arc:s", panes: [tab("arc:l", "Left"), tab("arc:r", "Right")], vertical: false)],
                      today: [tab("arc:t", "News")]),
        ImportedSpace(key: "arc-space:2", name: "Home"),
    ]
    profile.favorites = [tab("arc:fav1", "Calendar"), tab("arc:fav2", "Chat")]
    profile.history = [ImportedVisit(url: URL(string: "https://visited.example/")!, title: "Visited", visitedAt: Date())]
    return profile
}

private func chromeProfile() -> ImportedProfile {
    var profile = ImportedProfile(key: "chrome:Default", name: "Me", directory: nil)
    profile.bookmarks = [tab("chrome:Default:bm:1", "Bar"),
                         .folder(key: "chrome:Default:bm:other", title: "Other Bookmarks", children: [tab("chrome:Default:bm:2", "Deep")])]
    return profile
}

private func title(_ state: BrowserState, _ id: UUID?) -> String? { state.tabs.first { $0.id == id }?.title }

@Test func freshInstallBecomesTheImportedSidebar() throws {
    var state = BrowserState()
    #expect(state.isFresh)
    let outcome = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(state.spaces.map(\.name) == ["Work", "Home"])
    #expect(state.profiles.map(\.name) == ["Default"] && state.profiles.count == 1)
    #expect(outcome.firstSpaceID == state.spaces[0].id)
    #expect(outcome.spaceStyles[state.spaces[0].id] == SpaceStyle(icon: "🚀", tint: AppearanceColor(red: 0.2, green: 0.4, blue: 0.6)))
    try state.validate()
}

@Test func existingInstallKeepsItsSpacesAndAddsNewProfiles() throws {
    var state = BrowserState()
    _ = state.openTab(url: URL(string: "https://mine.example/")!)
    let before = state.spaces.map(\.id)
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(Array(state.spaces.map(\.id).prefix(2)) == before)
    #expect(state.profiles.count == 2 && state.profiles[1].name == "Default")
    #expect(state.spaces.suffix(2).allSatisfy { $0.profileID == state.profiles[1].id })
    try state.validate()
}

@Test func importingIntoAnExistingProfileUsesIt() throws {
    var state = BrowserState()
    _ = state.openTab(url: URL(string: "https://mine.example/")!)
    let mine = state.profiles[0].id
    _ = state.applyImport([arcProfile()], from: .arc, into: .existing(mine), options: ImportOptions())
    #expect(state.profiles.count == 1)
    #expect(state.spaces.allSatisfy { $0.profileID == mine })
}

@Test func pinnedTreeFoldersAndSplitArrive() throws {
    var state = BrowserState()
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    let work = state.spaces[0].id
    let docs = try #require(state.folders.first { $0.name == "Docs" && $0.spaceID == work })
    let deep = try #require(state.folders.first { $0.name == "Deep" })
    #expect(docs.parentID == nil && deep.parentID == docs.id)
    let note = try #require(state.tabs.first { $0.title == "Note" })
    #expect(note.kind == .pinned && note.folderID == deep.id)
    #expect(state.tabs.first { $0.title == "Mail" }.map { $0.kind == .pinned && $0.folderID == nil } == true)
    #expect(state.tabs.first { $0.title == "News" }?.kind == .today)
    let split = try #require(state.splitGroups.first)
    #expect(split.tabIDs.map { title(state, $0) } == ["Left", "Right"])
}

@Test func favoritesLandInTheRightProfile() throws {
    var state = BrowserState()
    _ = state.openTab(url: URL(string: "https://mine.example/")!)
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    let imported = state.profiles[1].id
    let favorites = state.tabs.filter { $0.kind == .favorite }
    #expect(favorites.map(\.title) == ["Calendar", "Chat"])
    #expect(favorites.allSatisfy { tab in state.spaces.first { $0.id == tab.spaceID }?.profileID == imported })
}

@Test func chromeBookmarksGoInOneFolderAtTheTop() throws {
    var state = BrowserState()
    let outcome = state.applyImport([chromeProfile()], from: .chrome, into: .newProfiles, options: ImportOptions())
    let container = try #require(state.folders.first { $0.name == "Bookmarks from Google Chrome" })
    #expect(container.parentID == nil)
    let other = try #require(state.folders.first { $0.name == "Other Bookmarks" })
    #expect(other.parentID == container.id)
    #expect(state.tabs.first { $0.title == "Bar" }?.folderID == container.id)
    #expect(Set(outcome.collapsedFolderIDs) == [container.id, other.id])
    #expect(state.spaces.map(\.name) == ["Me"])
}

@Test func importingTwiceAddsNothing() throws {
    var state = BrowserState()
    _ = state.applyImport([arcProfile(), chromeProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    let afterFirst = state
    let second = state.applyImport([arcProfile(), chromeProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(state == afterFirst)
    #expect(second.counts.values.allSatisfy { $0 == 0 })
}

@Test func newItemsInAnAlreadyImportedFolderLandInIt() throws {
    var state = BrowserState()
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    var changed = arcProfile()
    guard case .folder(let key, let title, let children) = changed.spaces[0].pinned[1] else { Issue.record("fixture"); return }
    changed.spaces[0].pinned[1] = .folder(key: key, title: title, children: children + [tab("arc:new", "Fresh")])
    let outcome = state.applyImport([changed], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(outcome.counts["tabs"] == 1)
    #expect(state.tabs.first { $0.title == "Fresh" }?.folderID == state.folders.first { $0.name == "Docs" }?.id)
}

@Test func deletedImportedItemsAreNotResurrected() throws {
    var state = BrowserState()
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    let docs = try #require(state.folders.first { $0.name == "Docs" }?.id)
    let mail = try #require(state.tabs.first { $0.title == "Mail" }?.id)
    let removed = state.deleteFolder(docs)
    #expect(removed)
    state.setKind(mail, kind: .today)
    state.archiveTab(mail)
    _ = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(!state.folders.contains { $0.name == "Docs" })
    #expect(state.tabs.filter { $0.title == "Mail" }.count == 1)
}

@Test func uncheckedOptionsAreNotImported() throws {
    var state = BrowserState()
    var options = ImportOptions()
    options.spacesAndTabs = false
    options.history = false
    let outcome = state.applyImport([arcProfile(), chromeProfile()], from: .arc, into: .newProfiles, options: options)
    #expect(state.tabs.filter { $0.title == "Mail" || $0.title == "Calendar" }.isEmpty)
    #expect(outcome.history.isEmpty)
    #expect(state.tabs.contains { $0.title == "Bar" })
}

@Test func outcomeCarriesHistoryForTheRightProfile() throws {
    var state = BrowserState()
    let outcome = state.applyImport([arcProfile()], from: .arc, into: .newProfiles, options: ImportOptions())
    #expect(outcome.history.map(\.profileID) == [state.profiles[0].id])
    #expect(outcome.history.first?.visits.count == 1)
}

@Test func historyMergeIsOneWriteAndDeduplicates() throws {
    let folder = try TemporaryDirectory()
    var store = try HistoryStore(fileURL: folder.url.appendingPathComponent("history.json"))
    let profile = UUID(), now = Date()
    try store.record(url: URL(string: "https://known.example/")!, title: "Known", profileID: profile, visitedAt: now.addingTimeInterval(-60))
    let added = try store.merge([
        ImportedVisit(url: URL(string: "https://known.example/")!, title: "Known again", visitedAt: now),
        ImportedVisit(url: URL(string: "https://new.example/")!, title: "New", visitedAt: now),
    ], profileID: profile)
    #expect(added == 1)
    let reloaded = try HistoryStore(fileURL: folder.url.appendingPathComponent("history.json"))
    #expect(reloaded.search("", profileID: profile).count == 2)
}

@Test func emojiIconsAreAcceptedAndJunkIsNot() {
    #expect(AppearancePreferences.isEmojiIcon("🚀"))
    #expect(AppearancePreferences.isEmojiIcon("👩‍💻"))
    for junk in ["ab", "🚀🚀", "<script>", "", "1"] { #expect(!AppearancePreferences.isEmojiIcon(junk)) }
}

// Final review fixes. Each test names the bug it catches.

@Test func largeBookmarkImportDoesNotFreezeTheApp() {
    var profile = ImportedProfile(key: "chrome:Default", name: "Me", directory: nil)
    profile.bookmarks = (0..<250).map { folder in
        .folder(key: "chrome:Default:bm:f\(folder)", title: "F\(folder)",
                children: (0..<20).map { tab("chrome:Default:bm:\(folder)-\($0)", "T\(folder)x\($0)") })
    }
    var state = BrowserState()
    let start = Date()
    let outcome = state.applyImport([profile], from: .chrome, into: .newProfiles, options: ImportOptions())
    #expect(outcome.counts["bookmarks"] == 5_000)
    #expect(Date().timeIntervalSince(start) < 1.5)
}

@Test func importLeavesOtherSpacesRememberedTabsAlone() throws {
    var state = BrowserState()
    let personal = state.spaces[0].id, work = state.spaces[1].id
    let mine = state.openTab(url: URL(string: "https://mine.example/")!)
    state.selectSpace(work)
    _ = state.applyImport([chromeProfile()], from: .chrome, into: .existing(state.profiles[0].id), options: ImportOptions())
    state.selectSpace(personal)
    #expect(state.selectedTabID == mine)
}
