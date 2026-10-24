import Foundation
import Testing
@testable import BrowserCore

@Test func appearanceRoundTripPreservesIndependentSpacesAndLayout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("nested/appearance.json")
    var store = try AppearanceStore(fileURL: path)
    let first = UUID(), second = UUID(), folder = UUID()
    #expect(store.state.sidebarWidth == 252)
    #expect(store.state.sidebarVisible)
    #expect(store.state.appearance == .system)
    #expect(store.state.space(first) == SpaceAppearance())
    #expect(!FileManager.default.fileExists(atPath: path.path))
    try store.update {
        $0.sidebarWidth = 315
        $0.sidebarVisible = false
        $0.appearance = .dark
        $0.spaces[first] = SpaceAppearance(tint: AppearanceColor(red: 0.1, green: 0.4, blue: 0.7),
                                           icon: "briefcase.fill", collapsedFolderIDs: [folder], pinnedCollapsed: true)
        $0.spaces[second] = SpaceAppearance(tint: AppearanceColor(red: 0.8, green: 0.2, blue: 0.3), icon: "leaf.fill")
    }
    let reopened = try AppearanceStore(fileURL: path)
    #expect(reopened.state == store.state)
    #expect(reopened.state.space(first).collapsedFolderIDs == [folder])
    #expect(reopened.state.space(second).collapsedFolderIDs.isEmpty)
    #expect(reopened.state.space(UUID()) == SpaceAppearance())
    try store.update { $0.spaces[first]?.pinnedCollapsed = false }
    #expect(try AppearanceStore(fileURL: path).state == store.state)
    #expect(store.state.space(second) == reopened.state.space(second))
}

@Test func appearanceWriteFailureNeverPublishesUnsavedChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appendingPathComponent("parent")
    var store = try AppearanceStore(fileURL: blocker.appendingPathComponent("appearance.json"))
    let original = store.state
    let sentinel = Data("not a directory".utf8)
    try sentinel.write(to: blocker)
    #expect(throws: (any Error).self) { try store.update { $0.sidebarWidth = 300 } }
    #expect(store.state == original)
    #expect(try Data(contentsOf: blocker) == sentinel)
}

@Test func invalidAppearanceFilesArePreservedForRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("appearance.json")
    var valid = AppearancePreferences()
    let space = UUID()
    valid.spaces[space] = SpaceAppearance()
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    var cases = [Data("{broken".utf8)]
    var future = original
    future["schemaVersion"] = 99
    cases.append(try JSONSerialization.data(withJSONObject: future))
    var absent = original
    absent.removeValue(forKey: "sidebarVisible")
    cases.append(try JSONSerialization.data(withJSONObject: absent))
    var wide = original
    wide["sidebarWidth"] = 10000
    cases.append(try JSONSerialization.data(withJSONObject: wide))
    var invalidColor = valid
    invalidColor.spaces[space]?.tint.red = -1
    cases.append(try JSONEncoder().encode(invalidColor))
    for bytes in cases {
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try AppearanceStore(fileURL: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
}

@Test func invalidAppearanceUpdatesPreserveMemoryAndDisk() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("appearance.json")
    var store = try AppearanceStore(fileURL: path)
    let space = UUID()
    try store.update { $0.spaces[space] = SpaceAppearance() }
    let original = store.state
    let bytes = try Data(contentsOf: path)
    for value in [Double.nan, .infinity, -.infinity, 209, 361] {
        #expect(throws: (any Error).self) { try store.update { $0.sidebarWidth = value } }
        #expect(store.state == original)
        #expect(try Data(contentsOf: path) == bytes)
    }
    for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
        #expect(throws: (any Error).self) { try store.update { $0.spaces[space]?.tint.green = value } }
        #expect(store.state == original)
        #expect(try Data(contentsOf: path) == bytes)
    }
}
