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
    @Published var mode: BrowserAppearance
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

    var bringTitle: String { "Bring your \(browser?.shortName ?? "browser") with you." }
    var arcTints: [AppearanceColor] {
        guard browser == .arc else { return [] }
        return (profiles ?? []).flatMap { $0.spaces.compactMap(\.tint) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var themeSubtitle: String {
        arcTints.isEmpty ? "Every Space gets its own." : "Every Space gets its own. We started you with the ones from your Arc."
    }
    var welcomeSubtitle: String {
        let spaces: Bool
        if startedFresh { spaces = false }
        else if let outcome { spaces = outcome.counts["spaces", default: 0] > 0 }
        else { spaces = browser == .arc && (profiles ?? []).contains { !$0.spaces.isEmpty } }
        return spaces ? "Your Spaces are where you left them. ⌘T opens anything." : "⌘T opens anything."
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
        case .favorites: browser == .arc ? "Favorites" : "Favorites from your most-visited sites"
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
            return "\(spaces) \(spaces == 1 ? "Space" : "Spaces") · \(number(tabs)) tabs"
        case .favorites: return number(all.reduce(0) { $0 + $1.favorites.count })
        case .bookmarks: return number(all.reduce(0) { $0 + count($1.bookmarks) })
        case .history: return "\(number(all.reduce(0) { $0 + $1.history.count })) sites"
        case .cookies: return "\(number(all.reduce(0) { $0 + $1.cookieCount })) cookies"
        case .extensions: return number(extensions.filter { !options.excludedExtensionIDs.contains($0.id) }.count)
        }
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
        music?.stop(fade: 0.6)
        finish(resolve: false)
    }

    func finish(resolve: Bool = true) {
        guard !finishing else { return }
        finishing = true
        if resolve { music?.cue(.resolve); music?.stop(fade: 3) }
        if browserModel.state.spaces.contains(where: { $0.id == browserModel.state.selectedSpaceID }) {
            _ = browserModel.appearance.update { prefs in
                var looks = prefs.space(browserModel.state.selectedSpaceID)
                looks.tint = tint
                prefs.spaces[browserModel.state.selectedSpaceID] = looks
                prefs.appearance = mode
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
            let found = (try? await Task.detached { try ImportSources.read(browser, home: home) }.value) ?? []
            guard let self, self.browser == browser else { return }
            self.profiles = found
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
            // Skipped ahead while this ran: say how it went once it lands, so nothing is lost silently.
            if finishing {
                let parts = [("spaces", "Spaces"), ("tabs", "tabs"), ("favorites", "Favorites"), ("bookmarks", "bookmarks")]
                    .compactMap { key, name in outcome.counts[key].flatMap { $0 > 0 ? "\($0) \(name)" : nil } }
                let note = outcome.skipped.isEmpty ? "" : " \(outcome.skipped.count) things didn't come over."
                browserModel.toast = BrowserToast(title: "Your \(browser.shortName) is in",
                                                  message: (parts.isEmpty ? "Everything came over." : parts.joined(separator: ", ") + " came over.") + note)
            }
            if let first = self.arcTints.first, self.tint == Self.defaultTint { self.tint = first }
        }
    }

    func startFresh() {
        startedFresh = true
        next()
    }

    func pick(_ color: AppearanceColor) {
        tint = color
        music?.cue(.warmth((color.red + color.green) / 2))
    }

    func makeDefault() {
        guard defaultState == .idle || defaultState == .declined else { return next() }
        defaultState = .asking
        let app = Bundle.main.bundleURL
        Task { @MainActor in
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            }
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
