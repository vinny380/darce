import Foundation
import Testing
@testable import BrowserCore

// Failure plan, written before implementation:
// 1. Settings revert after restart or defaults change existing behavior. Round-trip all fields
//    through the filesystem and verify that an absent file uses the current browser defaults.
// 2. Search text changes meaning or injects query parameters/fragments. Construct URLs for all
//    engines with literal plus, ampersand, Unicode, percent and fragment characters; parse back
//    the complete query and verify it remains one q parameter without sending a network request.
// 3. Corrupt/future/invalid settings silently reset and overwrite disk. Reject them and compare
//    unchanged bytes; invalid update values preserve both the old snapshot and saved bytes.
// 4. A write failure publishes unsaved settings. Force a parent-directory failure and verify
//    that the caller's existing state and the blocking sentinel remain unchanged.

@Test func browserSettingsDefaultsAndRoundTripPreserveBehavior() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("nested/settings.json")
    var store = try BrowserSettingsStore(fileURL: file)
    #expect(store.state.searchEngine == .duckDuckGo)
    #expect(store.state.autoArchiveAge == .twelveHours)
    let initialArchiveInterval = try #require(store.state.autoArchiveAge.interval)
    #expect(initialArchiveInterval == TimeInterval(43_200))
    #expect(store.state.pinnedExternalLinksOpenPeek)
    #expect(store.state.defaultZoom == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try store.update {
        $0.searchEngine = .brave
        $0.autoArchiveAge = .never
        $0.pinnedExternalLinksOpenPeek = false
        $0.defaultZoom = 1.35
    }
    let reopened = try BrowserSettingsStore(fileURL: file)
    #expect(reopened.state == store.state)
    #expect(reopened.state.autoArchiveAge.interval == nil)
    try store.update { $0.defaultZoom = 0.25 }
    #expect(try BrowserSettingsStore(fileURL: file).state.defaultZoom == 0.25)
    try store.update { $0.defaultZoom = 3 }
    #expect(try BrowserSettingsStore(fileURL: file).state.defaultZoom == 3)
}

@Test func searchEngineURLsPreserveQueryTextAsOneParameter() throws {
    let query = "C++ & café / x=1? #50% 🚀"
    let expected: [(SearchEngine, String, String)] = [
        (.duckDuckGo, "duckduckgo.com", "/"),
        (.google, "www.google.com", "/search"),
        (.bing, "www.bing.com", "/search"),
        (.brave, "search.brave.com", "/search"),
    ]
    for (engine, host, path) in expected {
        let url = engine.searchURL(for: query)
        let parsed = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parsed.scheme == "https" && parsed.host == host && parsed.path == path)
        #expect(parsed.fragment == nil)
        #expect(parsed.queryItems == [URLQueryItem(name: "q", value: query)])
        let encoded = try #require(parsed.percentEncodedQuery)
        #expect(encoded.contains("%2B%2B"))
        #expect(encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding == "q=" + query)
    }
}

@Test func invalidBrowserSettingsPreserveDiskAndPublishedState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    var store = try BrowserSettingsStore(fileURL: file)
    try store.update { $0.searchEngine = .google }
    let originalState = store.state
    let originalBytes = try Data(contentsOf: file)
    for value in [Double.nan, .infinity, -.infinity, 0.249, 3.001] {
        #expect(throws: (any Error).self) { try store.update { $0.defaultZoom = value } }
        #expect(store.state == originalState)
        #expect(try Data(contentsOf: file) == originalBytes)
    }
    let valid = try #require(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
    var cases = [Data("{broken-settings".utf8)]
    var future = valid
    future["schemaVersion"] = 99
    cases.append(try JSONSerialization.data(withJSONObject: future))
    var unknownEngine = valid
    unknownEngine["searchEngine"] = "not-an-engine"
    cases.append(try JSONSerialization.data(withJSONObject: unknownEngine))
    var missing = valid
    missing.removeValue(forKey: "autoArchiveAge")
    cases.append(try JSONSerialization.data(withJSONObject: missing))
    var invalidZoom = valid
    invalidZoom["defaultZoom"] = 4
    cases.append(try JSONSerialization.data(withJSONObject: invalidZoom))
    for bytes in cases {
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try BrowserSettingsStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}

@Test func browserSettingsWriteFailureKeepsOldSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let parent = directory.appendingPathComponent("blocked-parent")
    var store = try BrowserSettingsStore(fileURL: parent.appendingPathComponent("settings.json"))
    let original = store.state
    let sentinel = Data("preserve this file".utf8)
    try sentinel.write(to: parent)
    #expect(throws: (any Error).self) { try store.update { $0.searchEngine = .bing } }
    #expect(store.state == original)
    #expect(try Data(contentsOf: parent) == sentinel)
}
