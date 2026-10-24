import AppKit
import Foundation
import WebKit

/// A disposable simulated page and data icon exercise real WebKit with no network.
@MainActor
func runFaviconSmoke(page: BrowserPage, controller: FaviconController, profileID: UUID,
                     evidenceURL: URL? = nil) async -> [String: Bool] {
    let probe = FaviconProbeEvidence(output: evidenceURL)
    let firstURL = URL(string: "https://favicon-fixture.invalid/one")!
    let secondURL = URL(string: "https://favicon-fixture.invalid/two")!
    let marker = UUID().uuidString
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='#3139fb'/></svg>"
    let icon = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    var checks: [String: Bool] = [:]
    var gateInstalled = false

    func require(_ value: Bool, _ stage: String) throws {
        guard value else {
            throw NSError(domain: "FaviconProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed stage: \(stage)"])
        }
    }
    func js(_ stage: String, _ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        do {
            // `in: .defaultClient` is a different, Void-returning callback overload.
            let value: Any? = try await page.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
            probe.record(stage, ["type": value.map { String(reflecting: type(of: $0)) } ?? "nil",
                                 "value": value ?? NSNull()])
            return value
        } catch {
            probe.recordError(stage, error)
            throw error
        }
    }
    func load(_ url: URL, title: String) async throws {
        probe.record("load_requested", ["url": url.absoluteString, "title": title])
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>\(title)</title><link rel='icon' href='\(icon)'><main id='favicon-probe' data-marker='\(marker)'>Favicon fixture</main>")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if page.webView.url == url, page.webView.title == title, !page.webView.isLoading {
                let value = try await js("document_ready", """
                    return {url:location.href, title:document.title, readyState:document.readyState,
                            marker:document.querySelector('#favicon-probe')?.dataset.marker ?? null};
                    """) as? [String: Any]
                if value?["url"] as? String == url.absoluteString,
                   value?["title"] as? String == title,
                   value?["readyState"] as? String == "complete",
                   value?["marker"] as? String == marker {
                    probe.record("native_ready", ["url": page.webView.url?.absoluteString ?? "", "title": page.webView.title ?? "", "isLoading": page.webView.isLoading])
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        probe.record("readiness_timeout", ["url": page.webView.url?.absoluteString ?? "", "title": page.webView.title ?? "", "isLoading": page.webView.isLoading, "pageFailure": page.failure ?? ""])
        try require(false, "document readiness")
    }
    func refresh(_ stage: String) async throws -> Bool {
        var result: Bool?
        controller.refresh(from: page, profileID: profileID) {
            result = $0
            probe.record(stage + "_completion", ["accepted": $0])
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while result == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(result != nil, stage + " callback deadline")
        return result == true
    }
    func cleanGate() async {
        guard gateInstalled else { return }
        do {
            _ = try await js("gate_cleanup", "window.__faviconProbeCleanup?.(); return true;")
        } catch { /* The exact error has already been retained. */ }
        gateInstalled = false
    }

    do {
        try await load(firstURL, title: "Favicon One")
        let sentinel = try await js("async_boolean_sentinel", "return true;")
        try require(sentinel as? Bool == true, "async Boolean result")
        checks["favicon_profile_webview_loads_icon"] = try await refresh("initial_icon")
        checks["favicon_native_image_is_bounded"] = controller.image(for: firstURL, profileID: profileID).map { $0.size.width > 0 && $0.size.width <= 64 } ?? false
        checks["favicon_cache_is_profile_scoped"] = controller.image(for: firstURL, profileID: UUID()) == nil

        let installed = try await js("gate_installed", """
            const originalFetch = window.fetch;
            const state = {started:false, released:false, timedOut:false};
            window.__faviconProbe = state;
            window.fetch = async (...args) => {
                state.started = true;
                await new Promise(resolve => {
                    const timer = setTimeout(() => { state.timedOut = true; resolve(); }, 1500);
                    state.release = () => { state.released = true; clearTimeout(timer); resolve(); };
                });
                return await originalFetch.apply(window, args);
            };
            window.__faviconProbeCleanup = () => {
                state.release?.(); window.fetch = originalFetch;
                delete window.__faviconProbe; delete window.__faviconProbeCleanup;
            };
            return true;
            """)
        gateInstalled = true
        try require(installed as? Bool == true, "gate installation")
        var stale: Bool?
        var completionTime: TimeInterval?
        let requestedAt = ProcessInfo.processInfo.systemUptime
        probe.record("stale_refresh_requested")
        controller.refresh(from: page, profileID: profileID) {
            stale = $0; completionTime = ProcessInfo.processInfo.systemUptime
            probe.record("stale_completion", ["accepted": $0])
        }
        var started = false
        let startedDeadline = requestedAt + 1
        while !started, ProcessInfo.processInfo.systemUptime < startedDeadline {
            started = try await js("gate_started", "return window.__faviconProbe.started;") as? Bool == true
            if !started { try await Task.sleep(for: .milliseconds(10)) }
        }
        try require(started && stale == nil, "fetch started and callback pending")
        probe.record("pending_confirmed", ["pending": stale == nil])
        let releasedAt = ProcessInfo.processInfo.systemUptime
        let navigation = try await js("navigation_and_release", """
            history.pushState({}, '', nextURL);
            const state = window.__faviconProbe;
            state.release();
            return {url:location.href, started:state.started, released:state.released, timedOut:state.timedOut};
            """, arguments: ["nextURL": secondURL.absoluteString]) as? [String: Any]
        try require(navigation?["url"] as? String == secondURL.absoluteString &&
                    navigation?["started"] as? Bool == true && navigation?["released"] as? Bool == true &&
                    navigation?["timedOut"] as? Bool == false, "navigation confirmed and gate released before timeout")
        let completionDeadline = releasedAt + 2
        while stale == nil, ProcessInfo.processInfo.systemUptime < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let promptly = completionTime.map { $0 >= releasedAt && $0 < completionDeadline && $0 - requestedAt < 3 } ?? false
        checks["favicon_stale_navigation_is_discarded"] = stale == false && promptly
        probe.record("stale_assertion", ["rejected": stale == false, "completionBeforeDeadline": promptly,
                                         "nativeURL": page.webView.url?.absoluteString ?? ""])
        await cleanGate()
        try await load(secondURL, title: "Favicon Two")
        checks["favicon_new_navigation_loads_icon"] = try await refresh("new_document_icon")
    } catch {
        probe.recordError("probe_failed", error)
        checks["favicon_probe_setup_and_execution"] = false
        await cleanGate()
    }
    probe.finish(checks: checks)
    return checks
}

@MainActor
private final class FaviconProbeEvidence {
    private let output: URL?
    private let started = ProcessInfo.processInfo.systemUptime
    private var events: [[String: Any]] = []
    private var checks: [String: Bool] = [:]
    init(output: URL?) { self.output = output }

    func record(_ stage: String, _ details: [String: Any] = [:]) {
        events.append(["stage": stage, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "details": details])
        save()
    }
    func recordError(_ stage: String, _ error: Error) {
        let value = error as NSError
        record(stage, ["errorDomain": value.domain, "errorCode": value.code,
                       "errorDescription": value.localizedDescription,
                       "errorUserInfo": value.userInfo.mapValues { String(reflecting: $0) }])
    }
    func finish(checks: [String: Bool]) {
        self.checks = checks
        record("finished", ["passed": !checks.isEmpty && checks.values.allSatisfy { $0 }])
    }
    private func save() {
        guard let output else { return }
        do {
            let result: [String: Any] = ["schemaVersion": 1, "events": events, "checks": checks,
                                         "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch { NSLog("Favicon probe evidence write failed: %@", String(describing: error)) }
    }
}
