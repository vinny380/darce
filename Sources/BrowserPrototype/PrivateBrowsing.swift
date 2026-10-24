import AppKit
import Combine
import SwiftUI
import WebKit

struct PrivateBrowserTab: Identifiable {
    let id: UUID
    var url: URL
    var title: String
}

/// Has no filesystem configuration and never constructs a persistence-bearing BrowserModel.
@MainActor
final class PrivateBrowserSession: ObservableObject {
    @Published private(set) var tabs: [PrivateBrowserTab] = []
    @Published private(set) var selectedTabID: UUID?
    @Published var addressText = ""
    @Published var addressFocusRequest = UUID()
    @Published var showFind = false
    @Published var errorMessage: String?
    @Published private(set) var isClosed = false
    let dataStore = WKWebsiteDataStore.nonPersistent()
    var onRequestClose: (() -> Void)?
    private var pages: [UUID: BrowserPage] = [:]
    private var downloads: [UUID: PrivateDownload] = [:]

    var selectedPage: BrowserPage? { selectedTabID.flatMap { pages[$0] } }

    func newTab() {
        open(url: URL(string: "about:blank")!)
        focusAddress()
    }

    func open(url: URL) {
        guard !isClosed, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { return }
        let id = UUID()
        let page = BrowserPage(url: url, dataStore: dataStore)
        tabs.append(PrivateBrowserTab(id: id, url: url, title: url.host ?? "New Private Tab"))
        pages[id] = page
        page.onNavigate = { [weak self] url, title in
            guard let self, !self.isClosed, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            if let url { self.tabs[index].url = url }
            if let title { self.tabs[index].title = title }
        }
        page.onNewTab = { [weak self] url in self?.open(url: url) }
        page.onDownload = { [weak self, weak page] download in
            guard let self, !self.isClosed, let window = page?.webView.window else { download.cancel(nil); return }
            let taskID = UUID()
            let task = PrivateDownload(download: download, window: window) { [weak self] error in
                self?.downloads.removeValue(forKey: taskID)
                if let error { self?.errorMessage = error }
            }
            self.downloads[taskID] = task
        }
        select(id)
    }

    func select(_ id: UUID) {
        guard !isClosed, let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        addressText = tab.url.absoluteString == "about:blank" ? "" : tab.url.absoluteString
        showFind = false
    }

    func focusAddress() {
        if let id = selectedTabID, let tab = tabs.first(where: { $0.id == id }) {
            let url = selectedPage?.webView.url ?? tab.url
            addressText = url.absoluteString == "about:blank" ? "" : url.absoluteString
        }
        addressFocusRequest = UUID()
    }

    func navigateAddress() {
        guard !isClosed, let url = BrowserModel.destination(addressText) else { return }
        if let page = selectedPage { page.webView.load(URLRequest(url: url)) }
        else { open(url: url) }
    }

    func duplicateSelectedTab() {
        guard let id = selectedTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        open(url: selectedPage?.webView.url ?? tab.url)
    }

    func cycleTab(backwards: Bool) {
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { select(tabs[0].id); return }
        select(tabs[(index + (backwards ? tabs.count - 1 : 1)) % tabs.count].id)
    }

    func closeSelectedTab() { if let selectedTabID { close(selectedTabID) } }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let page = pages.removeValue(forKey: id) { teardown(page) }
        tabs.remove(at: index)
        if tabs.isEmpty {
            selectedTabID = nil
            addressText = ""
            onRequestClose?()
        } else if selectedTabID == id { select(tabs[min(index, tabs.count - 1)].id) }
    }

    func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        let pending = Array(downloads.values)
        downloads.removeAll()
        pending.forEach { $0.cancel() }
        pages.values.forEach(teardown)
        pages.removeAll()
        tabs.removeAll()
        selectedTabID = nil
        addressText = ""
        onRequestClose = nil
    }

    private func teardown(_ page: BrowserPage) {
        page.onNavigate = nil; page.onVisit = nil; page.onFinish = nil
        page.onNewTab = nil; page.onDownload = nil; page.onLink = nil
        page.cancelElementPicker()
        page.webView.stopLoading()
        page.webView.navigationDelegate = nil
        page.webView.uiDelegate = nil
    }
}

