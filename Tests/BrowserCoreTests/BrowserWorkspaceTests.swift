import Foundation
import XCTest
@testable import BrowserCore

@MainActor
final class BrowserWorkspaceTests: XCTestCase {
    private func fixture() throws -> (URL, BrowserWorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try BrowserWorkspaceStore(fileURL: directory.appendingPathComponent("session.json")))
    }

    func testInterleavedWindowsKeepBothWritesAndIndependentSelection() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = store.openWindow(), b = store.openWindow()
        var first: UUID!, second: UUID!
        try store.update(windowID: a) { first = $0.openTab(url: URL(string: "https://a.invalid")!) }
        try store.update(windowID: b) { second = $0.openTab(url: URL(string: "https://b.invalid")!) }
        XCTAssertEqual(store.state(for: a)?.selectedTabID, first)
        XCTAssertEqual(store.state(for: b)?.selectedTabID, second)
        XCTAssertEqual(Set(try BrowserStateFile.read(from: store.fileURL).tabs.map(\.id)), Set([first!, second!]))
    }

    func testProjectionPreservesNilAndActivityAndRepairsProfileVisibility() throws {
        var state = BrowserState()
        let timestamp = Date(timeIntervalSince1970: 100)
        let tab = state.openTab(url: URL(string: "https://favorite.invalid")!, now: timestamp)
        state.setKind(tab, kind: .favorite, now: timestamp)
        let otherSpace = state.spaces[1].id
        state.selectSpace(otherSpace, now: timestamp)
        let selection = BrowserWindowSelection(state: state)
        let projected = state.applying(windowSelection: selection)
        XCTAssertEqual(projected.tabs, state.tabs)
        state.clearSelection()
        XCTAssertNil(projected.applying(windowSelection: BrowserWindowSelection(state: state)).selectedTabID)
        let profile = state.addProfile(name: "Other")
        _ = state.assignSpaceProfile(otherSpace, profileID: profile)
        XCTAssertNil(state.applying(windowSelection: selection).selectedTabID)
    }

    func testFailedWriteDoesNotPublishOrReplaceMemory() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = store.openWindow()
        let original = store.state(for: id)
        var notifications = 0
        store.observe(windowID: id) { _ in notifications += 1 }
        try FileManager.default.removeItem(at: directory)
        try Data("blocking parent".utf8).write(to: directory)
        XCTAssertThrowsError(try store.update(windowID: id) { _ = $0.openTab(url: URL(string: "https://unsaved.invalid")!) })
        XCTAssertEqual(store.state(for: id), original)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(try Data(contentsOf: directory), Data("blocking parent".utf8))
    }

    func testArchivingRepairsOtherWindowAndPreservesIntentionalNil() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = store.openWindow(), b = store.openWindow()
        var id: UUID!
        try store.update(windowID: a) { id = $0.openTab(url: URL(string: "https://archive.invalid")!) }
        try store.update(windowID: b) { $0.selectTab(id) }
        let empty = store.openWindow()
        try store.update(windowID: empty) { $0.clearSelection() }
        try store.update(windowID: a) { $0.archiveTab(id) }
        XCTAssertNil(store.state(for: b)?.selectedTabID)
        XCTAssertNil(store.state(for: empty)?.selectedTabID)
    }

    func testAutomaticArchiveProtectsAllWindowSelections() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = store.openWindow(), b = store.openWindow()
        let old = Date(timeIntervalSince1970: 10), now = Date(timeIntervalSince1970: 1000)
        _ = try store.autoArchive(windowID: a, olderThan: 100, now: old)
        var first: UUID!, second: UUID!, unselected: UUID!
        try store.update(windowID: a) {
            first = $0.openTab(url: URL(string: "https://first.invalid")!, now: old)
            unselected = $0.openTab(url: URL(string: "https://unselected.invalid")!, now: old)
            $0.selectTab(first, now: old)
        }
        try store.update(windowID: b) { second = $0.openTab(url: URL(string: "https://second.invalid")!, now: old) }
        let archived = try store.autoArchive(windowID: a, olderThan: 100, now: now)
        XCTAssertEqual(archived, [unselected!])
        XCTAssertEqual(store.state(for: a)?.selectedTabID, first)
        XCTAssertEqual(store.state(for: b)?.selectedTabID, second)
    }

    func testClosedWindowAndReentrantMutationCannotWrite() throws {
        let (directory, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = store.openWindow()
        try store.update(windowID: id) { _ in
            var rejected = false
            do { try store.update(windowID: id) { _ = $0.addSpace(name: "Nested") } }
            catch { rejected = true }
            XCTAssertTrue(rejected)
        }
        store.closeWindow(id)
        XCTAssertThrowsError(try store.update(windowID: id) { _ = $0.addSpace(name: "Closed") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testCorruptFilePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json"), bytes = Data("broken session".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try BrowserWorkspaceStore(fileURL: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let recovery = BrowserWorkspaceStore(preservingUnreadableFile: file)
        let id = recovery.openWindow()
        try recovery.update(windowID: id) { _ = $0.openTab(url: URL(string: "https://recovery.invalid")!) }
        XCTAssertTrue(recovery.isVolatile)
        XCTAssertEqual(recovery.state(for: id)?.tabs.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
