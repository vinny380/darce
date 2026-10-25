import Foundation
import Testing
@testable import BrowserCore

/// Finding the extensions a person installed from the Chrome Web Store. Each test names the bug it catches.
private func entry(location: Int = 1, webStore: Bool = true, byDefault: Bool = false, oem: Bool = false,
                   disable: Any = [Int](), name: String? = nil, path: String? = nil) -> [String: Any] {
    var entry: [String: Any] = ["location": location, "from_webstore": webStore, "was_installed_by_default": byDefault,
                                "was_installed_by_oem": oem, "disable_reasons": disable]
    if let name { entry["manifest"] = ["name": name, "manifest_version": 3] }
    if let path { entry["path"] = path }
    return entry
}

private func preferences(_ settings: [String: Any], file: String = "Secure Preferences", in profile: URL) throws {
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings]]).write(to: profile.appendingPathComponent(file))
}

@Test func keepsOnlyEnabledUserWebStoreExtensions() throws {
    let folder = try TemporaryDirectory()
    try preferences([
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": entry(name: "Keep"),
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": entry(location: 5, webStore: false, name: "Component"),
        "cccccccccccccccccccccccccccccccc": entry(byDefault: true, name: "Default"),
        "dddddddddddddddddddddddddddddddd": entry(oem: true, name: "OEM"),
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": entry(location: 4, webStore: false, name: "Unpacked"),
        "ffffffffffffffffffffffffffffffff": entry(disable: [8_388_608], name: "MV2 disabled"),
        "gggggggggggggggggggggggggggggggg": entry(disable: 1, name: "Old-style disabled"),
        "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh": entry(disable: 0, name: "Old-style enabled"),
    ], in: folder.url)
    #expect(ChromiumReader.extensions(profile: folder.url).map(\.name) == ["Keep", "Old-style enabled"])
}

@Test func readsSettingsFromEitherPreferencesFile() throws {
    let folder = try TemporaryDirectory()
    try preferences(["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": entry(name: "Secure")], in: folder.url)
    try preferences(["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": entry(name: "Plain")], file: "Preferences", in: folder.url)
    #expect(Set(ChromiumReader.extensions(profile: folder.url).map(\.name)) == ["Secure", "Plain"])
}

@Test func resolvesLocalizedNames() throws {
    let folder = try TemporaryDirectory()
    let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let files = folder.url.appendingPathComponent("Extensions/\(id)/1.0_0")
    try FileManager.default.createDirectory(at: files.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["name": "__MSG_appName__", "default_locale": "en", "manifest_version": 3])
        .write(to: files.appendingPathComponent("manifest.json"))
    try JSONSerialization.data(withJSONObject: ["appname": ["message": "Localized Name"]])
        .write(to: files.appendingPathComponent("_locales/en/messages.json"))
    try preferences([id: entry(path: "\(id)/1.0_0")], in: folder.url)
    #expect(ChromiumReader.extensions(profile: folder.url).map(\.name) == ["Localized Name"])
}

@Test func pointsAtTheInstalledFiles() throws {
    let folder = try TemporaryDirectory()
    let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let files = folder.url.appendingPathComponent("Extensions/\(id)/2.1_0")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["name": "On Disk", "manifest_version": 3]).write(to: files.appendingPathComponent("manifest.json"))
    try preferences([id: entry(path: "\(id)/2.1_0")], in: folder.url)
    let found = try #require(ChromiumReader.extensions(profile: folder.url).first)
    #expect(found.id == id && found.name == "On Disk")
    #expect(found.files?.standardizedFileURL == files.standardizedFileURL)
}

@Test func skipsExtensionsTheBrowserBlocklisted() throws {
    let folder = try TemporaryDirectory()
    var malware = entry(name: "Blocklisted")
    malware["blacklist_state"] = 1
    var legacy = entry(name: "Legacy blocklisted")
    legacy["blacklist"] = true
    var clean = entry(name: "Clean")
    clean["blacklist_state"] = 0
    try preferences(["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": malware, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": legacy,
                     "cccccccccccccccccccccccccccccccc": clean], in: folder.url)
    #expect(ChromiumReader.extensions(profile: folder.url).map(\.name) == ["Clean"])
}
