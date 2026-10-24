import AppKit
import SwiftUI

/// Follows a two-finger swipe once it is clearly sideways. A swipe that starts vertical stays a scroll,
/// and momentum is never reported, so one flick moves at most one Space.
struct SpaceSwipeTracker {
    enum Update: Equatable { case drag(CGFloat), end(CGFloat, velocity: CGFloat) }
    private enum Axis { case horizontal, vertical }
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var last: CGFloat = 0
    private var axis: Axis?

    /// `fingerDX` is finger travel (negative = left). `.drag` carries total travel; `.end` carries it again
    /// (0 if cancelled) plus the last per-event delta, so the caller can tell a flick from a slow drag.
    mutating func handle(phase: NSEvent.Phase, fingerDX: CGFloat, fingerDY: CGFloat) -> Update? {
        if phase.contains(.began) { dx = 0; dy = 0; last = 0; axis = nil }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            defer { axis = nil }
            guard axis == .horizontal else { return nil }
            return .end(phase.contains(.cancelled) ? 0 : dx, velocity: last)
        }
        guard phase.contains(.began) || phase.contains(.changed), axis != .vertical else { return nil }
        dx += fingerDX
        dy += abs(fingerDY)
        last = fingerDX
        if axis == nil, abs(dx) + dy > 6 { axis = abs(dx) > dy * 1.5 ? .horizontal : .vertical }
        return axis == .horizontal ? .drag(dx) : nil
    }
}

/// Watches trackpad scrolls over the view it backs. Never takes clicks or consumes events.
struct SpaceSwipeMonitor: NSViewRepresentable {
    let onUpdate: (SpaceSwipeTracker.Update) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.onUpdate = onUpdate }

    final class MonitorView: NSView {
        var onUpdate: ((SpaceSwipeTracker.Update) -> Void)?
        private var monitor: Any?
        private var tracker = SpaceSwipeTracker()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard event.window === window, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // Natural scrolling reports finger direction; classic scrolling reports the opposite.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            if let update = tracker.handle(phase: event.phase, fingerDX: sign * event.scrollingDeltaX, fingerDY: event.scrollingDeltaY) {
                onUpdate?(update)
            }
        }
    }
}
