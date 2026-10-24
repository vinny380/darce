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
    private var order: [ObjectIdentifier] = []
    private var pending: [URL] = []
    private var launcher: NSPanel?
    private var launcherObserver: NSObjectProtocol?
    /// Arc remembers the Little Arc window's size and position; so does D'arce.
    private static let frameName = "DarceMiniWindow"

    var count: Int { windows.count }
    var newest: MiniBrowser? { order.last.flatMap { windows[$0]?.mini } }

    /// The mini window that has keyboard focus, so menu shortcuts can act on it instead of the main window.
    var active: MiniBrowser? {
        guard let window = NSApplication.shared.keyWindow else { return nil }
        return windows[ObjectIdentifier(window)]?.mini
    }

    @discardableResult
    func open(url: URL, model: BrowserModel? = nil) -> MiniBrowser? {
        guard let model = model ?? BrowserWindows.shared.activeModel ?? primaryModel else {
            pending.append(url)
            return nil
        }
        let mini = MiniBrowser(model: model, url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Mini Window"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MiniBrowserView(mini: mini, model: model))
        mini.onClose = { [weak window] in window?.performClose(nil) }
        let id = ObjectIdentifier(window)
        windows[id] = (window, mini)
        order.append(id)
        if windows.count == 1, window.setFrameUsingName(Self.frameName) {} else { window.center() }
        if windows.count == 1 { window.setFrameAutosaveName(Self.frameName) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return mini
    }

    /// ⌥⌘N: the floating launcher. With `target`, the choice loads in that mini window instead of a new one.
    func openLauncher(for target: MiniBrowser? = nil) {
        guard let model = target?.model ?? BrowserWindows.shared.activeModel ?? primaryModel else { return }
        closeLauncher()
        let size = NSSize(width: 600, height: 560)
        let panel = MiniLauncherPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the bar draws its own; a window shadow would outline the transparent margin
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MiniLauncherView(model: model, target: target) { [weak self] in self?.closeLauncher() })
        let anchor = target.flatMap { mini in windows.values.first { $0.mini === mini }?.window.frame }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let area = anchor ?? screen
        // Centered, with the bar's top a fifth of the way down (just under the toolbar when over a mini window).
        let top = anchor == nil ? area.maxY - area.height / 5 : area.maxY - 8
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: top - size.height + 40))
        launcher = panel
        launcherObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { MiniWindows.shared.closeLauncher() }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeLauncher() {
        launcherObserver.map(NotificationCenter.default.removeObserver)
        launcherObserver = nil
        launcher?.orderOut(nil)
        launcher = nil
    }

    func closeAll() { windows.values.forEach { $0.window.performClose(nil) } }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        order.removeAll { $0 == ObjectIdentifier(window) }
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
    @Published private(set) var title = ""
    var onClose: (() -> Void)?
    private(set) weak var model: BrowserModel?
    private let profileID: UUID
    /// The Space it was opened from; its theme frames the window and it's the default "Open in" target.
    let spaceID: UUID

    init(model: BrowserModel, url: URL) {
        self.model = model
        profileID = model.state.selectedProfileID
        spaceID = model.state.selectedSpaceID
        load(url)
    }

    var host: String {
        guard let host = currentURL?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func navigate(_ url: URL) { load(url) }

    func copyLink() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Moves this page into the main window as a tab (in `space`, or the one it came from), then closes.
    func openInMain(space: UUID? = nil) {
        guard let model, let url = page?.webView.url ?? currentURL else { return }
        if let space, space != model.state.selectedSpaceID { model.selectSpace(space) }
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
        page.onNavigate = { [weak self] url, title in
            if let url { self?.currentURL = url }
            if let title { self?.title = title }
        }
        page.onNewTab = { [weak page] url in page?.webView.load(URLRequest(url: url)) }
        page.onVisit = { [weak model] url, title in model?.recordVisit(url: url, title: title, profileID: profileID) }
        page.onDownload = { [weak model] download in _ = model?.downloads.accept(download: download, profileID: profileID) }
        page.applyBoosts(controller: model.boosts, profileID: profileID)
        self.page = page
    }
}

struct MiniBrowserView: View {
    @ObservedObject var mini: MiniBrowser
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("miniWindowTipShown") private var tipShown = 0
    @State private var showTip = false
    @State private var copied = false

    private var spaceName: String { model.state.spaces.first { $0.id == mini.spaceID }?.name ?? "D'arce" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                if let page = mini.page { BrowserPane(page: page) } else { Color(nsColor: .textBackgroundColor) }
                if showTip { tip.padding(10).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(.horizontal, 7).padding(.bottom, 7)
        }
        .background(model.appearance.background(forSpace: mini.spaceID, scheme: scheme))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            // Like Arc's first-run banner: shown the first few times only.
            guard tipShown < 3 else { return }
            tipShown += 1
            withAnimation(.smooth(duration: 0.3).delay(0.4)) { showTip = true }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 64)  // window buttons
            AddressPill(mini: mini, model: model)
            ToolbarIconButton(symbol: copied ? "checkmark" : "link", help: "Copy Link") {
                mini.copyLink()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
            Menu {
                Section("Open in") {
                    ForEach(model.state.spaces) { space in
                        Button { mini.openInMain(space: space.id) } label: {
                            Label(space.name, systemImage: model.appearance.state.space(space.id).icon)
                        }
                    }
                }
            } label: {
                Label("Open in \(spaceName)", systemImage: model.appearance.state.space(mini.spaceID).icon)
            } primaryAction: { mini.openInMain() }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.visible).fixedSize()
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Move this page to a full window (⌘O)")
            .keyboardShortcut("o")
        }
        .padding(.leading, 6).padding(.trailing, 8).frame(height: 44)
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Links open in mini windows").font(.system(size: 13, weight: .semibold))
                Text("Click “Open in” to move this page to a full window, or ⌘W to close.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { withAnimation(.smooth(duration: 0.25)) { showTip = false } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// The site pill in the toolbar; clicking it opens the launcher to go somewhere else in this window.
private struct AddressPill: View {
    @ObservedObject var mini: MiniBrowser
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if let url = mini.currentURL {
                SiteIcon(controller: model.favicons, url: url, profileID: model.state.selectedProfileID, size: 14)
            }
            Text(mini.host).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: .infinity)
        .background(Palette.color(hovered ? "SidebarItemHovered" : "SidebarItemBackground", scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { MiniWindows.shared.openLauncher(for: mini) }
        .help(mini.currentURL?.absoluteString ?? "")
        .accessibilityAddTraits(.isButton).accessibilityLabel("Address, \(mini.host)")
        .accessibilityAction { MiniWindows.shared.openLauncher(for: mini) }
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                .background(hovered ? Palette.color("SidebarItemBackground", scheme: scheme) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.help(help)
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
        if let model = MiniWindows.shared.primaryModel, !model.settings.state.externalLinksOpenInMiniWindow {
            let target = BrowserWindows.shared.activeModel ?? model
            target.open(url)
            BrowserWindows.shared.window(for: target)?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            MiniWindows.shared.open(url: url)
        }
    }
}
