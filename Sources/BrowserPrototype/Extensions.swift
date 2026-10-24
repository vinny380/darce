import AppKit
import BrowserCore
import Combine
import SwiftUI
import WebKit

/// Browser extensions through WebKit's Web Extensions API (macOS 15.4+): the same Chrome-style MV2/MV3
/// extensions Safari runs. Install from a Chrome Web Store link or an unpacked folder; normal tabs, Peeks and
/// mini windows take part; private windows never do.
@MainActor
enum Extensions {
    /// Attach normal (non-private) pages before their web view is created.
    static func attach(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *) { configuration.webExtensionController = ExtensionManager.shared?.controller }
    }

    static func opened(_ page: BrowserPage) {
        if #available(macOS 15.4, *), page.joinsExtensions { ExtensionManager.shared?.controller.didOpenTab(page) }
    }

    static func closed(_ page: BrowserPage) {
        if #available(macOS 15.4, *), page.joinsExtensions { ExtensionManager.shared?.controller.didCloseTab(page, windowIsClosing: false) }
    }

    static func activated(_ page: BrowserPage, previous: BrowserPage?) {
        guard #available(macOS 15.4, *), page.joinsExtensions else { return }
        ExtensionManager.shared?.controller.didActivateTab(page, previousActiveTab: previous?.joinsExtensions == true ? previous : nil)
    }

    static func navigated(_ page: BrowserPage) {
        if #available(macOS 15.4, *), page.joinsExtensions { ExtensionManager.shared?.controller.didChangeTabProperties([.URL, .title, .loading], for: page) }
    }
}

@available(macOS 15.4, *)
struct InstalledExtension: Identifiable {
    let id: String
    let context: WKWebExtensionContext
    var name: String { context.webExtension.displayName ?? id }
    func icon(for page: BrowserPage?) -> NSImage? {
        context.action(for: page)?.icon(for: CGSize(width: 32, height: 32)) ?? context.webExtension.icon(for: CGSize(width: 32, height: 32))
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    static var shared: ExtensionManager?
    // A fixed identifier keeps extension storage (settings, logins) across launches.
    let controller = WKWebExtensionController(configuration: .init(identifier: UUID(uuidString: "0D4A7C3E-6B1F-4F5A-9E2D-DA4CE0000001")!))
    @Published private(set) var installed: [InstalledExtension] = []
    @Published var lastError: String?
    let directory: URL
    /// The sidebar address bar of each window; extension popups open beside it.
    private var anchors: [ObjectIdentifier: WeakView] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("Extensions", isDirectory: true)
        super.init()
        controller.delegate = self
        Task { await loadInstalled() }
    }

    // MARK: Installing

