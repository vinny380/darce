import Foundation
import SQLite3
import Testing
@testable import BrowserCore

/// Reading a Chromium profile's bookmarks and history. Each test names the bug it catches.
enum ChromiumFixture {
    static func chromeTime(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    static func localState(_ profiles: [(String, String)], at userData: URL) throws {
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let cache = Dictionary(uniqueKeysWithValues: profiles.map { ($0.0, ["name": $0.1]) })
        let root: [String: Any] = ["profile": ["info_cache": cache, "profiles_order": profiles.map(\.0)]]
        try JSONSerialization.data(withJSONObject: root).write(to: userData.appendingPathComponent("Local State"))
    }

    static func bookmarks(_ roots: [String: [[String: Any]]], in profile: URL) throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let json = roots.mapValues { ["type": "folder", "name": "", "children": $0] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["roots": json, "version": 1]).write(to: profile.appendingPathComponent("Bookmarks"))
    }

    static func url(_ name: String, _ url: String, guid: String) -> [String: Any] { ["type": "url", "name": name, "url": url, "guid": guid] }
    static func folder(_ name: String, _ children: [[String: Any]], guid: String) -> [String: Any] {
        ["type": "folder", "name": name, "children": children, "guid": guid]
    }

    /// Creates `History` with Chromium's `urls` table. Returns the open handle when `keepOpenInWAL`, else nil.
    @discardableResult
    static func history(_ rows: [(url: String, title: String, at: Date)], in profile: URL, keepOpenInWAL: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(profile.appendingPathComponent("History").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        if keepOpenInWAL { sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil) }
        sqlite3_exec(db, "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER)", nil, nil, nil)
        for row in rows {
            let sql = "INSERT INTO urls(url, title, visit_count, last_visit_time) VALUES('\(row.url)', '\(row.title)', 1, \(chromeTime(row.at)))"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        if keepOpenInWAL { return db }
        sqlite3_close(db)
        return nil
    }
}

@Test func listsProfilesFromLocalState() throws {
    let folder = try TemporaryDirectory()
    try ChromiumFixture.localState([("Default", "Vinny"), ("Profile 1", "Work")], at: folder.url)
    let profiles = try ChromiumReader.profiles(userData: folder.url)
    #expect(profiles.map(\.directory) == ["Default", "Profile 1"])
    #expect(profiles.map(\.name) == ["Vinny", "Work"])
}

@Test func bookmarkTreeRootsBarThenOtherAndDropsMobileWhenEmpty() throws {
    let folder = try TemporaryDirectory()
    try ChromiumFixture.bookmarks([
        "bookmark_bar": [ChromiumFixture.url("A", "https://a.example/", guid: "g1"),
                         ChromiumFixture.folder("F", [ChromiumFixture.url("B", "https://b.example/", guid: "g2")], guid: "g3"),
                         ChromiumFixture.url("Settings", "chrome://settings", guid: "g4")],
        "other": [ChromiumFixture.url("C", "https://c.example/", guid: "g5")],
        "synced": [],
    ], in: folder.url)
    var skipped: [String] = []
    let tree = try ChromiumReader.bookmarks(profile: folder.url, keyPrefix: "chrome:Default", skipped: &skipped)
    #expect(skipped.count == 1)
    #expect(tree == [
        .tab(key: "chrome:Default:bm:g1", title: "A", url: URL(string: "https://a.example/")!),
        .folder(key: "chrome:Default:bm:g3", title: "F", children: [.tab(key: "chrome:Default:bm:g2", title: "B", url: URL(string: "https://b.example/")!)]),
        .folder(key: "chrome:Default:bm:other", title: "Other Bookmarks", children: [.tab(key: "chrome:Default:bm:g5", title: "C", url: URL(string: "https://c.example/")!)]),
    ])
}

@Test func historyConvertsThe1601EpochAndKeepsNewestFirst() throws {
    let folder = try TemporaryDirectory(), now = Date()
    try ChromiumFixture.history([("https://old.example/", "Old", now.addingTimeInterval(-3600)), ("https://new.example/", "New", now)], in: folder.url)
    let visits = try ChromiumReader.history(profile: folder.url, now: now)
    #expect(visits.map(\.title) == ["New", "Old"])
    #expect(abs(visits[0].visitedAt.timeIntervalSince(now)) < 1)
}

@Test func historyDropsOldAndNonWebRows() throws {
    let folder = try TemporaryDirectory(), now = Date()
    try ChromiumFixture.history([("https://keep.example/", "Keep", now),
                                 ("https://ancient.example/", "Ancient", now.addingTimeInterval(-200 * 86_400)),
                                 ("chrome://newtab/", "New Tab", now)], in: folder.url)
    #expect(try ChromiumReader.history(profile: folder.url, now: now).map(\.title) == ["Keep"])
}

@Test func historyHonoursTheLimit() throws {
    let folder = try TemporaryDirectory(), now = Date()
    try ChromiumFixture.history((0..<5).map { ("https://site\($0).example/", "S\($0)", now.addingTimeInterval(Double(-$0))) }, in: folder.url)
    #expect(try ChromiumReader.history(profile: folder.url, now: now, limit: 2).map(\.title) == ["S0", "S1"])
}

@Test func readsAHistoryDatabaseThatIsOpenInWALMode() throws {
    let folder = try TemporaryDirectory(), now = Date()
    let writer = try ChromiumFixture.history([("https://wal.example/", "Only in the WAL", now)], in: folder.url, keepOpenInWAL: true)
    defer { sqlite3_close(writer) }
    #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("History-wal").path))
    #expect(try ChromiumReader.history(profile: folder.url, now: now).map(\.title) == ["Only in the WAL"])
}
