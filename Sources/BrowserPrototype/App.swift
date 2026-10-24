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

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
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
        let ephemeral = isSmoke && value("--network-smoke") == nil
        _model = StateObject(wrappedValue: BrowserModel(directory: directory, ephemeralWebsiteData: ephemeral,
                                                       downloadsDirectory: isSmoke ? directory.appendingPathComponent("downloads") : nil))
        windowLifecycleOutput = value("--window-lifecycle-output").map { URL(fileURLWithPath: $0) }
        smokeOutput = value("--smoke-output").map { URL(fileURLWithPath: $0) }
    }

    var body: some Scene {
        Window("D'arce", id: "main") {
            BrowserWindow(model: model)
                .background(BrowserWindowRegistration(model: model))
                .frame(minWidth: 800, minHeight: 540)
                .task {
                    if let windowLifecycleOutput {
                        await runWindowLifecycleSmoke(primary: model, output: windowLifecycleOutput)
                    } else if let smokeOutput, let fixtureBase {
                        await runNetworkSmoke(model: model, base: fixtureBase, phase: networkPhase, output: smokeOutput)
                    } else if let smokeOutput { await runSmoke(model: model, output: smokeOutput) }
                    else {
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
    @State private var name = ""
    /// Horizontal travel of the Space's sidebar content; drives the slide and the theme cross-fade.
    @State private var spaceSlide: CGFloat = 0
    /// The other Space's theme, drawn over the current one at `slideProgress` opacity.
    @State private var overlaySpace: UUID?
    @State private var swipeSwitching = false
    @State private var transitionID = 0
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

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                if model.sidebarVisible {
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
                    if !model.sidebarVisible {
                        HStack {
                            Button { model.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                            Button { model.commandMode = .location } label: { Text(model.state.selectedTab?.url.host ?? "Search or Enter URL…") }
                            Spacer()
                        }.buttonStyle(.plain).padding(.leading, 78).padding(.trailing, 12).frame(height: 38)
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
                .padding(.top, model.sidebarVisible ? 8 : 0)
                .padding(.trailing, 8).padding(.bottom, 8)
                .padding(.leading, model.sidebarVisible ? 0 : 8)
            }
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
            if model.commandMode != nil { BrowserCommandBar(model: model).id(model.commandMode == .location ? "location" : "new-tab") }
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
        .sheet(isPresented: $showArchive) { archiveSheet }
        .sheet(item: $model.panel) { panel in
            switch panel {
            case .browsingData:
                BrowsingDataView(controller: model.browsingData, profileID: model.state.selectedProfileID,
                                 profileName: model.state.profiles.first(where: { $0.id == model.state.selectedProfileID })?.name ?? "Profile")
            case .documents:
                let profileID = model.state.selectedProfileID
                DocumentsView(controller: model.documents, profileID: profileID,
                              captureCurrentPage: { await model.captureCurrentPage(profileID: profileID) })
            case .settings: SettingsView(controller: model.settings, profiles: model.state.profiles)
            case .profiles: ProfilesView(model: model)
            case .history: HistoryView(model: model)
            case .downloads: DownloadsView(manager: model.downloads, profileID: model.state.selectedProfileID, resume: model.resumeDownload)
            case .appearance:
                AppearanceView(controller: appearance, spaceID: model.state.selectedSpaceID,
                               spaceName: model.state.spaces.first { $0.id == model.state.selectedSpaceID }?.name ?? "Space")
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
        .alert("New Space", isPresented: $showNewSpace) {
            TextField("Name", text: $name)
            Button("Create") { model.addSpace(name); name = "" }
            Button("Cancel", role: .cancel) { name = "" }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $name)
            Button("Create") { model.addFolder(name); name = "" }
            Button("Cancel", role: .cancel) { name = "" }
        }
    }

    @ViewBuilder private var content: some View {
        if let id = model.state.selectedTabID, let page = model.page(for: id) {
            BrowserPane(page: page).id(id).clipShape(RoundedRectangle(cornerRadius: 10))
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

    private var archiveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Archive").font(.title2.bold()); Spacer(); Button("Done") { showArchive = false } }
            let archived = model.archivedTabs
            if archived.isEmpty { Text("Archived tabs will appear here.").foregroundStyle(.secondary) }
            List(archived) { tab in
                HStack {
                    VStack(alignment: .leading) { Text(tab.title); Text(tab.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button("Restore") { model.restore(tab.id); showArchive = false }
                }
            }
        }.padding(24).frame(width: 560, height: 360)
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
    func makeNSView(context: Context) -> WKWebView { page.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

