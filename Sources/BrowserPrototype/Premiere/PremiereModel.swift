import AppKit
import BrowserCore
import Foundation
import SwiftUI

extension ImportBrowser {
    /// The name people say: "Chrome", not "Google Chrome".
    var shortName: String {
        switch self {
        case .chrome: "Chrome"
        case .edge: "Edge"
        default: displayName
        }
    }
}

/// The first-launch welcome: which step is showing, what was found to import, how each part of the import is
/// going, the colors picked, and the music.
@MainActor
final class PremiereModel: ObservableObject {
    enum Row: Hashable, CaseIterable { case spaces, favorites, bookmarks, history, cookies, extensions }
    enum RowState: Equatable { case idle, working, done, failed }
    enum DefaultState: Equatable { case idle, asking, done, declined }

    @Published private(set) var flow: OnboardingFlow
    /// +1 going forward, −1 going back (steps slide in from that side).
    @Published private(set) var direction = 1
    @Published private(set) var installed: [ImportBrowser]
    @Published private(set) var browser: ImportBrowser?
    @Published private(set) var profiles: [ImportedProfile]?
    @Published var options = ImportOptions()
    @Published private(set) var rows: [Row: RowState] = [:]
    @Published private(set) var importing = false
    @Published private(set) var imported = false
    @Published private(set) var outcome: ImportOutcome?
    @Published var tint: AppearanceColor
    @Published var mode: BrowserAppearance { didSet { modePicked = true } }
    /// Only what the person actually chose is written (a replayed welcome mustn't recolor a Space).
    private var tintPicked = false, modePicked = false
    @Published private(set) var readError: String?
    @Published private(set) var defaultState = DefaultState.idle
    @Published private(set) var muted: Bool
    @Published var finishing = false
    @Published private(set) var startedFresh = false

    let browserModel: BrowserModel
    private let music: PremiereMusic?
    var onFinish: (() -> Void)?

    static let defaultTint = AppearanceColor(red: 0.48, green: 0.35, blue: 0.66)
    static let curatedTints: [AppearanceColor] = [
        AppearanceColor(red: 0.25, green: 0.56, blue: 0.48), AppearanceColor(red: 0.77, green: 0.42, blue: 0.29),
        AppearanceColor(red: 0.29, green: 0.47, blue: 0.77), AppearanceColor(red: 0.73, green: 0.63, blue: 0.29),
        AppearanceColor(red: 0.54, green: 0.56, blue: 0.62),
    ]
    /// What VoiceOver says for each curated swatch.
    static let curatedNames = ["Green", "Ember", "Blue", "Gold", "Graphite"]

    init(browserModel: BrowserModel, installed: [ImportBrowser], isDefaultBrowser: Bool, resumeAt: OnboardingStep? = nil,
         prefetched: [ImportedProfile]? = nil, music: Bool = true) {
        self.browserModel = browserModel
        // Arc first: it's the browser people are leaving.
        let ordered = installed.sorted { ($0 == .arc ? 0 : 1, $0.rawValue) < ($1 == .arc ? 0 : 1, $1.rawValue) }
        self.installed = ordered
        browser = ordered.first
        profiles = prefetched
        flow = OnboardingFlow(hasBrowserToImport: !installed.isEmpty, isDefaultBrowser: isDefaultBrowser, resumeAt: resumeAt)
        tint = Self.defaultTint
        mode = browserModel.appearance.state.appearance
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let quiet = browserModel.settings.state.premiereMuted || reduceMotion || !music
        muted = quiet
        self.music = music ? PremiereMusic(muted: quiet) : nil
        if let first = arcTints.first { tint = first }
    }

    // MARK: Words that depend on what was found

    /// The browser was found but had nothing D'arce can bring over (or couldn't be read).
    var nothingToImport: Bool { profiles != nil && availableRows.isEmpty }

