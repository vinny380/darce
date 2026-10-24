import AppKit
import BrowserCore
import SwiftUI

// Tests-first failure plan: artifacts/sidebar-reset-mounted-fixture-plan.md.
// This held fixture uses CUA-only interactions, not injected events or hover setters.
// Cmd+1 toggles eligibility; Cmd+2 toggles editing; Cmd+3 saves the actual mounted
// view. Counter-only callbacks preserve all tabs/URLs. Today X delivery, region
// appearance and action correctness require external review; Finish is NOT pass.
// Timeout is 300 seconds after mounting. Snapshot only on first load/explicit Cmd+3.
@MainActor
private final class ResetRowInteractionProbe: NSObject, ObservableObject {
    let state: BrowserState
    let tabs: [BrowserTab]
    let output: URL
    @Published var eligible = true
    @Published var editing = false
    @Published private(set) var counters: [String: Int] = [:]
    @Published private(set) var snapshotCount = 0
    @Published private(set) var message = "Waiting for first snapshot"
    private(set) var finished = false
    private(set) var timedOut = false
    private(set) var windowClosed = false
    private(set) var snapshots: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var droppedEvents = 0
    private var mountedAt: Date?
    weak var window: NSWindow?
    weak var host: NSView?

    init(output: URL) {
        self.output = output
        var state = BrowserState()
        var ids: [UUID] = []
        for (name, kind, path) in [("Eligible pin", TabKind.pinned, "MixedCase/Home"),
                                    ("Ineligible pin", .pinned, "Other/Home"),
                                    ("Today control", .today, "Today")] {
            let url = URL(string: "https://example.invalid/\(path)?Keep=Case&dup=One&dup=Two#Section")!
            let id = state.openTab(url: url, title: name)
            state.setKind(id, kind: kind)
            ids.append(id)
        }
        self.state = state
        tabs = ids.compactMap { id in state.tabs.first { $0.id == id } }
        super.init()
    }

    func canReset(_ tab: BrowserTab) -> Bool { tab.id == tabs.first?.id && eligible && !editing }

    func action(_ name: String, tab: BrowserTab) {
        let key = tab.title + ": " + name
        counters[key, default: 0] += 1
        record(["event": "row_action", "action": name, "tab_id": tab.id.uuidString,
                "title": tab.title, "url": tab.url.absoluteString,
                "home_url": tab.homeURL?.absoluteString ?? "", "count": counters[key] ?? 0])
        writeLive()
    }

    func countText(_ tab: BrowserTab) -> String {
        "\(tab.title): Open \(counters[tab.title + ": open", default: 0]), Reset \(counters[tab.title + ": reset", default: 0]), Close \(counters[tab.title + ": close", default: 0])"
    }

    private func record(_ value: [String: Any]) {
        guard events.count < 8192 else { droppedEvents += 1; return }
        var record = value
        let pointer = NSEvent.mouseLocation
        record["time"] = Date().timeIntervalSince1970
        record["pointer_screen"] = [pointer.x, pointer.y]
        record["eligible"] = eligible
        record["editing"] = editing
        events.append(record)
    }

    func received(_ event: NSEvent) {
        guard [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .keyUp, .flagsChanged].contains(event.type) else { return }
        record(["event": "window_event", "type": event.type.rawValue,
                "window_number": event.windowNumber, "location_window": [event.locationInWindow.x, event.locationInWindow.y],
                "modifiers": event.modifierFlags.rawValue])
    }

    @objc func toggleEligibility(_ sender: Any?) {
        eligible.toggle()
        record(["event": "shortcut", "command": "Cmd+1 eligibility"])
        writeLive()
    }

    @objc func toggleEditing(_ sender: Any?) {
        editing.toggle()
        record(["event": "shortcut", "command": "Cmd+2 editing"])
        writeLive()
    }

