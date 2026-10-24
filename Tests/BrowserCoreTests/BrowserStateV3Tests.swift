import Foundation
import Testing
@testable import BrowserCore

@Test func v2MigrationKeepsRecordsAndStableProfileIdentity() throws {
    var previous = BrowserState()
    let result1 = previous.createFolder(name: "Keep", spaceID: previous.selectedSpaceID)
    let folder = try #require(result1)
    let pin = previous.openTab(url: URL(string: "https://example.com/pin")!)
    let result2 = previous.moveTab(pin, into: folder)
    #expect(result2)
    let archive = previous.openTab(url: URL(string: "https://example.com/archive")!)
    previous.archiveTab(archive)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
    json["schemaVersion"] = 2
    json.removeValue(forKey: "profiles")
    json["spaces"] = try #require(json["spaces"] as? [[String: Any]]).map { space in
        var result = space
        result.removeValue(forKey: "profileID")
        return result
    }
    let bytes = try JSONSerialization.data(withJSONObject: json)
    let first = try JSONDecoder().decode(BrowserState.self, from: bytes)
    let second = try JSONDecoder().decode(BrowserState.self, from: bytes)
    #expect(first == second)
    #expect(first.schemaVersion == 5)
    #expect(first.profiles.count == 1)
    #expect(first.tabs == previous.tabs)
    #expect(first.folders == previous.folders)
    #expect(first.selectedTabBySpace == previous.selectedTabBySpace)
    #expect(first.spaces.map(\.id) == previous.spaces.map(\.id))
    #expect(first.spaces.allSatisfy { $0.profileID == first.selectedProfileID })
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try BrowserStateFile.write(first, to: path)
    #expect(try BrowserStateFile.read(from: path) == first)
}

@Test func favoritesAndSelectionsStayInsideTheirProfile() throws {
    var state = BrowserState()
    let personal = state.selectedSpaceID, work = state.spaces[1].id
    let firstProfile = state.selectedProfileID
    let favorite = state.openTab(url: URL(string: "https://example.com/favorite")!)
    state.setKind(favorite, kind: .favorite)
    state.selectSpace(work)
    #expect(state.selectedTabID == favorite)
    let workProfile = state.addProfile(name: "Work")
    let result3 = state.assignSpaceProfile(work, profileID: workProfile)
    #expect(result3)
    #expect(state.selectedProfileID == workProfile)
    #expect(state.visibleTabs.isEmpty)
    #expect(state.selectedTabID == nil)
    #expect(state.selectedTabBySpace[work] == nil)
    let secondFavorite = state.openTab(url: URL(string: "https://example.com/work")!)
    state.setKind(secondFavorite, kind: .favorite)
    let result4 = state.reorderTab(favorite, before: secondFavorite)
    #expect(!result4)
    state.selectTab(favorite)
    #expect(state.selectedSpaceID == personal)
    #expect(state.selectedProfileID == firstProfile)
    #expect(state.visibleTabs.map(\.id) == [favorite])
    state.selectSpace(work)
    #expect(state.selectedTabID == secondFavorite)
    #expect(state.visibleTabs.map(\.id) == [secondFavorite])
    let extra = state.addSpace(name: "Extra")
    #expect(state.spaces.first { $0.id == extra }?.profileID == workProfile)
    state.selectSpace(extra)
    #expect(state.visibleTabs.map(\.id) == [secondFavorite])
    try state.validate()
}

@Test func profileReassignmentKeepsSpaceTreeAndUpdatesTabOwnership() throws {
    var state = BrowserState()
    let space = state.selectedSpaceID
    let result5 = state.createFolder(name: "Folder", spaceID: space)
    let folder = try #require(result5)
    let result6 = state.createFolder(name: "Child", spaceID: space, parentID: folder)
    let child = try #require(result6)
    let pin = state.openTab(url: URL(string: "https://example.com/pin")!)
    let result7 = state.moveTab(pin, into: child)
    #expect(result7)
    let archive = state.openTab(url: URL(string: "https://example.com/archive")!)
    state.archiveTab(archive)
    let oldTabs = state.tabs, oldFolders = state.folders
    let profile = state.addProfile(name: "  Another  ")
    let result8 = state.assignSpaceProfile(space, profileID: profile)
    #expect(result8)
    #expect(state.tabs == oldTabs)
    #expect(state.folders == oldFolders)
    #expect(state.profileID(forTab: pin) == profile)
    #expect(state.profileID(forTab: archive) == profile)
    state.renameProfile(profile, name: "  Renamed  ")
    #expect(state.profiles.first { $0.id == profile }?.name == "Renamed")
    let snapshot = state
    let result9 = state.assignSpaceProfile(space, profileID: UUID())
    #expect(!result9)
    let result10 = state.assignSpaceProfile(UUID(), profileID: profile)
    #expect(!result10)
    state.renameProfile(UUID(), name: "Missing")
    #expect(state == snapshot)
    state.moveTab(pin, to: state.spaces[1].id)
    #expect(state.profileID(forTab: pin) == state.spaces[1].profileID)
    #expect(state.profileID(forTab: archive) == profile)
    try state.validate()
}

@Test func invalidProfileFilesNeverFallBackOrOverwriteBytes() throws {
    var state = BrowserState()
    let favorite = state.openTab(url: URL(string: "https://example.com")!)
    state.setKind(favorite, kind: .favorite)
    let profile = state.addProfile(name: "Other")
    let result11 = state.assignSpaceProfile(state.spaces[1].id, profileID: profile)
    #expect(result11)
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    let spaces = try #require(original["spaces"] as? [[String: Any]])
    let profiles = try #require(original["profiles"] as? [[String: Any]])
    var cases: [[String: Any]] = []
    var missing = original
    missing.removeValue(forKey: "profiles")
    cases.append(missing)
    var duplicate = original
    duplicate["profiles"] = profiles + [profiles[0]]
    cases.append(duplicate)
    var dangling = original, modifiedSpaces = spaces
    modifiedSpaces[0]["profileID"] = UUID().uuidString
    dangling["spaces"] = modifiedSpaces
    cases.append(dangling)
    var absent = original
    modifiedSpaces = spaces
    modifiedSpaces[0].removeValue(forKey: "profileID")
    absent["spaces"] = modifiedSpaces
    cases.append(absent)
    var selection = original
    selection["selectedTabBySpace"] = [state.spaces[1].id.uuidString, favorite.uuidString]
    cases.append(selection)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    for invalid in cases {
        let bytes = try JSONSerialization.data(withJSONObject: invalid)
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try BrowserStateFile.read(from: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
