import Foundation
import Testing
@testable import BrowserCore

/// Per-site camera and microphone decisions (site controls → Settings). Each test names the bug it catches.
@Test func sitesAskByDefault() {
    #expect(BrowserSettings().mediaDecision(forHost: "meet.example", camera: true, microphone: true) == .ask)
}

@Test func allowingBothSkipsThePrompt() {
    var settings = BrowserSettings()
    settings.setPermission(.allow, for: .camera, host: "meet.example")
    settings.setPermission(.allow, for: .microphone, host: "meet.example")
    #expect(settings.mediaDecision(forHost: "meet.example", camera: true, microphone: true) == .allow)
}

@Test func blockingEitherDeviceBlocksARequestForBoth() {
    var settings = BrowserSettings()
    settings.setPermission(.allow, for: .camera, host: "meet.example")
    settings.setPermission(.block, for: .microphone, host: "meet.example")
    #expect(settings.mediaDecision(forHost: "meet.example", camera: true, microphone: true) == .block)
    #expect(settings.mediaDecision(forHost: "meet.example", camera: true, microphone: false) == .allow)
}

@Test func oneSitesChoiceNeverLeaksToAnother() {
    var settings = BrowserSettings()
    settings.setPermission(.allow, for: .camera, host: "meet.example")
    #expect(settings.mediaDecision(forHost: "evil.example", camera: true, microphone: false) == .ask)
}

@Test func hostMatchingIgnoresCase() {
    var settings = BrowserSettings()
    settings.setPermission(.block, for: .camera, host: "Meet.Example")
    #expect(settings.permission(for: .camera, host: "meet.example") == .block)
}

@Test func permissionsSurviveSaving() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    var store = try BrowserSettingsStore(fileURL: url)
    try store.update { $0.setPermission(.allow, for: .microphone, host: "meet.example") }
    #expect(try BrowserSettingsStore(fileURL: url).state.permission(for: .microphone, host: "meet.example") == .allow)
}