    @objc func requestSnapshot(_ sender: Any?) {
        record(["event": "shortcut", "command": "Cmd+3 snapshot"])
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.capture(reason: "explicit-Cmd+3")
        }
    }

    func finish() {
        guard !finished else { return }
        record(["event": "finish_button", "meaning": "manual session finished; not verification pass"])
        finished = true
        writeLive()
    }

    func closed() { windowClosed = true; record(["event": "window_closed"]); writeLive() }
    func timeout() { timedOut = true; record(["event": "timeout_300_seconds"]); writeLive() }
    func mounted() { mountedAt = Date(); record(["event": "mounted_ready"]); capture(reason: "first-load") }

    private func accessibilityTree(_ root: NSView) -> [[String: Any]] {
        var queue: [Any] = [root], seen = Set<ObjectIdentifier>(), result: [[String: Any]] = []
        var index = 0
        while index < queue.count && index < 512 {
            let object = queue[index]; index += 1
            guard seen.insert(ObjectIdentifier(object as AnyObject)).inserted else { continue }
            if let element = object as? any NSAccessibilityProtocol {
                let frame = element.accessibilityFrame()
                result.append(["label": element.accessibilityLabel() ?? "",
                               "role": element.accessibilityRole()?.rawValue ?? "",
                               "frame_screen": [frame.minX, frame.minY, frame.width, frame.height]])
                queue.append(contentsOf: (element.accessibilityChildren() ?? []).prefix(max(0, 512 - queue.count)))
            }
            if let view = object as? NSView {
                for child in view.subviews.prefix(max(0, 512 - queue.count)) { queue.append(child) }
            }
        }
        return result
    }

    private func payload() -> [String: Any] {
        let pointer = NSEvent.mouseLocation
        return ["scope": "manual CUA shared-row fixture; no automatic pass claim",
                "verification": "external review required", "manual_finished": finished,
                "timed_out": timedOut, "window_closed": windowClosed,
                "mounted_at": mountedAt?.timeIntervalSince1970 ?? 0,
                "eligible": eligible, "editing": editing, "supplied_can_reset": eligible && !editing,
                "counters": counters, "snapshots": snapshots, "events": events, "dropped_events": droppedEvents,
                "pointer_screen": [pointer.x, pointer.y], "window_number": window?.windowNumber ?? 0,
                "window_visible": window?.isVisible ?? false, "window_key": window?.isKeyWindow ?? false,
                "application_active": NSApp.isActive,
                "tabs": tabs.map { ["id": $0.id.uuidString, "title": $0.title, "kind": $0.kind.rawValue,
                                    "url": $0.url.absoluteString, "home_url": $0.homeURL?.absoluteString ?? ""] }]
    }

    private func write(_ payload: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    func writeLive() {
        do { try write(payload(), to: output) }
        catch { message = "Evidence write failed: \(error.localizedDescription)" }
    }

    private func capture(reason: String) {
        guard let host, let window, snapshotCount < 64 else { message = "Snapshot unavailable or 64-image bound reached"; writeLive(); return }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let sequence = snapshotCount + 1
        let stem = String(format: "row-interaction-%03d", sequence)
        do {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let folder = output.deletingLastPathComponent()
            try png.write(to: folder.appendingPathComponent(stem + ".png"), options: .atomic)
            let receipt: [String: Any] = ["sequence": sequence, "reason": reason, "png": stem + ".png", "json": stem + ".json",
                                         "eligible": eligible, "editing": editing, "counters": counters,
                                         "window_number": window.windowNumber, "scale": window.backingScaleFactor,
                                         "host_bounds": NSStringFromRect(host.bounds), "window_frame": NSStringFromRect(window.frame),
                                         "ax": accessibilityTree(host), "capture": "owned NSView cacheDisplay; not compositor/cursor capture"]
            var snapshot = payload()
            snapshot["capture"] = receipt
            try write(snapshot, to: folder.appendingPathComponent(stem + ".json"))
            snapshots.append(receipt)
            snapshotCount = sequence
            message = "Saved \(stem).png + .json"
            record(["event": "snapshot_saved", "sequence": sequence, "reason": reason])
        } catch { message = "Snapshot failed: \(error.localizedDescription)"; record(["event": "snapshot_error", "error": String(describing: error)]) }
        writeLive()
    }
}

