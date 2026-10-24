import AppKit
import BrowserCore
import Combine
import Foundation
import WebKit

// Failure plan precedes this fixture in artifacts/native-sidebar-reset-eligibility-failure-plan.md.
// Real WebKit documents use loadSimulatedRequest; this is not an HTTP transport test.
@MainActor
func runNativeSidebarResetEligibilitySmoke(directory: URL) async -> [String: Bool] {
    let probe = NativeResetEligibilityProbe(directory: directory)
    await probe.run()
    return probe.checks
}

@MainActor
private final class NativeResetEligibilityProbe {
    private struct PrerequisiteFailure: Error { let name: String }
    private let directory: URL
    private let model: BrowserModel
    private let window: NSWindow
    private var receipts: [[String: Any]] = []
    private var notifications = 0
    private var rawURLs: [String] = []
    private weak var observedPage: BrowserPage?
    private var phase = "setup"
    private var subscription: AnyCancellable?
    private(set) var checks: [String: Bool] = ["native_eligibility_fixture_finished": false]
    private let home = URL(string: "https://native-reset-fixture.invalid/Home?Keep=Case")!
    private let away = URL(string: "https://native-reset-fixture.invalid/Away?Keep=Other")!

    init(directory: URL) {
        self.directory = directory
        model = BrowserModel(directory: directory.appendingPathComponent("native-reset-owned-" + UUID().uuidString),
                             ephemeralWebsiteData: true)
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Owned WebKit reset eligibility fixture"
        subscription = model.objectWillChange.sink { [weak self] in
            guard let self else { return }
            notifications += 1
            receipts.append(["event": "model_objectWillChange", "count": notifications,
                             "selected_id": model.state.selectedTabID?.uuidString ?? "",
                             "phase": phase, "live_url": observedPage?.webView.url?.absoluteString ?? ""])
        }
    }

    private func require(_ name: String, _ value: Bool) throws {
        checks[name] = value
        if !value { throw PrerequisiteFailure(name: name) }
    }

    private func wait(_ name: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !predicate() { try await Task.sleep(for: .milliseconds(25)) }
        try require(name, predicate())
    }

    // Private-cache reflection is fixture-only. A renamed/changed field fails the
    // prerequisite instead of turning an unknown cache into an empty-cache pass.
    private func cache() throws -> [UUID: BrowserPage] {
        guard let value = Mirror(reflecting: model).children.first(where: { $0.label == "pages" })?.value,
              let pages = value as? [UUID: BrowserPage] else {
            try require("native_eligibility_typed_cache_available", false)
            throw PrerequisiteFailure(name: "native_eligibility_typed_cache_available")
        }
        checks["native_eligibility_typed_cache_available"] = true
        return pages
    }

    private func identities() throws -> [UUID: ObjectIdentifier] {
        try cache().mapValues { ObjectIdentifier($0) }
    }

    private func observe(_ name: String, id: UUID, expected: Bool, editing: Bool = false) throws {
        let before = try identities()
        let actual = model.canResetSidebarTab(id, isEditing: editing)
        let pages = try cache()
        checks[name] = actual == expected
        checks[name + "_lookup_preserves_renderers"] = before == (try identities())
        let tab = model.state.tabs.first { $0.id == id }
        receipts.append(["event": "eligibility", "check": name, "tab_id": id.uuidString,
                         "expected": expected, "actual": actual, "editing": editing,
                         "selected": model.state.selectedTabID == id, "page_exists": pages[id] != nil,
                         "page_identity": pages[id].map { String(describing: ObjectIdentifier($0)) } ?? "",
                         "live_url": pages[id]?.webView.url?.absoluteString ?? "",
                         "saved_url": tab?.url.absoluteString ?? "", "home_url": tab?.homeURL?.absoluteString ?? "",
                         "webkit_back": pages[id]?.webView.canGoBack ?? false,
                         "page_back": pages[id]?.canGoBack ?? false])
    }

    private func mount(_ page: BrowserPage) {
        page.webView.removeFromSuperview()
        window.contentView = page.webView
        window.orderFront(nil)
    }

