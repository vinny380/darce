import Foundation
import Testing
@testable import BrowserCore

private let documentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZpS8AAAAASUVORK5CYII=")!

@Test func documentsRoundTripTrashAndRestoreWithoutLosingCardsOrImages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = UUID()
    var store = try DocumentStore(directory: directory)
    let note = try store.create(kind: .note, title: "Note", profileID: profile)
    try store.updateNote(note, profileID: profile, text: "Keep this text.\nSecond line.")
    let easel = try store.create(kind: .easel, title: "Board", profileID: profile)
    let text = try store.addTextCard(documentID: easel, profileID: profile, text: "Card")
    let capture = try store.addCaptureCard(documentID: easel, profileID: profile, png: documentPNG, altText: "Static capture")
    try store.updateCard(text, documentID: easel, profileID: profile, x: 70, y: 90, width: 360, height: 240)
    try store.updateTextCards(easel, profileID: profile, values: [text: "Changed card"])
    let original = try #require(store.document(easel, profileID: profile))
    try store.trash(easel, profileID: profile)
    #expect(store.document(easel, profileID: profile) == nil)
    #expect(store.documents(profileID: profile).map(\.id) == [note])
    #expect(store.documents(profileID: profile, includeTrashed: true).count == 2)
    store = try DocumentStore(directory: directory)
    try store.restore(easel, profileID: profile)
    let restored = try #require(store.document(easel, profileID: profile))
    #expect(restored.cards == original.cards)
    #expect(restored.id == original.id && restored.profileID == profile && restored.createdAt == original.createdAt)
    #expect(restored.trashedAt == nil)
    #expect(try store.imageData(documentID: easel, cardID: capture, profileID: profile) == documentPNG)
    #expect(store.document(note, profileID: profile)?.text == "Keep this text.\nSecond line.")
}

@Test func documentsRejectEveryCrossProfileAccess() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = UUID(), other = UUID()
    var store = try DocumentStore(directory: directory)
    let note = try store.create(kind: .note, title: "Private", profileID: owner)
    let easel = try store.create(kind: .easel, title: "Private Board", profileID: owner)
    let capture = try store.addCaptureCard(documentID: easel, profileID: owner, png: documentPNG, altText: "Private image")
    let text = try store.addTextCard(documentID: easel, profileID: owner, text: "Private text")
    let before = store.documents(profileID: owner)
    #expect(store.documents(profileID: other, includeTrashed: true).isEmpty)
    #expect(store.document(note, profileID: other, includeTrashed: true) == nil)
    #expect(throws: (any Error).self) { try store.rename(note, profileID: other, title: "Stolen") }
    #expect(throws: (any Error).self) { try store.updateNote(note, profileID: other, text: "Stolen") }
    #expect(throws: (any Error).self) { try store.updateTextCards(easel, profileID: other, values: [text: "Stolen"]) }
    #expect(throws: (any Error).self) { try store.updateCard(text, documentID: easel, profileID: other, x: 0, y: 0, width: 200, height: 200) }
    #expect(throws: (any Error).self) { try store.addTextCard(documentID: easel, profileID: other, text: "Stolen") }
    #expect(throws: (any Error).self) { try store.addCaptureCard(documentID: easel, profileID: other, png: documentPNG, altText: "Stolen") }
    #expect(throws: (any Error).self) { try store.imageData(documentID: easel, cardID: capture, profileID: other) }
    #expect(throws: (any Error).self) { try store.exportHTML(easel, profileID: other) }
    #expect(throws: (any Error).self) { try store.trash(note, profileID: other) }
    #expect(throws: (any Error).self) { try store.restore(note, profileID: other) }
    #expect(store.documents(profileID: owner) == before)
}

