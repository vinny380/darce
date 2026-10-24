import Foundation
import WebKit

@MainActor
private final class BoostPickerHandler: NSObject, WKScriptMessageHandler {
    let name = "browserBoostPicker" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    weak var webView: WKWebView?
    var completion: ((String?) -> Void)?
    var navigationObservation: NSKeyValueObservation?

    init(webView: WKWebView, completion: @escaping (String?) -> Void) {
        self.webView = webView
        self.completion = completion
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == name, message.frameInfo.isMainFrame, message.webView === webView else { return }
        finish(message.body as? String)
    }

    func finish(_ selector: String?) {
        guard let completion else { return }
        self.completion = nil
        navigationObservation?.invalidate(); navigationObservation = nil
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
            BoostElementPicker.handlers.removeValue(forKey: ObjectIdentifier(webView))
            webView.evaluateJavaScript("window.__browserPrototypePickerCancel?.();") { _, _ in }
        }
        completion(selector)
    }
}

@MainActor
enum BoostElementPicker {
    fileprivate static var handlers: [ObjectIdentifier: BoostPickerHandler] = [:]

    static func cancel(in webView: WKWebView) {
        handlers[ObjectIdentifier(webView)]?.finish(nil)
    }

    static func begin(in webView: WKWebView, completion: @escaping (String?) -> Void) {
        let key = ObjectIdentifier(webView)
        handlers[key]?.finish(nil)
        let handler = BoostPickerHandler(webView: webView, completion: completion)
        handlers[key] = handler
        webView.configuration.userContentController.add(handler, name: handler.name)
        handler.navigationObservation = webView.observe(\.url, options: [.new]) { [weak handler] _, _ in
            Task { @MainActor in handler?.finish(nil) }
        }
        // Handler name is generated locally using alphanumeric characters only.
        let source = """
        (() => {
          window.__browserPrototypePickerCancel?.();
          const name = '\(handler.name)';
          const overlay = document.createElement('div');
          overlay.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #3139fb;background:#3139fb22;z-index:2147483647;box-sizing:border-box;';
          document.documentElement.appendChild(overlay);
          let finished = false;
          function path(element) {
            const parts = [];
            while (element && element.nodeType === 1) {
              if (element.id && document.querySelectorAll('#' + CSS.escape(element.id)).length === 1) {
                parts.unshift('#' + CSS.escape(element.id)); break;
              }
              let segment = CSS.escape(element.localName);
              const parent = element.parentElement;
              if (parent) {
                const peers = [...parent.children].filter(node => node.localName === element.localName);
                if (peers.length > 1) segment += ':nth-of-type(' + (peers.indexOf(element) + 1) + ')';
              }
              parts.unshift(segment); element = parent;
            }
            return parts.join(' > ');
          }
          function finish(selector) {
            if (finished) return;
            finished = true;
            document.removeEventListener('mousemove', move, true);
            document.removeEventListener('click', click, true);
            document.removeEventListener('keydown', key, true);
            window.removeEventListener('pagehide', cancel, true);
            overlay.remove();
            delete window.__browserPrototypePickerCancel;
            try { window.webkit.messageHandlers[name].postMessage(selector); } catch (_) {}
          }
          function move(event) {
            if (!(event.target instanceof Element)) return;
            const rect = event.target.getBoundingClientRect();
            Object.assign(overlay.style, {left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
          }
          function click(event) {
            event.preventDefault(); event.stopImmediatePropagation();
            finish(event.target instanceof Element ? path(event.target) : null);
          }
          function key(event) { if (event.key === 'Escape') {event.preventDefault();event.stopImmediatePropagation();finish(null);} }
          function cancel() { finish(null); }
          window.__browserPrototypePickerCancel = cancel;
          document.addEventListener('mousemove', move, true);
          document.addEventListener('click', click, true);
          document.addEventListener('keydown', key, true);
          window.addEventListener('pagehide', cancel, true);
        })();
        """
        webView.evaluateJavaScript(source) { [weak handler] _, error in
            if error != nil { handler?.finish(nil) }
        }
    }
}
