import Foundation
import Testing
@testable import BrowserCore

/// Easel drawing items (Arc's shapes, arrows, freehand). Each test names the bug it catches.
private func store() throws -> (DocumentStore, URL, UUID, UUID) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store = try DocumentStore(directory: directory)
    let profile = UUID()
    let easel = try store.create(kind: .easel, title: "Untitled Easel", profileID: profile)
    return (store, directory, profile, easel)
}

@Test func shapesArrowsAndStrokesSurviveReloading() throws {
    var (store, directory, profile, easel) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let points = [DrawingPoint(x: 0, y: 0), DrawingPoint(x: 40, y: 12), DrawingPoint(x: 90, y: 60)]
    let rect = try store.addCard(.shape(.rectangle, color: "#FF5A5F"), documentID: easel, profileID: profile, x: 10, y: 20, width: 200, height: 120)
    let stroke = try store.addCard(.stroke(points, color: "#300EFF"), documentID: easel, profileID: profile, x: 300, y: 40, width: 90, height: 60)
    let reloaded = try DocumentStore(directory: directory).document(easel, profileID: profile)
    #expect(reloaded?.cards.first { $0.id == rect }?.content == .shape(.rectangle, color: "#FF5A5F"))
    #expect(reloaded?.cards.first { $0.id == stroke }?.content == .stroke(points, color: "#300EFF"))
}

@Test func aStraightArrowIsValidEvenThoughItHasNoHeight() throws {
    var (store, directory, profile, easel) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try store.addCard(.arrow(from: DrawingPoint(x: 0, y: 0), to: DrawingPoint(x: 300, y: 0), color: "#55B948"),
                          documentID: easel, profileID: profile, x: 50, y: 50, width: 300, height: 1)
    #expect(try DocumentStore(directory: directory).document(easel, profileID: profile)?.cards.count == 1)
}

@Test func badColorsAreRejectedBeforeSaving() throws {
    var (store, directory, profile, easel) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: DocumentStoreError.invalidRecords) {
        try store.addCard(.shape(.ellipse, color: "red; drop"), documentID: easel, profileID: profile, x: 0, y: 0, width: 50, height: 50)
    }
    #expect(store.document(easel, profileID: profile)?.cards.isEmpty == true)
}

@Test func deletingAnImageCardAlsoDeletesItsFile() throws {
    var (store, directory, profile, easel) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A real 1×1 PNG: the store checks the image before keeping it.
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    let card = try store.addCaptureCard(documentID: easel, profileID: profile, png: png, altText: "Capture")
    let file = directory.appendingPathComponent("documents/images/\(card.uuidString).png")
    #expect(FileManager.default.fileExists(atPath: file.path))
    try store.deleteCard(card, documentID: easel, profileID: profile)
    #expect(store.document(easel, profileID: profile)?.cards.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func textCanBePlacedWhereYouClick() throws {
    var (store, directory, profile, easel) = try store()
    defer { try? FileManager.default.removeItem(at: directory) }
    let card = try store.addCard(.text("Hello"), documentID: easel, profileID: profile, x: 640, y: 380, width: 220, height: 80)
    let placed = store.document(easel, profileID: profile)?.cards.first { $0.id == card }
    #expect(placed?.x == 640 && placed?.y == 380)
}
