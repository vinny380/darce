import AppKit
import BrowserCore
import SwiftUI

/// What an import brought over, for the result screen and `--import-from`'s `import-result.json`.
struct ImportReport: Codable, Equatable {
    var counts: [String: Int]
    var skipped: [String]
}

extension ImportBrowser {
    /// The installed app, for its icon.
    var bundleIdentifier: String {
        switch self {
        case .arc: "company.thebrowser.Browser"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        }
    }

    var appIcon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

extension BrowserModel {
    /// Commits an import: the sidebar first, then each new Space's icon and color, collapsed folders, and history.
    /// Lands on the first imported Space.
    @discardableResult
    func applyBrowserImport(_ profiles: [ImportedProfile], from browser: ImportBrowser, into destination: ImportDestination,
                            options: ImportOptions) -> ImportOutcome {
        var applied = ImportOutcome()
        guard stateUpdate({ applied = $0.applyImport(profiles, from: browser, into: destination, options: options) }) else {
            var failed = ImportOutcome()
            failed.skipped = ["Nothing could be saved. D'arce can't write its session right now; recover it, then import again."]
            return failed
        }
        var outcome = applied
        let folderSpaces = Dictionary(uniqueKeysWithValues: state.folders.map { ($0.id, $0.spaceID) })
        _ = appearance.update { preferences in
            for (space, style) in outcome.spaceStyles {
                var looks = preferences.space(space)
                if let icon = style.icon, AppearancePreferences.isEmojiIcon(icon) || NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    looks.icon = icon
                }
                if let tint = style.tint { looks.tint = tint }
                preferences.spaces[space] = looks
            }
            for folder in outcome.collapsedFolderIDs {
                guard let space = folderSpaces[folder] else { continue }
                var looks = preferences.space(space)
                looks.collapsedFolderIDs.insert(folder)
                preferences.spaces[space] = looks
            }
        }
        var added = 0
        do { try workspace.updateHistory { store in for batch in outcome.history { added += try store.merge(batch.visits, profileID: batch.profileID) } } }
        catch { outcome.skipped.append("History: \(error.localizedDescription)") }
        outcome.counts["history"] = added
        if let first = outcome.firstSpaceID, outcome.counts.values.contains(where: { $0 > 0 }) { selectSpace(first) }
        return outcome
    }

    /// `--import-from <browser>`: imports everything into new profiles without asking, for end-to-end checks.
    func importWithoutAsking(from browser: ImportBrowser) async -> ImportReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            let profiles = try await Task.detached { try ImportSources.read(browser, home: home) }.value
            let outcome = applyBrowserImport(profiles, from: browser, into: .newProfiles, options: ImportOptions())
            return ImportReport(counts: outcome.counts, skipped: outcome.skipped)
        } catch {
            return ImportReport(counts: [:], skipped: ["\(browser.displayName) could not be read: \(error.localizedDescription)"])
        }
    }
}

/// Import from Another Browser, and the first-launch welcome.
struct ImportSheet: View {
    @ObservedObject var model: BrowserModel
    var welcome = false

