import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
import UniformTypeIdentifiers
@testable import BrowserCore

/// Bringing over site icons from a Chromium profile's Favicons database. Each test names the bug it catches.
func pngFixture(size: Int, red: CGFloat) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// `pages`: page URL → icon number; `bitmaps`: icon number → [(width, png)].
func faviconsDB(pages: [(String, Int)], bitmaps: [Int: [(Int, Data)]], in profile: URL) throws {
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open(profile.appendingPathComponent("Favicons").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER, page_url_type INTEGER DEFAULT 0);
        CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0,
          image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0);
        """, nil, nil, nil)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (page, icon) in pages {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO icon_mapping(page_url, icon_id) VALUES(?, ?)", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, page, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(icon))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    for (icon, sizes) in bitmaps {
        for (width, data) in sizes {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO favicon_bitmaps(icon_id, image_data, width, height) VALUES(?, ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(icon))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
            sqlite3_bind_int(statement, 3, Int32(width))
            sqlite3_bind_int(statement, 4, Int32(width))
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
}

@Test func picksThe32PixelIconForAnExactPage() throws {
    let folder = try TemporaryDirectory()
    let small = pngFixture(size: 16, red: 0.1), large = pngFixture(size: 32, red: 0.9)
    try faviconsDB(pages: [("https://mail.example/inbox", 1)], bitmaps: [1: [(16, small), (32, large)]], in: folder.url)
    let icons = ChromiumReader.icons(profile: folder.url, pages: [URL(string: "https://mail.example/inbox")!])
    #expect(icons["https://mail.example/inbox"] == large)
}

@Test func fallsBackToAnotherPageOnTheSameSite() throws {
    let folder = try TemporaryDirectory()
    let icon = pngFixture(size: 32, red: 0.5)
    try faviconsDB(pages: [("https://mail.example/u/0/#inbox", 1)], bitmaps: [1: [(32, icon)]], in: folder.url)
    let icons = ChromiumReader.icons(profile: folder.url, pages: [URL(string: "https://mail.example/")!])
    #expect(icons["https://mail.example/"] == icon)
}

@Test func skipsIconsThatArentUsablePNGs() throws {
    let folder = try TemporaryDirectory()
    let huge = pngFixture(size: 256, red: 0.5)
    try faviconsDB(pages: [("https://a.example/", 1), ("https://b.example/", 2)],
                   bitmaps: [1: [(32, Data("not a png".utf8))], 2: [(256, huge)]], in: folder.url)
    let icons = ChromiumReader.icons(profile: folder.url, pages: [URL(string: "https://a.example/")!, URL(string: "https://b.example/")!])
    #expect(icons.isEmpty)
}

@Test func noFaviconsDatabaseMeansNoIcons() throws {
    let folder = try TemporaryDirectory()
    #expect(ChromiumReader.icons(profile: folder.url, pages: [URL(string: "https://a.example/")!]).isEmpty)
}

@Test func importedPinsAndFavoritesShowTheirIconBeforeLoading() throws {
    var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
    profile.spaces = [ImportedSpace(key: "arc-space:icons", name: "Work",
                                    pinned: [.tab(key: "arc:pin", title: "Mail", url: URL(string: "https://mail.example/")!)])]
    profile.favorites = [.tab(key: "arc:fav", title: "Chat", url: URL(string: "https://chat.example/")!)]
    let icon = pngFixture(size: 32, red: 0.3)
    profile.icons = ["https://mail.example/": icon, "https://chat.example/": icon]
    var state = BrowserState()
    _ = state.applyImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    for title in ["Mail", "Chat"] {
        let tab = try #require(state.tabs.first { $0.title == title })
        #expect(state.savedFaviconPNG(forTab: tab.id) == icon)
    }
}
