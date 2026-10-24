import BrowserCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsController: ObservableObject {
    @Published private(set) var state = BrowserSettings()
    @Published private(set) var errorMessage: String?
    private(set) var recoveryRequired = false
    private var store: BrowserSettingsStore?

    init(directory: URL) {
        do {
            let loaded = try BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            store = loaded
            state = loaded.state
        } catch {
            recoveryRequired = true
            errorMessage = "Settings could not be loaded. Saving is disabled to preserve the original file. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func update(_ change: (inout BrowserSettings) -> Void) -> Bool {
        guard !recoveryRequired, var candidate = store else { return false }
        do {
            try candidate.update(change)
            store = candidate
            state = candidate.state
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: SettingsController
    let profiles: [BrowserProfile]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Form {
                Section("Search") {
                    Picker("Default Search Engine", selection: Binding(
                        get: { controller.state.searchEngine },
                        set: { engine in controller.update { $0.searchEngine = engine } }
                    )) {
                        ForEach(SearchEngine.allCases, id: \.self) { engine in Text(engine.name).tag(engine) }
                    }
                }
                Section("Tabs") {
                    Picker("Archive Inactive Tabs", selection: Binding(
                        get: { controller.state.autoArchiveAge },
                        set: { age in controller.update { $0.autoArchiveAge = age } }
                    )) {
                        ForEach(AutoArchiveAge.allCases, id: \.self) { age in Text(age.name).tag(age) }
                    }
                    Text("Pinned tabs and Favorites stay in your sidebar. Archived tabs can be restored from the Archive.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Open links to other websites in Peek from pinned tabs", isOn: Binding(
                        get: { controller.state.pinnedExternalLinksOpenPeek },
                        set: { enabled in controller.update { $0.pinnedExternalLinksOpenPeek = enabled } }
                    ))
                }
                ProfileArchiveSettings(controller: controller, profiles: profiles)
                Section("Websites") {
                    HStack {
                        Slider(value: Binding(
                            get: { controller.state.defaultZoom },
                            set: { zoom in controller.update { $0.defaultZoom = zoom } }
                        ), in: 0.25...3, step: 0.05) { Text("Default Zoom") }
                        Text("\(Int((controller.state.defaultZoom * 100).rounded()))%")
                            .monospacedDigit().frame(width: 45, alignment: .trailing)
                    }
                    Text("Applied when opening a new page.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(controller.recoveryRequired)
        }
        .padding(20)
        .frame(width: 520, height: 490)
    }
}

struct ProfileArchiveSettings: View {
    @ObservedObject var controller: SettingsController
    let profiles: [BrowserProfile]

    var body: some View {
        Section("Archive by Profile") {
            ForEach(profiles) { profile in
                Picker(profile.name, selection: Binding<AutoArchiveAge?>(
                    get: { controller.state.autoArchiveAgeByProfile?[profile.id] },
                    set: { age in controller.update { $0.setAutoArchiveAge(age, forProfile: profile.id) } }
                )) {
                    Text("Use Global Setting").tag(Optional<AutoArchiveAge>.none)
                    ForEach(AutoArchiveAge.allCases, id: \.self) { age in Text(age.name).tag(Optional(age)) }
                }
            }
        }
    }
}
