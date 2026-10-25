import AppKit
import BrowserCore
import Foundation

@MainActor
func runSmoke(model: BrowserModel, output: URL) async {
    var checks: [[String: String]] = []
    func check(_ name: String, _ condition: Bool) throws {
        checks.append(["name": name, "status": condition ? "passed" : "failed"])
        if !condition { throw CocoaError(.validationMissingMandatoryProperty) }
    }
    if ProcessInfo.processInfo.arguments.contains("--sidebar-reset-row-interaction-only") {
        await runSidebarResetRowInteractionSmoke(output: output)
        NSApplication.shared.terminate(nil)
        return
    }
    if ProcessInfo.processInfo.arguments.contains("--sidebar-reset-eligibility-only") {
        let values = await runNativeSidebarResetEligibilitySmoke(directory: output.deletingLastPathComponent())
        let result: [String: Any] = ["passed": values["native_eligibility_fixture_finished"] == true && values.values.allSatisfy { $0 },
            "checks": values.keys.sorted().map { ["name": $0, "status": values[$0] == true ? "passed" : "failed"] },
            "runtime": "owned WebKit loadSimulatedRequest documents and real same-document history",
            "scope": "model eligibility and metadata; fixture-only typed Mirror cache inspection"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { NSLog("Cannot write native eligibility result: %@", String(describing: error)) }
        NSApplication.shared.terminate(nil)
        return
    }
    if ProcessInfo.processInfo.arguments.contains("--semantic-colors-only") {
        var values: [String: Bool]
        do { values = try await runNativeSemanticColorsSmoke(model: model, directory: output.deletingLastPathComponent()) }
        catch { values = ["semantic_fixture_error": false] }
        let result: [String: Any] = ["passed": !values.isEmpty && values.values.allSatisfy { $0 },
            "checks": values.keys.sorted().map { ["name": $0, "status": values[$0] == true ? "passed" : "failed"] },
            "runtime": "owned mounted WebKit sidebar rows"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { NSLog("Cannot write semantic result: %@", String(describing: error)) }
        NSApplication.shared.terminate(nil)
        return
    }
    if ProcessInfo.processInfo.arguments.contains("--favicon-only") {
        let page = BrowserPage(url: URL(string: "about:blank")!, dataStore: model.dataStore(for: model.state.selectedProfileID))
        let values = await runFaviconSmoke(page: page, controller: model.favicons, profileID: model.state.selectedProfileID,
                                          evidenceURL: output.deletingLastPathComponent().appendingPathComponent("favicon-probe.json"))
        let result: [String: Any] = ["passed": !values.isEmpty && values.values.allSatisfy { $0 },
                                    "checks": values.keys.sorted().map { ["name": $0, "status": values[$0] == true ? "passed" : "failed"] },
                                    "runtime": "isolated native WebKit favicon probe"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { NSLog("Cannot write favicon smoke result: %@", String(describing: error)) }
        NSApplication.shared.terminate(nil)
        return
    }
    // Separate experimental gate: the owned in-process AX walk currently cannot
    // find SwiftUI divider nodes. Preserve a failing result without claiming AX parity.
    if ProcessInfo.processInfo.arguments.contains("--split-interaction-only") {
        let values = await runSplitInteractionSmoke()
        let result: [String: Any] = ["passed": !values.isEmpty && values.values.allSatisfy { $0 },
            "checks": values.keys.sorted().map { ["name": $0, "status": values[$0] == true ? "passed" : "failed"] },
            "runtime": "owned mounted split accessibility probe", "scope": "experimental; divider discovery unverified"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic) }
        catch { NSLog("Cannot write split interaction result: %@", String(describing: error)) }
        NSApplication.shared.terminate(nil)
        return
    }
    do {
        for (name, passed) in try await runSplitSmoke(directory: output.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in try runArchiveProfileSmoke(directory: output.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in try runArchiveExclusionSmoke(directory: output.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in try runMultiwindowSmoke(directory: output.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runPrivateBrowsingSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runNavigationCommandSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runMiniWindowSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runUndoCloseSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runMiniLauncherSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runDeveloperModeSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runDialogSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runClosePinnedSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runShortcutAliasSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runEaselSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runSavedIconSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runEmojiSpaceIconSmoke(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runBrowserImportSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runUnsavedImportSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runUserAgentSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runFullscreenAPISmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runImportCookiesSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runDeniedKeychainSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runImportExtensionSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runSafariExtensionSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereMusicSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereLifecycleSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runPremiereEngineSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereReviewSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereMeshSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereBringSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in runPremiereBackdropSmoke().sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        try check("reject javascript URL", BrowserModel.destination("javascript:alert(1)") == nil)
        try check("reject file URL", BrowserModel.destination("file:///etc/hosts") == nil)
        let query = BrowserModel.destination("swift & spaces")
        try check("encode search query", URLComponents(url: query!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift & spaces")
        model.open(URL(string: "https://example.invalid/fixture")!)
        let first = model.state.selectedTabID!
        let page = model.page(for: first)!
        // No network is needed: exercise the real WebKit renderer with a local document.
        page.webView.stopLoading()
        page.webView.loadHTMLString("<title>Fixture One</title><h1>Native browser smoke</h1><script>window.smokeValue = 73</script>", baseURL: nil)
        for _ in 0..<100 {
            if page.webView.title == "Fixture One", model.state.selectedTab?.title == "Fixture One" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check("real WebKit page loaded", page.webView.title == "Fixture One")
        try check("page title reaches persisted tab state", model.state.selectedTab?.title == "Fixture One")
        let value = try await page.webView.evaluateJavaScript("window.smokeValue")
        try check("JavaScript executed in renderer", (value as? Int) == 73)
        for (name, passed) in await runPageActionsSmoke(page: page).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        let capturedPage = await model.captureCurrentPage(profileID: model.state.selectedProfileID)
        try check("capture renders current page as PNG", capturedPage?.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) == true)
        let rejectedCapture = await model.captureCurrentPage(profileID: UUID())
        try check("capture rejects a different profile", rejectedCapture == nil)
        model.pin(first, kind: .favorite)
        try check("same-host pinned link stays in tab", page.onLink?(URL(string: "https://example.invalid/within-site")!) == false && model.peekPage == nil)
        _ = try await page.webView.evaluateJavaScript("var link = document.createElement('a'); link.href='https://outbound.invalid/link-peek'; document.body.appendChild(link); link.click();")
        for _ in 0..<100 {
            if model.peekPage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check("real pinned-page link opens Peek", model.peekPage != nil && model.state.selectedTabID == first)
        model.closePeek()
        let secondSpace = model.state.spaces[1].id
        model.selectSpace(secondSpace)
        try check("favorite visible across Spaces", model.state.visibleTabs.contains(where: { $0.id == first }))
        model.open(URL(string: "https://example.invalid/second")!)
        let second = model.state.selectedTabID!
        model.select(first)
        let retained = try await model.page(for: first)!.webView.evaluateJavaScript("window.smokeValue")
        try check("switching tabs preserves page state", (retained as? Int) == 73)
        model.selectSpace(model.state.spaces[0].id)
        try check("Today tabs isolated by Space", !model.state.visibleTabs.contains(where: { $0.id == second }))
        model.selectSpace(secondSpace)
        model.archive(second)
        try check("archive preserves record", model.state.tabs.contains(where: { $0.id == second && $0.kind == .archived }))
        let beforePutBack = BrowserWindowSelection(state: model.state)
        model.restore(second)
        try check("archive put back preserves window selection", BrowserWindowSelection(state: model.state) == beforePutBack)
        try check("restore preserves tab identity", model.state.visibleTabs.contains(where: { $0.id == second }))
        let folder = model.addFolder("Research")!
        model.move(second, into: folder)
        try check("folder action pins the tab", model.state.tabs.first { $0.id == second }?.folderID == folder && model.state.tabs.first { $0.id == second }?.kind == .pinned)
        let home = model.state.tabs.first { $0.id == second }!.homeURL!
        model.stateUpdate { $0.updateTab(second, url: URL(string: "https://example.invalid/away")!) }
        model.resetPin(second)
        try check("pin reset restores its saved URL", model.state.tabs.first { $0.id == second }?.url == home)
        model.select(second)
        model.split(first)
        try check("split uses distinct tab renderers", model.secondaryTabID == first && model.page(for: first) !== model.page(for: second))
        model.split(second)
        try check("split rejects the selected tab", model.secondaryTabID != second)
        model.showPeek(URL(string: "https://example.invalid/peek")!)
        let peek = model.peekPage!
        peek.webView.stopLoading()
        peek.webView.loadHTMLString("<title>Peek Fixture</title><h1>Peek</h1>", baseURL: nil)
        for _ in 0..<100 {
            if peek.webView.title == "Peek Fixture" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check("Peek uses a separate renderer", peek !== model.page(for: second) && peek.webView.title == "Peek Fixture")
        model.closePeek()
        try check("closing Peek preserves original selection and home", model.state.selectedTabID == second && model.state.selectedTab?.homeURL == home && model.peekPage == nil)
        for (name, passed) in runBookmarkSmokeChecks(model: model).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        let boostPage = BrowserPage(url: URL(string: "about:blank")!, dataStore: model.dataStore(for: model.state.selectedProfileID))
        for (name, passed) in await runBoostSmoke(page: boostPage, controller: model.boosts, profileID: model.state.selectedProfileID).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        for (name, passed) in await runFaviconSmoke(page: boostPage, controller: model.favicons, profileID: model.state.selectedProfileID, evidenceURL: output.deletingLastPathComponent().appendingPathComponent("favicon-probe.json")).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        let spaceID = model.state.selectedSpaceID
        try check("appearance saves through native controller", model.appearance.update {
            $0.sidebarWidth = 276
            $0.spaces[spaceID, default: SpaceAppearance()].icon = "leaf.fill"
            $0.spaces[spaceID, default: SpaceAppearance()].pinnedCollapsed = true
        })
        let appearance = AppearanceController(directory: model.sessionURL.deletingLastPathComponent())
        try check("appearance restores persisted layout and Space customization", appearance.state.sidebarWidth == 276 && appearance.state.space(spaceID).icon == "leaf.fill" && appearance.state.space(spaceID).pinnedCollapsed)
        model.appearance.update { $0.spaces[spaceID, default: SpaceAppearance()].pinnedCollapsed = false }
        for (name, passed) in runDocumentsSmoke(directory: output.deletingLastPathComponent()).sorted(by: { $0.key < $1.key }) { try check(name, passed) }
        let savedSettings = model.settings.state
        try check("browser settings save through controller", model.settings.update {
            $0.searchEngine = .brave; $0.autoArchiveAge = .never; $0.defaultZoom = 1.25; $0.pinnedExternalLinksOpenPeek = false
        })
        try check("configured search engine encodes literal plus", model.destination("C++ browser")?.absoluteString.contains("search.brave.com/search?q=C%2B%2B") == true)
        model.open(URL(string: "https://settings-fixture.invalid/page")!)
        let settingsID = model.state.selectedTabID!
        model.pin(settingsID, kind: .pinned)
        let settingsPage = model.page(for: settingsID)!
        try check("default zoom reaches new renderer", settingsPage.webView.pageZoom == 1.25)
        try check("disabled Peek leaves outbound link in page", settingsPage.onLink?(URL(string: "https://outbound.invalid/settings")!) == false && model.peekPage == nil)
        let restoredSettings = SettingsController(directory: model.sessionURL.deletingLastPathComponent())
        try check("browser settings restore after reload", restoredSettings.state == model.settings.state)
        model.settings.update { $0 = savedSettings }
        let original = model.state
        let oldProfile = model.state.selectedProfileID
        var scopedArchive: UUID?
        model.stateUpdate { value in
            let tab = value.openTab(url: URL(string: "https://archive-fixture.invalid/one")!)
            value.archiveTab(tab)
            scopedArchive = tab
            let profile = value.addProfile(name: "Archive Isolation Fixture")
            let space = value.addSpace(name: "Archive Isolation Fixture")
            _ = value.assignSpaceProfile(space, profileID: profile)
            value.selectSpace(space)
        }
        try check("archive hides records from another profile", !model.archivedTabs.contains { $0.id == scopedArchive })
        model.reopenLastArchived()
        try check("reopen ignores other profiles", model.state.selectedTabID == nil && model.state.selectedProfileID != oldProfile)
        model.stateUpdate { $0.selectSpace(original.selectedSpaceID) }
        model.reopenLastArchived()
        try check("reopen restores latest archived tab identity", model.state.selectedTabID == scopedArchive && model.state.selectedTab?.kind == .today)
        model.stateUpdate { $0 = original }
        try BrowserStateFile.write(model.state, to: model.sessionURL)
        let restored = try BrowserStateFile.read(from: model.sessionURL)
        try check("disk roundtrip preserves workspace", restored == model.state)
        model.separateAllPanes()
        model.select(first)
        // Capture this app's own rendered NSView. It does not capture the desktop.
        try await Task.sleep(for: .milliseconds(250))
        try renderWindow(to: output.deletingLastPathComponent().appendingPathComponent("native-shell.png"))
        model.commandMode = .newTab
        try await Task.sleep(for: .milliseconds(250))
        try renderWindow(to: output.deletingLastPathComponent().appendingPathComponent("native-command-bar.png"))
        try check("native shell render artifacts written", true)
    } catch {
        checks.append(["name": "smoke error", "status": "failed", "detail": String(describing: error)])
    }
    do {
        let result: [String: Any] = ["checks": checks, "engine": "system WebKit", "runtime": "native macOS app", "passed": checks.allSatisfy { $0["status"] == "passed" }]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    } catch { NSLog("Cannot write smoke result: %@", String(describing: error)) }
    NSApplication.shared.terminate(nil)
}

@MainActor
private func renderWindow(to url: URL) throws {
    guard let view = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw CocoaError(.fileWriteUnknown)
    }
    view.layoutSubtreeIfNeeded()
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url, options: .atomic)
}
