import AppKit
import BrowserCore
import Combine
import SwiftUI

@MainActor
final class BrowserWindows: ObservableObject {
    static let shared = BrowserWindows()
    @Published private(set) var isNormalWindowActive = false
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var ownedWindows: [ObjectIdentifier: NSWindow] = [:]
    private var modelObservations: [ObjectIdentifier: AnyCancellable] = [:]
    private var notifications: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] notification in
            guard let self else { return }
            if let window = notification.object as? NSWindow { self.entry(for: window)?.model.activateWindow() }
            self.refreshFocus()
        }.store(in: &notifications)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFocus() }
        }.store(in: &notifications)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.closed(window)
        }.store(in: &notifications)
    }

    var activeModel: BrowserModel? {
        guard let window = NSApplication.shared.keyWindow else { return nil }
        return entry(for: window)?.model
    }

    /// Read-only lookup for window lifecycle verification and explicit window operations.
    func window(for model: BrowserModel) -> NSWindow? {
        entries.values.first(where: { $0.model === model })?.window
    }

    func model(for window: NSWindow) -> BrowserModel? { entry(for: window)?.model }

    private func entry(for window: NSWindow) -> Entry? {
        var parent = window
        while let owner = parent.sheetParent { parent = owner }
        return entries[ObjectIdentifier(parent)]
    }

    func register(_ window: NSWindow, model: BrowserModel) {
        let id = ObjectIdentifier(window)
        guard entries[id]?.model !== model else { return }
        for obsolete in Array(entries.keys) where entries[obsolete]?.window == nil {
            entries.removeValue(forKey: obsolete)
            modelObservations.removeValue(forKey: obsolete)
        }
        entries[id] = Entry(window: window, model: model)
        model.activateWindow()
        modelObservations[id] = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        refreshFocus()
    }

    @discardableResult
    func open(workspace: BrowserWorkspaceSession, selection: BrowserWindowSelection? = nil) -> BrowserModel {
        let model = BrowserModel(workspace: workspace, selection: selection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "D'arce"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 800, height: 540)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: BrowserWindow(model: model).task {
            while !Task.isCancelled {
                model.archiveExpired()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        })
        ownedWindows[ObjectIdentifier(window)] = window
        register(window, model: model)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return model
    }

    private func refreshFocus() { isNormalWindowActive = activeModel != nil }

    private func closed(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let entry = entries[id] else { return }
        entry.model.suspendWindow()
        if ownedWindows.removeValue(forKey: id) != nil {
            window.contentView = nil
            entries.removeValue(forKey: id)
            modelObservations.removeValue(forKey: id)
        }
        // Keep the primary SwiftUI window's weak registration so macOS can reopen that scene.
        Task { @MainActor [weak self] in self?.refreshFocus() }
    }

    private final class Entry {
        weak var window: NSWindow?
        let model: BrowserModel
        init(window: NSWindow, model: BrowserModel) { self.window = window; self.model = model }
    }
}

/// Registers the existing SwiftUI-owned primary window without replacing its delegate.
struct BrowserWindowRegistration: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> RegistrationView { RegistrationView(model: model) }
    func updateNSView(_ nsView: RegistrationView, context: Context) { nsView.model = model }

    final class RegistrationView: NSView {
        weak var model: BrowserModel?
        init(model: BrowserModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let model else { return }
            Task { @MainActor [weak window, weak model] in
                guard let window, let model else { return }
                BrowserWindows.shared.register(window, model: model)
            }
        }
    }
}
