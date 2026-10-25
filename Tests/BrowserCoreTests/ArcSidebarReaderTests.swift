import Foundation
import Testing
@testable import BrowserCore

/// Reading Arc's sidebar into the import model. Each test names the bug it catches.
private func readStandard() throws -> (profiles: [ImportedProfile], folder: TemporaryDirectory) {
    let folder = try TemporaryDirectory()
    let sidebar = folder.url.appendingPathComponent("StorableSidebar.json")
    try ArcSidebarFixture.standard().data().write(to: sidebar)
    let userData = folder.url.appendingPathComponent("User Data")
    try FileManager.default.createDirectory(at: userData.appendingPathComponent("Default"), withIntermediateDirectories: true)
    return (try ArcSidebarReader.read(sidebar: sidebar, userData: userData), folder)
}

private func names(_ items: [ImportedItem]) -> [String] {
    items.map {
        switch $0 {
        case .tab(_, let title, _): title
        case .folder(_, let title, let children): "\(title)[\(names(children).joined(separator: ","))]"
        case .split(_, let panes, let vertical): "split\(vertical ? "V" : "H")[\(names(panes).joined(separator: ","))]"
        }
    }
}

@Test func readsSpacesInOrderWithIconsAndTint() throws {
    let (profiles, _) = try readStandard()
    let main = try #require(profiles.first { $0.key == "arc:Default" })
    #expect(main.spaces.map(\.name) == ["Work", "Space"])
    #expect(main.spaces[0].icon == "globe.americas.fill")
    #expect(main.spaces[1].icon == "🚀")
    #expect(main.spaces[0].tint == AppearanceColor(red: 0.2, green: 0.4, blue: 0.6))
    #expect(main.spaces[1].tint == nil)
}

@Test func keepsFolderNestingAndSplits() throws {
    let (profiles, _) = try readStandard()
    let work = try #require(profiles.first { $0.key == "arc:Default" }?.spaces.first)
    #expect(names(work.pinned) == ["Mail", "Docs[Spec,Deep[Note]]", "splitH[Left,Right]"])
    #expect(work.pinned.allSatisfy {
        switch $0 { case .tab(let key, _, _), .folder(let key, _, _), .split(let key, _, _): key.hasPrefix("arc:item-") }
    })
    #expect(work.key.hasPrefix("arc-space:space-"))
}

@Test func todayComesFromTheUnpinnedContainer() throws {
    let (profiles, _) = try readStandard()
    let work = try #require(profiles.first { $0.key == "arc:Default" }?.spaces.first)
    #expect(names(work.today) == ["News"])
}

@Test func favoritesBelongToTheirProfile() throws {
    let (profiles, _) = try readStandard()
    #expect(names(try #require(profiles.first { $0.key == "arc:Default" }).favorites) == ["Calendar", "Chat"])
    #expect(try #require(profiles.first { $0.key == "arc:Profile 9" }).favorites.isEmpty)
}

@Test func missingCustomProfileDirStillImportsItsSpaces() throws {
    let (profiles, folder) = try readStandard()
    let side = try #require(profiles.first { $0.key == "arc:Profile 9" })
    #expect(side.directory == nil && side.spaces.map(\.name) == ["Side"])
    #expect(profiles.first { $0.key == "arc:Default" }?.directory?.standardizedFileURL
            == folder.url.appendingPathComponent("User Data/Default").standardizedFileURL)
}

@Test func unsupportedURLsAreSkippedAndListed() throws {
    let (profiles, _) = try readStandard()
    let main = try #require(profiles.first { $0.key == "arc:Default" })
    #expect(!names(main.spaces[0].pinned).contains("Bad"))
    #expect(!names(main.spaces[0].pinned).contains("Local"))
    #expect(main.skipped.count == 2)
}

@Test func arcIconNamesMapToSymbolsAndUnknownOnesFallBack() {
    #expect(ArcSidebarReader.symbol(forArcIcon: "planet") == "globe.americas.fill")
    #expect(ArcSidebarReader.symbol(forArcIcon: "logoGithub") == "chevron.left.forwardslash.chevron.right")
    #expect(ArcSidebarReader.symbol(forArcIcon: "cloudOutline") == "cloud.fill")
    #expect(ArcSidebarReader.symbol(forArcIcon: "somethingNew") == nil)
}