    var bringTitle: String { "Bring your \(browser?.shortName ?? "browser")." }
    var arcTints: [AppearanceColor] {
        guard browser == .arc else { return [] }
        return (profiles ?? []).flatMap { $0.spaces.compactMap(\.tint) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var themeSubtitle: String {
        "Each Space has its own."
    }
    var welcomeSubtitle: String {
        let spaces: Bool
        if startedFresh { spaces = false }
        else if let outcome { spaces = outcome.counts["spaces", default: 0] > 0 }
        else { spaces = browser == .arc && (profiles ?? []).contains { !$0.spaces.isEmpty } }
        return spaces ? "Everything’s where you left it. ⌘T opens anything." : "⌘T opens anything."
    }

    // MARK: What the import would bring

    private func count(_ items: [ImportedItem]) -> Int {
        items.reduce(0) { total, item in
            switch item {
            case .tab: total + 1
            case .folder(_, _, let children), .split(_, let children, _): total + count(children)
            }
        }
    }

    var availableRows: [Row] {
        let all = profiles ?? []
        var rows: [Row] = []
        if all.contains(where: { !$0.spaces.isEmpty }) { rows.append(.spaces) }
        if all.contains(where: { !$0.favorites.isEmpty }) { rows.append(.favorites) }
        if all.contains(where: { !$0.bookmarks.isEmpty }) { rows.append(.bookmarks) }
        if all.contains(where: { !$0.history.isEmpty }) { rows.append(.history) }
        if all.contains(where: { $0.cookieCount > 0 }) { rows.append(.cookies) }
        if !extensions.isEmpty { rows.append(.extensions) }
        return rows
    }

    var extensions: [ImportedExtension] {
        var seen: Set<String> = []
        return (profiles ?? []).flatMap(\.extensions).filter { seen.insert($0.id).inserted }
    }

    func title(_ row: Row) -> String {
        switch row {
        case .spaces: "Spaces & pinned tabs"
        case .favorites: browser == .arc ? "Favorites" : "Favorites (your most-visited sites)"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .cookies: "Stay signed in"
        case .extensions: "Extensions"
        }
    }

    func detail(_ row: Row) -> String {
        let all = profiles ?? []
        let number = { (value: Int) in value.formatted(.number) }
        switch row {
        case .spaces:
            let spaces = all.reduce(0) { $0 + $1.spaces.count }
            let tabs = all.reduce(0) { $0 + $1.spaces.reduce(0) { $0 + count($1.pinned) + count($1.today) } }
            return "\(spaces) \(spaces == 1 ? "Space" : "Spaces"), \(number(tabs)) tabs"
        case .favorites: return "\(number(all.reduce(0) { $0 + $1.favorites.count })) sites"
        case .bookmarks: return number(all.reduce(0) { $0 + count($1.bookmarks) })
        case .history: return "\(number(all.reduce(0) { $0 + $1.history.count })) sites"
        case .cookies: return imported ? "\(number(all.reduce(0) { $0 + $1.cookieCount })) cookies" : "macOS asks for your password once"
        case .extensions:
            let kept = extensions.filter { !options.excludedExtensionIDs.contains($0.id) }.count
            return kept == extensions.count ? "\(kept) found" : "\(kept) of \(extensions.count)"
        }
    }

    /// The Bring step's one sentence: exactly what's ticked, numbers in white, the words between them dimmer.
    var bringSummary: AttributedString {
        let all = profiles ?? []
        let number = { (value: Int) in value.formatted(.number) }
        let plural = { (value: Int, one: String, many: String) in "\(number(value)) \(value == 1 ? one : many)" }
        func strong(_ text: String) -> AttributedString {
            var run = AttributedString(text)
            run.foregroundColor = .white
            run.font = .system(size: 18, weight: .semibold)
            return run
        }
        var phrases: [AttributedString] = []
        for row in availableRows where isOn(row) {
            switch row {
            case .spaces:
                let spaces = all.reduce(0) { $0 + $1.spaces.count }
                let tabs = all.reduce(0) { $0 + $1.spaces.reduce(0) { $0 + count($1.pinned) + count($1.today) } }
                phrases.append(strong(plural(spaces, "Space", "Spaces")) + AttributedString(" with ") + strong(plural(tabs, "tab", "tabs")))
            case .favorites: phrases.append(strong(plural(all.reduce(0) { $0 + $1.favorites.count }, "Favorite", "Favorites")))
            case .bookmarks: phrases.append(strong(plural(all.reduce(0) { $0 + count($1.bookmarks) }, "bookmark", "bookmarks")))
            case .history: phrases.append(strong(plural(all.reduce(0) { $0 + $1.history.count }, "site", "sites")) + AttributedString(" you’ve visited"))
            case .cookies: phrases.append(AttributedString("your sign-ins"))
            case .extensions:
                let kept = extensions.filter { !options.excludedExtensionIDs.contains($0.id) }.count
                if kept > 0 { phrases.append(strong(plural(kept, "extension", "extensions"))) }
            }
        }
        guard !phrases.isEmpty else { return AttributedString("Nothing selected. You’ll start with a clean slate.") }
        var sentence = AttributedString()
        for (index, phrase) in phrases.enumerated() {
            if index > 0 { sentence += AttributedString(index == phrases.count - 1 ? " and " : ", ") }
            sentence += phrase
        }
        return sentence + AttributedString(".")
    }

    func isOn(_ row: Row) -> Bool {
        switch row {
        case .spaces: options.spacesAndTabs
        case .favorites: options.favorites
        case .bookmarks: options.bookmarks
        case .history: options.history
        case .cookies: options.cookies
        case .extensions: options.extensions
        }
    }

    func setOn(_ row: Row, _ on: Bool) {
        switch row {
        case .spaces: options.spacesAndTabs = on
        case .favorites: options.favorites = on
        case .bookmarks: options.bookmarks = on
        case .history: options.history = on
        case .cookies: options.cookies = on
        case .extensions: options.extensions = on
        }
    }

    func state(_ row: Row) -> RowState { rows[row] ?? .idle }

    /// What the preview sidebar shows: the person's real Favorites and first Space.
    var previewFavorites: [(title: String, url: URL, icon: NSImage?)] {
        let profile = (profiles ?? []).first { !$0.favorites.isEmpty }
        return (profile?.favorites ?? []).prefix(6).compactMap { item in
            guard case .tab(_, let title, let url) = item else { return nil }
            return (title, url, profile?.icons[url.absoluteString].flatMap(NSImage.init(data:)))
        }
    }

    var previewSpace: (name: String, tabs: [(title: String, icon: NSImage?)])? {
        guard let profile = (profiles ?? []).first(where: { !$0.spaces.isEmpty || !$0.bookmarks.isEmpty }) else { return nil }
        func tabs(_ items: [ImportedItem]) -> [(String, NSImage?)] {
            items.flatMap { item -> [(String, NSImage?)] in
                switch item {
                case .tab(_, let title, let url): [(title, profile.icons[url.absoluteString].flatMap(NSImage.init(data:)))]
                case .folder(_, let title, _): [(title, NSImage(systemSymbolName: "folder", accessibilityDescription: nil))]
                case .split(_, let panes, _): tabs(panes)
                }
            }
        }
        if let space = profile.spaces.first {
            return (space.name, Array(tabs(space.pinned + space.today).prefix(3)))
        }
        return (profile.name, Array(tabs(profile.bookmarks).prefix(3)))
    }

    // MARK: Moving through the steps

    func show(_ step: OnboardingStep) {
        guard flow.steps.contains(step) else { return }
        while flow.current != step {
            if (flow.steps.firstIndex(of: flow.current) ?? 0) < (flow.steps.firstIndex(of: step) ?? 0) { flow.next() } else { flow.back() }
        }
    }

    func next() {
        guard !flow.isFinished else { return }
        if flow.current == .welcome { finish(); return }
        direction = 1
        flow.next()
        entered()
    }

    func back() {
        direction = -1
        flow.back()
        entered()
    }

    /// "Skip setup": straight to the browser, letting a running import finish on its own.
    func skipSetup() {
        music?.stop(fade: 0)
        finish(resolve: false)
    }

    func finish(resolve: Bool = true) {
        guard !finishing else { return }
        finishing = true
        if resolve { music?.cue(.resolve); music?.stop(fade: 3) }
        if (tintPicked || modePicked), browserModel.state.spaces.contains(where: { $0.id == browserModel.state.selectedSpaceID }) {
            _ = browserModel.appearance.update { prefs in
                if tintPicked {
                    var looks = prefs.space(browserModel.state.selectedSpaceID)
                    looks.tint = tint
                    prefs.spaces[browserModel.state.selectedSpaceID] = looks
                }
                if modePicked { prefs.appearance = mode }
            }
        }
        _ = browserModel.settings.update { $0.onboardingCompleted = true; $0.onboardingStep = nil }
        onFinish?()
    }

    private func entered() {
        _ = browserModel.settings.update { $0.onboardingStep = flow.current }
        switch flow.current {
        case .bring: music?.cue(.addBass)
        case .defaultBrowser: music?.cue(.addShuffle)
        default: break
        }
    }

    // MARK: Things the steps do

    func appeared() {
        music?.start()
        // Resumed partway: bring back the layers the earlier steps added.
        if (flow.steps.firstIndex(of: flow.current) ?? 0) > (flow.steps.firstIndex(of: .bring) ?? 99) || flow.current == .bring { music?.cue(.addBass) }
        if flow.current == .defaultBrowser || flow.current == .welcome { music?.cue(.addShuffle) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_450))
            self?.music?.cue(.bloom)
        }
        if profiles == nil, let browser { read(browser) }
    }

