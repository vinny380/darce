import Foundation

/// Browsers D'arce can import from. All are Chromium-based, so one reader covers them.
public enum ImportBrowser: String, CaseIterable, Sendable {
    case arc, chrome, brave, edge, vivaldi, opera

    public var displayName: String {
        switch self {
        case .arc: "Arc"
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    /// The browser's Chromium user-data folder.
    public func userData(home: URL) -> URL {
        let support = home.appendingPathComponent("Library/Application Support")
        return switch self {
        case .arc: support.appendingPathComponent("Arc/User Data")
        case .chrome: support.appendingPathComponent("Google/Chrome")
        case .brave: support.appendingPathComponent("BraveSoftware/Brave-Browser")
        case .edge: support.appendingPathComponent("Microsoft Edge")
        case .vivaldi: support.appendingPathComponent("Vivaldi")
        case .opera: support.appendingPathComponent("com.operasoftware.Opera")
        }
    }
}

public enum ImportSources {
    /// A browser counts as installed only when it has written `Local State`; other apps sometimes leave
    /// an empty folder in a browser's place.
    public static func installed(home: URL) -> [ImportBrowser] {
        ImportBrowser.allCases.filter {
            FileManager.default.fileExists(atPath: $0.userData(home: home).appendingPathComponent("Local State").path)
        }
    }

    /// Everything one browser has to import. Arc profiles come from its sidebar and carry their Chromium
    /// history; other browsers' profiles carry bookmarks and history. Profiles with nothing are dropped.
    public static func read(_ browser: ImportBrowser, home: URL, now: Date = Date()) throws -> [ImportedProfile] {
        let userData = browser.userData(home: home)
        var profiles: [ImportedProfile]
        if browser == .arc {
            let sidebar = userData.deletingLastPathComponent().appendingPathComponent("StorableSidebar.json")
            profiles = try ArcSidebarReader.read(sidebar: sidebar, userData: userData)
        } else {
            profiles = try ChromiumReader.profiles(userData: userData).map {
                ImportedProfile(key: "\(browser.rawValue):\($0.directory)", name: $0.name,
                                directory: userData.appendingPathComponent($0.directory))
            }
        }
        for index in profiles.indices {
            guard let directory = profiles[index].directory else { continue }
            profiles[index].history = try ChromiumReader.history(profile: directory, now: now)
            profiles[index].bookmarks = try ChromiumReader.bookmarks(profile: directory, keyPrefix: profiles[index].key)
        }
        return profiles.filter { !($0.spaces.isEmpty && $0.favorites.isEmpty && $0.bookmarks.isEmpty && $0.history.isEmpty) }
    }
}
