import AppKit
import BrowserCore
import Foundation
import UniformTypeIdentifiers

extension BrowserModel {
    func importBookmarks() {
        guard !recoveryRequired else {
            errorMessage = "Bookmarks cannot be imported while session saving is disabled. Recover the existing session first."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Choose a bookmarks HTML export. It will be added to a new folder in the current Space."
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try NetscapeBookmarks.read(from: url)
            guard !result.roots.isEmpty else {
                errorMessage = result.issues.isEmpty ? "The selected file contains no bookmarks." : "No supported bookmarks were found. \(result.issues.count) import issues were reported."
                return
            }
            if !result.issues.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Import with \(result.issues.count) issues?"
                let details = result.issues.prefix(5).map { "• \($0.title.isEmpty ? "Unnamed item" : $0.title): \($0.reason)" }.joined(separator: "\n")
                alert.informativeText = "Unsupported links will be skipped and empty folder names replaced.\n\n\(details)" + (result.issues.count > 5 ? "\n\nPlus \(result.issues.count - 5) more issues." : "")
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Import Supported Bookmarks")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            try importBookmarkTree(result.roots)
        } catch {
            errorMessage = "Bookmarks could not be imported: \(error.localizedDescription)"
        }
    }

    /// Builds the complete candidate before one session transaction. No renderer is opened.
    func importBookmarkTree(_ roots: [BookmarkNode]) throws {
        guard !recoveryRequired else { throw BookmarkFileError.invalidStructure("session saving is disabled") }
        _ = try NetscapeBookmarks.export(roots)
        var candidate = state
        let originalSelection = candidate.selectedTabID
        let destination = candidate.selectedSpaceID
        guard let container = candidate.createFolder(name: "Imported Bookmarks", spaceID: destination) else {
            throw BookmarkFileError.invalidStructure("destination Space is unavailable")
        }
        func append(_ nodes: [BookmarkNode], parent: UUID) throws {
            for node in nodes {
                switch node {
                case .bookmark(let title, let url):
                    let tab = candidate.openTab(url: url, title: title)
                    candidate.setKind(tab, kind: .pinned)
                    guard candidate.moveTab(tab, into: parent) else {
                        throw BookmarkFileError.invalidStructure("destination folder is unavailable")
                    }
                case .folder(let title, let children):
                    guard let folder = candidate.createFolder(name: title, spaceID: destination, parentID: parent) else {
                        throw BookmarkFileError.invalidStructure("destination folder is unavailable")
                    }
                    try append(children, parent: folder)
                }
            }
        }
        try append(roots, parent: container)
        if let originalSelection { candidate.selectTab(originalSelection) }
        else { candidate.clearSelection() }
        guard stateUpdate({ $0 = candidate }) else {
            throw BookmarkFileError.invalidStructure("session could not be saved")
        }
    }

    func exportBookmarks() {
        let panel = NSSavePanel()
        panel.title = "Export Bookmarks"
        panel.message = "Export the current Space’s pinned tabs and folders, plus this profile’s Favorites."
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try NetscapeBookmarks.write(bookmarkExportTree(), to: url) }
        catch { errorMessage = "Bookmarks could not be exported: \(error.localizedDescription)" }
    }

    func bookmarkExportTree() -> [BookmarkNode] {
        let space = state.selectedSpaceID
        func contents(parent: UUID?) -> [BookmarkNode] {
            let folders: [BookmarkNode] = state.folders.filter { $0.spaceID == space && $0.parentID == parent }.map {
                .folder(title: $0.name, children: contents(parent: $0.id))
            }
            let bookmarks: [BookmarkNode] = state.tabs.filter { $0.spaceID == space && $0.kind == .pinned && $0.folderID == parent }.map {
                .bookmark(title: $0.title, url: $0.homeURL ?? $0.url)
            }
            return folders + bookmarks
        }
        let favorites: [BookmarkNode] = state.visibleTabs.filter { $0.kind == .favorite }.map {
            .bookmark(title: $0.title, url: $0.homeURL ?? $0.url)
        }
        let spaceName = state.spaces.first { $0.id == space }?.name ?? "Space"
        var roots: [BookmarkNode] = []
        if !favorites.isEmpty { roots.append(.folder(title: "Favorites", children: favorites)) }
        roots.append(.folder(title: spaceName, children: contents(parent: nil)))
        return roots
    }
}


@MainActor
func runBookmarkSmokeChecks(model: BrowserModel) -> [String: Bool] {
    let original = model.state
    let url = URL(string: "https://bookmark-fixture.invalid/home")!
    let roots: [BookmarkNode] = [.folder(title: "Fixture Folder", children: [.bookmark(title: "Fixture Link", url: url), .folder(title: "Empty", children: [])])]
    var checks: [String: Bool] = [:]
    do {
        try model.importBookmarkTree(roots)
        checks["bookmark_import_preserves_selection"] = model.state.selectedTabID == original.selectedTabID
        let links = model.state.tabs.filter { $0.url == url }
        checks["bookmark_import_pins_nested_link"] = links.count == 1 && links[0].kind == .pinned && links[0].folderID != nil
        if let link = links.first {
            model.stateUpdate { $0.updateTab(link.id, url: URL(string: "https://bookmark-fixture.invalid/navigated")!) }
        }
        let exported = model.bookmarkExportTree()
        let reimported = try NetscapeBookmarks.parse(NetscapeBookmarks.export(exported))
        func containsHome(_ nodes: [BookmarkNode]) -> Bool {
            nodes.contains { $0.url == url || containsHome($0.children ?? []) }
        }
        checks["bookmark_export_round_trip_home_url"] = reimported.roots == exported && containsHome(exported)
        model.stateUpdate { $0 = original; $0.clearSelection() }
        try model.importBookmarkTree(roots)
        checks["bookmark_import_preserves_empty_selection"] = model.state.selectedTabID == nil
    } catch {
        checks["bookmark_actions_error"] = false
    }
    checks["bookmark_smoke_restores_session"] = model.stateUpdate { $0 = original }
    return checks
}
