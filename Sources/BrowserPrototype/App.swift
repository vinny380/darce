import AppKit
import BrowserCore
import SwiftUI
import WebKit

@main
struct BrowserPrototypeApp: App {
    @StateObject private var model: BrowserModel
    private let windowLifecycleOutput: URL?
    private let smokeOutput: URL?
    private let fixtureBase: URL?
    private let networkPhase: String
    private let importFrom: ImportBrowser?
    private let importResult: URL

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // Debug: write the welcome's score to a file to listen to it, then quit.
        if let path = value("--render-premiere-music") {
            _ = try? PremiereMusic.renderOffline(seconds: 40, to: URL(fileURLWithPath: path))
            exit(0)
        }
        // Owned verification bundles remain isolated when a UI tool relaunches them without CLI arguments.
        let verificationDirectory = (Bundle.main.object(forInfoDictionaryKey: "BrowserVerificationDataDirectory") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = value("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? verificationDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Darce")
        let isSmoke = verificationDirectory != nil || value("--smoke-output") != nil || value("--window-lifecycle-output") != nil
        fixtureBase = value("--network-smoke").flatMap(URL.init(string:))
        networkPhase = value("--network-phase") ?? "seed"
        importFrom = value("--import-from").flatMap(ImportBrowser.init(rawValue:))
        importResult = directory.appendingPathComponent("import-result.json")
        let ephemeral = isSmoke && value("--network-smoke") == nil
        if #available(macOS 15.4, *) { ExtensionManager.shared = ExtensionManager(directory: directory) }
        _model = StateObject(wrappedValue: BrowserModel(directory: directory, ephemeralWebsiteData: ephemeral,
                                                       downloadsDirectory: isSmoke ? directory.appendingPathComponent("downloads") : nil))
        windowLifecycleOutput = value("--window-lifecycle-output").map { URL(fileURLWithPath: $0) }
        smokeOutput = value("--smoke-output").map { URL(fileURLWithPath: $0) }
        if !isSmoke { ExternalLinkHandler.shared.install() }
        QuitConfirmation.enabled = !isSmoke
        ShortcutAliases.install()
        MenuTracking.install()
    }

    var body: some Scene {
        Window("D'arce", id: "main") {
            BrowserWindow(model: model)
                .background(BrowserWindowRegistration(model: model))
                .onAppear {
                    MiniWindows.shared.primaryModel = model
                    GlobalMiniWindowShortcut.shared.setEnabled(model.settings.state.globalMiniWindowShortcut)
                }
                .frame(minWidth: 800, minHeight: 540)
                .task {
                    if let windowLifecycleOutput {
                        await runWindowLifecycleSmoke(primary: model, output: windowLifecycleOutput)
                    } else if let smokeOutput, let fixtureBase {
                        await runNetworkSmoke(model: model, base: fixtureBase, phase: networkPhase, output: smokeOutput)
                    } else if let smokeOutput { await runSmoke(model: model, output: smokeOutput) }
                    else if let importFrom {
                        let report = await model.importWithoutAsking(from: importFrom,
                                                                     cookies: ProcessInfo.processInfo.arguments.contains("--import-cookies"))
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try? encoder.encode(report).write(to: importResult, options: .atomic)
                        NSApplication.shared.terminate(nil)
                    } else {
                        if model.isFirstLaunch, !ImportSources.installed(home: FileManager.default.homeDirectoryForCurrentUser).isEmpty {
                            model.panel = .welcome
                        }
                        while !Task.isCancelled {
                            model.archiveExpired()
                            do { try await Task.sleep(for: .seconds(60)) } catch { break }
                        }
                    }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { BrowserApplicationCommands(model: model) }
        Settings { SettingsWindow(model: model) }
    }
}

struct BrowserWindow: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var appearance: AppearanceController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewSidebarWidth: CGFloat?
    @State private var dragWidth: CGFloat?
    @State private var showArchive = false
    @State private var showNewSpace = false
    @State private var showNewFolder = false
    @State private var fullScreen = false
    @State private var name = ""
    /// Horizontal travel of the Space's sidebar content; drives the slide and the theme cross-fade.
    @State private var spaceSlide: CGFloat = 0
    /// The other Space's theme, drawn over the current one at `slideProgress` opacity.
    @State private var overlaySpace: UUID?
    @State private var swipeSwitching = false
    @State private var transitionID = 0
    /// The hidden sidebar, slid out over the page because the pointer reached the window's left edge.
    @State private var edgeRevealed = false
    @State private var edgeHide: Task<Void, Never>?
    @State private var swipeWatchdog: Task<Void, Never>?
    @State private var lastSwipeDX: CGFloat = 0

    init(model: BrowserModel) {
        self.model = model
        self.appearance = model.appearance
    }

    private var sidebarWidth: CGFloat { previewSidebarWidth ?? CGFloat(appearance.state.sidebarWidth) }
    private var slideProgress: CGFloat { min(1, abs(spaceSlide) / max(sidebarWidth, 1)) }
    private var themeLayers: [UUID] {
        let current = model.state.selectedSpaceID
        return [current] + (overlaySpace.map { $0 == current ? [] : [$0] } ?? [])
    }

    private func neighborSpace(next: Bool) -> UUID? {
        let ids = model.state.spaces.map(\.id)
        guard let index = ids.firstIndex(of: model.state.selectedSpaceID) else { return nil }
        let target = index + (next ? 1 : -1)
        return ids.indices.contains(target) ? ids[target] : nil
    }

    /// Settles the slide at 0, then drops the overlay unless a newer transition has started.
    private func settle(_ animation: Animation) {
        transitionID += 1
        let id = transitionID
        withAnimation(animation) { spaceSlide = 0 } completion: { if id == transitionID { overlaySpace = nil } }
    }

    /// Jumps the content to `offset`, then springs it home. The jump must render first; written in the same
    /// update, SwiftUI merges both and the content slides in from the side it left.
    private func slideIn(from offset: CGFloat) {
        withTransaction(Transaction(animation: nil)) { spaceSlide = offset }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            settle(.spring(duration: 0.4, bounce: 0.12))
        }
    }

