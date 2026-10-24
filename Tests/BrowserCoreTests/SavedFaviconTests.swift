import Foundation
import XCTest
@testable import BrowserCore

@MainActor
final class SavedFaviconTests: XCTestCase {
    private let red = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    private let blue = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==")!
    private let largest = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAABK0lEQVR4nO3SoQEAMBCEsNt/6e8YFUTEI9htR9d+B2AADIABMAAGwAAYAANgAAyAATAABsAAGAADYAAMgAEwAAbAABgAA2AADIABMAAGwAAYAANgAAyAATAABsAAGAADYAAMgAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8Q9VtGHcj7WUZsAAAAASUVORK5CYII=")!
    private let tooWide = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAIEAAAABCAYAAAD5EM2IAAAAEUlEQVR4nGP4z8DwfxSPbAwAka0BDmlABCIAAAAASUVORK5CYII=")!
    private let zeroWidth = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAAAAAABCAYAAADw16+3AAAACUlEQVR4nGMAAAABAAFe/335AAAAAElFTkSuQmCC")!

    private let home = URL(string: "https://example.invalid/home")!
    private let away = URL(string: "https://example.invalid/away")!

    private func fresh(_ kind: TabKind = .today) -> (BrowserState, UUID, UUID) {
        var state = BrowserState()
        let id = state.openTab(url: home)
        state.setKind(id, kind: kind)
        return (state, id, state.selectedProfileID)
    }

    @discardableResult
    private func update(_ state: inout BrowserState, _ id: UUID, _ profile: UUID,
                        _ png: Data?, live: URL? = URL(string: "https://example.invalid/home"),
                        back: Bool = false, loaded: Bool = true) -> Bool {
        state.updateSavedFavicon(id, profileID: profile, png: png,
                                 liveURL: live, canGoBack: back, hasLoaded: loaded)
    }

    func testTodayAcceptsEarlyImageButOnlyClearsAfterHasLoadedAndReportsActualChange() {
        var (state, id, profile) = fresh()
        XCTAssertFalse(update(&state, id, profile, nil, loaded: false))
        XCTAssertTrue(update(&state, id, profile, red, loaded: false))
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
        XCTAssertFalse(update(&state, id, profile, red, loaded: false))
        XCTAssertFalse(update(&state, id, profile, nil, loaded: false))
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
        XCTAssertTrue(update(&state, id, profile, blue, live: URL(string: "https://other.invalid"), back: true))
        XCTAssertTrue(update(&state, id, profile, nil))
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertFalse(update(&state, id, profile, nil))
    }

    func testSavedKindsUseHostAdmissionUntilImageExistsAndBackHistoryExists() {
        for kind in [TabKind.pinned, .favorite] {
            var (state, id, profile) = fresh(kind)
            XCTAssertTrue(update(&state, id, profile, red, live: away, back: true, loaded: false))
            XCTAssertFalse(update(&state, id, profile, blue, live: away, back: true))
            XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
            XCTAssertTrue(update(&state, id, profile, blue, live: away, back: false))
            XCTAssertFalse(update(&state, id, profile, red, live: URL(string: "https://elsewhere.invalid/home"), back: false))
            XCTAssertFalse(update(&state, id, profile, nil, live: home))
            XCTAssertEqual(state.savedFaviconPNG(forTab: id), blue)
        }
    }

    func testSavedKindsAdmitNormalizedEqualityAndMissingLiveURLWithoutDroppingPinIdentity() {
        for kind in [TabKind.pinned, .favorite] {
            var (state, id, profile) = fresh(kind)
            XCTAssertTrue(update(&state, id, profile, red))
            let equivalent = URL(string: "http://www.example.invalid/HOME/?utm_source=test#section")!
            XCTAssertTrue(update(&state, id, profile, blue, live: equivalent, back: true))
            XCTAssertTrue(update(&state, id, profile, red, live: nil, back: true))
            XCTAssertEqual(state.tabs.first { $0.id == id }?.homeURL, home)
            XCTAssertEqual(state.tabs.first { $0.id == id }?.kind, kind)
        }
    }

    func testInitialSavedImageRejectsDifferentHostAndFullModeDistinguishesPathQueryAndPort() {
        for kind in [TabKind.pinned, .favorite] {
            var (state, id, profile) = fresh(kind)
            XCTAssertFalse(update(&state, id, profile, red, live: URL(string: "https://elsewhere.invalid/home")))
            XCTAssertNil(state.savedFaviconPNG(forTab: id))
            XCTAssertTrue(update(&state, id, profile, red))
            for url in [away, URL(string: "https://example.invalid/home?q=1")!, URL(string: "https://example.invalid:8443/home")!] {
                XCTAssertFalse(update(&state, id, profile, blue, live: url, back: true))
                XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
            }
        }
    }

    func testOwnershipRejectionsLeaveStateUnchangedIncludingArchivedImage() {
        var (state, id, profile) = fresh()
        XCTAssertTrue(update(&state, id, profile, red))
        let before = state
        XCTAssertFalse(update(&state, id, UUID(), blue))
        XCTAssertFalse(update(&state, UUID(), profile, blue))
        XCTAssertEqual(state, before)
        state.archiveTab(id)
        let archived = state
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertFalse(update(&state, id, profile, blue))
        XCTAssertEqual(state, archived)
        state.restoreTab(id)
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
    }

