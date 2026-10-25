import Foundation
import SQLite3

/// Reads a Chromium-family browser's profiles, bookmarks and history (Chrome, Arc, Brave, Edge, Vivaldi, Opera).
/// Databases are read from a private copy, so the browser can stay open.
public enum ChromiumReader {
    public enum ReadError: Error, LocalizedError {
        case unreadableDatabase
        public var errorDescription: String? { "the browser's database couldn't be read" }
    }

    /// Profile folders and their display names, in the browser's own order.
    public static func profiles(userData: URL) throws -> [(directory: String, name: String)] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: userData.appendingPathComponent("Local State"))) as? [String: Any]
        let profile = root?["profile"] as? [String: Any]
        let cache = profile?["info_cache"] as? [String: Any] ?? [:]
        let order = (profile?["profiles_order"] as? [String] ?? []).filter { cache[$0] != nil }
        let directories = order + cache.keys.filter { !order.contains($0) }.sorted()
        return directories.filter { !$0.isEmpty && !$0.contains("/") }.map { directory in
            let name = (cache[directory] as? [String: Any])?["name"] as? String
            return (directory, name?.isEmpty == false ? name! : directory)
        }
    }

    /// The bookmark bar's items, then "Other Bookmarks" and "Mobile Bookmarks" folders when they have anything.
    public static func bookmarks(profile: URL, keyPrefix: String, skipped: inout [String]) throws -> [ImportedItem] {
        let file = profile.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let roots = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["roots"] as? [String: Any] ?? [:]
        func items(_ node: Any?) -> [ImportedItem] {
            ((node as? [String: Any])?["children"] as? [[String: Any]] ?? []).compactMap { child in
                let key = "\(keyPrefix):bm:\(child["guid"] as? String ?? child["id"] as? String ?? UUID().uuidString)"
                let name = child["name"] as? String ?? ""
                if child["type"] as? String == "folder" {
                    let children = items(child)
                    return children.isEmpty ? nil : .folder(key: key, title: name.isEmpty ? "Folder" : name, children: children)
                }
                let address = child["url"] as? String ?? ""
                guard let url = ImportURL.supported(address) else {
                    skipped.append("Bookmark “\(name.isEmpty ? address : name)”: D'arce can't open this kind of address")
                    return nil
                }
                return .tab(key: key, title: name.isEmpty ? url.absoluteString : name, url: url)
            }
        }
        var tree = items(roots["bookmark_bar"])
        for (root, title, suffix) in [("other", "Other Bookmarks", "other"), ("synced", "Mobile Bookmarks", "mobile")] {
            let children = items(roots[root])
            if !children.isEmpty { tree.append(.folder(key: "\(keyPrefix):bm:\(suffix)", title: title, children: children)) }
        }
        return tree
    }

    /// The most recently visited web pages, newest first.
    public static func history(profile: URL, now: Date = Date(), limit: Int = 10_000,
                               maxAge: TimeInterval = 180 * 86_400) throws -> [ImportedVisit] {
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent("History").path) else { return [] }
        return try withCopy(of: "History", in: profile) { db in
            // Chromium time: microseconds since 1601-01-01 UTC.
            let epochOffset = 11_644_473_600.0
            let cutoff = Int64((now.timeIntervalSince1970 - maxAge + epochOffset) * 1_000_000)
            var statement: OpaquePointer?
            let sql = "SELECT url, title, last_visit_time FROM urls WHERE last_visit_time > ? ORDER BY last_visit_time DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unreadableDatabase }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, cutoff)
            // ponytail: over-fetch so non-web rows don't starve the limit; a page of chrome:// rows past 2× is unlikely.
            sqlite3_bind_int64(statement, 2, Int64(limit * 2))
            var visits: [ImportedVisit] = []
            var step = SQLITE_ROW
            while visits.count < limit {
                step = sqlite3_step(statement)
                guard step == SQLITE_ROW else { break }
                guard let raw = sqlite3_column_text(statement, 0),
                      let url = ImportURL.supported(String(cString: raw)), url.scheme?.hasPrefix("http") == true else { continue }
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let seconds = Double(sqlite3_column_int64(statement, 2)) / 1_000_000 - epochOffset
                visits.append(ImportedVisit(url: url, title: title.isEmpty ? url.absoluteString : title,
                                            visitedAt: Date(timeIntervalSince1970: seconds)))
            }
            guard step == SQLITE_ROW || step == SQLITE_DONE else { throw ReadError.unreadableDatabase }
            return visits
        }
    }

    /// Copies the database with its `-wal`/`-journal` into a private folder, opens the copy read-only, and
    /// deletes the folder afterwards.
    static func withCopy<T>(of name: String, in profile: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in ["", "-wal", "-journal"] {
            let source = profile.appendingPathComponent(name + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name + suffix))
            }
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(folder.appendingPathComponent(name).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReadError.unreadableDatabase
        }
        return try body(db)
    }
}
