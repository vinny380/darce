import Foundation
import Testing
@testable import BrowserCore

private let themeFixtureFirst = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let themeFixtureSecond = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let themeFixtureFolder = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

/// UUID-keyed Swift dictionaries encode as alternating key/value arrays. This
/// saved-file fixture deliberately uses no AppearancePreferences/model encoder.
private func themeFixture(schema: Int = 1, theme: [String: Any]? = nil) throws -> Data {
    var first: [String: Any] = [
        "tint": ["red": 0.123456789, "green": 0.456789123, "blue": 0.789123456, "alpha": 0.625],
        "icon": "briefcase.fill", "collapsedFolderIDs": [themeFixtureFolder.uuidString],
        "pinnedCollapsed": true,
    ]
    if let theme { first["theme"] = theme }
    let second: [String: Any] = [
        "tint": ["red": 0.9, "green": 0.2, "blue": 0.1, "alpha": 1.0],
        "icon": "leaf.fill", "collapsedFolderIDs": [], "pinnedCollapsed": false,
    ]
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": schema, "sidebarWidth": 317.25, "sidebarVisible": false,
        "appearance": "dark",
        "spaces": [themeFixtureFirst.uuidString, first, themeFixtureSecond.uuidString, second],
    ], options: [.sortedKeys])
}

private func themeFixturePath() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("theme-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("appearance.json")
}

@Test func themeSchemaOneMigrationIsReadOnlyAndPreservesAppearance() throws {
    let path = try themeFixturePath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let bytes = try themeFixture()
    try bytes.write(to: path)
    var store = try AppearanceStore(fileURL: path)
    #expect(store.state.schemaVersion == 2)
    #expect(try Data(contentsOf: path) == bytes)
    #expect(store.state.sidebarWidth == 317.25)
    #expect(!store.state.sidebarVisible)
    #expect(store.state.appearance == .dark)
    #expect(store.state.space(themeFixtureFirst).tint == AppearanceColor(red: 0.123456789, green: 0.456789123, blue: 0.789123456, alpha: 0.625))
    #expect(store.state.space(themeFixtureFirst).icon == "briefcase.fill")
    #expect(store.state.space(themeFixtureFirst).collapsedFolderIDs == [themeFixtureFolder])
    #expect(store.state.space(themeFixtureFirst).pinnedCollapsed)
    #expect(store.state.space(themeFixtureFirst).theme == nil)
    #expect(store.state.space(themeFixtureSecond).theme == nil)
    let migrated = store.state
    try store.update { $0.sidebarVisible = true }
    let disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(disk["schemaVersion"] as? Int == 2)
    #expect(store.state.spaces == migrated.spaces)
    #expect(store.state.sidebarWidth == migrated.sidebarWidth)
    #expect(store.state.appearance == migrated.appearance)
    #expect(try AppearanceStore(fileURL: path).state == store.state)
}

@Test func themeSchemaTwoRoundTripPreservesSpaceOwnershipAndAbsentSettings() throws {
    let path = try themeFixturePath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    try themeFixture(schema: 2).write(to: path)
    var store = try AppearanceStore(fileURL: path)
    let legacySpaces = store.state.spaces
    let defaults = SpaceThemeSettings()
    #expect(defaults.colorCount == 1)
    #expect(defaults.wheel == .complimentary)
    #expect(defaults.intensity == 0.8)
    var first = defaults
    first.colorCount = 3; first.intensity = 0
    var second = defaults
    second.colorCount = 2; second.wheel = .analogous; second.intensity = 1
    let absent = UUID()
    try store.update {
        $0.spaces[themeFixtureFirst]?.theme = first
        $0.spaces[themeFixtureSecond]?.theme = second
        $0.spaces[absent] = SpaceAppearance()
    }
    let reopened = try AppearanceStore(fileURL: path)
    #expect(reopened.state.schemaVersion == 2)
    #expect(reopened.state == store.state)
    #expect(reopened.state.space(themeFixtureFirst).theme == first)
    #expect(reopened.state.space(themeFixtureSecond).theme == second)
    #expect(reopened.state.space(absent).theme == nil)
    #expect(reopened.state.space(themeFixtureFirst).tint == legacySpaces[themeFixtureFirst]?.tint)
    #expect(reopened.state.space(themeFixtureSecond).tint == legacySpaces[themeFixtureSecond]?.tint)
    #expect(reopened.state.space(themeFixtureFirst).collapsedFolderIDs == [themeFixtureFolder])
}

@Test func invalidThemeUpdatesNeverClampPublishOrOverwrite() throws {
    let path = try themeFixturePath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    try themeFixture(schema: 2, theme: ["colorCount": 1, "wheel": "complimentary", "intensity": 0.8]).write(to: path)
    var store = try AppearanceStore(fileURL: path)
    let state = store.state
    let bytes = try Data(contentsOf: path)
    for count in [-1, 0, 4, Int.max] {
        #expect(throws: (any Error).self) { try store.update { $0.spaces[themeFixtureFirst]?.theme?.colorCount = count } }
        #expect(store.state == state)
        #expect(try Data(contentsOf: path) == bytes)
    }
    for intensity in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
        #expect(throws: (any Error).self) { try store.update { $0.spaces[themeFixtureFirst]?.theme?.intensity = intensity } }
        #expect(store.state == state)
        #expect(try Data(contentsOf: path) == bytes)
    }
}

@Test func invalidThemeFilesRemainUntouchedForRecovery() throws {
    let path = try themeFixturePath()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let validTheme: [String: Any] = ["colorCount": 2, "wheel": "analogous", "intensity": 0.5]
    var cases = [try themeFixture(schema: 99, theme: validTheme)]
    for (key, value): (String, Any) in [("colorCount", 0), ("colorCount", 4), ("intensity", -0.01), ("intensity", 1.01), ("wheel", "future-wheel")] {
        var theme = validTheme; theme[key] = value
        cases.append(try themeFixture(schema: 2, theme: theme))
    }
    let overflow = String(decoding: try themeFixture(schema: 2, theme: validTheme), as: UTF8.self)
        .replacingOccurrences(of: "\"intensity\":0.5", with: "\"intensity\":1e999")
    #expect(overflow.contains("1e999"))
    cases.append(Data(overflow.utf8))
    for bytes in cases {
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try AppearanceStore(fileURL: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
}
