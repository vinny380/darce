import AppKit
import BrowserCore
import Combine
import Foundation
import WebKit

enum CommandMode { case newTab, location, split }
enum LibraryPanel: String, Identifiable { case profiles, history, downloads, appearance, boosts, documents, browsingData; var id: String { rawValue } }

@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var state: BrowserState
    @Published var errorMessage: String?
    @Published var commandMode: CommandMode?
    var sidebarVisible: Bool {
        get { appearance.state.sidebarVisible }
        set { appearance.update { $0.sidebarVisible = newValue } }
    }
    @Published var panel: LibraryPanel?
    @Published var showFind = false
    var history: HistoryStore? { workspace.history }
    var secondaryTabID: UUID? { state.selectedSplitGroup?.tabIDs.first { $0 != state.selectedTabID } }
    @Published private(set) var peekPage: BrowserPage?
    @Published private(set) var isWindowClosed = false
    private var peekURL: URL?
    let workspace: BrowserWorkspaceSession
    private(set) var windowID: UUID
    var sessionURL: URL { workspace.store.fileURL }
    var recoveryRequired: Bool { workspace.store.isVolatile }
    let supportsDocuments = true
    var documents: DocumentController { workspace.documents }
    var settings: SettingsController { workspace.settings }
    var favicons: FaviconController { workspace.favicons }
    var appearance: AppearanceController { workspace.appearance }
    var boosts: BoostController { workspace.boosts }
    var downloads: DownloadManager { workspace.downloads }
    var clearingProfiles: Set<UUID> { workspace.clearingProfiles }
    var browsingData: BrowsingDataController { workspace.browsingData }
    private var workspaceObservation: AnyCancellable?
    private var pages: [UUID: BrowserPage] = [:]
    private var pageProfiles: [UUID: UUID] = [:]
    /// Most recently selected first; in memory only, like Arc's recent-tab switcher.
    private var recentTabIDs: [UUID] = []
    private var recentSwitch: RecentTabSwitch?
    private static weak var switchingModel: BrowserModel?
    private static var controlReleaseMonitor: Any?

    func prepareBrowsingDataRemoval(_ profileID: UUID) async throws {
        let ids = pages.keys.filter { pageProfiles[$0] == profileID }
        var ownedPages = ids.compactMap { pages[$0] }
        for id in ids { pages.removeValue(forKey: id); pageProfiles.removeValue(forKey: id) }
        if let peekPage, peekPage.webView.configuration.websiteDataStore.identifier == profileID {
            ownedPages.append(peekPage)
            self.peekPage = nil
            peekURL = nil
        }
        for page in ownedPages { try await page.prepareForBrowsingDataRemoval() }
    }

    func finishBrowsingDataRemoval(_ profileID: UUID) {
        guard !isWindowClosed else { return }
        for id in state.displayedTabIDs where state.profileID(forTab: id) == profileID { _ = page(for: id) }
    }

    convenience init(directory: URL, ephemeralWebsiteData: Bool = false, downloadsDirectory: URL? = nil) {
        self.init(workspace: BrowserWorkspaceSession.open(directory: directory, ephemeralWebsiteData: ephemeralWebsiteData,
                                                          downloadsDirectory: downloadsDirectory))
    }

    init(workspace: BrowserWorkspaceSession, selection: BrowserWindowSelection? = nil) {
        self.workspace = workspace
        windowID = workspace.store.openWindow(selection: selection)
        state = workspace.store.state(for: windowID)!
        errorMessage = workspace.loadError
        observeWorkspace()
        workspaceObservation = workspace.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func observeWorkspace() {
        workspace.register(self)
        workspace.store.observe(windowID: windowID) { [weak self] candidate in self?.receiveState(candidate) }
    }

    func suspendWindow() {
        guard !isWindowClosed else { return }
        isWindowClosed = true
        workspace.unregister(windowID: windowID)
        pages.values.forEach(teardown)
        pages.removeAll()
        pageProfiles.removeAll()
        closePeek()
        panel = nil
        commandMode = nil
        showFind = false
    }

    func activateWindow() {
        guard isWindowClosed else { return }
        windowID = workspace.store.openWindow(selection: BrowserWindowSelection(state: state))
        isWindowClosed = false
        state = workspace.store.state(for: windowID)!
        observeWorkspace()
    }

    @discardableResult
    func stateUpdate(_ change: (inout BrowserState) -> Void) -> Bool {
        guard !isWindowClosed else { return false }
        do { try workspace.store.update(windowID: windowID, change); return !recoveryRequired }
        catch { errorMessage = "Session could not be saved; the change was not applied: \(error.localizedDescription)"; return false }
    }

    private func receiveState(_ candidate: BrowserState) {
        guard !isWindowClosed else { return }
        let previous = state
        state = candidate
        for id in Array(pages.keys) {
            guard let page = pages[id] else { continue }
            let tab = candidate.tabs.first { $0.id == id && $0.kind != .archived }
            let changedURL = tab != nil && previous.tabs.first(where: { $0.id == id })?.url != tab?.url && page.webView.url != tab?.url
            if tab == nil || pageProfiles[id] != candidate.profileID(forTab: id) || changedURL {
                teardown(page)
                pages.removeValue(forKey: id)
                pageProfiles.removeValue(forKey: id)
            }
        }
        if previous.selectedProfileID != state.selectedProfileID { closePeek() }
        if recentSwitch == nil, candidate.selectedTabID != previous.selectedTabID { noteRecent(candidate.selectedTabID) }
    }

    private func noteRecent(_ id: UUID?) {
        guard let id else { return }
        recentTabIDs.removeAll { $0 == id }
        recentTabIDs.insert(id, at: 0)
        if recentTabIDs.count > 50 { recentTabIDs.removeLast() }
    }

    /// Control+Tab walks recent tabs; while Control stays held, repeated presses go further back.
    func cycleRecentTab(backwards: Bool) {
        if recentSwitch == nil {
            recentSwitch = RecentTabSwitch(recent: recentTabIDs, visible: state.visibleTabs.map(\.id), current: state.selectedTabID)
        }
        guard var walk = recentSwitch else { return }
        let id = walk.step(backwards: backwards)
        recentSwitch = walk
        select(id)
        guard NSEvent.modifierFlags.contains(.control) else { recentSwitch = nil; noteRecent(id); return }
        Self.switchingModel = self
        if Self.controlReleaseMonitor == nil {
            Self.controlReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                if !event.modifierFlags.contains(.control) { MainActor.assumeIsolated { BrowserModel.switchingModel?.endRecentTabSwitch() } }
                return event
            }
        }
    }

    func endRecentTabSwitch() {
        guard recentSwitch != nil else { return }
        recentSwitch = nil
        noteRecent(state.selectedTabID)
    }

    private func teardown(_ page: BrowserPage) {
        page.onNavigate = nil; page.onVisit = nil; page.onFinish = nil
        page.onNavigationStateChange = nil
        page.onNewTab = nil; page.onDownload = nil; page.onLink = nil; page.onModifiedLink = nil; page.onFocus = nil
        page.cancelElementPicker()
        page.webView.stopLoading()
        page.webView.navigationDelegate = nil
        page.webView.uiDelegate = nil
        page.webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
    }

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore { workspace.dataStore(for: profileID) }

    // Read only: row rendering cannot create a WebKit page or borrow stale ownership.
    func canResetSidebarTab(_ id: UUID, isEditing: Bool = false) -> Bool {
        guard !isWindowClosed, let owner = state.profileID(forTab: id),
              !clearingProfiles.contains(owner), pageProfiles[id] == owner,
              let tab = state.tabs.first(where: { $0.id == id && $0.kind != .archived }),
              let page = pages[id] else { return false }
        return SidebarResetEligibility.isEligible(kind: tab.kind, isEditing: isEditing,
            savedURL: tab.homeURL, liveURL: page.webView.url, canGoBack: page.webView.canGoBack)
    }

    func page(for id: UUID) -> BrowserPage? {
        guard !isWindowClosed, let owner = state.profileID(forTab: id), !clearingProfiles.contains(owner),
              let tab = state.tabs.first(where: { $0.id == id && $0.kind != .archived }) else { return nil }
        if let page = pages[id] { return page }
        guard let profileID = state.profileID(forTab: id) else { return nil }
        let page = BrowserPage(url: tab.url, dataStore: dataStore(for: profileID))
        page.webView.pageZoom = settings.state.defaultZoom
        page.onNavigationStateChange = { [weak self, weak page] in
            guard let self, let page, !self.isWindowClosed, self.pages[id] === page,
                  self.pageProfiles[id] == profileID, self.state.profileID(forTab: id) == profileID,
                  !self.clearingProfiles.contains(profileID) else { return }
            self.objectWillChange.send()
        }
        page.onNavigate = { [weak self, weak page] url, title in
            guard let self, let page, self.pages[id] === page, self.state.profileID(forTab: id) == profileID else { return }
            self.stateUpdate { $0.updateTab(id, url: url, title: title) }
        }
        page.onVisit = { [weak self, weak page] url, title in
            guard let self, let page, self.pages[id] === page, !self.clearingProfiles.contains(profileID) else { return }
            self.recordVisit(url: url, title: title, profileID: profileID)
        }
        page.onFocus = { [weak self, weak page] in
            guard let self, let page, self.pages[id] === page, self.state.displayedTabIDs.contains(id), self.state.selectedTabID != id else { return }
            self.select(id)
        }
        page.onDownload = { [weak self] download in _ = self?.downloads.accept(download: download, profileID: profileID) }
        page.onNewTab = { [weak self] url in self?.open(url) }
        page.onModifiedLink = { [weak self] url, flags in
            guard let self else { return false }
            let settings = self.settings.state
            if flags.contains([.option, .command]), settings.optionCommandClickOpensMiniWindow {
                MiniWindows.shared.open(url: url, model: self)
                return true
            }
            if flags.contains(.shift), !flags.contains(.command), !flags.contains(.option), settings.shiftClickOpensPeek {
                self.showPeek(url)
                return true
            }
            return false
        }
        page.onLink = { [weak self] url in
            guard let self, self.settings.state.pinnedExternalLinksOpenPeek, let tab = self.state.tabs.first(where: { $0.id == id }),
                  tab.kind == .pinned || tab.kind == .favorite else { return false }
            guard url.host?.lowercased() != tab.url.host?.lowercased() else { return false }
            self.showPeek(url)
            return true
        }
        page.onFinish = { [weak self, weak page] in
            guard let self, let page else { return }
            self.favicons.refresh(from: page, profileID: profileID)
        }
        page.applyBoosts(controller: boosts, profileID: profileID)
        pages[id] = page
        pageProfiles[id] = profileID
        return page
    }

    func open(_ url: URL) { stateUpdate { _ = $0.openTab(url: url) } }
    func select(_ id: UUID) { stateUpdate { $0.selectTab(id) } }
    func selectSpace(_ id: UUID) { stateUpdate { $0.selectSpace(id) } }
    func pin(_ id: UUID, kind: TabKind) { stateUpdate { $0.setKind(id, kind: kind) } }
    func move(_ id: UUID, to space: UUID) { stateUpdate { $0.moveTab(id, to: space) } }
    func archive(_ id: UUID) { closeWithUndo([id], name: "Close Tab") { $0.archiveTab(id) } }

    /// Closes tabs so ⌘Z (Edit ▸ Undo) puts them back exactly where they were, like Arc. Uses the window's undo
    /// history, so ⌘Z in a text field still undoes typing first.
    private func closeWithUndo(_ ids: [UUID], name: String, _ change: (inout BrowserState) -> Void) {
        let snapshots = state.tabs.filter { ids.contains($0.id) && $0.kind != .archived }
        guard stateUpdate(change), !snapshots.isEmpty, let undo = BrowserWindows.shared.window(for: self)?.undoManager else { return }
        undo.registerUndo(withTarget: self) { model in model.stateUpdate { $0.undoClose(snapshots) } }
        undo.setActionName(name)
    }
    func restore(_ id: UUID) { stateUpdate { $0.restoreTab(id, select: false) } }
    var archivedTabs: [BrowserTab] {
        state.tabs.filter { $0.kind == .archived && state.profileID(forTab: $0.id) == state.selectedProfileID }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }
    func reopenLastArchived() {
        if let id = archivedTabs.first?.id { stateUpdate { $0.restoreTab(id) } }
    }

    func resetPin(_ id: UUID) {
        guard stateUpdate({ $0.resetPinnedTab(id) }) else { return }
        if let tab = state.tabs.first(where: { $0.id == id }), let home = tab.homeURL {
            page(for: id)?.webView.load(URLRequest(url: home))
        }
    }
    @discardableResult
    func addFolder(_ name: String, parent: UUID? = nil) -> UUID? {
        var id: UUID?
        let saved = stateUpdate { id = $0.createFolder(name: name, spaceID: $0.selectedSpaceID, parentID: parent) }
        return saved ? id : nil
    }
    func move(_ id: UUID, into folder: UUID?) { stateUpdate { _ = $0.moveTab(id, into: folder) } }
    /// Drag one sidebar tab onto another; see `BrowserState.splitTab`.
    func splitTab(_ id: UUID, onto target: UUID, at slot: Int? = nil) {
        var split = false
        stateUpdate { split = $0.splitTab(id, onto: target, at: slot) }
        if split { dropFeedback() }
    }

    /// A light trackpad tap when a dragged tab lands, like Arc.
    private func dropFeedback() {
        guard settings.state.hapticFeedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    /// Drag and drop into any sidebar section; see `BrowserState.placeTab`.
    @discardableResult
    func place(_ id: UUID, kind: TabKind, folder: UUID? = nil, before target: UUID? = nil) -> Bool {
        var placed = false
        stateUpdate { placed = $0.placeTab(id, kind: kind, folderID: folder, before: target) }
        if placed { dropFeedback() }
        return placed
    }
    func focusPane(_ id: UUID) {
        guard state.displayedTabIDs.contains(id), stateUpdate({ $0.selectTab(id) }), let page = page(for: id) else { return }
        page.webView.window?.makeFirstResponder(page.webView)
    }
    func split(_ id: UUID) {
        guard id != state.selectedTabID, state.visibleTabs.contains(where: { $0.id == id }) else { return }
        stateUpdate { _ = $0.addToSplit(id) }
    }
    /// Opens a new page beside the current one; the new pane takes focus.
    func openInSplit(_ url: URL) {
        guard let anchor = state.selectedTabID else { open(url); return }
        stateUpdate { state in
            let id = state.openTab(url: url)
            state.selectTab(anchor)
            if state.addToSplit(id) { state.selectTab(id) }
        }
    }
    func closeSelectedPane() {
        guard let group = state.selectedSplitGroup, let id = state.selectedTabID else { return }
        closeWithUndo([id], name: "Close Tab") { $0.closePane(id, from: group.id) }
    }
    func cycleSpace(backwards: Bool) { stateUpdate { BrowserOrderedNavigation.cycleSpace(&$0, backwards: backwards) } }
    /// Archives every Today tab in this Space; Favorites and pins stay.
    func clearTodayTabs() {
        let ids = state.visibleTabs.filter { $0.kind == .today }.map(\.id)
        closeWithUndo(ids, name: "Clear Today Tabs") { state in ids.forEach { state.archiveTab($0) } }
    }
    func separatePane(_ id: UUID, from groupID: UUID) {
        stateUpdate { state in
            guard let group = state.selectedSplitGroup, group.id == groupID, group.tabIDs.contains(id) else { return }
            _ = state.removeFromSplit(id)
        }
    }
    func separateAllPanes() {
        guard let group = state.selectedSplitGroup else { return }
        stateUpdate { _ = $0.dissolveSplit(group.id) }
    }
    func showPeek(_ url: URL) {
        guard !isWindowClosed, !clearingProfiles.contains(state.selectedProfileID) else { return }
        closePeek()
        peekURL = url
        let profileID = state.selectedProfileID
        let page = BrowserPage(url: url, dataStore: dataStore(for: profileID))
        page.webView.pageZoom = settings.state.defaultZoom
        page.onNewTab = { [weak self] in self?.open($0) }
        page.onNavigate = { [weak self] url, _ in if let url { self?.peekURL = url } }
        page.onVisit = { [weak self] url, title in self?.recordVisit(url: url, title: title, profileID: profileID) }
        page.onDownload = { [weak self] download in _ = self?.downloads.accept(download: download, profileID: profileID) }
        page.onFinish = { [weak self, weak page] in
            guard let self, let page else { return }
            self.favicons.refresh(from: page, profileID: profileID)
        }
        page.applyBoosts(controller: boosts, profileID: profileID)
        peekPage = page
    }
    func closePeek() {
        if let peekPage { teardown(peekPage) }
        peekPage = nil
        peekURL = nil
    }
    func promotePeek() {
        guard let url = peekURL else { return }
        open(url)
        closePeek()
    }
    func archiveExpired(now: Date = Date()) {
        guard !isWindowClosed else { return }
        do { _ = try workspace.store.autoArchive(windowID: windowID, settings: settings.state, now: now, protecting: workspace.displayedSplitTabIDs) }
        catch { errorMessage = "Tabs could not be archived: \(error.localizedDescription)" }
    }
    func addSpace(_ name: String) {
        stateUpdate { state in
            let id = state.addSpace(name: name)
            state.selectSpace(id)
        }
    }

    func addProfile(_ name: String) {
        stateUpdate { state in
            let profile = state.addProfile(name: name)
            let space = state.addSpace(name: name.isEmpty ? "New Profile" : name)
            _ = state.assignSpaceProfile(space, profileID: profile)
            state.selectSpace(space)
        }
    }
    func assignProfile(_ profile: UUID, to space: UUID) { stateUpdate { _ = $0.assignSpaceProfile(space, profileID: profile) } }
    func recordVisit(url: URL, title: String, profileID: UUID) {
        guard !isWindowClosed, !clearingProfiles.contains(profileID), history != nil else { return }
        do { try workspace.updateHistory { try $0.record(url: url, title: title, profileID: profileID) } }
        catch { errorMessage = "History could not be saved: \(error.localizedDescription)" }
    }
    func removeHistory(id: UUID) {
        guard history != nil else { return }
        do { try workspace.updateHistory { try $0.remove(id: id, profileID: state.selectedProfileID) } }
        catch { errorMessage = "History could not be changed: \(error.localizedDescription)" }
    }
    func clearHistory() {
        guard history != nil else { return }
        do { try workspace.updateHistory { try $0.clear(profileID: state.selectedProfileID) } }
        catch { errorMessage = "History could not be cleared: \(error.localizedDescription)" }
    }
    func captureCurrentPage(profileID: UUID) async -> Data? {
        guard state.selectedProfileID == profileID, let id = state.selectedTabID,
              let page = page(for: id) else { return nil }
        do {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(1600, max(1, page.webView.bounds.width)))
            let image = try await page.webView.takeSnapshot(configuration: configuration)
            guard state.selectedProfileID == profileID, state.profileID(forTab: id) == profileID,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        } catch { documents.report("Page capture failed: \(error.localizedDescription)"); return nil }
    }

    func resumeDownload(_ id: UUID) {
        let page = state.selectedTabID.flatMap { page(for: $0) }
        if let page { downloads.resume(id, using: page.webView, profileID: state.selectedProfileID) }
        else { errorMessage = "Open a tab in this profile to resume its download." }
    }

    func refreshBoosts() {
        for (id, page) in pages {
            if let profile = pageProfiles[id] { page.applyBoosts(controller: boosts, profileID: profile) }
        }
        peekPage?.applyBoosts(controller: boosts, profileID: state.selectedProfileID)
    }

    func pickBoostElement() {
        guard let id = state.selectedTabID, let page = page(for: id),
              let url = page.webView.url, ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host?.lowercased() else { return }
        let profile = state.selectedProfileID
        page.beginElementPicker { [weak self, weak page] selector in
            guard let self, let selector, self.state.profileID(forTab: id) == profile,
                  page?.webView.url?.host?.lowercased() == host else { return }
            if !self.boosts.save(BrowserBoost(profileID: profile, host: host,
                name: "Hidden Element", hiddenSelectors: [selector])) {
                self.errorMessage = self.boosts.errorMessage
            }
        }
    }

    func submit(_ text: String, newTab: Bool = false) {
        guard let url = destination(text) else {
            errorMessage = "Enter an HTTP or HTTPS address, or words to search for."
            return
        }
        errorMessage = nil
        if !newTab, let id = state.selectedTabID, let page = page(for: id) {
            guard stateUpdate({ $0.updateTab(id, url: url) }) else { return }
            if pages[id] === page { page.webView.load(URLRequest(url: url)) }
            else { _ = self.page(for: id) }
        } else { open(url) }
    }

    func destination(_ input: String) -> URL? {
        Self.destination(input, searchEngine: settings.state.searchEngine(forProfile: state.selectedProfileID))
    }

    static func destination(_ input: String, searchEngine: SearchEngine = .duckDuckGo) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let candidate = URL(string: text), let scheme = candidate.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), candidate.host != nil else { return nil }
            return candidate
        }
        if !text.contains(where: \.isWhitespace), text.contains(".") || text == "localhost" {
            return URL(string: (text == "localhost" ? "http://" : "https://") + text)
        }
        return searchEngine.searchURL(for: text)
    }
}

