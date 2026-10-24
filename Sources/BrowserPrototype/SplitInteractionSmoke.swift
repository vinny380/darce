import AppKit
import BrowserCore
import SwiftUI

// Owned, mounted interaction probe for SplitPaneLayout's recorded failure plan.
// No resize callback is invoked by the harness: AppKit accessibility actions on
// the actual SwiftUI divider must produce the callback and model/view change.
// SDK source: AppKit/NSAccessibilityProtocols.h, NSAccessibility children,
// label/frame/value and accessibilityPerformIncrement/Decrement. These are
// in-process object methods, not cross-process AXUIElement or global CG events.
// This probe covers AX adjustment, not pointer-drag/cancellation/preview timing.
@MainActor
private final class SplitInteractionFixture: ObservableObject {
    @Published var state = BrowserState()
    let tabs: [UUID]
    let names: [UUID: String]
    var commits: [[Double]] = []
    var accepted: [Bool] = []
    var views: [UUID: NSView] = [:]

    init() {
        var initial = BrowserState()
        var created: [UUID] = []
        var labels: [UUID: String] = [:]
        for name in ["A", "B", "C", "D"] {
            let id = initial.openTab(url: URL(string: "about:blank#split-interaction-\(name)")!)
            created.append(id)
            labels[id] = "Fixture \(name)"
        }
        initial.selectTab(created[0])
        for id in created.dropFirst() { _ = initial.addToSplit(id) }
        tabs = created
        names = labels
        state = initial
    }

    func commit(_ weights: [Double]) {
        commits.append(weights)
        guard let group = state.selectedSplitGroup else { accepted.append(false); return }
        accepted.append(state.resizeSplit(group.id, weights: weights))
    }
}

private struct SplitInteractionColorPane: NSViewRepresentable {
    let id: UUID
    let fixture: SplitInteractionFixture

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple]
        let index = fixture.tabs.firstIndex(of: id) ?? 0
        view.layer?.backgroundColor = colors[index % colors.count].cgColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Mounted \(fixture.names[id] ?? "pane")")
        fixture.views[id] = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SplitInteractionRoot: View {
    @ObservedObject var fixture: SplitInteractionFixture

    var body: some View {
        if let group = fixture.state.selectedSplitGroup {
            SplitPaneLayout(
                group: group,
                selectedTabID: fixture.state.selectedTabID,
                title: { fixture.names[$0] ?? "Pane" },
                onFocus: { fixture.state.selectTab($0) },
                onSeparate: { _ = fixture.state.removeFromSplit($0) },
                onResize: { fixture.commit($0) },
                onAxis: { _ = fixture.state.setSplitAxis(group.id, axis: $0) },
                onReorder: { _ = fixture.state.reorderSplit(group.id, tabIDs: $0) }
            ) { id in
                SplitInteractionColorPane(id: id, fixture: fixture)
            }
        }
    }
}

@MainActor
private func splitInteractionWait(_ predicate: () -> Bool) async -> Bool {
    // At most two seconds, yielding the app's actual main runloop throughout.
    for _ in 0..<100 {
        if predicate() { return true }
        if Task.isCancelled { return false }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
    }
    return predicate()
}

@MainActor
private func splitInteractionElement(in root: NSView, label: String) -> (any NSAccessibilityProtocol)? {
    var pending: [Any] = [root]
    var seen = Set<ObjectIdentifier>()
    var index = 0
    // Bounded owned-root traversal; cycles/proxy duplication cannot hang a run.
    while index < pending.count && index < 512 {
        let candidate = pending[index]
        index += 1
        let object = candidate as AnyObject
        guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
        if let accessible = candidate as? any NSAccessibilityProtocol {
            if accessible.accessibilityLabel() == label { return accessible }
            pending.append(contentsOf: (accessible.accessibilityChildren() ?? []).prefix(512 - min(pending.count, 512)))
        }
        // Some hosting roots expose their SwiftUI AX elements through a child
        // NSView. This remains a walk of the same mounted, owned view hierarchy.
        if let view = candidate as? NSView {
            for child in view.subviews.prefix(512 - min(pending.count, 512)) { pending.append(child) }
        }
    }
    return nil
}

