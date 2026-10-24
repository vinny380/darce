import AppKit
import SwiftUI

/// Shows or hides the window's close/minimize/zoom buttons, fading them like Arc does when the pointer
/// reaches the sidebar's top row. Hidden buttons are also made unclickable, so nothing invisible can close the window.
struct WindowControlsVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let visible = visible
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            if visible { buttons.forEach { $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
            } completionHandler: {
                if !visible, buttons.first?.alphaValue == 0 { buttons.forEach { $0.isHidden = true } }
            }
        }
    }
}

/// Reports when the pointer enters or leaves this view's area by position alone, so the window buttons drawn on
/// top of it (which SwiftUI hover would treat as leaving) still count as inside.
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

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