@Test func documentValidationAndWriteFailurePreserveManifestAndMemory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = UUID()
    var store = try DocumentStore(directory: directory)
    let easel = try store.create(kind: .easel, title: "Board", profileID: profile)
    let card = try store.addTextCard(documentID: easel, profileID: profile, text: "Keep")
    let manifest = directory.appendingPathComponent("documents/manifest.json")
    let original = try Data(contentsOf: manifest), snapshot = store.documents(profileID: profile)
    for invalid in [Double.nan, .infinity, -1, 20_001] {
        #expect(throws: (any Error).self) { try store.updateCard(card, documentID: easel, profileID: profile, x: invalid, y: 0, width: 200, height: 200) }
        #expect(try Data(contentsOf: manifest) == original)
        #expect(store.documents(profileID: profile) == snapshot)
    }
    #expect(throws: (any Error).self) { try store.addCaptureCard(documentID: easel, profileID: profile, png: Data("not PNG".utf8), altText: "Bad") }
    var oversized = documentPNG
    oversized.replaceSubrange(16..<24, with: [0, 0, 128, 0, 0, 0, 128, 0])
    #expect(throws: (any Error).self) { try store.addCaptureCard(documentID: easel, profileID: profile, png: oversized, altText: "Too many pixels") }
    let moved = directory.appendingPathComponent("preserved-manifest.json")
    try FileManager.default.moveItem(at: manifest, to: moved)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.addCaptureCard(documentID: easel, profileID: profile, png: documentPNG, altText: "Cannot commit") }
    #expect(store.documents(profileID: profile) == snapshot)
    #expect(try Data(contentsOf: moved) == original)
    let images = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("documents/images"), includingPropertiesForKeys: nil)
    #expect(images.isEmpty)
    try FileManager.default.removeItem(at: manifest)
    try original.write(to: manifest)
    let decoded = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    var future = decoded
    future["schemaVersion"] = 99
    let invalidFiles = [Data("{broken-documents".utf8), try JSONSerialization.data(withJSONObject: future)]
    for bytes in invalidFiles {
        try bytes.write(to: manifest)
        #expect(throws: (any Error).self) { try DocumentStore(directory: directory) }
        #expect(try Data(contentsOf: manifest) == bytes)
    }
}

@Test func documentHTMLIsEscapedSelfContainedAndRejectsImagePaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = UUID()
    var store = try DocumentStore(directory: directory)
    let note = try store.create(kind: .note, title: "<script>Title</script>", profileID: profile)
    try store.updateNote(note, profileID: profile, text: "<img src='https://example.com'> & text")
    let noteHTML = try store.exportHTML(note, profileID: profile)
    #expect(noteHTML.contains("&lt;script&gt;Title&lt;/script&gt;"))
    #expect(noteHTML.contains("&lt;img src=&#39;https://example.com&#39;&gt; &amp; text"))
    #expect(!noteHTML.contains("<script>") && !noteHTML.contains("<img src='https"))
    let easel = try store.create(kind: .easel, title: "Easel", profileID: profile)
    _ = try store.addTextCard(documentID: easel, profileID: profile, text: "<b>plain text</b>")
    _ = try store.addCaptureCard(documentID: easel, profileID: profile, png: documentPNG, altText: "\" onload=\"bad")
    let html = try store.exportHTML(easel, profileID: profile)
    #expect(html.contains("&lt;b&gt;plain text&lt;/b&gt;"))
    #expect(html.contains("data:image/png;base64," + documentPNG.base64EncodedString()))
    #expect(html.contains("alt=\"&quot; onload=&quot;bad\""))
    #expect(html.contains("default-src 'none'"))
    let manifest = directory.appendingPathComponent("documents/manifest.json")
    let valid = try String(contentsOf: manifest, encoding: .utf8)
    let pattern = #"[A-F0-9-]{36}\.png"#
    let malicious = valid.replacingOccurrences(of: pattern, with: "../../escape.png", options: .regularExpression)
    #expect(malicious != valid)
    try Data(malicious.utf8).write(to: manifest)
    #expect(throws: (any Error).self) { try DocumentStore(directory: directory) }
    #expect(try String(contentsOf: manifest, encoding: .utf8) == malicious)
}
