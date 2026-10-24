import AppKit
import BrowserCore
import CryptoKit
import Foundation
import WebKit

@MainActor
func runNetworkSmoke(model: BrowserModel, base: URL, phase: String, output: URL) async {
    var checks: [[String: String]] = []
    func check(_ name: String, _ value: Bool) throws {
        checks.append(["name": name, "status": value ? "passed" : "failed"])
        if !value { throw CocoaError(.validationMissingMandatoryProperty) }
    }
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NativeServicesSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Condition timed out after 20 seconds"])
    }
    do {
        let profile = model.state.selectedProfileID
        if phase == "seed" {
            for (name, passed) in try await runBrowsingDataSmoke(base: base, directory: model.sessionURL.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
            model.stateUpdate { _ = $0.addProfile(name: "Isolated Fixture") }
            model.open(base.appendingPathComponent("seed"))
            let tabID = model.state.selectedTabID!
            let page = model.page(for: tabID)!
            try await waitUntil { page.webView.title == "Native Services Fixture" && !page.loading }
            _ = try await page.webView.evaluateJavaScript("localStorage.setItem('darce_fixture','persisted')")
            let cookies = await model.dataStore(for: profile).httpCookieStore.allCookies()
            try check("HTTP cookie established in selected profile", cookies.contains { $0.name == "darce_fixture" && $0.value == "retained" })
            let isolated = model.state.profiles.first { $0.id != profile }!.id
            let otherCookies = await model.dataStore(for: isolated).httpCookieStore.allCookies()
            try check("second profile has no first-profile cookie", !otherCookies.contains { $0.name == "darce_fixture" })
            try check("successful navigation reaches history", model.history?.search("Native Services", profileID: profile).isEmpty == false)
            for count in 1...2 {
                _ = try await page.webView.evaluateJavaScript("document.getElementById('download').click()")
                try await waitUntil { model.downloads.records.filter { $0.status == .completed }.count == count }
            }
            let completed = model.downloads.records.filter { $0.status == .completed }
            try check("same filename produces distinct files", Set(completed.compactMap(\.destinationURL)).count == 2)
            let expected = Data(String(repeating: "Native browser download fixture.\n", count: 8192).utf8)
            try check("both downloads preserve every byte", try completed.allSatisfy { try Data(contentsOf: $0.destinationURL!) == expected })
            let download = await page.webView.startDownload(using: URLRequest(url: base.appendingPathComponent("slow")))
            let downloadID = model.downloads.accept(download: download, profileID: profile)!
            try await waitUntil { model.downloads.records.first { $0.id == downloadID }?.receivedBytes ?? 0 > 100_000 }
            model.downloads.pause(downloadID)
            try await waitUntil { model.downloads.records.first { $0.id == downloadID }?.status == .paused }
            try check("paused download retains resumable identity", model.downloads.records.first { $0.id == downloadID }?.canResume == true)
            model.downloads.resume(downloadID, using: page.webView, profileID: profile)
            try await waitUntil { model.downloads.records.first { $0.id == downloadID }?.status == .completed }
            let resumed = model.downloads.records.first { $0.id == downloadID }!
            let expectedSlow = Data((0..<(256 * 32768)).map { UInt8($0 % 256) })
            try check("resumed download retains exact payload", try Data(contentsOf: resumed.destinationURL!) == expectedSlow)
            try check("download records retain originating profile", model.downloads.records.allSatisfy { $0.profileID == profile })
            for (name, passed) in try await seedDownloadRecovery(model: model, base: base).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
            // Wait for WebKit's persistent storage work before graceful process termination.
            _ = await model.dataStore(for: profile).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            try await Task.sleep(for: .seconds(1))
        } else {
            let cookies = await model.dataStore(for: profile).httpCookieStore.allCookies()
            try check("HTTP cookie survives application restart", cookies.contains { $0.name == "darce_fixture" && $0.value == "retained" })
            model.open(base.appendingPathComponent("inspect"))
            let page = model.page(for: model.state.selectedTabID!)!
            try await waitUntil { page.webView.title == "Native Services Fixture" && !page.loading }
            let stored = try await page.webView.evaluateJavaScript("localStorage.getItem('darce_fixture')")
            try check("localStorage survives application restart", stored as? String == "persisted")
            let otherProfile = model.state.profiles.first { $0.id != profile }!.id
            let other = BrowserPage(url: base.appendingPathComponent("inspect"), dataStore: model.dataStore(for: otherProfile))
            try await waitUntil { other.webView.title == "Native Services Fixture" && !other.loading }
            let absent = try await other.webView.evaluateJavaScript("localStorage.getItem('darce_fixture')")
            try check("localStorage isolated between profiles", absent is NSNull)
            for (name, passed) in try await verifyDownloadRecovery(model: model, base: base).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
            try check("download metadata survives application restart", model.downloads.records.filter { $0.status == .completed }.count == 4)
            try check("history persists and remains profile scoped", model.history?.search("Native Services", profileID: profile).isEmpty == false && model.history?.search("Native Services", profileID: otherProfile).isEmpty == true)
            let id = model.state.selectedTabID!
            let previousPage = model.page(for: id)!
            model.assignProfile(otherProfile, to: model.state.selectedSpaceID)
            let reassignedPage = model.page(for: id)!
            try check("Space profile reassignment replaces renderer", previousPage !== reassignedPage && reassignedPage.webView.configuration.websiteDataStore.identifier == otherProfile)
        }
    } catch {
        checks.append(["name": "scenario error", "status": "failed", "detail": String(describing: error)])
    }
    do {
        let result: [String: Any] = ["phase": phase, "checks": checks, "passed": checks.allSatisfy { $0["status"] == "passed" }, "origin": base.absoluteString, "runtime": "native macOS WebKit, separate processes"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    } catch { NSLog("Network smoke result failed: %@", String(describing: error)) }
    NSApplication.shared.terminate(nil)
}
