import AppKit
import BrowserCore
import SwiftUI
import WebKit

/// Opens WebKit's Web Inspector panels from D'arce's own buttons and shortcuts.
/// WebKit has no public API for this, so it calls the inspector object WKWebView keeps internally, checking each
/// method exists first: on a WebKit without it the developer buttons simply disappear (`isAvailable` is false),
/// and right-click ▸ Inspect Element keeps working.
@MainActor
enum WebInspector {
    enum Panel: String { case tools = "show", console = "showConsole", resources = "showResources", pickElement = "toggleElementSelection" }

    static func isAvailable(_ webView: WKWebView) -> Bool { inspector(of: webView) != nil }

    /// The inspector only attaches to pages created with WebKit's developer extras on (also what puts
    /// Inspect Element in the right-click menu).
    static func enableDeveloperExtras(_ configuration: WKWebViewConfiguration) {
        if configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
    }

    /// Docks the inspector beside the page (see `WebContainer`). Connect first; panel calls do nothing until then.
    static func open(_ panel: Panel, in webView: WKWebView) {
        guard let inspector = inspector(of: webView) else { return }
        for name in ["connect", "show"] + (panel == .tools ? [] : [panel.rawValue]) {
            let selector = NSSelectorFromString(name)
            if inspector.responds(to: selector) { inspector.perform(selector) }
        }
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }
}

extension BrowserModel {
    var selectedPage: BrowserPage? { state.selectedTabID.flatMap { page(for: $0) } }
    private var selectedHost: String? { (selectedPage?.webView.url ?? state.selectedTab?.url)?.host }

    /// Arc's per-site Developer Mode (⌃D) for the site in the selected tab.
    var isDeveloperModeOn: Bool { selectedHost.map { settings.state.isDeveloperMode(host: $0) } ?? false }

    func isDeveloperTab(_ tab: BrowserTab) -> Bool {
        tab.url.host.map { settings.state.isDeveloperMode(host: $0) } ?? false
    }

    func toggleDeveloperMode() {
        guard let host = selectedHost else { return }
        settings.update { $0.toggleDeveloperMode(host: host) }
    }

    func openInspector(_ panel: WebInspector.Panel) {
        if let page = selectedPage { WebInspector.open(panel, in: page.webView) }
    }

    /// Developer Mode's reload menu: "Clear Cookies and Refresh" drops this site's cookies, then reloads.
    func clearCookiesAndReload() {
        guard let page = selectedPage, let host = page.webView.url?.host?.lowercased() else { return }
        let store = page.webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            let group = DispatchGroup()
            for cookie in matching { group.enter(); store.delete(cookie) { group.leave() } }
            group.notify(queue: .main) { page.webView.reloadFromOrigin() }
        }
    }
}

/// Arc's developer bar (ContentPanel): diagonal stripes in the Space's color across the top of the page, with
/// copy and capture on the left of the tools, then console, network, inspect, extensions and site settings.
struct DeveloperBar: View {
    @ObservedObject var model: BrowserModel
    let page: BrowserPage
    let tint: Color
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            Text(Self.label(for: page.webView.url))
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 12)
            Spacer()
            barButton(copied ? "checkmark" : "link", "Copy link button") {
                guard let url = page.webView.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
            barButton("camera", "Capture page to clipboard") { capture() }
            separator
            if WebInspector.isAvailable(page.webView) {
                barButton("terminal", "Developer console (⌥⌘J)") { model.openInspector(.console) }
                barButton("network", "Toggle Network Panel") { model.openInspector(.resources) }
                barButton("scope", "Inspect element (⌥⌘C)") { model.openInspector(.pickElement) }
                separator
            }
            barButton("puzzlepiece.extension", "Extensions") { model.siteControlsVisible = true }
            barButton("slider.horizontal.3", "View Site Settings") { model.siteControlsVisible = true }
        }
        .padding(.trailing, 8).frame(height: 34)
        .background(Stripes(background: Self.barColor(tint), foreground: .white.opacity(0.12)))
        .foregroundStyle(.white)
    }

    /// The Space's color, deepened so white icons stay readable even on pale themes (Arc's bar is a strong tint).
    static func barColor(_ tint: Color) -> Color {
        guard let rgb = NSColor(tint).usingColorSpace(.sRGB) else { return tint }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: max(saturation, 0.55), brightness: min(max(brightness, 0.4), 0.62))
    }

    /// "localhost:3000", or the site's host.
    private static func label(for url: URL?) -> String {
        guard let url, let host = url.host else { return "" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 16).padding(.horizontal, 6) }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func capture() {
        Task {
            guard let data = await model.captureCurrentPage(profileID: model.state.selectedProfileID), let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }
}

/// Arc draws its developer stripes in code (StripesConfig: background, foreground, degrees, barWidth, barSpacing).
/// Its numbers weren't recovered; these are D'arce's.
struct Stripes: View {
    let background: Color
    let foreground: Color
    var degrees = 45.0
    var barWidth: CGFloat = 10
    var barSpacing: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            let step = barWidth + barSpacing
            let run = size.height / tan(degrees * .pi / 180)
            var x = -run
            while x < size.width + run {
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: size.height))
                bar.addLine(to: CGPoint(x: x + run, y: 0))
                bar.addLine(to: CGPoint(x: x + run + barWidth, y: 0))
                bar.addLine(to: CGPoint(x: x + barWidth, y: size.height))
                bar.closeSubpath()
                context.fill(bar, with: .color(foreground))
                x += step
            }
        }
    }
}
