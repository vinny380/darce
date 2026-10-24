import AppKit
import BrowserCore
import SwiftUI

/// The Settings window (⌘,), laid out like Arc's: General, Profiles, Links, Shortcuts, Advanced.
struct SettingsWindow: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        TabView {
            GeneralSettings(settings: model.settings).tabItem { Label("General", systemImage: "gearshape") }
            ProfileSettings(model: model, settings: model.settings).tabItem { Label("Profiles", systemImage: "person") }
            LinkSettings(settings: model.settings).tabItem { Label("Links", systemImage: "macwindow.on.rectangle") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AdvancedSettings(model: model, settings: model.settings).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 640)
    }
}

/// Binds a toggle or picker straight to one setting.
private extension SettingsController {
    func binding<Value>(_ keyPath: WritableKeyPath<BrowserSettings, Value>) -> Binding<Value> {
        Binding(get: { self.state[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: SettingsController
    @State private var isDefault = GeneralSettings.isDefaultBrowser()

    var body: some View {
        Form {
            Section {
                LabeledContent("Default browser") {
                    if isDefault { Label("D'arce is your default browser", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    else { Button("Make Default") { makeDefault() } }
                }
            } footer: {
                Text("Links you click in other apps open in D'arce.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Search engine", selection: settings.binding(\.searchEngine)) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                LabeledContent("Default zoom") {
                    HStack {
                        // Snaps to 5% in code: a stepped Slider would draw 55 tick marks.
                        Slider(value: Binding(get: { settings.state.defaultZoom },
                                              set: { zoom in settings.update { $0.defaultZoom = (zoom * 20).rounded() / 20 } }),
                               in: 0.25...3).frame(width: 180)
                        Text("\(Int((settings.state.defaultZoom * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            if let error = settings.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped).disabled(settings.recoveryRequired).frame(height: 300)
    }

    private static func isDefaultBrowser() -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        // macOS asks the user to confirm; check again once it answers.
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in
            DispatchQueue.main.async { isDefault = GeneralSettings.isDefaultBrowser() }
        }
    }
}

private struct ProfileSettings: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: SettingsController
    @State private var selection: UUID?
    @State private var naming: Naming?
    @State private var name = ""
    @State private var clearingData = false
    private enum Naming: Equatable { case new, rename(UUID) }

    private var selected: BrowserProfile? {
        model.state.profiles.first { $0.id == (selection ?? model.state.selectedProfileID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profiles keep your data separate across Spaces: history, sign-ins and cookies. Any profile can be used by one or more Spaces.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                profileList
                if let profile = selected { profileDetail(profile) }
            }
        }
        .padding(20).frame(height: 470)
        .alert(naming == .new ? "New Profile" : "Rename Profile", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .sheet(isPresented: $clearingData) {
            if let profile = selected { BrowsingDataView(controller: model.browsingData, profileID: profile.id, profileName: profile.name) }
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selection ?? model.state.selectedProfileID }, set: { selection = $0 })) {
                Section("Your Profiles") {
                    ForEach(model.state.profiles) { profile in
                        let spaces = model.state.spaces.filter { $0.profileID == profile.id }.count
                        HStack {
                            Text(profile.name)
                            Spacer()
                            Text(spaces == 1 ? "1 Space" : "\(spaces) Spaces").foregroundStyle(.secondary).font(.callout)
                        }.tag(profile.id)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button { name = ""; naming = .new } label: { Image(systemName: "plus") }.help("New Profile")
                Button { if let profile = selected { name = profile.name; naming = .rename(profile.id) } } label: { Image(systemName: "pencil") }
                    .help("Rename Profile").disabled(selected == nil)
                Spacer()
            }.buttonStyle(.borderless).padding(8)
        }
        .frame(width: 220).background(.background.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func profileDetail(_ profile: BrowserProfile) -> some View {
        Form {
            Section {
                Picker("Search engine", selection: Binding(
                    get: { settings.state.searchEngine(forProfile: profile.id) },
                    set: { engine in settings.update { $0.setSearchEngine(engine, forProfile: profile.id) } })) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Picker("Archive tabs after", selection: Binding<AutoArchiveAge?>(
                    get: { settings.state.autoArchiveAgeByProfile?[profile.id] },
                    set: { age in settings.update { $0.setAutoArchiveAge(age, forProfile: profile.id) } })) {
                    Text("\(settings.state.autoArchiveAge.name) (default)").tag(Optional<AutoArchiveAge>.none)
                    ForEach(AutoArchiveAge.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
            }
            Section("Your Data and Settings") {
                dataRow("Passwords", icon: "key.fill", color: .green) { openPasswords() }
                dataRow("Clear Browsing Data", icon: "trash.fill", color: .red) { clearingData = true }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private func dataRow(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(color, in: RoundedRectangle(cornerRadius: 6))
                Text(title)
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// WebKit browsers use the system's saved passwords, managed in the Passwords app.
    private func openPasswords() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { naming = nil }
        guard !trimmed.isEmpty else { return }
        switch naming {
        case .new: model.addProfile(trimmed)
        case .rename(let id): model.stateUpdate { $0.renameProfile(id, name: trimmed) }
        case nil: break
        }
    }
}

private struct LinkSettings: View {
    @ObservedObject var settings: SettingsController

    var body: some View {
        Form {
            Section {
                Toggle("Open a mini window when I press ⌥⌘N in any app", isOn: settings.binding(\.globalMiniWindowShortcut))
                Toggle("Open a mini window when clicking links with ⌥⌘ held", isOn: settings.binding(\.optionCommandClickOpensMiniWindow))
                Toggle("Links from other apps open in a mini window", isOn: settings.binding(\.externalLinksOpenInMiniWindow))
            } header: {
                Text("A mini window is a smaller, simpler window, perfect for quick lookups and the links friends send you.")
                    .font(.body).foregroundStyle(.secondary).textCase(nil)
            }
            Section {
                Toggle("Open a Peek when clicking links with Shift held", isOn: settings.binding(\.shiftClickOpensPeek))
                Toggle(isOn: settings.binding(\.pinnedExternalLinksOpenPeek)) {
                    Text("Open a Peek when clicking links to other sites")
                    Text("Only affects Favorites and pinned tabs")
                }
            } header: {
                Text("Peek previews a link without opening a new tab, perfect for a quick look at a link in an email, article or post.")
                    .font(.body).foregroundStyle(.secondary).textCase(nil)
            }
        }
        .formStyle(.grouped).disabled(settings.recoveryRequired).frame(height: 420)
    }
}

/// Every built-in shortcut, searchable by name or keys.
private struct ShortcutSettings: View {
    @State private var query = ""

    static let shortcuts: [(name: String, keys: String)] = [
        ("Add Split View", "⌃⇧="), ("Archive Tab", "⌘W"), ("Back", "⌘["), ("Clear Today Tabs", "⇧⌘K"),
        ("Close Split View Pane", "⌃⇧-"), ("Close Window", "⇧⌘W"), ("Copy URL", "⇧⌘C"), ("Copy URL as Markdown", "⌥⇧⌘C"),
        ("Cycle Tab Backward", "⌃⌘←"), ("Cycle Tab Forward", "⌃⌘→"), ("Downloads", "⇧⌘J"), ("Find in Page", "⌘F"),
        ("Forward", "⌘]"), ("Go to Last Tab", "⌘9"), ("Go to Tab 1–8", "⌘1 … ⌘8"), ("History", "⌘Y"),
        ("New Mini Window", "⌥⌘N"), ("New Private Window", "⇧⌘N"), ("New Tab", "⌘T"), ("New Window", "⌘N"),
        ("Next Space", "⌥⌘→"), ("Next Tab", "⌥⌘↓"), ("Open in D'arce (mini window)", "⌘O"), ("Open Location", "⌘L"),
        ("Pin / Unpin Tab", "⌘D"), ("Previous Space", "⌥⌘←"), ("Previous Tab", "⌥⌘↑"), ("Print", "⌘P"),
        ("Reload", "⌘R"), ("Reload from Origin", "⇧⌘R"), ("Reopen Last Archived Tab", "⇧⌘T"), ("Settings", "⌘,"),
        ("Stop Loading", "⌘."), ("Switch to Recent Tab", "⌃Tab"), ("Switch to Space 1–9", "⌃1 … ⌃9"),
        ("Toggle Sidebar", "⌘S"), ("Undo Close Tab", "⌘Z"), ("Zoom In", "⌘+"), ("Zoom Out", "⌘-"), ("Actual Size", "⌘0"),
    ]

    private var filtered: [(name: String, keys: String)] {
        let all = Self.shortcuts.sorted { $0.name < $1.name }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.keys.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a feature name or shortcut (like “Split” or “⌘T”)", text: $query).textFieldStyle(.plain)
            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).padding([.horizontal, .top], 20)
            List(filtered, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.keys).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }.padding(.vertical, 3)
            }
            .scrollContentBackground(.hidden).padding(.horizontal, 8)
        }
        .frame(height: 470)
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var settings: SettingsController

    var body: some View {
        Form {
            Section {
                row("Haptic feedback when reordering tabs", icon: "hand.tap.fill", color: .blue, \.hapticFeedback)
            }
            Section {
                row("Show full URL in the sidebar", icon: "link", color: .red, \.showFullURL)
            }
            Section {
                row("Enable Boosts on websites you visit", icon: "paintbrush.pointed.fill", color: .purple, \.boostsEnabled)
            }
            HStack {
                Button("Export Bookmarks…") { model.exportBookmarks() }
                Button("Import Bookmarks…") { model.importBookmarks() }
                Spacer()
            }
        }
        .formStyle(.grouped).disabled(settings.recoveryRequired).frame(height: 330)
    }

    private func row(_ title: String, icon: String, color: Color, _ keyPath: WritableKeyPath<BrowserSettings, Bool>) -> some View {
        Toggle(isOn: settings.binding(keyPath)) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(color, in: RoundedRectangle(cornerRadius: 6))
                Text(title)
            }
        }
    }
}