    private enum Step { case pick, reading(ImportBrowser), choose(ImportBrowser, [ImportedProfile]), importing, done(ImportOutcome), failed(String) }
    @State private var step = Step.pick
    @State private var installed: [ImportBrowser] = []
    @State private var chosen: Set<String> = []
    @State private var options = ImportOptions()
    @State private var intoNewProfiles = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(welcome ? "Bring your stuff from your old browser" : "Import from your old browser").font(.title2.weight(.semibold))
                Text("Your Spaces, pinned tabs, Favorites, bookmarks and history, so you can pick up where you left off.")
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(24).frame(width: 460)
        .onAppear { installed = ImportSources.installed(home: FileManager.default.homeDirectoryForCurrentUser) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .pick:
            if installed.isEmpty {
                Text("No other browsers were found on this Mac.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(installed, id: \.self) { browser in
                        Button { read(browser) } label: {
                            HStack(spacing: 10) {
                                if let icon = browser.appIcon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                                else { Image(systemName: "globe").frame(width: 28, height: 28) }
                                Text(browser.displayName).font(.body.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Spacer()
                Button(welcome ? "Start Fresh" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        case .reading(let browser):
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking at \(browser.displayName)…") }
        case .choose(let browser, let profiles):
            chooser(browser, profiles)
        case .importing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Bringing everything over…") }
        case .done(let outcome):
            result(outcome)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func chooser(_ browser: ImportBrowser, _ profiles: [ImportedProfile]) -> some View {
        let selected = profiles.filter { chosen.contains($0.key) }
        let tabs = selected.reduce(0) { $0 + $1.spaces.reduce(0) { $0 + count($1.pinned) + count($1.today) } + count($1.favorites) }
        let spaces = selected.reduce(0) { $0 + $1.spaces.count }
        let bookmarks = selected.reduce(0) { $0 + count($1.bookmarks) }
        let history = selected.reduce(0) { $0 + $1.history.count }
        return VStack(alignment: .leading, spacing: 14) {
            if profiles.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profiles").font(.headline)
                    ForEach(profiles, id: \.key) { profile in
                        Toggle(isOn: Binding(get: { chosen.contains(profile.key) },
                                             set: { if $0 { chosen.insert(profile.key) } else { chosen.remove(profile.key) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                if !profile.spaces.isEmpty {
                                    Text(profile.spaces.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Picker("Import into", selection: $intoNewProfiles) {
                Text(profiles.count > 1 ? "A new profile for each" : "A new profile").tag(true)
                Text("My current profile").tag(false)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What to bring").font(.headline)
                if browser == .arc { Toggle("Spaces & tabs (\(spaces) Spaces, \(tabs) tabs)", isOn: $options.spacesAndTabs) }
                if bookmarks > 0 || browser != .arc { Toggle("Bookmarks (\(bookmarks))", isOn: $options.bookmarks) }
                Toggle("History (\(history) sites)", isOn: $options.history)
            }
            HStack {
                Button("Back") { step = .pick }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { commit(browser, selected) }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }
    }

    private func result(_ outcome: ImportOutcome) -> some View {
        let lines: [(String, String)] = [("spaces", "Spaces"), ("tabs", "Tabs"), ("favorites", "Favorites"), ("folders", "Folders"),
                                         ("bookmarks", "Bookmarks"), ("history", "History")]
        return VStack(alignment: .leading, spacing: 12) {
            let nothing = outcome.counts.values.allSatisfy { $0 == 0 }
            Text(outcome.skipped.isEmpty ? "Success! Everything came over" : nothing ? "Nothing came over" : "Most of your stuff came over")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(lines.filter { (outcome.counts[$0.0] ?? 0) > 0 }, id: \.0) { key, name in
                    GridRow { Text(name).foregroundStyle(.secondary); Text("\(outcome.counts[key] ?? 0)").monospacedDigit() }
                }
            }
            if nothing && outcome.skipped.isEmpty { Text("Everything here was already in D'arce.").foregroundStyle(.secondary) }
            if !outcome.skipped.isEmpty {
                DisclosureGroup("Didn't come over (\(outcome.skipped.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(outcome.skipped.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }

    private func read(_ browser: ImportBrowser) {
        step = .reading(browser)
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task {
            do {
                let profiles = try await Task.detached { try ImportSources.read(browser, home: home) }.value
                guard !profiles.isEmpty else { step = .failed("\(browser.displayName) has nothing D'arce can import yet."); return }
                chosen = Set(profiles.map(\.key))
                options = ImportOptions()
                intoNewProfiles = model.state.isFresh || profiles.count > 1
                step = .choose(browser, profiles)
            } catch {
                step = .failed("\(browser.displayName) couldn't be read: \(error.localizedDescription)")
            }
        }
    }

    private func commit(_ browser: ImportBrowser, _ profiles: [ImportedProfile]) {
        step = .importing
        let destination: ImportDestination = intoNewProfiles ? .newProfiles : .existing(model.state.selectedProfileID)
        Task { @MainActor in
            await Task.yield()   // let the progress row draw before the main-actor commit
            step = .done(model.applyBrowserImport(profiles, from: browser, into: destination, options: options))
        }
    }

    private func count(_ items: [ImportedItem]) -> Int {
        items.reduce(0) { total, item in
            switch item {
            case .tab: total + 1
            case .folder(_, _, let children), .split(_, let children, _): total + count(children)
            }
        }
    }
}
