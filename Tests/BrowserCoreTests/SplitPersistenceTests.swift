import Foundation
import XCTest
@testable import BrowserCore

@MainActor
final class SplitPersistenceTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("split-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session.json")
    }
    private func tabs(_ count: Int = 5) -> (BrowserState, [UUID]) {
        var state = BrowserState()
        let ids = (0..<count).map { state.openTab(url: URL(string: "https://split.invalid/\($0)")!, now: Date(timeIntervalSince1970: 10)) }
        state.selectTab(ids[0], now: Date(timeIntervalSince1970: 10))
        return (state, ids)
    }

    func testLegacyReadsKeepBytesRecordsAndEmptyGroups() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (original, ids) = tabs()
        let folder = try XCTUnwrap(original.createFolder(name: "Saved", spaceID: original.selectedSpaceID))
        XCTAssertTrue(original.moveTab(ids[1], into: folder))
        original.archiveTab(ids[2])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for version in 1...4 {
            var old = encoded
            old["schemaVersion"] = version
            old.removeValue(forKey: "splitGroups")
            if version < 3 {
                old.removeValue(forKey: "profiles")
                old["spaces"] = try XCTUnwrap(old["spaces"] as? [[String: Any]]).map { space in
                    var value = space; value.removeValue(forKey: "profileID"); return value
                }
            }
            let bytes = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
            try bytes.write(to: path)
            let migrated = try BrowserStateFile.read(from: path)
            XCTAssertEqual(migrated.schemaVersion, 5)
            XCTAssertTrue(migrated.splitGroups.isEmpty)
            XCTAssertEqual(migrated.tabs, original.tabs)
            XCTAssertEqual(migrated.folders, original.folders)
            XCTAssertEqual(migrated.spaces.map(\.id), original.spaces.map(\.id))
            XCTAssertEqual(migrated.selectedTabID, original.selectedTabID)
            XCTAssertEqual(try BrowserStateFile.read(from: path).profiles, migrated.profiles)
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testLayoutRoundTripCarriesWeightsWithMembersAndDissolvesWithoutDeletingTabs() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (state, ids) = tabs()
        let records = state.tabs
        XCTAssertTrue(state.addToSplit(ids[1]))
        let group = try XCTUnwrap(state.selectedSplitGroup?.id)
        XCTAssertTrue(state.resizeSplit(group, weights: [0.25, 0.75]))
        XCTAssertTrue(state.addToSplit(ids[2]))
        let appended = try XCTUnwrap(state.selectedSplitGroup)
        XCTAssertEqual(appended.weights[0] / appended.weights[1], 1.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(appended.weights[2], 1.0 / 3, accuracy: 1e-10)
        XCTAssertTrue(state.reorderSplit(group, tabIDs: [ids[2], ids[0], ids[1]]))
        XCTAssertTrue(state.setSplitAxis(group, axis: .vertical))
        try BrowserStateFile.write(state, to: path)
        var reopened = try BrowserStateFile.read(from: path)
        let restored = try XCTUnwrap(reopened.selectedSplitGroup)
        XCTAssertEqual(restored.id, group)
        XCTAssertEqual(restored.axis, .vertical)
        XCTAssertEqual(restored.tabIDs, [ids[2], ids[0], ids[1]])
        XCTAssertEqual(restored.weights, [appended.weights[2], appended.weights[0], appended.weights[1]])
        XCTAssertEqual(reopened.displayedTabIDs, restored.tabIDs)
        XCTAssertEqual(reopened.tabs, records)
        XCTAssertTrue(reopened.removeFromSplit(ids[0]))
        XCTAssertTrue(reopened.removeFromSplit(ids[1]))
        XCTAssertTrue(reopened.splitGroups.isEmpty)
        XCTAssertEqual(reopened.tabs, records)
        reopened.selectTab(ids[0])
        XCTAssertTrue(reopened.addToSplit(ids[1]))
        let recreated = try XCTUnwrap(reopened.selectedSplitGroup?.id)
        let beforeDissolve = reopened.tabs
        XCTAssertTrue(reopened.dissolveSplit(recreated))
        XCTAssertEqual(reopened.tabs, beforeDissolve)
        try BrowserStateFile.write(reopened, to: path)
        XCTAssertTrue(try BrowserStateFile.read(from: path).splitGroups.isEmpty)
    }

    func testRejectedEditsLeaveSavedSplitAndRecordsUntouched() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (state, ids) = tabs()
        XCTAssertTrue(state.addToSplit(ids[1]))
        let group = try XCTUnwrap(state.selectedSplitGroup?.id)
        try BrowserStateFile.write(state, to: path)
        let snapshot = state, bytes = try Data(contentsOf: path)
        for weights in [[0.0, 1.0], [-0.1, 1.1], [Double.nan, 0.5], [.infinity, 0.5], [0.4, 0.4], [1.0]] {
            XCTAssertFalse(state.resizeSplit(group, weights: weights))
            XCTAssertEqual(state, snapshot)
        }
        XCTAssertFalse(state.reorderSplit(group, tabIDs: [ids[1], ids[1]]))
        XCTAssertEqual(state, snapshot)
        XCTAssertFalse(state.addToSplit(ids[0]))
        XCTAssertEqual(state, snapshot)
        XCTAssertTrue(state.addToSplit(ids[1]))
        XCTAssertEqual(state, snapshot)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        state.selectTab(ids[2])
        XCTAssertTrue(state.addToSplit(ids[3]))
        let otherGroup = try XCTUnwrap(state.selectedSplitGroup?.id)
        state.selectTab(ids[0])
        let occupied = state
        XCTAssertFalse(state.addToSplit(ids[2]))
        XCTAssertEqual(state, occupied)
        XCTAssertTrue(state.dissolveSplit(otherGroup))
        XCTAssertTrue(state.addToSplit(ids[2]))
        XCTAssertTrue(state.addToSplit(ids[3]))
        let full = state
        XCTAssertFalse(state.addToSplit(ids[4]))
        XCTAssertEqual(state, full)
    }

    func testSchemaFiveCorruptGroupsNeverOverwriteRecoveryBytes() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (state, ids) = tabs()
        XCTAssertTrue(state.addToSplit(ids[1]))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let groups = try XCTUnwrap(valid["splitGroups"] as? [[String: Any]])
        var cases: [[String: Any]] = []
        var missing = valid; missing.removeValue(forKey: "splitGroups"); cases.append(missing)
        var future = valid; future["schemaVersion"] = 99; cases.append(future)
        for (key, value): (String, Any) in [
            ("weights", [0.0, 1.0]), ("weights", [0.3, 0.3]), ("weights", [1.0]),
            ("tabIDs", [ids[0].uuidString, ids[0].uuidString]),
            ("tabIDs", [ids[0].uuidString, UUID().uuidString]),
            ("spaceID", UUID().uuidString), ("axis", "future-axis"),
        ] {
            var badGroup = groups[0]; badGroup[key] = value
            var bad = valid; bad["splitGroups"] = [badGroup]; cases.append(bad)
        }
        var duplicate = groups[0]; duplicate["id"] = UUID().uuidString
        var overlapping = valid; overlapping["splitGroups"] = [groups[0], duplicate]; cases.append(overlapping)
        for json in cases {
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try bytes.write(to: path)
            XCTAssertThrowsError(try BrowserStateFile.read(from: path))
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testWindowFocusIsIndependentAndFailedResizeDoesNotPublish() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (initial, ids) = tabs()
        XCTAssertTrue(initial.addToSplit(ids[1]))
        try BrowserStateFile.write(initial, to: path)
        let store = try BrowserWorkspaceStore(fileURL: path)
        let a = store.openWindow(), b = store.openWindow()
        try store.update(windowID: b) { $0.selectTab(ids[1]) }
        XCTAssertEqual(store.state(for: a)?.selectedTabID, ids[0])
        XCTAssertEqual(store.state(for: b)?.selectedTabID, ids[1])
        XCTAssertEqual(store.state(for: a)?.displayedTabIDs, [ids[0], ids[1]])
        XCTAssertEqual(store.state(for: b)?.displayedTabIDs, [ids[0], ids[1]])
        let group = try XCTUnwrap(initial.selectedSplitGroup?.id)
        try store.update(windowID: b) { $0.selectTab(ids[2]); XCTAssertTrue($0.resizeSplit(group, weights: [0.3, 0.7])) }
        XCTAssertEqual(store.state(for: a)?.selectedTabID, ids[0])
        XCTAssertEqual(store.state(for: b)?.displayedTabIDs, [ids[2]])
        XCTAssertEqual(store.state(for: a)?.selectedSplitGroup?.weights, [0.3, 0.7])
        let snapshot = store.state, aBefore = store.state(for: a), bBefore = store.state(for: b)
        let bytes = try Data(contentsOf: path)
        let preserved = path.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: path, to: preserved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let sentinel = path.appendingPathComponent("owned-sentinel")
        try Data("keep".utf8).write(to: sentinel)
        var notifications = 0
        store.observe(windowID: a) { _ in notifications += 1 }
        store.observe(windowID: b) { _ in notifications += 1 }
        XCTAssertThrowsError(try store.update(windowID: a) { XCTAssertTrue($0.resizeSplit(group, weights: [0.6, 0.4])) })
        XCTAssertEqual(store.state, snapshot)
        XCTAssertEqual(store.state(for: a), aBefore)
        XCTAssertEqual(store.state(for: b), bBefore)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(try Data(contentsOf: preserved), bytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testOwnershipAndContainerChangesPruneGroupsWithoutDeletingTabs() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (state, ids) = tabs()
        let source = state.selectedSpaceID, destination = state.spaces[1].id
        let folder = try XCTUnwrap(state.createFolder(name: "Keep", spaceID: source))
        XCTAssertTrue(state.moveTab(ids[0], into: folder))
        XCTAssertTrue(state.addToSplit(ids[1]))
        let groupID = try XCTUnwrap(state.selectedSplitGroup?.id)
        let tabIDs = state.tabs.map(\.id)
        XCTAssertTrue(state.removeSpace(source, movingContentsTo: destination))
        XCTAssertEqual(state.splitGroups.first?.id, groupID)
        XCTAssertEqual(state.splitGroups.first?.spaceID, destination)
        XCTAssertEqual(state.tabs.map(\.id), tabIDs)
        XCTAssertEqual(state.tabs.first { $0.id == ids[0] }?.folderID, folder)
        state.archiveTab(ids[1])
        XCTAssertTrue(state.splitGroups.isEmpty)
        XCTAssertEqual(state.tabs.map(\.id), tabIDs)
        state.setKind(ids[0], kind: .favorite)
        let other = state.addSpace(name: "Other")
        state.selectSpace(other)
        let local = state.openTab(url: URL(string: "https://split.invalid/local")!)
        XCTAssertTrue(state.addToSplit(ids[0]))
        let before = state
        XCTAssertFalse(state.addToSplit(ids[2])) // ordinary tab is not visible in Other
        XCTAssertEqual(state, before)
        let foreignProfile = state.addProfile(name: "Different cookies")
        XCTAssertTrue(state.assignSpaceProfile(destination, profileID: foreignProfile))
        XCTAssertTrue(state.splitGroups.isEmpty) // Favorite no longer visible in Other
        XCTAssertEqual(state.profileID(forTab: local), before.profileID(forTab: local))
        XCTAssertEqual(state.tabs.count, tabIDs.count + 1)
        state.selectSpace(destination)
        state.selectTab(ids[2])
        XCTAssertTrue(state.addToSplit(ids[3]))
        state.moveTab(ids[3], to: other)
        XCTAssertTrue(state.splitGroups.isEmpty)
        XCTAssertEqual(state.tabs.count, tabIDs.count + 1)
        try BrowserStateFile.write(state, to: path)
        XCTAssertEqual(try BrowserStateFile.read(from: path), state)
    }

    func testArchiveProtectsLiveDisplayedMembersButNotDormantGroupsOrClosedWindows() throws {
        let path = try file()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var (initial, ids) = tabs()
        let old = Date(timeIntervalSince1970: 10), now = Date(timeIntervalSince1970: 1000)
        initial.initializeAutoArchiveClock(now: old)
        XCTAssertTrue(initial.addToSplit(ids[1]))
        initial.selectTab(ids[2], now: old)
        XCTAssertTrue(initial.addToSplit(ids[3]))
        initial.selectTab(ids[0], now: old)
        try BrowserStateFile.write(initial, to: path)
        let store = try BrowserWorkspaceStore(fileURL: path)
        let a = store.openWindow(), b = store.openWindow()
        try store.update(windowID: b) { $0.selectTab(ids[4], now: old) }
        let dormantArchived = try store.autoArchive(windowID: b, olderThan: 100, now: now)
        XCTAssertEqual(Set(dormantArchived), Set([ids[2], ids[3]]))
        XCTAssertEqual(store.state(for: a)?.displayedTabIDs, [ids[0], ids[1]])
        store.closeWindow(a)
        let closedArchived = try store.autoArchive(windowID: b, olderThan: 100, now: now)
        XCTAssertEqual(Set(closedArchived), Set([ids[0], ids[1]]))
        XCTAssertTrue(store.state.splitGroups.isEmpty)
        XCTAssertEqual(store.state.tabs.count, ids.count)
        XCTAssertEqual(store.state(for: b)?.selectedTabID, ids[4])
        XCTAssertEqual(try BrowserStateFile.read(from: path), store.state)
    }
}