    private func loadInstalled() async {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            do { try await load(folder) } catch { lastError = "\(folder.lastPathComponent) couldn't load: \(error.localizedDescription)" }
        }
    }

    /// Everything in the folder was approved when it was installed, so its requested access is granted again.
    @discardableResult
    private func load(_ folder: URL) async throws -> InstalledExtension {
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = folder.lastPathComponent
        context.isInspectable = true
        for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try controller.load(context)
        let item = InstalledExtension(id: folder.lastPathComponent, context: context)
        installed.removeAll { $0.id == item.id }
        installed.append(item)
        return item
    }

    /// A Chrome Web Store link (or bare id): download the package Chrome would, unpack it, confirm, load.
    func install(fromStoreLink text: String) async {
        guard let id = CRXFile.extensionID(from: text) else { lastError = "That isn't a Chrome Web Store link."; return }
        do {
            let (data, response) = try await URLSession.shared.data(from: CRXFile.downloadURL(forExtensionID: id))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
            let zip = try CRXFile.zipPayload(data)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("darce-ext-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let archive = staging.appendingPathComponent("extension.zip")
            try zip.write(to: archive)
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try Self.unzip(archive, to: unpacked)
            try await installFolder(unpacked, as: id)
        } catch { lastError = "Couldn't install that extension: \(error.localizedDescription)" }
    }

    /// An unpacked extension folder (one with a manifest.json), copied in so the original can move.
    func install(fromFolder folder: URL) async {
        do { try await installFolder(folder, as: "local-" + folder.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }) }
        catch { lastError = "Couldn't install that extension: \(error.localizedDescription)" }
    }

    private func installFolder(_ source: URL, as id: String) async throws {
        let candidate = try await WKWebExtension(resourceBaseURL: source)
        guard confirmInstall(candidate) else { return }
        let destination = directory.appendingPathComponent(id, isDirectory: true)
        if let existing = installed.first(where: { $0.id == id }) { try? controller.unload(existing.context) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try await load(destination)
    }

    func uninstall(_ item: InstalledExtension) {
        try? controller.unload(item.context)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id))
        installed.removeAll { $0.id == item.id }
    }

    private static func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func confirmInstall(_ webExtension: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(webExtension.displayName ?? "this extension")”?"
        var lines = webExtension.requestedPermissions.map(Self.describe).sorted()
        if webExtension.allRequestedMatchPatterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            lines.insert("Read and change all your data on websites you visit", at: 0)
        } else if !webExtension.allRequestedMatchPatterns.isEmpty {
            lines.insert("Read and change your data on: " + webExtension.allRequestedMatchPatterns.map(\.host).compactMap { $0 }.sorted().joined(separator: ", "), at: 0)
        }
        alert.informativeText = lines.isEmpty ? "It doesn't ask for any special access." : "It can:\n• " + lines.joined(separator: "\n• ")
        if let icon = webExtension.icon(for: CGSize(width: 64, height: 64)) { alert.icon = icon }
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func describe(_ permission: WKWebExtension.Permission) -> String {
        switch permission {
        case .storage, .unlimitedStorage: "Store data"
        case .tabs: "Read your tabs and browsing activity"
        case .scripting: "Run scripts on pages it can access"
        case .cookies: "Read and change cookies"
        case .webNavigation: "See where you navigate"
        case .contextMenus, .menus: "Add items to right-click menus"
        case .alarms: "Run on a schedule"
        case .declarativeNetRequest, .declarativeNetRequestWithHostAccess, .declarativeNetRequestFeedback: "Block or change network requests"
        case .clipboardWrite: "Write to your clipboard"
        default: permission.rawValue
        }
    }

    // MARK: Running

    func performAction(_ item: InstalledExtension, in model: BrowserModel) {
        let page = model.state.selectedTabID.flatMap { model.page(for: $0) }
        item.context.performAction(for: page)
    }

    func setAnchor(_ view: NSView, for model: BrowserModel) { anchors[ObjectIdentifier(model)] = WeakView(view: view) }

    func window(for model: BrowserModel) -> ExtensionWindow {
        if let existing = windows[ObjectIdentifier(model)] { return existing }
        let window = ExtensionWindow(model: model)
        windows[ObjectIdentifier(model)] = window
        return window
    }

    private var liveModels: [BrowserModel] { BrowserWindows.shared.models.filter { !$0.isWindowClosed } }
    private var focusedModel: BrowserModel? { BrowserWindows.shared.activeModel ?? MiniWindows.shared.primaryModel }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        liveModels.map { window(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedModel.map { window(for: $0) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let model = (configuration.window as? ExtensionWindow)?.model ?? focusedModel else { completionHandler(nil, nil); return }
        model.open(configuration.url ?? URL(string: "about:blank")!)
        completionHandler(model.state.selectedTabID.flatMap { model.page(for: $0) }, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL, let model = focusedModel { model.open(url) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let allowed = ask(extensionContext, "wants to " + permissions.map(Self.describe).sorted().joined(separator: ", ").lowercased())
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let allowed = ask(extensionContext, "wants to read and change data on " + urls.compactMap(\.host).sorted().joined(separator: ", "))
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = ask(extensionContext, "wants to read and change data on " + matchPatterns.map(\.string).sorted().joined(separator: ", "))
        completionHandler(allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { completionHandler(nil); return }
        let anchor = focusedModel.flatMap { anchors[ObjectIdentifier($0)]?.view } ?? NSApplication.shared.keyWindow?.contentView
        guard let anchor else { completionHandler(nil); return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        objectWillChange.send()  // badge or icon changed
    }

    private func ask(_ context: WKWebExtensionContext, _ request: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(context.webExtension.displayName ?? "An extension")” \(request)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct WeakView { weak var view: NSView? }
}

/// One D'arce window as extensions see it: its loaded tabs, in sidebar order.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { model?.loadedPagesInOrder ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        model?.state.selectedTabID.flatMap { model?.loadedPage($0) }
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    private var nsWindow: NSWindow? { model.flatMap { BrowserWindows.shared.window(for: $0) } }
    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        nsWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        nsWindow?.performClose(nil)
        completionHandler(nil)
    }
}

/// A sidebar tab as extensions see it.
@available(macOS 15.4, *)
extension BrowserPage: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        owner.map { ExtensionManager.shared?.window(for: $0) } ?? nil
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let owner, let tabID else { return NSNotFound }
        return owner.state.visibleTabs.firstIndex { $0.id == tabID } ?? NSNotFound
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !loading }
    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let owner, let tabID, let tab = owner.state.tabs.first(where: { $0.id == tabID }) else { return false }
        return tab.kind == .pinned || tab.kind == .favorite
    }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tabID != nil && owner?.state.selectedTabID == tabID }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let owner, let tabID { owner.select(tabID) }
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goBack()
        completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.goForward()
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let owner, let tabID { owner.archive(tabID) }
        completionHandler(nil)
    }
}
