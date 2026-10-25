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
            // One unreadable file costs only that part of that profile.
            do { profiles[index].history = try ChromiumReader.history(profile: directory, now: now) }
            catch { profiles[index].skipped.append("History from \(profiles[index].name): \(error.localizedDescription)") }
            do { profiles[index].bookmarks = try ChromiumReader.bookmarks(profile: directory, keyPrefix: profiles[index].key, skipped: &profiles[index].skipped) }
            catch { profiles[index].skipped.append("Bookmarks from \(profiles[index].name): \(error.localizedDescription)") }
            // Browsers without Favorites get the sites the person visits most, the way Arc suggested them.
            if browser != .arc, profiles[index].favorites.isEmpty {
                profiles[index].favorites = suggestedFavorites(profiles[index].history, keyPrefix: profiles[index].key)
            }
            let profile = profiles[index]
            let pages = (profile.spaces.flatMap { $0.pinned + $0.today } + profile.favorites + profile.bookmarks).flatMap(\.urls)
            profiles[index].icons = ChromiumReader.icons(profile: directory, pages: pages)
            profiles[index].cookieCount = ChromiumReader.cookieCount(profile: directory)
            profiles[index].extensions = ChromiumReader.extensions(profile: directory)
        }
        return profiles.filter {
            !($0.spaces.isEmpty && $0.favorites.isEmpty && $0.bookmarks.isEmpty && $0.history.isEmpty && $0.cookieCount == 0 && $0.extensions.isEmpty)
        }
    }

    /// The 6 most-visited sites (all their pages counted together), each once, as Favorites.
    static func suggestedFavorites(_ history: [ImportedVisit], keyPrefix: String) -> [ImportedItem] {
        var visits: [String: Int] = [:], latest: [String: Date] = [:]
        for visit in history {
            guard var host = visit.url.host?.lowercased() else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            visits[host, default: 0] += visit.visitCount
            latest[host] = max(latest[host] ?? .distantPast, visit.visitedAt)
        }
        let top = visits.keys.sorted { visits[$0]! != visits[$1]! ? visits[$0]! > visits[$1]! : latest[$0]! > latest[$1]! }.prefix(6)
        return top.compactMap { host in
            URL(string: "https://\(host)/").map { .tab(key: "\(keyPrefix):fav:\(host)", title: host, url: $0) }
        }
    }

    /// Each profile's cookies, decrypted. `secret` reads the browser's Safe Storage key from the keychain (macOS asks
    /// the user) and is called at most once; if it fails, no cookies come over and the reason is listed.
    public static func cookies(_ profiles: [ImportedProfile], browser: ImportBrowser,
                               secret: () throws -> Data) -> (cookies: [String: [ImportedCookie]], skipped: [String]) {
        let sources = profiles.filter { $0.cookieCount > 0 && $0.directory != nil }
        guard !sources.isEmpty else { return ([:], []) }
        let key: Data
        do { key = SafeStorage.key(secret: try secret()) }
        catch SafeStorage.KeychainError.denied { return ([:], ["Cookies: you didn't allow access to \(browser.displayName)'s Safe Storage"]) }
        catch { return ([:], ["Cookies: \(error.localizedDescription)"]) }
        var cookies: [String: [ImportedCookie]] = [:], skipped: [String] = []
        for profile in sources {
            do {
                let result = try ChromiumReader.cookies(profile: profile.directory!, key: key)
                cookies[profile.key] = result.cookies
                if result.undecryptable > 0 { skipped.append("\(result.undecryptable) cookies from \(profile.name) couldn't be decrypted") }
            } catch {
                skipped.append("Cookies from \(profile.name): \(error.localizedDescription)")
            }
        }
        return (cookies, skipped)
    }
}