    private func document(_ page: BrowserPage, url: URL, name: String, history: Bool? = nil) async throws {
        let token = UUID().uuidString
        page.webView.stopLoading()
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML:
            "<title>Owned reset fixture</title><h1>Reset eligibility</h1><script>window.fixtureToken='\(token)'</script>")
        try await wait(name + "_load") {
            page.webView.url == url && page.webView.title == "Owned reset fixture" && !page.webView.isLoading && !page.loading
        }
        let value = try await page.webView.evaluateJavaScript("({url:location.href,token:window.fixtureToken})") as? [String: Any]
        try require(name + "_document", value?["url"] as? String == url.absoluteString && value?["token"] as? String == token)
        if let history {
            try await wait(name + "_history") { page.webView.canGoBack == history && page.canGoBack == history }
        }
        receipts.append(["event": "document", "name": name, "url": url.absoluteString, "token": token,
                         "page_identity": String(describing: ObjectIdentifier(page)), "back": page.webView.canGoBack])
    }

    private func replace(_ page: BrowserPage, url: URL, name: String) async throws {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [url.absoluteString]), as: UTF8.self)
        let result = try await page.webView.evaluateJavaScript("history.replaceState(null,'',\(encoded)[0]); location.href")
        try require(name + "_document", result as? String == url.absoluteString)
        try await wait(name + "_url") { page.webView.url == url }
    }

    private func liveCase(anchor: UUID) async throws -> UUID {
        model.open(home)
        let id = try selectedID()
        guard let page = model.page(for: id) else { throw PrerequisiteFailure(name: "home_page") }
        mount(page)
        observedPage = page
        try await document(page, url: home, name: "native_eligibility_home", history: false)
        model.pin(id, kind: .pinned)
        try require("native_eligibility_pin_home", model.state.tabs.first { $0.id == id }?.homeURL == home)
        try observe("native_eligibility_home_suppressed", id: id, expected: false)
        try await document(page, url: away, name: "native_eligibility_away", history: true)
        try observe("native_eligibility_away_allowed", id: id, expected: true)
        try observe("native_eligibility_editing_suppressed", id: id, expected: false, editing: true)
        model.select(anchor)
        try require("native_eligibility_unselected_retained", model.state.selectedTabID == anchor && (try cache())[id] === page)
        try observe("native_eligibility_unselected_allowed", id: id, expected: true)

        // These are actual same-document URL changes, with neither a navigation
        // delegate injection nor a title change. Snapshot after loads settle.
        try await Task.sleep(for: .milliseconds(200))
        let stateBefore = model.state
        let diskBefore = try Data(contentsOf: model.sessionURL)
        phase = "same-document"
        let noticeBefore = notifications
        rawURLs.removeAll()
        let urlObservation = page.webView.observe(\.url, options: [.new]) { [weak self] _, change in
            let value = (change.newValue ?? nil)?.absoluteString ?? ""
            Task { @MainActor [weak self] in self?.rawURLs.append(value) }
        }
        defer { urlObservation.invalidate() }
        let normalized = URL(string: home.absoluteString + "&utm_source=Fixture#Ordinary")!
        try await replace(page, url: normalized, name: "native_eligibility_normalized")
        try require("native_eligibility_normalized_setup", normalized != home && PinnedURLComparison.normalized(normalized) == PinnedURLComparison.normalized(home) && page.webView.canGoBack)
        try observe("native_eligibility_normalized_suppressed", id: id, expected: false)
        try await replace(page, url: away, name: "native_eligibility_metadata")
        try observe("native_eligibility_metadata_allowed", id: id, expected: true)
        // Allow the model's main-actor metadata forwarding to drain; this phase
        // contains only replaceState, so favicon/didFinish cannot stand in for it.
        let noticeDeadline = Date().addingTimeInterval(2)
        while notifications == noticeBefore && Date() < noticeDeadline { try await Task.sleep(for: .milliseconds(25)) }
        checks["native_eligibility_metadata_notifies_model"] = notifications > noticeBefore
        checks["native_eligibility_metadata_without_durable_write"] = try model.state == stateBefore && Data(contentsOf: model.sessionURL) == diskBefore
        try await wait("native_eligibility_raw_url_observed") { rawURLs.contains(normalized.absoluteString) && rawURLs.contains(self.away.absoluteString) }
        receipts.append(["event": "same_document_metadata", "raw_urls": rawURLs, "notifications_before": noticeBefore,
                         "notifications_after": notifications, "durable_unchanged": checks["native_eligibility_metadata_without_durable_write"] == true])
        phase = "internal-navigation"
        try await replace(page, url: home, name: "native_eligibility_raw_equal")
        try observe("native_eligibility_equal_with_history_suppressed", id: id, expected: false)

        // Establish durable home, then navigate to an internal URL whose real
        // live value must not be replaced by the persisted HTTP URL in lookup.
        model.select(id)
        try await document(page, url: home, name: "native_eligibility_internal_seed", history: true)
        try require("native_eligibility_internal_saved_home", model.state.tabs.first { $0.id == id }?.url == home)
        page.webView.load(URLRequest(url: URL(string: "about:blank")!))
        try await wait("native_eligibility_internal_load") { page.webView.url?.absoluteString == "about:blank" && !page.webView.isLoading && !page.loading && page.webView.canGoBack }
        let internalURL = try await page.webView.evaluateJavaScript("location.href") as? String
        try require("native_eligibility_internal_document", internalURL == "about:blank")
        checks["native_eligibility_internal_durable_home_preserved"] = try model.state.tabs.first { $0.id == id }?.url == home && (try BrowserStateFile.read(from: model.sessionURL)).tabs.first { $0.id == id }?.url == home
        try observe("native_eligibility_internal_live_allowed", id: id, expected: true)
        return id
    }

    private func selectedID() throws -> UUID {
        guard let id = model.state.selectedTabID else { throw PrerequisiteFailure(name: "selected_tab") }
        return id
    }

    private func lifecycleCase(anchor: UUID) async throws {
        var id: UUID?
        try require("native_eligibility_dormant_saved", model.stateUpdate {
            let created = $0.openTab(url: home)
            $0.setKind(created, kind: .pinned)
            $0.updateTab(created, url: away)
            $0.selectTab(anchor)
            id = created
        })
        guard let id else { throw PrerequisiteFailure(name: "dormant_id") }
        try require("native_eligibility_dormant_no_page", (try cache())[id] == nil)
        try observe("native_eligibility_dormant_suppressed", id: id, expected: false)
        model.select(id)
        guard let page = model.page(for: id) else { throw PrerequisiteFailure(name: "dormant_created_page") }
        mount(page)
        try await document(page, url: away, name: "native_eligibility_first_content", history: false)
        try observe("native_eligibility_no_back_suppressed", id: id, expected: false)
        let next = away.appendingPathComponent("next")
        try await document(page, url: next, name: "native_eligibility_history", history: true)
        try observe("native_eligibility_history_allowed", id: id, expected: true)
        let originalProfile = model.state.profileID(forTab: id)
        var profile = UUID()
        try require("native_eligibility_new_profile_saved", model.stateUpdate { profile = $0.addProfile(name: "Owned eligibility profile") })
        model.assignProfile(profile, to: model.state.selectedSpaceID)
        try require("native_eligibility_profile_discards_association", model.state.profileID(forTab: id) == profile && originalProfile != profile && (try cache())[id] == nil)
        try observe("native_eligibility_profile_dormant_suppressed", id: id, expected: false)
        guard let fresh = model.page(for: id) else { throw PrerequisiteFailure(name: "new_profile_page") }
        try require("native_eligibility_profile_new_renderer", fresh !== page && fresh.webView.configuration.websiteDataStore !== page.webView.configuration.websiteDataStore)
        mount(fresh)
        try await document(fresh, url: next, name: "native_eligibility_new_profile", history: false)
        try observe("native_eligibility_profile_no_old_history", id: id, expected: false)
        try await Task.sleep(for: .milliseconds(200))
        let before = notifications
        let stateBefore = model.state
        page.webView.loadSimulatedRequest(URLRequest(url: home), responseHTML: "<title>Retired renderer</title><script>window.retiredToken=51</script>")
        try await wait("native_eligibility_retired_real_load") { page.webView.title == "Retired renderer" && !page.webView.isLoading }
        let retiredToken = try await page.webView.evaluateJavaScript("window.retiredToken") as? Int
        try require("native_eligibility_retired_document", retiredToken == 51)
        try await Task.sleep(for: .milliseconds(100))
        checks["native_eligibility_retired_metadata_ignored"] = try notifications == before && model.state == stateBefore && (try cache())[id] === fresh
        model.pin(id, kind: .today)
        model.archive(id)
        try require("native_eligibility_archive_removes_page", (try cache())[id] == nil && model.state.tabs.first { $0.id == id }?.kind == .archived)
        try observe("native_eligibility_archived_suppressed", id: id, expected: false)
    }

    func run() async {
        defer { subscription?.cancel(); model.suspendWindow(); window.contentView = nil; window.close() }
        do {
            _ = try cache()
            model.open(URL(string: "about:blank")!)
            let anchor = try selectedID()
            let live = try await liveCase(anchor: anchor)
            try await lifecycleCase(anchor: anchor)
            model.suspendWindow()
            try require("native_eligibility_suspended_cache_empty", (try cache()).isEmpty)
            try observe("native_eligibility_suspended_suppressed", id: live, expected: false)
            checks["native_eligibility_fixture_finished"] = true
        } catch {
            receipts.append(["event": "fixture_error", "error": String(describing: error)])
            checks["native_eligibility_prerequisites_completed"] = false
        }
        do {
            let evidence: [String: Any] = ["scope": "owned WK loadSimulatedRequest documents; fixture-only Mirror page-cache introspection",
                                          "checks": checks, "receipts": receipts]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("native-reset-eligibility-observations.json"), options: .atomic)
            checks["native_eligibility_evidence_written"] = true
        } catch { checks["native_eligibility_evidence_written"] = false }
    }
}