    private func handleSpaceSwipe(_ update: SpaceSwipeTracker.Update) {
        switch update {
        case .drag(let dx):
            guard !reduceMotion else { return }
            // If the gesture's end event never arrives, settle anyway so the sidebar can't stay shifted.
            lastSwipeDX = dx
            swipeWatchdog?.cancel()
            swipeWatchdog = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                handleSpaceSwipe(.end(lastSwipeDX, velocity: 0))
            }
            transitionID += 1
            let target = neighborSpace(next: dx < 0)
            overlaySpace = target
            spaceSlide = target == nil ? dx * 0.2 : max(-sidebarWidth, min(sidebarWidth, dx))  // rubber band at the ends
        case .end(let dx, let velocity):
            swipeWatchdog?.cancel()
            swipeWatchdog = nil
            let next = dx < 0
            let flick = abs(dx) > 12 && abs(velocity) > 6 && (velocity < 0) == next
            guard abs(dx) > 50 || flick, let target = neighborSpace(next: next) else {
                settle(.spring(duration: 0.35, bounce: 0.25))
                return
            }
            guard !reduceMotion else { model.selectSpace(target); return }
            transitionID += 1
            let width = sidebarWidth
            // A committed swipe always finishes; dropping it would strand the content off-screen.
            withAnimation(.easeOut(duration: 0.12)) { spaceSlide = next ? -width : width } completion: {
                swipeSwitching = true
                model.selectSpace(target)
                overlaySpace = nil
                slideIn(from: next ? width * 0.45 : -width * 0.45)
            }
        }
    }

    /// Keyboard and click switches slide the new Space in while the old theme fades out.
    private func animateSpaceChange(from old: UUID, to new: UUID) {
        if swipeSwitching { swipeSwitching = false; return }
        let ids = model.state.spaces.map(\.id)
        guard !reduceMotion, let from = ids.firstIndex(of: old), let to = ids.firstIndex(of: new) else { return }
        overlaySpace = old
        slideIn(from: to > from ? sidebarWidth * 0.6 : -sidebarWidth * 0.6)
    }

    /// Full screen with the sidebar hidden: only the page, edge to edge, like Arc.
    private var bare: Bool { fullScreen && !model.sidebarVisible && !model.libraryOpen }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.libraryOpen {
                    LibraryView(model: model, downloads: model.downloads, documents: model.documents, boosts: model.boosts)
                        .frame(width: max(sidebarWidth, 390))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else if model.sidebarVisible {
                    BrowserSidebar(model: model, appearance: appearance, showArchive: $showArchive, showNewSpace: $showNewSpace, showNewFolder: $showNewFolder,
                                   spaceSlide: spaceSlide, spaceSlideProgress: slideProgress)
                        .frame(width: sidebarWidth)
                        .background(SpaceSwipeMonitor(onUpdate: handleSpaceSwipe))
                    Color.clear.frame(width: 5).contentShape(Rectangle())
                        .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture().onChanged { value in
                            if dragWidth == nil { dragWidth = sidebarWidth }
                            previewSidebarWidth = min(360, max(210, (dragWidth ?? sidebarWidth) + value.translation.width))
                        }.onEnded { _ in
                            let width = Double(sidebarWidth)
                            appearance.update { $0.sidebarWidth = width }
                            previewSidebarWidth = nil
                            dragWidth = nil
                        })
                        .accessibilityLabel("Resize sidebar")
                        .accessibilityValue("\(Int(sidebarWidth)) points")
                        .accessibilityAdjustableAction { direction in
                            appearance.update {
                                switch direction {
                                case .increment: $0.sidebarWidth = min(360, $0.sidebarWidth + 10)
                                case .decrement: $0.sidebarWidth = max(210, $0.sidebarWidth - 10)
                                @unknown default: break
                                }
                            }
                        }
                }
                VStack(spacing: 0) {
                    if !model.sidebarVisible && !bare {
                        HStack {
                            Button { model.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                            Button { model.commandMode = .location } label: { Text(model.state.selectedTab?.url.host ?? "Search or Enter URL…") }
                            Spacer()
                        }.buttonStyle(.plain).padding(.leading, 78).padding(.trailing, 12).frame(height: 38)
                        .background(WindowControlsVisibility(visible: true))  // no sidebar: keep the window buttons
                    }
                    if let error = appearance.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red).padding(10)
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red).padding(10)
                    }
                    if model.showFind, let id = model.state.selectedTabID, let page = model.page(for: id) {
                        FindBar(page: page, close: { model.showFind = false })
                    }
                    if let group = model.state.selectedSplitGroup {
                        SplitPaneLayout(group: group, selectedTabID: model.state.selectedTabID,
                            title: { id in model.state.tabs.first { $0.id == id }?.title ?? "Split View" },
                            onFocus: model.focusPane,
                            onSeparate: { model.separatePane($0, from: group.id) },
                            onResize: { weights in model.stateUpdate { state in
                                guard state.selectedSplitGroup == group else { return }
                                _ = state.resizeSplit(group.id, weights: weights)
                            } },
                            onAxis: { axis in model.stateUpdate { _ = $0.setSplitAxis(group.id, axis: axis) } },
                            onReorder: { ids in model.stateUpdate { _ = $0.reorderSplit(group.id, tabIDs: ids) } }
                        ) { id in
                            if let page = model.page(for: id) { BrowserPane(page: page) }
                        }
                    } else { content }
                }
                .padding(.top, model.sidebarVisible && !bare ? 8 : 0)
                .padding(.trailing, bare ? 0 : 8).padding(.bottom, bare ? 0 : 8)
                .padding(.leading, model.sidebarVisible || bare ? 0 : 8)
            }
            if !model.sidebarVisible && !model.libraryOpen { edgeSidebar }
            if let page = model.peekPage {
                Color.black.opacity(0.20).ignoresSafeArea().onTapGesture { model.closePeek() }
                VStack(spacing: 0) {
                    HStack {
                        Button { model.closePeek() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close Peek")
                        Spacer()
                        Text(page.webView.url?.host ?? "Peek").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button { model.promotePeek() } label: { Image(systemName: "arrow.up.right.square") }.help("Open Peek as a tab")
                    }.buttonStyle(.plain).padding(14).background(.regularMaterial)
                    BrowserPane(page: page)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.2), radius: 32, y: 12)
                .padding(.horizontal, model.sidebarVisible ? 90 : 50).padding(.vertical, 55)
                .onExitCommand { model.closePeek() }
            }
            if model.boostPanelOpen, let host = model.state.selectedTab?.url.host?.lowercased() {
                // Arc docks the Boost editor at the right of the page.
                BoostPanel(model: model, boosts: model.boosts, host: host, profileID: model.state.selectedProfileID)
                    .id(host)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if model.commandMode != nil { BrowserCommandBar(model: model).id(model.commandMode == .location ? "location" : "new-tab") }
            DialogOverlay(center: .shared, model: model)
        }
        .background {
            ZStack {
                ForEach(themeLayers, id: \.self) { id in
                    appearance.background(forSpace: id, scheme: scheme)
                        .opacity(id == model.state.selectedSpaceID ? 1 : Double(slideProgress))
                }
            }
        }
        .onChange(of: model.state.selectedSpaceID) { old, new in animateSpaceChange(from: old, to: new) }
        .preferredColorScheme(appearance.preferredColorScheme)
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.sidebarVisible)
        .background(FullScreenReader(isFullScreen: $fullScreen))
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.boostPanelOpen)
        // The sidebar's bottom-left button opens the Library, like Arc (it used to open an Archive sheet).
        .onChange(of: showArchive) { _, show in if show { showArchive = false; model.libraryOpen = true } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.libraryOpen)
        .sheet(item: $model.panel) { panel in
            switch panel {
            case .importBrowser: ImportSheet(model: model)
            case .welcome: ImportSheet(model: model, welcome: true)
            case .browsingData:
                BrowsingDataView(controller: model.browsingData, profileID: model.state.selectedProfileID,
                                 profileName: model.state.profiles.first(where: { $0.id == model.state.selectedProfileID })?.name ?? "Profile")
            case .documents:
                let profileID = model.state.selectedProfileID
                DocumentsView(controller: model.documents, profileID: profileID,
                              captureCurrentPage: { await model.captureCurrentPage(profileID: profileID) })
            case .profiles: ProfilesView(model: model)
            case .history: HistoryView(model: model)
            case .downloads: DownloadsView(manager: model.downloads, profileID: model.state.selectedProfileID, resume: model.resumeDownload)
            case .appearance:
                AppearanceView(controller: appearance, spaceID: model.state.selectedSpaceID,
                               spaceName: model.state.spaces.first { $0.id == model.state.selectedSpaceID }?.name ?? "Space")
            case .spaces:
                ManageSpacesView(model: model)
            case .boosts:
                if let url = model.state.selectedTab?.url, url.host != nil {
                    BoostEditor(controller: model.boosts, profileID: model.state.selectedProfileID, url: url)
                } else {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Open a Website", systemImage: "paintbrush", description: Text("Boosts customize the website in your current tab."))
                        Button("Done") { model.panel = nil }.keyboardShortcut(.cancelAction)
                    }.padding(20).frame(width: 400, height: 280)
                }
            }
        }
        .alert(model.spacePrompt == .new ? "New Space" : "Rename Space",
               isPresented: Binding(get: { model.spacePrompt != nil }, set: { if !$0 { model.spacePrompt = nil } })) {
            TextField("Name", text: $name)
            Button(model.spacePrompt == .new ? "Create" : "Rename") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                switch model.spacePrompt {
                case .new: model.addSpace(trimmed)
                case .rename(let id): if !trimmed.isEmpty { model.stateUpdate { $0.renameSpace(id, name: trimmed) } }
                case nil: break
                }
                name = ""
            }
            Button("Cancel", role: .cancel) { name = "" }
        }
        .onChange(of: showNewSpace) { _, show in if show { showNewSpace = false; name = ""; model.spacePrompt = .new } }
        .onChange(of: model.spacePrompt) { _, prompt in
            if case .rename(let id) = prompt { name = model.state.spaces.first { $0.id == id }?.name ?? "" }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $name)
            Button("Create") { model.addFolder(name); name = "" }
            Button("Cancel", role: .cancel) { name = "" }
        }
    }

    /// Like Arc: with the sidebar hidden, pushing the pointer to the left edge slides it out over the page,
    /// and leaving it tucks it straight back. It stays built and slides on a transform, so both ways are smooth.
    @ViewBuilder private var edgeSidebar: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 6).frame(maxHeight: .infinity).contentShape(Rectangle())
                .onHover { inside in
                    guard inside else { return }
                    edgeHide?.cancel()
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { edgeRevealed = true }
                }
                .accessibilityHidden(true)
            BrowserSidebar(model: model, appearance: appearance, showArchive: $showArchive, showNewSpace: $showNewSpace, showNewFolder: $showNewFolder,
                           spaceSlide: spaceSlide, spaceSlideProgress: slideProgress, floating: true)
                .frame(width: sidebarWidth)
                // The Space color is translucent; an opaque base keeps the page and header from showing through.
                .background {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        appearance.background(forSpace: model.state.selectedSpaceID, scheme: scheme)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
                .compositingGroup()
                .shadow(color: .black.opacity(edgeRevealed ? 0.3 : 0), radius: 24, x: 6)
                // Swipes are read wherever the monitor's view sits, so it only exists while the sidebar is out.
                .background { if edgeRevealed { SpaceSwipeMonitor(onUpdate: handleSpaceSwipe) } }
                // Flush with the window's top so its first row lines up with the window buttons, as when docked.
                .padding([.leading, .bottom], 6)
                .contentShape(Rectangle())
                .onHover { inside in
                    edgeHide?.cancel()
                    guard !inside, edgeRevealed else { return }
                    let width = sidebarWidth + 6
                    edgeHide = Task { @MainActor in
                        // A right-click menu over the sidebar also reads as leaving; wait for it to close, then
                        // stay out only if the pointer came back over the sidebar.
                        while MenuTracking.isOpen || Self.pointerInLeadingStrip(width: width) {
                            try? await Task.sleep(for: .milliseconds(80))
                            guard !Task.isCancelled else { return }
                        }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { edgeRevealed = false }
                    }
                }
                .offset(x: edgeRevealed ? 0 : -(sidebarWidth + 40))
                .allowsHitTesting(edgeRevealed)
                .accessibilityHidden(!edgeRevealed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onChange(of: model.sidebarVisible) { _, _ in edgeRevealed = false }
    }

    private static func pointerInLeadingStrip(width: CGFloat) -> Bool {
        guard let window = NSApplication.shared.keyWindow else { return false }
        let point = NSEvent.mouseLocation
        return window.frame.contains(point) && point.x - window.frame.minX < width
    }

    @ViewBuilder private var content: some View {
        if let tab = model.state.selectedTab, let easel = tab.url.easelID {
            EaselCanvas(model: model, documents: model.documents, documentID: easel, tabID: tab.id)
                .id(tab.id).clipShape(RoundedRectangle(cornerRadius: bare ? 0 : 10))
        } else if let id = model.state.selectedTabID, let page = model.page(for: id) {
            VStack(spacing: 0) {
                if model.isDeveloperModeOn {
                    let tint = appearance.state.space(model.state.selectedSpaceID).tint
                    DeveloperBar(model: model, page: page, tint: Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue))
                }
                BrowserPane(page: page).id(id)
            }.clipShape(RoundedRectangle(cornerRadius: bare ? 0 : 10))
        } else {
            Button { model.commandMode = .newTab } label: {
                VStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 26, weight: .ultraLight))
                    Text("Search or Enter URL…").font(.system(size: 15))
                    Text("⌘T").font(.system(size: 12)).opacity(0.55)
                }.foregroundStyle(.primary.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.buttonStyle(.plain).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct BrowserPane: View {
    @ObservedObject var page: BrowserPage
    var body: some View {
        VStack(spacing: 0) {
            if page.loading { ProgressView().progressViewStyle(.linear).frame(height: 2) }
            if let failure = page.failure {
                HStack { Image(systemName: "exclamationmark.circle"); Text(failure); Spacer(); Button("Reload") { page.webView.reload() } }
                    .font(.callout).padding(12).background(.bar)
            }
            WebContent(page: page).id(ObjectIdentifier(page.webView))
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

struct WebContent: NSViewRepresentable {
    let page: BrowserPage
    func makeNSView(context: Context) -> WebContainer { WebContainer(page.webView) }
    func updateNSView(_ nsView: WebContainer, context: Context) {}
}

/// The page sits in its own container, as in other browsers, so WebKit's docked Web Inspector has a superview
/// to share: it inserts itself beside the page and shrinks it, which SwiftUI's own layout wouldn't allow.
final class WebContainer: NSView {
    init(_ webView: WKWebView) {
        super.init(frame: .zero)
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }
}


/// Whether this view's own window is in full screen (other windows don't count).
private struct FullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ReaderView { ReaderView { isFullScreen = $0 } }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        private let report: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(report: @escaping (Bool) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            report(window.styleMask.contains(.fullScreen))
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(window.styleMask.contains(.fullScreen)) }
                })
            }
        }
    }
}