@MainActor
private final class ResetRowInteractionWindow: NSWindow, NSWindowDelegate {
    weak var probe: ResetRowInteractionProbe?
    override func sendEvent(_ event: NSEvent) { probe?.received(event); super.sendEvent(event) }
    func windowWillClose(_ notification: Notification) { probe?.closed() }
}

private struct ResetRowInteractionView: View {
    @ObservedObject var probe: ResetRowInteractionProbe
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sidebar reset interaction").font(.title2)
            Text("Cmd+1: eligibility   Cmd+2: editing   Cmd+3: save snapshot").font(.system(size: 12))
            Text("Eligible: \(probe.eligible ? "ON" : "OFF") | Editing: \(probe.editing ? "ON" : "OFF")")
                .accessibilityLabel("Eligibility \(probe.eligible ? "on" : "off"), editing \(probe.editing ? "on" : "off")")
            Text("252 pt row field — top: eligible pin; middle: ineligible; bottom: Today").font(.system(size: 11))
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 3) {
                    ForEach(probe.tabs) { tab in
                        SidebarTabRow(tab: tab, selected: false, canReset: probe.canReset(tab),
                            resetIcon: Rectangle().fill(Color(red: 0, green: 1, blue: 1)).frame(width: 14, height: 14),
                            icon: Rectangle().fill(Color(red: 1, green: 0, blue: 1)).frame(width: 14, height: 14),
                            select: { probe.action("open", tab: tab) }, reset: { probe.action("reset", tab: tab) },
                            close: { probe.action("close", tab: tab) })
                    }
                }.frame(width: 252).background(Color(white: 0.17))
                Text("Empty padding\nClick here for outside-row position").font(.system(size: 11)).frame(width: 170, height: 120)
            }
            ForEach(probe.tabs) { tab in
                Text(probe.countText(tab)).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(probe.countText(tab))
            }
            Text(probe.message).font(.system(size: 12)).accessibilityLabel(probe.message)
            Text("Finish records completion only; external verification is required. 300-second limit.").font(.system(size: 11))
            Button("Finish fixture") { probe.finish() }.accessibilityLabel("Finish fixture")
        }.padding(24).frame(width: 560, height: 480, alignment: .topLeading)
            .background(Color(white: 0.12)).preferredColorScheme(.dark)
    }
}

@MainActor
func runSidebarResetRowInteractionSmoke(output: URL) async {
    let probe = ResetRowInteractionProbe(output: output)
    let previousMenu = NSApp.mainMenu
    // Hide only windows owned by this app instance; never close other apps/windows.
    for owned in NSApp.windows { owned.orderOut(nil) }
    let window = ResetRowInteractionWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 480),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Owned Sidebar Reset Interaction"
    window.identifier = NSUserInterfaceItemIdentifier("smoke.sidebar-reset-interaction")
    window.acceptsMouseMovedEvents = true
    window.probe = probe
    window.delegate = window
    let host = NSHostingView(rootView: ResetRowInteractionView(probe: probe))
    host.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
    window.contentView = host
    probe.window = window
    probe.host = host
    // Real Cocoa menu key equivalents consume actual CUA keyboard input. No
    // key synthesis, event monitor, or direct production row actions are used.
    let menu = NSMenu(title: "Fixture"), controls = NSMenu(title: "Fixture controls")
    let root = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
    root.submenu = controls; menu.addItem(root)
    for (title, key, action) in [("Toggle eligibility", "1", #selector(ResetRowInteractionProbe.toggleEligibility(_:))),
                                ("Toggle editing", "2", #selector(ResetRowInteractionProbe.toggleEditing(_:))),
                                ("Save snapshot", "3", #selector(ResetRowInteractionProbe.requestSnapshot(_:)))] {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = probe
        controls.addItem(item)
    }
    NSApp.mainMenu = menu
    defer {
        NSApp.mainMenu = previousMenu
        window.delegate = nil
        window.probe = nil
        window.contentView = nil
        window.close()
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    let deadline = Date().addingTimeInterval(300)
    probe.mounted()
    while !probe.finished && !probe.windowClosed && Date() < deadline && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
    }
    if !probe.finished && !probe.windowClosed && Date() >= deadline { probe.timeout() }
    probe.writeLive()
}