@MainActor
func runSplitInteractionSmoke() async -> [String: Bool] {
    let fixture = SplitInteractionFixture()
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 1200, height: 700),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Owned Split Interaction Verification"
    window.identifier = NSUserInterfaceItemIdentifier("smoke.split-interaction")
    let host = NSHostingView(rootView: SplitInteractionRoot(fixture: fixture))
    host.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    defer {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        fixture.views.removeAll()
    }
    // No activation, key-window changes or external event posting required.
    window.orderFront(nil)
    var checks: [String: Bool] = [:]
    checks["split_interaction_four_core_tabs"] = fixture.state.selectedSplitGroup?.tabIDs == fixture.tabs
    checks["split_interaction_mounted_four_panes"] = await splitInteractionWait {
        host.layoutSubtreeIfNeeded()
        return fixture.views.count == 4 && fixture.tabs.allSatisfy {
            guard let view = fixture.views[$0] else { return false }
            return view.window === window && view.bounds.width > 0 && view.bounds.height > 0
        }
    }
    guard checks["split_interaction_mounted_four_panes"] == true else { return checks }
    let originalViews = fixture.tabs.compactMap { fixture.views[$0].map(ObjectIdentifier.init) }

    func lengths(horizontal: Bool) -> [CGFloat] {
        fixture.tabs.compactMap { id in
            guard let view = fixture.views[id] else { return nil }
            return horizontal ? view.bounds.width : view.bounds.height
        }
    }
    func near(_ first: Double, _ second: Double) -> Bool { abs(first - second) < 1e-9 }

    let scenarios: [(String, BrowserSplitAxis, Int, Bool)] = [
        ("horizontal_increment", .horizontal, 0, true),
        ("horizontal_decrement", .horizontal, 0, false),
        ("vertical_increment", .vertical, 1, true),
        ("vertical_decrement", .vertical, 1, false),
    ]
    for (name, axis, divider, increment) in scenarios {
        guard let group = fixture.state.selectedSplitGroup else {
            checks["split_interaction_\(name)_group_available"] = false
            break
        }
        let horizontal = axis == .horizontal
        if group.axis != axis {
            // Scenario setup changes the axis through Core; the interaction
            // being tested remains an actual mounted divider accessibility action.
            _ = fixture.state.setSplitAxis(group.id, axis: axis)
            checks["split_interaction_\(name)_axis_mounted"] = await splitInteractionWait {
                host.layoutSubtreeIfNeeded()
                guard let first = fixture.views[fixture.tabs[0]] else { return false }
                return horizontal ? first.bounds.height > first.bounds.width : first.bounds.width > first.bounds.height
            }
            if checks["split_interaction_\(name)_axis_mounted"] != true { continue }
        }
        let label = "Resize split between \(fixture.names[fixture.tabs[divider]]!) and \(fixture.names[fixture.tabs[divider + 1]]!)"
        checks["split_interaction_\(name)_divider_found"] = await splitInteractionWait {
            splitInteractionElement(in: host, label: label) != nil
        }
        guard let element = splitInteractionElement(in: host, label: label),
              let before = fixture.state.selectedSplitGroup?.weights else { continue }
        let commitCount = fixture.commits.count
        let beforeLengths = lengths(horizontal: horizontal)
        let invoked = increment ? element.accessibilityPerformIncrement() : element.accessibilityPerformDecrement()
        checks["split_interaction_\(name)_action_accepted"] = invoked
        checks["split_interaction_\(name)_callback_arrived"] = await splitInteractionWait {
            fixture.commits.count > commitCount
        }
        checks["split_interaction_\(name)_mounted_geometry_changed"] = await splitInteractionWait {
            host.layoutSubtreeIfNeeded()
            let current = lengths(horizontal: horizontal)
            guard current.count == 4, beforeLengths.count == 4 else { return false }
            return increment ? current[divider] > beforeLengths[divider] + 1 : current[divider] < beforeLengths[divider] - 1
        }
        // Observe a bounded quiet interval, rather than accepting the first
        // callback while a duplicate model mutation is still queued.
        try? await Task.sleep(for: .milliseconds(100))
        let after = fixture.state.selectedSplitGroup?.weights ?? []
        checks["split_interaction_\(name)_single_commit"] = fixture.commits.count == commitCount + 1 && fixture.accepted.last == true
        checks["split_interaction_\(name)_finite_normalized"] = after.count == 4 && after.allSatisfy { $0.isFinite && $0 > 0 } && near(after.reduce(0, +), 1)
        if after.count == 4, before.count == 4 {
            checks["split_interaction_\(name)_adjacent_pair_only"] = near(after[divider] + after[divider + 1], before[divider] + before[divider + 1]) && before.indices.filter { $0 != divider && $0 != divider + 1 }.allSatisfy { near(before[$0], after[$0]) }
            checks["split_interaction_\(name)_requested_direction"] = increment ? after[divider] > before[divider] : after[divider] < before[divider]
        } else {
            checks["split_interaction_\(name)_adjacent_pair_only"] = false
            checks["split_interaction_\(name)_requested_direction"] = false
        }
        checks["split_interaction_\(name)_same_mounted_views"] = fixture.tabs.compactMap { fixture.views[$0].map(ObjectIdentifier.init) } == originalViews
        NSLog("Split interaction %@: action=%d commits=%ld before=%@ after=%@", name, invoked ? 1 : 0, fixture.commits.count - commitCount, String(describing: before), String(describing: after))
    }
    return checks
}