    func testProfileReassignmentClearsActiveAndArchivedCachesWithoutResurrection() {
        var (state, id, profile) = fresh()
        let archived = state.openTab(url: home)
        XCTAssertTrue(update(&state, id, profile, red))
        XCTAssertTrue(update(&state, archived, profile, blue))
        state.archiveTab(archived)
        let space = state.selectedSpaceID
        XCTAssertTrue(state.assignSpaceProfile(space, profileID: profile))
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
        let other = state.addProfile(name: "Other")
        XCTAssertTrue(state.assignSpaceProfile(space, profileID: other))
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertTrue(state.assignSpaceProfile(space, profileID: profile))
        state.restoreTab(archived)
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertNil(state.savedFaviconPNG(forTab: archived))
    }

    func testCrossProfileTabAndFolderMovesClearButSameProfileMovePreserves() throws {
        var (state, id, profile) = fresh(.pinned)
        let originalSpace = state.selectedSpaceID
        let sameProfileSpace = try XCTUnwrap(state.spaces.first { $0.id != originalSpace }?.id)
        XCTAssertTrue(update(&state, id, profile, red))
        state.moveTab(id, to: sameProfileSpace)
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
        let otherProfile = state.addProfile(name: "Other")
        let otherSpace = state.addSpace(name: "Other")
        XCTAssertTrue(state.assignSpaceProfile(otherSpace, profileID: otherProfile))
        state.moveTab(id, to: otherSpace)
        state.moveTab(id, to: originalSpace)
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertTrue(update(&state, id, profile, blue))
        let folder = try XCTUnwrap(state.createFolder(name: "Other folder", spaceID: otherSpace))
        XCTAssertTrue(state.moveTab(id, into: folder))
        state.moveTab(id, to: originalSpace)
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
    }

    func testMalformedOrUnboundedPNGsCannotReplaceExistingImage() {
        var (state, id, profile) = fresh()
        XCTAssertTrue(update(&state, id, profile, red))
        var badCRC = red
        badCRC[29] ^= 0xff
        for png in [Data(), Data("not PNG".utf8), Data(red.prefix(24)), tooWide, zeroWidth,
                    badCRC, Data(repeating: 0, count: 262_145)] {
            XCTAssertFalse(update(&state, id, profile, png))
            XCTAssertEqual(state.savedFaviconPNG(forTab: id), red)
        }
        XCTAssertTrue(update(&state, id, profile, largest))
        XCTAssertEqual(state.savedFaviconPNG(forTab: id), largest)
    }

    private func modifiedCache(_ state: BrowserState, cache: Any?) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
        tabs[0]["savedFavicon"] = cache
        json["tabs"] = tabs
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testOldSessionAndMalformedDerivedCachePreserveTabs() throws {
        let (state, id, profile) = fresh(.pinned)
        let caches: [Any?] = [nil, "wrong shape", ["profileID": "invalid", "png": red.base64EncodedString()],
                           ["profileID": profile.uuidString, "png": "bad base64"],
                           ["profileID": profile.uuidString, "png": tooWide.base64EncodedString()]]
        for cache in caches {
            let decoded = try JSONDecoder().decode(BrowserState.self, from: modifiedCache(state, cache: cache))
            XCTAssertEqual(decoded.schemaVersion, 5)
            XCTAssertEqual(decoded.tabs, state.tabs)
            XCTAssertNil(decoded.savedFaviconPNG(forTab: id))
        }
    }

    func testPersistedForeignProfileCacheCannotResurrectOnProfileChange() throws {
        var (state, id, _) = fresh(.pinned)
        let other = state.addProfile(name: "Other")
        state = try JSONDecoder().decode(BrowserState.self, from: modifiedCache(state, cache: ["profileID": other.uuidString, "png": red.base64EncodedString()]))
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
        XCTAssertTrue(state.assignSpaceProfile(state.selectedSpaceID, profileID: other))
        XCTAssertNil(state.savedFaviconPNG(forTab: id))
    }

    func testAtomicDiskRoundTripPreservesCacheAcrossArchiveRestoreAndLegacyAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-favicon-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        var (state, id, profile) = fresh()
        XCTAssertTrue(update(&state, id, profile, red))
        state.archiveTab(id)
        try BrowserStateFile.write(state, to: file)
        var loaded = try BrowserStateFile.read(from: file)
        XCTAssertEqual(loaded, state)
        loaded.restoreTab(id, select: false)
        XCTAssertEqual(loaded.savedFaviconPNG(forTab: id), red)
        XCTAssertTrue(update(&loaded, id, profile, blue))
        try BrowserStateFile.write(loaded, to: file)
        XCTAssertEqual(try BrowserStateFile.read(from: file).savedFaviconPNG(forTab: id), blue)
        try modifiedCache(loaded, cache: nil).write(to: file)
        let legacy = try BrowserStateFile.read(from: file)
        XCTAssertNil(legacy.savedFaviconPNG(forTab: id))
        XCTAssertEqual(legacy.tabs.first?.url, home)
    }

    func testFailedWorkspaceWriteCannotPublishNewSavedImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saved-favicon-blocked-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked")
        let store = try BrowserWorkspaceStore(fileURL: blocked.appendingPathComponent("session.json"))
        let window = store.openWindow()
        try store.update(windowID: window) { state in _ = state.openTab(url: home) }
        let before = store.state
        let id = try XCTUnwrap(before.selectedTabID)
        try FileManager.default.removeItem(at: blocked)
        let marker = Data("owned fixture".utf8)
        try marker.write(to: blocked)
        XCTAssertThrowsError(try store.update(windowID: window) { state in
            _ = state.updateSavedFavicon(id, profileID: before.selectedProfileID, png: red,
                                        liveURL: home, canGoBack: false, hasLoaded: true)
        })
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(try Data(contentsOf: blocked), marker)
    }
}
