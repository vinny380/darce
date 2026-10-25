import CryptoKit
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

    /// How many cookies there are to bring over, without decrypting anything (for the import sheet).
    public static func cookieCount(profile: URL) -> Int {
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path) else { return 0 }
        return (try? withCopy(of: "Cookies", in: profile) { db -> Int in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM cookies WHERE top_frame_site_key = ''", -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }) ?? 0
    }

    /// The profile's cookies, decrypted with the browser's Safe Storage key. Partitioned cookies (which WebKit can't
    /// keep apart) and expired ones are left out; rows that don't decrypt are counted.
    public static func cookies(profile: URL, key: Data, now: Date = Date()) throws -> (cookies: [ImportedCookie], undecryptable: Int) {
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path) else { return ([], 0) }
        return try withCopy(of: "Cookies", in: profile) { db in
            var version = 0
            var meta: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &meta, nil) == SQLITE_OK,
               sqlite3_step(meta) == SQLITE_ROW, let text = sqlite3_column_text(meta, 0) {
                version = Int(String(cString: text)) ?? 0
            }
            sqlite3_finalize(meta)
            var statement: OpaquePointer?
            let sql = """
                SELECT host_key, top_frame_site_key, name, value, encrypted_value, path, expires_utc,
                       is_secure, is_httponly, has_expires, is_persistent, samesite FROM cookies
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unreadableDatabase }
            defer { sqlite3_finalize(statement) }
            let latest = now.addingTimeInterval(400 * 86_400)   // the longest a cookie may live (RFC 6265bis)
            var cookies: [ImportedCookie] = [], undecryptable = 0
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                defer { step = sqlite3_step(statement) }
                let text = { (column: Int32) in sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
                let host = text(0)
                guard text(1).isEmpty, !host.isEmpty else { continue }
                var value = text(3)
                let blobLength = Int(sqlite3_column_bytes(statement, 4))
                if blobLength > 0, let bytes = sqlite3_column_blob(statement, 4) {
                    guard var plain = SafeStorage.decrypt(Data(bytes: bytes, count: blobLength), key: key) else { undecryptable += 1; continue }
                    // Version 24 puts SHA-256(host) in front of the value; strip it only when it's really there.
                    let hash = Data(SHA256.hash(data: Data(host.utf8)))
                    if version >= 24, plain.count >= 32, plain.prefix(32) == hash { plain = plain.dropFirst(32) }
                    guard let decoded = String(data: plain, encoding: .utf8) else { undecryptable += 1; continue }
                    value = decoded
                }
                let persistent = sqlite3_column_int(statement, 9) != 0 && sqlite3_column_int(statement, 10) != 0
                var expires: Date?
                if persistent {
                    let seconds = Double(sqlite3_column_int64(statement, 6)) / 1_000_000 - 11_644_473_600
                    let date = Date(timeIntervalSince1970: seconds)
                    guard date > now else { continue }
                    expires = min(date, latest)
                }
                let sameSite: String? = switch sqlite3_column_int(statement, 11) { case 1: "lax"; case 2: "strict"; default: nil }
                cookies.append(ImportedCookie(domain: host, name: text(2), value: value, path: text(5).isEmpty ? "/" : text(5),
                                              expires: expires, secure: sqlite3_column_int(statement, 7) != 0,
                                              httpOnly: sqlite3_column_int(statement, 8) != 0, sameSite: sameSite))
            }
            guard step == SQLITE_DONE else { throw ReadError.unreadableDatabase }
            return (cookies, undecryptable)
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
