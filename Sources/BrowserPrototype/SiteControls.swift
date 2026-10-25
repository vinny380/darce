import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar address bar, like Arc's: the site, a copy-link button, and the site controls button.
struct AddressBar: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    private var url: URL? { model.state.selectedTab.flatMap { model.page(for: $0.id)?.webView.url ?? $0.url } }

    var body: some View {
        if url?.easelID != nil {
            // An Easel has no web address, like Arc's: its name in place of the URL.
            HStack(spacing: 8) {
                Image(systemName: "scribble.variable").font(.system(size: 11))
                Text(model.state.selectedTab?.title ?? "Easel").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .foregroundStyle(.primary.opacity(0.65))
            .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            addressBar
        }
    }

    private var addressBar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 8) {
                if url == nil { Image(systemName: "magnifyingglass").font(.system(size: 10)) }
                Text((model.settings.state.showFullURL ? url?.absoluteString : url?.host.map(Self.trimmed)) ?? "Search or Enter URL…")
                    .font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle())
            .onTapGesture { model.commandMode = .location }
            .accessibilityAddTraits(.isButton).accessibilityLabel("Address and search")
            .accessibilityAction { model.commandMode = .location }
            if url != nil {
                SidebarIconButton(symbol: copied ? "checkmark" : "link", help: "Copy Link (⇧⌘C)") {
                    guard let url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                SidebarIconButton(symbol: "slider.horizontal.3", help: "Site Controls", filled: model.siteControlsVisible) { model.siteControlsVisible.toggle() }
                    .popover(isPresented: $model.siteControlsVisible, arrowEdge: .bottom) { SiteControls(model: model, close: { model.siteControlsVisible = false }) }
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).frame(height: 36)
        .foregroundStyle(.primary.opacity(0.65))
        .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(ExtensionAnchor(model: model))
    }

    static func trimmed(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
}

private struct SidebarIconButton: View {
    let symbol: String
    let help: String
    var filled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                .background(filled || hovered ? Palette.color("SidebarItemHovered", scheme: scheme) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.help(help)
    }
}

/// Where extension popups open: beside the address bar of the window they belong to.
private struct ExtensionAnchor: NSViewRepresentable {
    let model: BrowserModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if #available(macOS 15.4, *) { ExtensionManager.shared?.setAnchor(view, for: model) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Arc's site controls: quick actions, extensions, page settings, and whether the connection is secure.
struct SiteControls: View {
    @ObservedObject var model: BrowserModel
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var installing = false
    @State private var captured = false

