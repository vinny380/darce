import AppKit
import WebKit

/// Report actual responder changes and mouse interaction inside WebKit's private content subviews.
@MainActor
final class FocusReportingWebView: WKWebView {
    var onPaneFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onPaneFocus?() }
        return accepted
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .rightMouseDown {
            // Let WebKit finish dispatching the event before publishing SwiftUI selection.
            DispatchQueue.main.async { [weak self] in
                guard let self, let responder = self.window?.firstResponder as? NSView,
                      responder === self || responder.isDescendant(of: self) else { return }
                self.onPaneFocus?()
            }
        }
        return hit
    }
}
