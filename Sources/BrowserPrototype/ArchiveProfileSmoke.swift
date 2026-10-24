import BrowserCore
import Foundation

@MainActor
func runArchiveProfileSmoke(directory: URL) throws -> [String: Bool] {
    let root = directory.appendingPathComponent("archive-profiles-" + UUID().uuidString)
    let old = Date(timeIntervalSince1970: 10)
    let now = old.addingTimeInterval(43_201)
    var state = BrowserState()
    let initialProfile = state.selectedProfileID
    let firstSpace = state.selectedSpaceID
    let secondSpace = state.spaces.first { $0.id != firstSpace }!.id
    let secondProfile = state.addProfile(name: "Separate")
    _ = state.assignSpaceProfile(secondSpace, profileID: secondProfile)
    let overridden = state.openTab(url: URL(string: "about:blank#finite-override")!, now: old)
    _ = state.openTab(url: URL(string: "about:blank#first-selected")!, now: old)
    state.selectSpace(secondSpace)
    let inherited = state.openTab(url: URL(string: "about:blank#inherited-never")!, now: old)
    _ = state.openTab(url: URL(string: "about:blank#second-selected")!, now: old)
    state.initializeAutoArchiveClock(now: old)
    try BrowserStateFile.write(state, to: root.appendingPathComponent("session.json"))
    var settings = BrowserSettings()
    settings.autoArchiveAge = .never
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
    json["autoArchiveAgeByProfile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([initialProfile: AutoArchiveAge.twelveHours]))
    try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("settings.json"))
    let model = BrowserModel(directory: root, ephemeralWebsiteData: true)
    defer { model.suspendWindow() }
    model.archiveExpired(now: now)
    var checks = [
        "archive_profile_finite_overrides_global_never": model.state.tabs.first { $0.id == overridden }?.kind == .archived,
        "archive_profile_missing_override_inherits_never": model.state.tabs.first { $0.id == inherited }?.kind == .today,
        "archive_profile_sweep_uses_candidate_not_active_profile": model.state.selectedProfileID == secondProfile && model.state.tabs.first { $0.id == overridden }?.kind == .archived
    ]
    model.settings.update {
        $0.autoArchiveAge = .twelveHours
        $0.setAutoArchiveAge(.never, forProfile: secondProfile)
    }
    let reopened = try BrowserSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
    checks["archive_profile_overrides_persist"] = reopened.state.autoArchiveAge(forProfile: initialProfile) == .twelveHours && reopened.state.autoArchiveAge(forProfile: secondProfile) == .never
    model.archiveExpired(now: now)
    checks["archive_profile_never_overrides_finite_global"] = model.state.tabs.first { $0.id == inherited }?.kind == .today
    model.settings.update { $0.setAutoArchiveAge(nil, forProfile: secondProfile) }
    model.archiveExpired(now: now)
    let removed = try BrowserSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
    checks["archive_profile_remove_override_restores_inheritance"] = model.state.tabs.first { $0.id == inherited }?.kind == .archived && removed.state.autoArchiveAge(forProfile: secondProfile) == .twelveHours
    checks["archive_profile_changes_preserve_start_clock"] = model.state.autoArchiveStartTime == old
    return checks
}
