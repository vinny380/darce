import Foundation
import Testing
@testable import BrowserCore

@Test func historyCoalescesExactURLsWithoutLeakingProfiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("nested/history.json")
    var store = try HistoryStore(fileURL: path)
    let personal = UUID(), work = UUID()
    let url = URL(string: "https://example.com/page?q=1#one")!
    let old = Date(timeIntervalSince1970: 1000), recent = Date(timeIntervalSince1970: 2000)
    try store.record(url: url, title: "Old", profileID: personal, visitedAt: old)
    let identity = try #require(store.search("", profileID: personal).first?.id)
    try store.record(url: url, title: "New & improved", profileID: personal, visitedAt: recent)
    try store.record(url: url, title: "Stale callback", profileID: personal, visitedAt: old)
    try store.record(url: url, title: "Secret Work", profileID: work, visitedAt: recent)
    try store.record(url: URL(string: "https://example.com/page?q=1#two")!, title: "Second", profileID: personal, visitedAt: old)
    #expect(store.search("", profileID: personal).count == 2)
    #expect(store.search("NEW", profileID: personal).first?.id == identity)
    #expect(store.search("secret", profileID: personal).isEmpty)
    #expect(store.search("", profileID: personal, limit: -1).isEmpty)
    #expect(store.search("", profileID: personal, limit: 1).count == 1)
    #expect(store.groups(profileID: personal).flatMap(\.records).count == 2)
    let reloaded = try HistoryStore(fileURL: path)
    #expect(reloaded.search("", profileID: personal) == store.search("", profileID: personal))
    try store.remove(id: identity, profileID: work)
    #expect(store.search("", profileID: personal).count == 2)
    try store.clear(profileID: personal, since: recent)
    #expect(store.search("", profileID: personal).count == 1)
    #expect(store.search("", profileID: work).count == 1)
}

@Test func historyPreservesCorruptFilesAndRollsBackFailedWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.json")
    for bytes in [Data("{broken".utf8), Data("{\"schemaVersion\":99,\"records\":[]}".utf8)] {
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try HistoryStore(fileURL: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
    try FileManager.default.removeItem(at: path)
    var store = try HistoryStore(fileURL: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    let profile = UUID()
    #expect(throws: (any Error).self) {
        try store.record(url: URL(string: "https://example.com")!, title: "Cannot save", profileID: profile)
    }
    #expect(store.search("", profileID: profile).isEmpty)
}

@Test func netscapeHTMLMaintainsHierarchyEntitiesEmptyFoldersAndReportsUnsafeLinks() throws {
    let html = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
    <DL><p>
      <DT><H3>Work &amp; Study</H3>
      <DL><p>
        <DT><A HREF="https://example.com/?a=1&amp;b=2">Café &lt;Research&gt;</A>
        <DT><H3>Empty</H3><DL><p></DL><p>
        <DT><H3>Deep</H3><DL><p><DT><A HREF='https://deep.example'>Deep</A></DL><p>
      </DL><p>
      <DT><A HREF="https://root.example/">Root</A>
      <DT><A HREF="javascript:alert(1)">Unsafe</A>
    </DL><p>
    """
    let result = try NetscapeBookmarks.parse(Data(html.utf8))
    #expect(result.roots.count == 2)
    #expect(result.roots[0].title == "Work & Study")
    #expect(result.roots[0].children?.map(\.title) == ["Café <Research>", "Empty", "Deep"])
    #expect(result.roots[0].children?[0].url?.absoluteString == "https://example.com/?a=1&b=2")
    #expect(result.roots[0].children?[1].children == [])
    #expect(result.issues.count == 1)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("bookmarks.html")
    try NetscapeBookmarks.write(result.roots, to: path)
    let reimported = try NetscapeBookmarks.read(from: path)
    #expect(reimported.roots == result.roots)
    #expect(reimported.issues.isEmpty)
}

@Test func bookmarkMalformedHierarchyRejectsRatherThanPartiallyImporting() throws {
    let malformed = [
        "<html><A HREF='https://example.com'>No list</A></html>",
        "<DL><DT><A HREF='https://example.com'>Unclosed</A>",
        "<DL></DL></DL>",
        "<DL><DT><H3>Orphan</H3></DL>",
    ]
    for html in malformed {
        #expect(throws: (any Error).self) { try NetscapeBookmarks.parse(Data(html.utf8)) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("bookmarks.html")
    let original = Data("original export".utf8)
    try original.write(to: path)
    #expect(throws: (any Error).self) {
        try NetscapeBookmarks.write([.bookmark(title: "Unsafe", url: URL(string: "file:///etc/passwd")!)], to: path)
    }
    #expect(try Data(contentsOf: path) == original)
}