@MainActor
final class PrivateBrowserWindows: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PrivateBrowserWindows()
    @Published private(set) var isPrivateWindowActive = false
    private var windows: [ObjectIdentifier: (NSWindow, PrivateBrowserSession)] = [:]
    private var sessionObservations: [ObjectIdentifier: AnyCancellable] = [:]

    var activeSession: PrivateBrowserSession? {
        guard var window = NSApplication.shared.keyWindow else { return nil }
        while let parent = window.sheetParent { window = parent }
        return windows[ObjectIdentifier(window)]?.1
    }

    @discardableResult
    func open(url: URL? = nil) -> PrivateBrowserSession {
        let session = PrivateBrowserSession()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Private Browsing"
        window.minSize = NSSize(width: 700, height: 450)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PrivateBrowserView(session: session))
        session.onRequestClose = { [weak window] in window?.performClose(nil) }
        windows[ObjectIdentifier(window)] = (window, session)
        sessionObservations[ObjectIdentifier(window)] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if let url { session.open(url: url) } else { session.newTab() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return session
    }

    private func publishSettledContext() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.isPrivateWindowActive = self.activeSession != nil
            // Commands can validate synchronously on willChange; notify again after focus state settles.
            self.objectWillChange.send()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        isPrivateWindowActive = activeSession != nil
        publishSettledContext()
    }
    func windowDidResignKey(_ notification: Notification) {
        // A native sheet can become key without leaving its private browsing context.
        publishSettledContext()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (_, session) = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        sessionObservations.removeValue(forKey: ObjectIdentifier(window))
        session.shutdown()
        window.contentView = nil
        isPrivateWindowActive = activeSession != nil
        publishSettledContext()
    }
}

private struct PrivateBrowserView: View {
    @ObservedObject var session: PrivateBrowserSession
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.purple)
                Text("Private").font(.headline)
                if let page = session.selectedPage { PrivatePageNavigation(page: page) }
                TextField("Search or enter address", text: $session.addressText)
                    .textFieldStyle(.roundedBorder).focused($addressFocused)
                    .onSubmit { session.navigateAddress(); addressFocused = false }
                    .accessibilityLabel("Private window address")
                Button { session.newTab() } label: { Image(systemName: "plus") }.help("New Private Tab")
            }.padding(10)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(session.tabs) { tab in
                        HStack(spacing: 8) {
                            Button { session.select(tab.id) } label: { Text(tab.title).lineLimit(1).frame(maxWidth: 180) }
                                .buttonStyle(.plain)
                            Button { session.close(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(.plain).accessibilityLabel("Close \(tab.title)")
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .background(session.selectedTabID == tab.id ? Color.purple.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(.horizontal, 10).padding(.bottom, 7)
            }
            if let error = session.errorMessage {
                HStack { Text(error); Spacer(); Button("Dismiss") { session.errorMessage = nil } }
                    .font(.callout).padding(10).foregroundStyle(.red)
            }
            if let page = session.selectedPage {
                if session.showFind { FindBar(page: page, close: { session.showFind = false }) }
                BrowserPane(page: page)
            } else { Spacer() }
            Text("History and website data stay in this private window. Files you save remain on your Mac.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onChange(of: session.addressFocusRequest) { _, _ in addressFocused = true }
        .onAppear { addressFocused = true }
    }
}

private struct PrivatePageNavigation: View {
    @ObservedObject var page: BrowserPage
    var body: some View {
        HStack(spacing: 8) {
            Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!page.canGoBack).help("Back")
            Button { page.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!page.canGoForward).help("Forward")
            Button { if page.loading { page.webView.stopLoading() } else { page.webView.reload() } } label: {
                Image(systemName: page.loading ? "xmark" : "arrow.clockwise")
            }.help(page.loading ? "Stop Loading" : "Reload")
        }.buttonStyle(.plain)
    }
}
