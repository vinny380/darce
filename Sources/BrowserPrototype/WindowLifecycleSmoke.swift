import AppKit
import BrowserCore
import Foundation

@MainActor
func runWindowLifecycleSmoke(primary: BrowserModel, output: URL) async {
    let manager = BrowserWindows.shared
    var checks: [[String: String]] = []
    var snapshots: [[String: Any]] = []
    var failure: String?
    var secondary: BrowserModel?
    var privateWindow: NSWindow?

    func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + menuItems($0.submenu) }
    }

    func updateMenus(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.update()
        for item in menu.items { updateMenus(item.submenu) }
    }

    func snapshot(_ stage: String) {
        let windows: [[String: Any]] = NSApplication.shared.windows.map { window in
            let model = manager.model(for: window)
            return ["number": window.windowNumber, "title": window.title, "visible": window.isVisible,
                    "key": window.isKeyWindow, "main": window.isMainWindow,
                    "frame": NSStringFromRect(window.frame), "managed": model != nil,
                    "role": model === primary ? "primary" : (model === secondary ? "secondary" : "other"),
                    "modelClosed": model?.isWindowClosed ?? false,
                    "excludedFromWindowsMenu": window.isExcludedFromWindowsMenu]
        }
        snapshots.append(["stage": stage, "windows": windows,
                          "windowMenuTitles": NSApplication.shared.windowsMenu?.items.map(\.title) ?? [],
                          "applicationActive": NSApplication.shared.isActive,
                          "privateManagerActive": PrivateBrowserWindows.shared.isPrivateWindowActive,
                          "privateTabs": PrivateBrowserWindows.shared.activeSession?.tabs.count ?? 0,
                          "relevantCommands": menuItems(NSApplication.shared.mainMenu).filter {
                              ["Archive Current Tab", "Close Private Tab", "Import Bookmarks…", "Export Bookmarks…"].contains($0.title)
                          }.map { ["title": $0.title, "enabled": $0.isEnabled, "key": $0.keyEquivalent] }])
    }

    func check(_ name: String, _ passed: Bool) throws {
        checks.append(["name": name, "status": passed ? "passed" : "failed"])
        guard passed else { throw NSError(domain: "WindowLifecycleSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }

    func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<Int(seconds / 0.025) {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    func capture(_ window: NSWindow, name: String) throws {
        guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        if let bytes = image.representation(using: .png, properties: [:]) {
            try bytes.write(to: output.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
        }
    }

    do {
        let primaryReady = try await waitUntil { manager.window(for: primary)?.isVisible == true }
        snapshot("primary-ready")
        try check("primary_registered_and_visible_before_new_window", primaryReady)
        guard let firstWindow = manager.window(for: primary) else { throw CocoaError(.validationMissingMandatoryProperty) }
        firstWindow.collectionBehavior.insert(.moveToActiveSpace)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        firstWindow.makeKeyAndOrderFront(nil)
        let focusRequest: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier ?? "", "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": firstWindow.windowNumber]
        try JSONSerialization.data(withJSONObject: focusRequest, options: [.prettyPrinted]).write(to: output.deletingLastPathComponent().appendingPathComponent("focus-request.json"), options: .atomic)
        let startMarker = output.deletingLastPathComponent().appendingPathComponent("start-verification")
        let receivedStart = try await waitUntil(seconds: 120) { FileManager.default.fileExists(atPath: startMarker.path) }
        try check("verification_started_by_explicit_fixture_marker", receivedStart)
        let primaryFocusedInitially = try await waitUntil(seconds: 45) { NSApplication.shared.isActive && firstWindow.isKeyWindow }
        snapshot("initial-focus")
        try check("diagnostic_application_is_active_with_primary_key", primaryFocusedInitially)
        let firstNumber = firstWindow.windowNumber
        try capture(firstWindow, name: "primary-before.png")
        secondary = manager.open(workspace: primary.workspace, selection: BrowserWindowSelection(state: primary.state))
        guard let secondary, let secondWindow = manager.window(for: secondary) else { throw CocoaError(.validationMissingMandatoryProperty) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        secondWindow.makeKeyAndOrderFront(nil)
        let secondReady = try await waitUntil { secondWindow.isVisible && NSApplication.shared.keyWindow === secondWindow }
        snapshot("two-windows-open")
        try check("secondary_is_visible_and_key", secondReady)
        try check("primary_and_secondary_are_distinct_visible_windows", firstWindow !== secondWindow && firstWindow.isVisible && secondWindow.isVisible && firstWindow.windowNumber == firstNumber)
        try check("normal_models_remain_independent_and_open", manager.model(for: firstWindow) === primary && manager.model(for: secondWindow) === secondary && !primary.isWindowClosed && !secondary.isWindowClosed)
        try capture(secondWindow, name: "secondary-before-close.png")
        NSApplication.shared.keyWindow?.performClose(nil)
        let secondClosed = try await waitUntil { !secondWindow.isVisible && secondary.isWindowClosed }
        // Let AppKit finish any main/key-window transition before recording its final state.
        try await Task.sleep(for: .milliseconds(250))
        snapshot("secondary-closed")
        try check("closing_key_secondary_closes_only_its_model", secondClosed && !primary.isWindowClosed)
        try check("primary_remains_registered_and_visible_after_secondary_close", manager.window(for: primary) === firstWindow && firstWindow.isVisible)
        firstWindow.makeKeyAndOrderFront(nil)
        let primaryFocused = try await waitUntil { manager.activeModel === primary && firstWindow.isKeyWindow }
        try check("primary_can_become_key_after_secondary_close", primaryFocused)
        primary.open(URL(string: "about:blank")!)
        guard let id = primary.state.selectedTabID, let page = primary.page(for: id) else { throw CocoaError(.validationMissingMandatoryProperty) }
        page.webView.loadHTMLString("<!doctype html><title>Primary survived secondary close</title><h1>Window lifecycle fixture</h1>", baseURL: nil)
        let rendererReady = try await waitUntil { page.webView.title == "Primary survived secondary close" && primary.state.selectedTab?.title == "Primary survived secondary close" }
        snapshot("primary-usable-after-close")
        try check("primary_renderer_and_model_work_after_secondary_close", rendererReady)
        try capture(firstWindow, name: "primary-after.png")
        _ = primary.stateUpdate { $0.clearSelection() }
        try await Task.sleep(for: .milliseconds(250))
        let privateSession = PrivateBrowserWindows.shared.open()
        privateSession.newTab()
        privateWindow = NSApplication.shared.keyWindow
        let privateReady = try await waitUntil { PrivateBrowserWindows.shared.activeSession === privateSession && PrivateBrowserWindows.shared.isPrivateWindowActive }
        try await Task.sleep(for: .milliseconds(300))
        updateMenus(NSApplication.shared.mainMenu)
        snapshot("private-before-shortcut")
        try check("private_manager_tracks_key_window", privateReady)
        let commands = menuItems(NSApplication.shared.mainMenu)
        try check("private_menu_uses_enabled_close_private_tab", commands.contains { $0.title == "Close Private Tab" && $0.isEnabled } && !commands.contains { $0.title == "Archive Current Tab" })
        try check("private_menu_disables_persistent_bookmark_actions", commands.contains { $0.title == "Import Bookmarks…" && !$0.isEnabled } && commands.contains { $0.title == "Export Bookmarks…" && !$0.isEnabled })
        let initialCount = privateSession.tabs.count
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                       windowNumber: privateWindow?.windowNumber ?? 0, context: nil, characters: "w",
                                       charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) {
            _ = NSApplication.shared.mainMenu?.performKeyEquivalent(with: event)
        }
        let privateClosedTab = try await waitUntil { privateSession.tabs.count == initialCount - 1 }
        snapshot("private-after-command-w")
        try check("private_command_w_closes_exactly_one_private_tab", privateClosedTab && !primary.isWindowClosed && primary.state.selectedTabID == nil)
        privateWindow?.performClose(nil)
        let privateWindowClosed = try await waitUntil { privateSession.isClosed }
        firstWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        updateMenus(NSApplication.shared.mainMenu)
        snapshot("normal-after-private-close")
        let normalMenuRestored = try await waitUntil {
            updateMenus(NSApplication.shared.mainMenu)
            return privateWindowClosed && manager.activeModel === primary && !PrivateBrowserWindows.shared.isPrivateWindowActive && menuItems(NSApplication.shared.mainMenu).contains { $0.title == "Archive Current Tab" }
        }
        snapshot("normal-menu-settled")
        try check("closing_private_window_restores_normal_menu_context", normalMenuRestored)
    } catch { failure = error.localizedDescription; snapshot("failure") }

    if let privateWindow, privateWindow.isVisible { privateWindow.performClose(nil) }
    if let secondary, let window = manager.window(for: secondary), window.isVisible { window.performClose(nil) }
    let result: [String: Any] = ["passed": failure == nil, "runtime": "native macOS SwiftUI/AppKit windows and WebKit", "checks": checks,
                                 "snapshots": snapshots, "error": failure ?? "", "pid": ProcessInfo.processInfo.processIdentifier]
    do {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    } catch { NSLog("Window lifecycle result could not be written: %@", error.localizedDescription) }
    if ProcessInfo.processInfo.arguments.contains("--hold-after-window-lifecycle") {
        let finishMarker = output.deletingLastPathComponent().appendingPathComponent("finish-verification")
        for _ in 0..<2400 {
            if FileManager.default.fileExists(atPath: finishMarker.path) { break }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
        }
    }
    NSApplication.shared.terminate(nil)
}

