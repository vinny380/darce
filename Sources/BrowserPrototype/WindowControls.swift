import AppKit
import SwiftUI

/// Shows or hides the window's close/minimize/zoom buttons, fading them like Arc does when the pointer
/// reaches the sidebar's top row. Hidden buttons are also made unclickable, so nothing invisible can close the window.
/// In full screen the buttons belong to the system's reveal bar, so they are always left visible there.
struct WindowControlsVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.visible = visible }

    final class ControlsView: NSView {
        var visible = false { didSet { if visible != oldValue { DispatchQueue.main.async { self.apply(animated: true) } } } }
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(animated: false) }
                })
            }
            DispatchQueue.main.async { self.apply(animated: false) }
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            let show = visible || window.styleMask.contains(.fullScreen)
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            if show { buttons.forEach { $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.18 : 0
                buttons.forEach { $0.animator().alphaValue = show ? 1 : 0 }
            } completionHandler: {
                if !show, buttons.first?.alphaValue == 0 { buttons.forEach { $0.isHidden = true } }
            }
        }
    }
}

/// Reports when the pointer enters or leaves this view's area by position alone, so the window buttons drawn on
/// top of it (which SwiftUI hover would treat as leaving) still count as inside. Never reports inside in full
/// screen, where there are no window buttons to make room for.
struct PointerRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        private var fullScreenObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fullScreenObserver.map(NotificationCenter.default.removeObserver)
            fullScreenObserver = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(false) }
                }
            }
        }

        override func mouseEntered(with event: NSEvent) { onChange?(!(window?.styleMask.contains(.fullScreen) ?? false)) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

/// Whether any menu (menu bar, context menu, pop-up) is open right now.
@MainActor
enum MenuTracking {
    private(set) static var isOpen = false
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isOpen = true }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { isOpen = false }
            },
        ]
    }
}
