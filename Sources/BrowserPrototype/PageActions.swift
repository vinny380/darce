import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The sheet callback and parent-window close notification may both arrive.
@MainActor
private final class PageSheetCompletion<Value: Sendable> {
    private var completion: ((Value) -> Void)?
    private var observer: NSObjectProtocol?

    init(window: NSWindow, sheet: NSWindow, cancelled: Value, completion: @escaping (Value) -> Void) {
        self.completion = completion
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window, weak sheet] _ in
            MainActor.assumeIsolated {
                self?.finish(cancelled)
                if let sheet, sheet.sheetParent != nil { window?.endSheet(sheet, returnCode: .cancel) }
            }
        }
    }

    func finish(_ value: Value) {
        guard let completion else { return }
        self.completion = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        completion(value)
    }
}

extension BrowserPage {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(); return }
        let alert = websiteAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        let completion = PageSheetCompletion(window: window, sheet: alert.window, cancelled: (), completion: { _ in completionHandler() })
        alert.beginSheetModal(for: window) { _ in completion.finish(()) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(false); return }
        let alert = websiteAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let completion = PageSheetCompletion(window: window, sheet: alert.window, cancelled: false, completion: completionHandler)
        alert.beginSheetModal(for: window) { completion.finish($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(nil); return }
        let alert = websiteAlert(prompt, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        field.setAccessibilityLabel("Website prompt response")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let completion = PageSheetCompletion<String?>(window: window, sheet: alert.window, cancelled: nil, completion: completionHandler)
        alert.beginSheetModal(for: window) { completion.finish($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose Files for \(websiteHost(frame))"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let completion = PageSheetCompletion<[URL]?>(window: window, sheet: panel, cancelled: nil, completion: completionHandler)
        panel.beginSheetModal(for: window) { completion.finish($0 == .OK ? panel.urls : nil) }
    }

    private func websiteHost(_ frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? "This Website" : frame.securityOrigin.host
    }

    private func websiteAlert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "\(websiteHost(frame)) says"
        alert.informativeText = message
        return alert
    }

    func printPage() {
        guard let window = webView.window, window.attachedSheet == nil else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func savePDF() {
        guard let window = webView.window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Page as PDF"
        panel.allowedContentTypes = [.pdf]
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Page"
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = String((safeTitle.isEmpty ? "Page" : safeTitle).prefix(120)) + ".pdf"
        let completion = PageSheetCompletion<URL?>(window: window, sheet: panel, cancelled: nil) { [weak self] url in
            guard let self, let url else { return }
            self.webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                do {
                    let data = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try data.write(to: url, options: .atomic)
                } catch { self?.failure = "PDF could not be saved: \(error.localizedDescription)" }
            }
        }
        panel.beginSheetModal(for: window) { completion.finish($0 == .OK ? panel.url : nil) }
    }
}

struct FindBar: View {
    @ObservedObject var page: BrowserPage
    let close: () -> Void
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var matchFound: Bool?
    @State private var request = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Page", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { search() }
                .accessibilityLabel("Find in page")
            if !query.isEmpty, let matchFound {
                Text(matchFound ? "Match found" : "Not found")
                    .font(.caption).foregroundStyle(matchFound ? Color.secondary : Color.red)
                    .fixedSize()
            }
            Toggle("Match Case", isOn: $caseSensitive).toggleStyle(.button).font(.caption)
                .accessibilityLabel("Match case")
            Button { search(backwards: true) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous Match (⇧⌘G)").accessibilityLabel("Previous match").disabled(query.isEmpty)
            Button { search() } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: [.command])
                .help("Next Match (⌘G)").accessibilityLabel("Next match").disabled(query.isEmpty)
            Button("Done") { close() }.keyboardShortcut(.cancelAction)
        }
        .padding(10).background(.regularMaterial)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in search() }
        .onChange(of: caseSensitive) { _, _ in search() }
        .onChange(of: ObjectIdentifier(page)) { _, _ in search() }
        .onExitCommand { close() }
        .onDisappear {
            request = UUID()
            page.webView.find("", configuration: WKFindConfiguration()) { _ in }
        }
    }

    private func search(backwards: Bool = false) {
        let token = UUID()
        request = token
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = caseSensitive
        config.wraps = true
        page.webView.find(query, configuration: config) { result in
            guard request == token else { return }
            matchFound = query.isEmpty ? nil : result.matchFound
        }
    }
}

/// Pass the loaded "Native browser smoke" synthetic fixture; no dialogs or printer run.
@MainActor
func runPageActionsSmoke(page: BrowserPage) async -> [String: Bool] {
    func find(_ text: String, backwards: Bool = false) async -> Bool {
        let config = WKFindConfiguration()
        config.wraps = true
        config.backwards = backwards
        return await withCheckedContinuation { continuation in
            page.webView.find(text, configuration: config) { continuation.resume(returning: $0.matchFound) }
        }
    }
    var checks: [String: Bool] = [:]
    checks["native_find_matches_fixture"] = await find("Native browser smoke")
    checks["native_find_backwards_wraps"] = await find("Native browser smoke", backwards: true)
    checks["native_find_miss"] = !(await find("nonexistent-fixture-token-375A"))
    let pdf: Data? = await withCheckedContinuation { continuation in
        page.webView.createPDF(configuration: WKPDFConfiguration()) { result in
            continuation.resume(returning: try? result.get())
        }
    }
    checks["native_pdf_has_valid_header"] = pdf.map { $0.starts(with: Data("%PDF-".utf8)) && $0.count > 100 } ?? false
    page.webView.find("", configuration: WKFindConfiguration()) { _ in }
    return checks
}
