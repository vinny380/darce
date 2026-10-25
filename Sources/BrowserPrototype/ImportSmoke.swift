import BrowserCore
import Foundation

/// The import's app half: the sidebar, Space looks and history all land, and importing again adds nothing.
@MainActor
func runBrowserImportSmoke() -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
    profile.spaces = [ImportedSpace(key: "arc-space:smoke", name: "Imported", emoji: "🚀",
                                    tint: AppearanceColor(red: 0.2, green: 0.4, blue: 0.6),
                                    pinned: [.folder(key: "arc:folder", title: "Reading",
                                                     children: [.tab(key: "arc:pin", title: "Pin", url: URL(string: "https://pin.invalid/")!)])])]
    profile.favorites = [.tab(key: "arc:fav", title: "Favorite", url: URL(string: "https://favorite.invalid/")!)]
    profile.history = [ImportedVisit(url: URL(string: "https://visited.invalid/")!, title: "Visited", visitedAt: Date())]
    let first = model.applyBrowserImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    let space = model.state.spaces.first { $0.name == "Imported" }
    let folder = model.state.folders.first { $0.name == "Reading" }
    let looks = space.map { model.appearance.state.space($0.id) }
    let second = model.applyBrowserImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    return [
        "import_replaces_fresh_sidebar": model.state.spaces.map(\.name) == ["Imported"],
        "import_space_looks": looks?.icon == "🚀" && looks?.tint == AppearanceColor(red: 0.2, green: 0.4, blue: 0.6),
        "import_folder_collapsed": folder.map { looks?.collapsedFolderIDs.contains($0.id) == true } ?? false,
        "import_history_merged": first.counts["history"] == 1
            && model.history?.search("", profileID: model.state.profiles[0].id).count == 1,
        "import_selects_first_space": model.state.selectedSpaceID == space?.id,
        "import_twice_adds_nothing": second.counts.values.allSatisfy { $0 == 0 },
    ]
}
