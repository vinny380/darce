import Foundation
import Testing
@testable import BrowserCore

/// Finding installed browsers and reading one for import. Each test names the bug it catches.
private func support(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support") }

@Test func aFolderWithoutLocalStateIsNotInstalled() throws {
    let home = try TemporaryDirectory()
    try FileManager.default.createDirectory(at: support(home.url).appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
                                            withIntermediateDirectories: true)
    try ChromiumFixture.localState([("Default", "Me")], at: support(home.url).appendingPathComponent("BraveSoftware/Brave-Browser"))
    #expect(ImportSources.installed(home: home.url) == [.brave])
}

@Test func arcProfilesCarryTheirChromiumHistory() throws {
    let home = try TemporaryDirectory()
    let arc = support(home.url).appendingPathComponent("Arc")
    try ChromiumFixture.localState([("Default", "Default")], at: arc.appendingPathComponent("User Data"))
    try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
    try ArcSidebarFixture.standard().data().write(to: arc.appendingPathComponent("StorableSidebar.json"))
    try ChromiumFixture.history([("https://visited.example/", "Visited", Date())], in: arc.appendingPathComponent("User Data/Default"))
    let profiles = try ImportSources.read(.arc, home: home.url)
    let main = try #require(profiles.first { $0.key == "arc:Default" })
    #expect(main.history.map(\.title) == ["Visited"])
    #expect(main.spaces.count == 2)
    #expect(profiles.first { $0.key == "arc:Profile 9" }?.history.isEmpty == true)
}

@Test func emptyProfilesAreDropped() throws {
    let home = try TemporaryDirectory()
    let chrome = support(home.url).appendingPathComponent("Google/Chrome")
    try ChromiumFixture.localState([("Default", "Me"), ("Profile 1", "Empty")], at: chrome)
    try ChromiumFixture.bookmarks(["bookmark_bar": [ChromiumFixture.url("A", "https://a.example/", guid: "g1")]],
                                  in: chrome.appendingPathComponent("Default"))
    try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
    let profiles = try ImportSources.read(.chrome, home: home.url)
    #expect(profiles.map(\.key) == ["chrome:Default"])
    #expect(profiles[0].name == "Me" && profiles[0].bookmarks.count == 1)
}

@Test func oneUnreadableProfileDoesNotStopTheOthers() throws {
    let home = try TemporaryDirectory()
    let chrome = support(home.url).appendingPathComponent("Google/Chrome")
    try ChromiumFixture.localState([("Default", "Me"), ("Profile 1", "Broken")], at: chrome)
    try ChromiumFixture.bookmarks(["bookmark_bar": [ChromiumFixture.url("A", "https://a.example/", guid: "g1")]],
                                  in: chrome.appendingPathComponent("Default"))
    try ChromiumFixture.bookmarks(["bookmark_bar": [ChromiumFixture.url("B", "https://b.example/", guid: "g2")]],
                                  in: chrome.appendingPathComponent("Profile 1"))
    try Data("not a database".utf8).write(to: chrome.appendingPathComponent("Profile 1/History"))
    let profiles = try ImportSources.read(.chrome, home: home.url)
    #expect(profiles.map(\.key) == ["chrome:Default", "chrome:Profile 1"])
    #expect(profiles[1].bookmarks.count == 1)
    #expect(profiles[1].skipped.contains { $0.hasPrefix("History") })
}

private func chromeWithCookies(_ home: URL, profiles: [String]) throws -> URL {
    let chrome = support(home).appendingPathComponent("Google/Chrome")
    try ChromiumFixture.localState(profiles.map { ($0, $0) }, at: chrome)
    for profile in profiles {
        let folder = chrome.appendingPathComponent(profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try cookiesDB([CookieRow()], in: folder)
        try JSONSerialization.data(withJSONObject: ["extensions": ["settings": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": [
            "location": 1, "from_webstore": true, "disable_reasons": [Int](), "manifest": ["name": "Ext"]]]]])
            .write(to: folder.appendingPathComponent("Secure Preferences"))
    }
    return chrome
}