@MainActor
final class BrowserPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var loading = false
    @Published var failure: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    var onNavigate: ((URL?, String?) -> Void)?
    var onVisit: ((URL, String) -> Void)?
    var onFinish: (() -> Void)?
    var onNavigationStateChange: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)?
    var onNewTab: ((URL) -> Void)?
    var onLink: ((URL) -> Bool)?
    /// A link clicked with modifier keys held (⌥⌘ = mini window, ⇧ = Peek); true when handled.
    var onModifiedLink: ((URL, NSEvent.ModifierFlags) -> Bool)?
    var onFocus: (() -> Void)?
    private var titleObservation: NSKeyValueObservation?
    private var navigationObservations: [NSKeyValueObservation] = []

    init(url: URL, dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = FocusReportingWebView(frame: .zero, configuration: configuration)
        super.init()
        (webView as? FocusReportingWebView)?.onPaneFocus = { [weak self] in self?.onFocus?() }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            let title = change.newValue ?? nil
            Task { @MainActor [weak self] in
                guard let self, let title, !title.isEmpty else { return }
                self.onNavigate?(nil, title)
                if !self.loading, let url = self.webView.url, ["http", "https"].contains(url.scheme ?? "") {
                    self.onVisit?(url, title)
                }
            }
        }
        let navigationChanged: @Sendable () -> Void = { [weak self] in
            // KVO may arrive during view construction; publish after the current
            // actor turn, reading the latest actual WebKit state.
            Task { @MainActor [weak self] in self?.refreshNavigationState() }
        }
        navigationObservations = [
            webView.observe(\.url, options: [.new]) { _, _ in navigationChanged() },
            webView.observe(\.canGoBack, options: [.new]) { _, _ in navigationChanged() },
            webView.observe(\.canGoForward, options: [.new]) { _, _ in navigationChanged() },
        ]
        webView.load(URLRequest(url: url))
    }

    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        onNavigationStateChange?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelElementPicker()
        loading = false
        failure = "The page process stopped. Reload to continue."
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failure = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        let url = webView.url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        onNavigate?(url, title)
        if let url { onVisit?(url, title ?? url.host ?? url.absoluteString) }
        onFinish?()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        loading = false
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        // Subframe/data URLs remain WebKit's responsibility; top-level external protocols need a later explicit handoff.
        if navigationAction.targetFrame?.isMainFrame != false && !["http", "https", "about"].contains(scheme) {
            failure = "This prototype does not open \(scheme) links."
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(scheme),
           !navigationAction.modifierFlags.intersection([.shift, .option, .command]).isEmpty,
           onModifiedLink?(url, navigationAction.modifierFlags) == true {
            decisionHandler(.cancel)
        } else if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           ["http", "https"].contains(scheme), onLink?(url) == true {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { onDownload?(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { onDownload?(download) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") { onNewTab?(url) }
        return nil
    }
}
