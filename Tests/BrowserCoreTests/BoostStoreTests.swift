import Foundation
import Testing
@testable import BrowserCore

@Test func boostsPersistAndRemainProfileAndHostScoped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("nested/boosts.json")
    let personal = UUID(), work = UUID()
    var store = try BoostStore(fileURL: path)
    let boost = BrowserBoost(profileID: personal, host: "EXAMPLE.com", name: "Reading", css: "body { color: red; }", hiddenSelectors: [".ads"])
    try store.save(boost)
    try store.save(BrowserBoost(profileID: work, host: "example.com", name: "Work", css: "body { color: blue; }"))
    #expect(store.matching(profileID: personal, host: "example.com").map(\.id) == [boost.id])
    #expect(store.matching(profileID: personal, host: "sub.example.com").isEmpty)
    let reloaded = try BoostStore(fileURL: path)
    #expect(reloaded.boosts == store.boosts)
    var edited = boost
    edited.enabled = false
    try store.save(edited)
    #expect(store.matching(profileID: personal, host: "example.com").isEmpty)
    #expect(store.boosts.count == 2)
    try store.remove(id: boost.id, profileID: work)
    #expect(store.boosts.count == 2)
    try store.remove(id: boost.id, profileID: personal)
    #expect(store.boosts.count == 1)
}

@Test func boostFilesNeverOverwriteCorruptionOrLoseStateOnWriteFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("boosts.json")
    for bytes in [Data("broken".utf8), Data("{\"schemaVersion\":99,\"boosts\":[]}".utf8)] {
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { try BoostStore(fileURL: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }
    try FileManager.default.removeItem(at: path)
    var store = try BoostStore(fileURL: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) {
        try store.save(BrowserBoost(profileID: UUID(), host: "example.com", name: "Unsaved", css: "body{}"))
    }
    #expect(store.boosts.isEmpty)
}