@Test func readFillsCookieCountsAndExtensionsWithoutTheKeychain() throws {
    let home = try TemporaryDirectory()
    _ = try chromeWithCookies(home.url, profiles: ["Default"])
    let profile = try #require(try ImportSources.read(.chrome, home: home.url).first)
    #expect(profile.cookieCount == 1)
    #expect(profile.extensions.map(\.name) == ["Ext"])
}

@Test func cookiesCallsTheSecretOnce() throws {
    let home = try TemporaryDirectory()
    _ = try chromeWithCookies(home.url, profiles: ["Default", "Profile 1"])
    let profiles = try ImportSources.read(.chrome, home: home.url)
    var calls = 0
    let result = ImportSources.cookies(profiles, browser: .chrome) { calls += 1; return Data("fixture secret".utf8) }
    #expect(calls == 1)
    #expect(result.cookies["chrome:Default"]?.map(\.value) == ["secret-value"])
    #expect(result.cookies["chrome:Profile 1"]?.count == 1)
    #expect(result.skipped.isEmpty)
}

@Test func deniedKeychainSkipsCookiesWithAReason() throws {
    let home = try TemporaryDirectory()
    _ = try chromeWithCookies(home.url, profiles: ["Default"])
    let profiles = try ImportSources.read(.chrome, home: home.url)
    let result = ImportSources.cookies(profiles, browser: .chrome) { throw SafeStorage.KeychainError.denied }
    #expect(result.cookies.isEmpty)
    #expect(result.skipped == ["Cookies: you didn't allow access to Google Chrome's Safe Storage"])
}

@Test func nonArcProfilesSuggestTheirMostVisitedSitesAsFavorites() throws {
    let home = try TemporaryDirectory()
    let chrome = support(home.url).appendingPathComponent("Google/Chrome")
    try ChromiumFixture.localState([("Default", "Me")], at: chrome)
    let now = Date()
    // visit counts: github 9 (over two pages), mail 5, news 1; seven more hosts with 2 each.
    var rows: [(url: String, title: String, at: Date, count: Int)] = [
        ("https://github.com/a", "A", now, 5), ("https://github.com/b", "B", now, 4),
        ("https://mail.example/", "Mail", now, 5), ("https://news.example/", "News", now, 1),
    ]
    for i in 0..<7 { rows.append(("https://site\(i).example/", "S\(i)", now.addingTimeInterval(Double(-i)), 2)) }
    try ChromiumFixture.history(counted: rows, in: chrome.appendingPathComponent("Default"))
    let profile = try #require(try ImportSources.read(.chrome, home: home.url).first)
    let hosts = profile.favorites.compactMap { if case .tab(_, _, let url) = $0 { url.host } else { nil } }
    #expect(hosts.count == 6)
    #expect(Array(hosts.prefix(2)) == ["github.com", "mail.example"])
    #expect(!hosts.contains("news.example"))
    #expect(profile.favorites.allSatisfy { if case .tab(let key, _, _) = $0 { key.hasPrefix("chrome:Default:fav:") } else { false } })
}

@Test func arcProfilesKeepTheirOwnFavorites() throws {
    let home = try TemporaryDirectory()
    let arc = support(home.url).appendingPathComponent("Arc")
    try ChromiumFixture.localState([("Default", "Default")], at: arc.appendingPathComponent("User Data"))
    try ArcSidebarFixture.standard().data().write(to: arc.appendingPathComponent("StorableSidebar.json"))
    try ChromiumFixture.history(counted: [("https://busy.example/", "Busy", Date(), 50)], in: arc.appendingPathComponent("User Data/Default"))
    let main = try #require(try ImportSources.read(.arc, home: home.url).first { $0.key == "arc:Default" })
    let titles = main.favorites.compactMap { if case .tab(_, let title, _) = $0 { title } else { nil } }
    #expect(titles == ["Calendar", "Chat"])
}
