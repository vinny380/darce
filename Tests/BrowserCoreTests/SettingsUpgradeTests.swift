import Foundation
import Testing
@testable import BrowserCore

/// A settings file written before the Arc-style options existed must still load, or saving would be disabled.
@Test func settingsFromBeforeTheNewOptionsStillLoadWithArcDefaults() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let legacy = #"{"schemaVersion":1,"searchEngine":"google","autoArchiveAge":"oneDay","pinnedExternalLinksOpenPeek":false,"defaultZoom":1.25}"#
    try Data(legacy.utf8).write(to: url)
    let state = try BrowserSettingsStore(fileURL: url).state
    #expect(state.searchEngine == .google && state.autoArchiveAge == .oneDay && !state.pinnedExternalLinksOpenPeek)
    #expect(state.shiftClickOpensPeek && state.optionCommandClickOpensMiniWindow && state.externalLinksOpenInMiniWindow)
    #expect(!state.globalMiniWindowShortcut && state.boostsEnabled && state.hapticFeedback && !state.showFullURL)
}

/// Each profile can search with its own engine; profiles without one follow the global choice.
@Test func searchEngineCanDifferPerProfileAndSurvivesSaving() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let work = UUID(), personal = UUID()
    var store = try BrowserSettingsStore(fileURL: url)
    try store.update { $0.searchEngine = .duckDuckGo; $0.setSearchEngine(.google, forProfile: work) }
    let reloaded = try BrowserSettingsStore(fileURL: url).state
    #expect(reloaded.searchEngine(forProfile: work) == .google)
    #expect(reloaded.searchEngine(forProfile: personal) == .duckDuckGo)
}