    private var page: BrowserPage? { model.state.selectedTabID.flatMap { model.page(for: $0) } }
    private var url: URL? { page?.webView.url ?? model.state.selectedTab?.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let url { ShareLink(item: url) { tile("square.and.arrow.up") }.buttonStyle(.plain).help("Share") }
                Button { close(); model.boostPanelOpen = true } label: { tile("wand.and.sparkles") }.buttonStyle(.plain).help("Boost this site")
                Button { capture() } label: { tile(captured ? "checkmark" : "camera") }.buttonStyle(.plain).help("Capture page to clipboard")
                Button { close(); model.showFind = true } label: { tile("text.magnifyingglass") }.buttonStyle(.plain).help("Find on page (⌘F)")
            }
            if #available(macOS 15.4, *), let manager = ExtensionManager.shared {
                ExtensionsSection(model: model, manager: manager, url: url, close: close, installing: $installing)
            } else {
                Text("Extensions need macOS 15.4 or later.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Settings").font(.system(size: 13, weight: .semibold))
            if let host = url?.host {
                PermissionRow(settings: model.settings, device: .camera, host: host)
                PermissionRow(settings: model.settings, device: .microphone, host: host)
            }
            if url?.host != nil { DeveloperModeRow(model: model, settings: model.settings) }
            if let page { ZoomRow(page: page) }
            Divider()
            HStack {
                let secure = url?.scheme == "https"
                Label(secure ? "Secure" : "Not Secure", systemImage: secure ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 28)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(secure ? Color.primary : Color.orange)
                Spacer()
                Menu {
                    Button("Copy Link") { copy(url?.absoluteString) }
                    Button("Copy Link as Markdown") { copy(url.map { "[\(page?.webView.title ?? $0.host ?? "")](\($0.absoluteString))" }) }
                    Divider()
                    Button("Clear Browsing Data…") { close(); model.panel = .browsingData }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(14).frame(width: 300)
        .sheet(isPresented: $installing) {
            if #available(macOS 15.4, *), let manager = ExtensionManager.shared { InstallExtensionSheet(manager: manager, model: model) }
        }
    }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func capture() {
        Task {
            guard let data = await model.captureCurrentPage(profileID: model.state.selectedProfileID), let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            captured = true
        }
    }
}

/// Arc-style settings row: what the site may use, and the current answer. Click to change it.
private struct PermissionRow: View {
    @ObservedObject var settings: SettingsController
    let device: SiteDevice
    let host: String

    private var decision: SiteDecision { settings.state.permission(for: device, host: host) }

    var body: some View {
        Menu {
            Picker(device == .camera ? "Camera" : "Microphone", selection: Binding(
                get: { decision }, set: { value in settings.update { $0.setPermission(value, for: device, host: host) } })) {
                Text("Ask").tag(SiteDecision.ask)
                Text("Allow").tag(SiteDecision.allow)
                Text("Block").tag(SiteDecision.block)
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device == .camera ? "video.fill" : "mic.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30).background(.primary.opacity(decision == .block ? 0.04 : 0.08), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(device == .camera ? "Camera" : "Microphone").font(.system(size: 13, weight: .semibold))
                    Text(decision == .ask ? "Ask" : decision == .allow ? "Allowed" : "Blocked").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

/// Arc's "Developer Mode" site setting (hammer): on shows the developer bar for this site.
private struct DeveloperModeRow: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: SettingsController

    var body: some View {
        Button { model.toggleDeveloperMode() } label: {
            HStack(spacing: 10) {
                Image(systemName: "hammer.fill").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                    .background(.primary.opacity(model.isDeveloperModeOn ? 0.16 : 0.08), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Developer Mode").font(.system(size: 13, weight: .semibold))
                    Text(model.isDeveloperModeOn ? "On" : "Off").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("Turn \(model.isDeveloperModeOn ? "off" : "on") Developer Mode for this site (⌃D)")
    }
}

private struct ZoomRow: View {
    @ObservedObject var page: BrowserPage
    @State private var zoom: Double = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                .background(.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Zoom").font(.system(size: 13, weight: .semibold))
                Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            ControlGroup {
                Button { set(zoom - 0.1) } label: { Image(systemName: "minus") }
                Button { set(zoom + 0.1) } label: { Image(systemName: "plus") }
            }.fixedSize()
        }
        .onAppear { zoom = page.webView.pageZoom }
    }

    private func set(_ value: Double) {
        zoom = min(3, max(0.25, (value * 10).rounded() / 10))
        page.webView.pageZoom = zoom
    }
}

@available(macOS 15.4, *)
private struct ExtensionsSection: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var manager: ExtensionManager
    let url: URL?
    let close: () -> Void
    @Binding var installing: Bool

    /// On a Chrome Web Store extension page, offer to add it directly.
    private var storeExtensionID: String? {
        guard let url, let host = url.host, host.contains("chromewebstore.google.com") || host == "chrome.google.com" else { return nil }
        return CRXFile.extensionID(from: url.absoluteString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = storeExtensionID, !manager.installed.contains(where: { $0.id == id }) {
                Button {
                    close()
                    Task { await manager.install(fromStoreLink: id) }
                } label: {
                    Label("Add to D'arce", systemImage: "plus.circle.fill").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
            Text("Extensions").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(manager.installed) { item in
                    Button {
                        close()
                        manager.performAction(item, in: model)
                    } label: {
                        Group {
                            if let icon = item.icon(for: model.state.selectedTabID.flatMap { model.loadedPage($0) }) {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                            } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain).help(item.name)
                    .contextMenu {
                        if let options = item.context.optionsPageURL { Button("Options") { close(); model.open(options) } }
                        Button("Remove “\(item.name)”", role: .destructive) { manager.uninstall(item) }
                    }
                }
                Button { installing = true } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plain).help("Add Extension")
            }
            if let error = manager.lastError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

@available(macOS 15.4, *)
private struct InstallExtensionSheet: View {
    @ObservedObject var manager: ExtensionManager
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Extension").font(.title3.bold())
            Text("Most Chrome extensions work. Paste a Chrome Web Store link, or add an unpacked extension folder.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://chromewebstore.google.com/detail/…", text: $link).textFieldStyle(.roundedBorder).onSubmit(add)
            if let error = manager.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Browse the Chrome Web Store") {
                    model.open(URL(string: "https://chromewebstore.google.com")!)
                    dismiss()
                }
                Button("Choose Folder…") { chooseFolder() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Adding…" : "Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(working || CRXFile.extensionID(from: link) == nil)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func add() {
        guard CRXFile.extensionID(from: link) != nil else { return }
        working = true
        manager.lastError = nil
        Task {
            await manager.install(fromStoreLink: link)
            working = false
            if manager.lastError == nil { dismiss() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose an unpacked extension folder (it contains manifest.json)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            await manager.install(fromFolder: folder)
            if manager.lastError == nil { dismiss() }
        }
    }
}
