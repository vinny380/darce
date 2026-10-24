import Foundation
import XCTest
@testable import BrowserCore

@MainActor
final class ArchiveClockPersistenceTests: XCTestCase {
    func testMigrationRestartAndStrictStartGatePreserveTabsUntilEligible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-clock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        let firstSweep = Date(timeIntervalSince1970: 1_000)
        var old = BrowserState()
        let stale = old.openTab(url: URL(string: "https://old.invalid")!, now: .init(timeIntervalSince1970: 0))
        let recent = old.openTab(url: URL(string: "https://recent.invalid")!, now: firstSweep.addingTimeInterval(50))
        let selected = old.openTab(url: URL(string: "https://selected.invalid")!, now: firstSweep)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["schemaVersion"] = 3
        json.removeValue(forKey: "autoArchiveStartTime")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let store = try BrowserWorkspaceStore(fileURL: file)
        let window = store.openWindow()
        XCTAssertNil(store.state.autoArchiveStartTime)
        XCTAssertEqual(try store.autoArchive(windowID: window, olderThan: 100, now: firstSweep), [])
        XCTAssertEqual(store.state.autoArchiveStartTime, firstSweep)
        let reopened = try BrowserWorkspaceStore(fileURL: file)
        let restoredWindow = reopened.openWindow()
        XCTAssertEqual(reopened.state.schemaVersion, 5)
        XCTAssertEqual(reopened.state.autoArchiveStartTime, firstSweep)
        XCTAssertEqual(reopened.state.tabs, old.tabs)
        XCTAssertEqual(try reopened.autoArchive(windowID: restoredWindow, olderThan: 100, now: firstSweep.addingTimeInterval(-100)), [])
        XCTAssertEqual(try reopened.autoArchive(windowID: restoredWindow, olderThan: 100, now: firstSweep.addingTimeInterval(100)), [])
        XCTAssertEqual(try reopened.autoArchive(windowID: restoredWindow, olderThan: 100, now: firstSweep.addingTimeInterval(101)), [stale])
        let saved = try BrowserStateFile.read(from: file)
        XCTAssertEqual(saved.autoArchiveStartTime, firstSweep)
        XCTAssertEqual(saved.selectedTabID, selected)
        XCTAssertEqual(saved.tabs.first { $0.id == recent }?.kind, .today)
        XCTAssertEqual(saved.tabs.first { $0.id == stale }?.kind, .archived)
    }

    func testDisabledAndSecondWindowSweepsInitializeOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-clock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let store = try BrowserWorkspaceStore(fileURL: file)
        let a = store.openWindow(), b = store.openWindow()
        let first = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(try store.autoArchive(windowID: a, olderThan: nil, now: first), [])
        XCTAssertEqual(try store.autoArchive(windowID: b, olderThan: 100, now: first.addingTimeInterval(200)), [])
        XCTAssertEqual(try store.autoArchive(windowID: a, olderThan: nil, now: first.addingTimeInterval(500)), [])
        XCTAssertEqual(store.state(for: a)?.autoArchiveStartTime, first)
        XCTAssertEqual(store.state(for: b)?.autoArchiveStartTime, first)
        XCTAssertEqual(try BrowserStateFile.read(from: file).autoArchiveStartTime, first)
    }

    func testFailedClockWriteCannotAdvanceInMemoryState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-clock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = directory.appendingPathComponent("blocked-parent")
        let store = try BrowserWorkspaceStore(fileURL: parent.appendingPathComponent("session.json"))
        let window = store.openWindow()
        let original = store.state
        let blocker = Data("owned fixture".utf8)
        try blocker.write(to: parent)
        XCTAssertThrowsError(try store.autoArchive(windowID: window, olderThan: 100, now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(store.state, original)
        XCTAssertNil(store.state.autoArchiveStartTime)
        XCTAssertEqual(try Data(contentsOf: parent), blocker)
    }
}
