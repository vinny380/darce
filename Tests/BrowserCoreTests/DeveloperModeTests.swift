import Foundation
import Testing
@testable import BrowserCore

/// Developer Mode is per site, like Arc's "Turn on Developer Mode for this site" (⌃D). Each test names the bug it catches.
@Test func ordinarySitesStartWithDeveloperModeOff() {
    #expect(!BrowserSettings().isDeveloperMode(host: "youtube.com"))
}

@Test func localDevelopmentHostsStartOn() {
    let settings = BrowserSettings()
    #expect(settings.isDeveloperMode(host: "localhost") && settings.isDeveloperMode(host: "127.0.0.1"))
}

@Test func togglingASiteOnlyAffectsThatSite() {
    var settings = BrowserSettings()
    settings.toggleDeveloperMode(host: "app.example")
    #expect(settings.isDeveloperMode(host: "APP.example"))
    #expect(!settings.isDeveloperMode(host: "other.example"))
}

@Test func turningOffADefaultHostSticks() {
    var settings = BrowserSettings()
    settings.toggleDeveloperMode(host: "localhost")
    #expect(!settings.isDeveloperMode(host: "localhost"))
    settings.toggleDeveloperMode(host: "localhost")
    #expect(settings.isDeveloperMode(host: "localhost"))
}

@Test func developerSitesSurviveSaving() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    var store = try BrowserSettingsStore(fileURL: url)
    try store.update { $0.toggleDeveloperMode(host: "app.example"); $0.toggleDeveloperMode(host: "localhost") }
    let reloaded = try BrowserSettingsStore(fileURL: url).state
    #expect(reloaded.isDeveloperMode(host: "app.example") && !reloaded.isDeveloperMode(host: "localhost"))
}
