import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

/// Reading Chromium's cookie database. Each test names the bug it catches.
private let key = SafeStorage.key(secret: Data("fixture secret".utf8))

private func encrypt(_ plain: Data) -> Data {
    let iv = [UInt8](repeating: 0x20, count: 16)
    var output = Data(count: plain.count + 16)
    var length = 0
    let capacity = output.count
    _ = output.withUnsafeMutableBytes { out in
        plain.withUnsafeBytes { input in
            key.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, 16, iv, input.baseAddress, plain.count, out.baseAddress, capacity, &length)
            }
        }
    }
    return Data("v10".utf8) + output.prefix(length)
}

private struct Row {
    var host = ".example.com", partition = "", name = "session", value = "secret-value", path = "/"
    var expires: Date? = Date().addingTimeInterval(86_400), secure = true, httpOnly = true, sameSite = -1
    var hashPrefix = true, garbage = false
}

private func cookiesDB(_ rows: [Row], version: Int = 24, in folder: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(folder.appendingPathComponent("Cookies").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES('version', '\(version)');
        CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
          name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
          expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
          last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
          priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
          last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL, has_cross_site_ancestor INTEGER NOT NULL);
        """, nil, nil, nil)
    for row in rows {
        var plain = Data(row.value.utf8)
        if row.hashPrefix { plain = Data(SHA256.hash(data: Data(row.host.utf8))) + plain }
        let blob = row.garbage ? Data("v10".utf8) + Data(repeating: 7, count: 32) : encrypt(plain)
        let expires = row.expires.map(ChromiumFixture.chromeTime) ?? 0
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO cookies VALUES(0, ?, ?, ?, '', ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, 2, 443, 0, 0, 0)
            """, -1, &statement, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, row.host, -1, transient)
        sqlite3_bind_text(statement, 2, row.partition, -1, transient)
        sqlite3_bind_text(statement, 3, row.name, -1, transient)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), transient) }
        sqlite3_bind_text(statement, 5, row.path, -1, transient)
        sqlite3_bind_int64(statement, 6, expires)
        sqlite3_bind_int(statement, 7, row.secure ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.httpOnly ? 1 : 0)
        sqlite3_bind_int(statement, 9, row.expires == nil ? 0 : 1)
        sqlite3_bind_int(statement, 10, row.expires == nil ? 0 : 1)
        sqlite3_bind_int(statement, 11, Int32(row.sameSite))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
}

private func readCookies(_ rows: [Row], version: Int = 24, now: Date = Date()) throws -> (cookies: [ImportedCookie], undecryptable: Int) {
    let folder = try TemporaryDirectory()
    try cookiesDB(rows, version: version, in: folder.url)
    return try ChromiumReader.cookies(profile: folder.url, key: key, now: now)
}

@Test func stripsTheHostHashOnVersion24() throws {
    let result = try readCookies([Row()])
    #expect(result.cookies.map(\.value) == ["secret-value"])
    #expect(result.cookies.first?.domain == ".example.com")
}

@Test func keepsValuesWithoutTheHostHash() throws {
    var row = Row()
    row.hashPrefix = false
    row.value = String(repeating: "x", count: 40)   // long enough to be mistaken for a prefix
    #expect(try readCookies([row]).cookies.map(\.value) == [row.value])
}

@Test func oldVersionsKeepThePlaintext() throws {
    var row = Row()
    row.hashPrefix = false
    #expect(try readCookies([row], version: 23).cookies.map(\.value) == ["secret-value"])
}

@Test func skipsPartitionedAndExpiredCookies() throws {
    var partitioned = Row(), expired = Row()
    partitioned.partition = "https://top.example"
    expired.name = "old"
    expired.expires = Date().addingTimeInterval(-60)
    #expect(try readCookies([Row(), partitioned, expired]).cookies.map(\.name) == ["session"])
}

@Test func sessionCookiesHaveNoExpiry() throws {
    var row = Row()
    row.expires = nil
    let cookies = try readCookies([row]).cookies
    #expect(cookies.count == 1 && cookies[0].expires == nil)
}

@Test func farExpiriesAreClampedTo400Days() throws {
    let now = Date()
    var row = Row()
    row.expires = now.addingTimeInterval(5 * 365 * 86_400)
    let expires = try #require(try readCookies([row], now: now).cookies.first?.expires)
    #expect(abs(expires.timeIntervalSince(now) - 400 * 86_400) < 2)
}

@Test func mapsSameSite() throws {
    let rows = [-1, 0, 1, 2].map { value -> Row in var row = Row(); row.name = "s\(value)"; row.sameSite = value; return row }
    #expect(try readCookies(rows).cookies.map(\.sameSite) == [nil, nil, "lax", "strict"])
}

@Test func countsUndecryptableRows() throws {
    var bad = Row()
    bad.name = "bad"
    bad.garbage = true
    let result = try readCookies([Row(), bad])
    #expect(result.cookies.map(\.name) == ["session"] && result.undecryptable == 1)
}

@Test func cookieCountNeedsNoKey() throws {
    let folder = try TemporaryDirectory()
    var partitioned = Row()
    partitioned.partition = "https://top.example"
    try cookiesDB([Row(), Row(name: "two"), partitioned], in: folder.url)
    #expect(ChromiumReader.cookieCount(profile: folder.url) == 2)
}
