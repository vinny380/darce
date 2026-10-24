import AppKit
import Combine
import SwiftUI
import WebKit

/// Arc's Little Arc: a small floating window for a quick look. Links from other apps open here when D'arce is the
/// default browser, and "Open in D'arce" moves the page into the main window as a tab.
@MainActor
final class MiniWindows: NSObject, NSWindowDelegate {
    static let shared = MiniWindows()
    /// The primary window's model. Links that arrive before it exists (D'arce launched by a click) wait for it.
    var primaryModel: BrowserModel? { didSet { flushPending() } }
    private var windows: [ObjectIdentifier: (window: NSWindow, mini: MiniBrowser)] = [:]
    private var pending: [URL] = []

    var count: Int { windows.count }

    /// The mini window that has keyboard focus, so menu shortcuts can act on it instead of the main window.
    var active: MiniBrowser? {
        guard let window = NSApplication.shared.keyWindow else { return nil }
        return windows[ObjectIdentifier(window)]?.mini
    }

    @discardableResult
    func open(url: URL? = nil, model: BrowserModel? = nil) -> MiniBrowser? {
        guard let model = model ?? BrowserWindows.shared.activeModel ?? primaryModel else {
            if let url { pending.append(url) }
            return nil
        }
        let mini = MiniBrowser(model: model, url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MiniBrowserView(mini: mini, appearance: model.appearance))
        mini.onClose = { [weak window] in window?.performClose(nil) }
        windows[ObjectIdentifier(window)] = (window, mini)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return mini
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.mini.teardown()
        window.contentView = nil
    }

    private func flushPending() {
        guard primaryModel != nil, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        urls.forEach { open(url: $0) }
    }
}

@MainActor
final class MiniBrowser: ObservableObject {
    @Published private(set) var page: BrowserPage?
    @Published private(set) var currentURL: URL?
    @Published var addressText = ""
    @Published var editingAddress = false
    var onClose: (() -> Void)?
    private weak var model: BrowserModel?
    private let profileID: UUID
    /// The Space it was opened from; its theme frames the window.
    let spaceID: UUID

    init(model: BrowserModel, url: URL?) {
        self.model = model
        profileID = model.state.selectedProfileID
        spaceID = model.state.selectedSpaceID
        if let url { load(url) } else { editingAddress = true }
    }

    var host: String { currentURL?.host ?? "New Mini Window" }

    func beginEditing() {
        addressText = currentURL?.absoluteString ?? ""
        editingAddress = true
    }

    func submitAddress() {
        guard let url = model.flatMap({ $0.destination(addressText) }) else { return }
        editingAddress = false
        load(url)
    }

    func copyLink() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Moves this page into the main window as a tab, then closes the mini window.
    func openInMain() {
        guard let model, let url = page?.webView.url ?? currentURL else { return }
        model.open(url)
        BrowserWindows.shared.window(for: model)?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    func teardown() {
        page?.webView.stopLoading()
        page?.webView.removeFromSuperview()
        page = nil
    }

    private func load(_ url: URL) {
        currentURL = url
        if let page { page.webView.load(URLRequest(url: url)); return }
        guard let model else { return }
        let profileID = profileID
        let page = BrowserPage(url: url, dataStore: model.dataStore(for: profileID))
        page.webView.pageZoom = model.settings.state.defaultZoom
        page.onNavigate = { [weak self] url, _ in if let url { self?.currentURL = url } }
        page.onNewTab = { [weak page] url in page?.webView.load(URLRequest(url: url)) }
        page.onVisit = { [weak model] url, title in model?.recordVisit(url: url, title: title, profileID: profileID) }
        page.onDownload = { [weak model] download in _ = model?.downloads.accept(download: download, profileID: profileID) }
        page.applyBoosts(controller: model.boosts, profileID: profileID)
        self.page = page
    }
}

struct MiniBrowserView: View {
    @ObservedObject var mini: MiniBrowser
    @ObservedObject var appearance: AppearanceController
    @Environment(\.colorScheme) private var scheme
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 56)  // window buttons
                if mini.editingAddress {
                    TextField("Search or Enter URL…", text: $mini.addressText)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($addressFocused)
                        .onSubmit { mini.submitAddress() }
                        .onExitCommand { if mini.page != nil { mini.editingAddress = false } }
                        .onAppear { addressFocused = true }
                } else {
                    Text(mini.host).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .contentShape(Rectangle()).onTapGesture { mini.beginEditing() }
                        .help("Edit address (⌘L)")
                }
                Spacer(minLength: 8)
                Button { mini.copyLink() } label: { Image(systemName: "link") }
                    .help("Copy Link").disabled(mini.currentURL == nil)
                Button { mini.openInMain() } label: {
                    Label("Open in D'arce", systemImage: "arrow.up.forward.app").labelStyle(.titleAndIcon)
                }
                .help("Move this page into the main window (⌘O)").keyboardShortcut("o").disabled(mini.page == nil)
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.7))
            .padding(.horizontal, 12).frame(height: 38)
            Group {
                if let page = mini.page { BrowserPane(page: page) }
                else { Color(nsColor: .textBackgroundColor) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .background(appearance.background(forSpace: mini.spaceID, scheme: scheme))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: mini.editingAddress) { _, editing in if editing { addressFocused = true } }
    }
}

/// When D'arce is the default browser, links clicked in other apps arrive as "get URL" Apple events and open in a
/// mini window, like Little Arc. Installed again as launch finishes so SwiftUI's own URL handling can't replace it.
@MainActor
final class ExternalLinkHandler: NSObject {
    static let shared = ExternalLinkHandler()
    private var launchObserver: NSObjectProtocol?

    func install() {
        register()
        launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.willFinishLaunchingNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ExternalLinkHandler.shared.register() }
        }
    }

    private func register() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MiniWindows.shared.open(url: url)
    }
}