    func choose(_ browser: ImportBrowser) {
        guard browser != self.browser, !importing, !imported else { return }
        self.browser = browser
        profiles = nil
        read(browser)
    }

    /// Reads the browser in the background while the intro plays, so the import step opens with real numbers.
    private func read(_ browser: ImportBrowser) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task { @MainActor [weak self] in
            let result: Result<[ImportedProfile], Error> = await Task.detached {
                Result { try ImportSources.read(browser, home: home) }
            }.value
            guard let self, self.browser == browser else { return }
            switch result {
            case .success(let found): self.profiles = found; self.readError = nil
            case .failure(let error): self.profiles = []; self.readError = "Couldn’t read \(browser.shortName): \(error.localizedDescription)"
            }
            if let first = self.arcTints.first { self.tint = first }
        }
    }

    func runImport() {
        guard let browser, let profiles, !importing, !imported else { return }
        importing = true
        let visible = availableRows.filter(isOn)
        for row in visible { rows[row] = .working }
        let options = options, keychain = browser.safeStorage
        Task { @MainActor in
            await Task.yield()
            var outcome = browserModel.applyBrowserImport(profiles, from: browser, into: .newProfiles, options: options)
            // The sidebar parts landed together; tick them one after another so each is seen.
            var tick = 0
            for row in [Row.spaces, .favorites, .bookmarks, .history] where visible.contains(row) {
                try? await Task.sleep(for: .milliseconds(tick == 0 ? 120 : 240))
                rows[row] = outcome.saved ? .done : .failed
                music?.cue(.tick(tick)); tick += 1
            }
            if visible.contains(.cookies) {
                outcome = await browserModel.importCookies(profiles, from: browser, options: options, outcome: outcome) {
                    try SafeStorage.secret(service: keychain.service, account: keychain.account)
                }
                rows[.cookies] = outcome.counts["cookies", default: 0] > 0 ? .done : .failed
                music?.cue(.tick(tick)); tick += 1
            }
            if visible.contains(.extensions) {
                outcome = await browserModel.installExtensions(profiles, options: options, outcome: outcome)
                rows[.extensions] = outcome.counts["extensions", default: 0] > 0 ? .done : .failed
                music?.cue(.tick(tick)); tick += 1
            }
            self.outcome = outcome
            importing = false
            imported = true
            // Moved on while this ran: say how it went once it lands, so nothing is lost silently.
            if finishing || flow.current != .bring { browserModel.toast = Self.lateImportNote(outcome, browser: browser) }
            if let first = self.arcTints.first, self.tint == Self.defaultTint { self.tint = first }
        }
    }

    func startFresh() {
        startedFresh = true
        next()
    }

    /// What a finished import says when the person has already moved on.
    static func lateImportNote(_ outcome: ImportOutcome, browser: ImportBrowser) -> BrowserToast {
        guard outcome.saved else {
            return BrowserToast(title: "Your \(browser.shortName) didn’t come over", message: outcome.skipped.first ?? "It couldn’t be saved.")
        }
        let names: [(String, String, String)] = [("spaces", "Space", "Spaces"), ("tabs", "tab", "tabs"), ("favorites", "Favorite", "Favorites"),
                                                 ("bookmarks", "bookmark", "bookmarks"), ("history", "history site", "history sites"),
                                                 ("cookies", "cookie", "cookies"), ("extensions", "extension", "extensions")]
        let parts = names.compactMap { key, one, many -> String? in
            guard let count = outcome.counts[key], count > 0 else { return nil }
            return "\(count.formatted(.number)) \(count == 1 ? one : many)"
        }
        var message = parts.isEmpty ? "Nothing new came over." : (parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts.last!) + " came over."
        if !outcome.skipped.isEmpty {
            message += " \(outcome.skipped.count) \(outcome.skipped.count == 1 ? "thing" : "things") didn’t come over."
        }
        return BrowserToast(title: "Your \(browser.shortName) is in", message: message)
    }

    func pick(_ color: AppearanceColor) {
        tintPicked = true
        tint = color
        music?.cue(.warmth((color.red + color.green) / 2))
    }

    func makeDefault() {
        guard defaultState == .idle || defaultState == .declined else { return next() }
        defaultState = .asking
        let app = Bundle.main.bundleURL
        Task { @MainActor in
            // Stop at the first "no": asking again for https would be a second prompt right after a decline.
            do { for scheme in ["http", "https"] { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) } }
            catch {}
            let isDefault = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
                == app.standardizedFileURL
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { defaultState = isDefault ? .done : .declined }
        }
    }

    func toggleMute() {
        muted.toggle()
        music?.setMuted(muted)
        _ = browserModel.settings.update { $0.premiereMuted = muted }
    }

    func setActive(_ active: Bool) { music?.setPaused(!active) }

    /// Problems worth one quiet line under the rows.
    var problems: [String] { outcome?.skipped ?? [] }
}
