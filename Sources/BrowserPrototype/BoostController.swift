import BrowserCore
import Combine
import CryptoKit
import Foundation
import SwiftUI
import WebKit

@MainActor
final class BoostController: ObservableObject {
    @Published private(set) var boosts: [BrowserBoost] = []
    /// Settings → Advanced → Enable Boosts. Off injects an empty boost script, which removes any applied ones.
    var globallyEnabled = true
    @Published var errorMessage: String?
    let recoveryRequired: Bool
    var onChange: (() -> Void)?
    private var store: BoostStore?

    init(directory: URL) {
        do {
            let loaded = try BoostStore(fileURL: directory.appendingPathComponent("boosts.json"))
            store = loaded
            boosts = loaded.boosts
            recoveryRequired = false
        } catch {
            recoveryRequired = true
            errorMessage = "Boosts could not be loaded. Saving is disabled to preserve the file. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ boost: BrowserBoost) -> Bool {
        guard var candidate = store else { return false }
        do {
            try candidate.save(boost)
            store = candidate; boosts = candidate.boosts; errorMessage = nil
            onChange?()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func remove(id: UUID, profileID: UUID) -> Bool {
        guard var candidate = store else { return false }
        do {
            try candidate.remove(id: id, profileID: profileID)
            store = candidate; boosts = candidate.boosts; errorMessage = nil
            onChange?()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func script(profileID: UUID) throws -> String {
        let payload: [[String: Any]] = boosts.filter { globallyEnabled && $0.profileID == profileID && $0.enabled }.map {
            ["id": $0.id.uuidString, "host": $0.host, "css": $0.css + "\n" + BoostStyle.css(for: $0),
             "matrix": BoostStyle.colorMatrix(for: $0).map { $0.map { String(format: "%.4f", $0) }.joined(separator: " ") } ?? "",
             "filterID": BoostStyle.filterID(for: $0) ?? "",
             "javascript": $0.javascript ?? "", "selectors": $0.hiddenSelectors,
             "scriptVersion": SHA256.hash(data: Data(($0.javascript ?? "").utf8)).map { String(format: "%02x", $0) }.joined()]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return Self.scriptMarker + "\n" + """
        (() => {
          const boosts = \(json);
          const owned = 'data-browser-prototype-boost';
          document.querySelectorAll('style[' + owned + ']').forEach(node => node.remove());
          document.querySelectorAll('svg[data-darce-boost-colors]').forEach(node => node.remove());
          if (!['http:', 'https:'].includes(location.protocol)) return;
          const executed = window.__browserPrototypeBoostExecutions ||= new Set();
          for (const boost of boosts) {
            if (location.hostname.toLowerCase() !== boost.host) continue;
            const style = document.createElement('style');
            style.setAttribute(owned, boost.id);
            let hiding = '';
            for (const selector of boost.selectors) {
              try { document.querySelector(selector); hiding += '\\n' + selector + '{display:none!important;}'; }
              catch (_) { /* Invalid selectors have no effect. */ }
            }
            style.textContent = boost.css + hiding;
            (document.head || document.documentElement).appendChild(style);
            if (boost.matrix) {
              // Arc recolors with a native 4×5 color matrix; WebKit gets the same through an SVG filter.
              const ns = 'http://www.w3.org/2000/svg';
              const svg = document.createElementNS(ns, 'svg');
              svg.setAttribute('data-darce-boost-colors', boost.id);
              svg.setAttribute('style', 'position:absolute;width:0;height:0;pointer-events:none');
              const filter = document.createElementNS(ns, 'filter');
              filter.setAttribute('id', boost.filterID);
              filter.setAttribute('color-interpolation-filters', 'sRGB');
              const matrix = document.createElementNS(ns, 'feColorMatrix');
              matrix.setAttribute('type', 'matrix');
              matrix.setAttribute('values', boost.matrix);
              filter.appendChild(matrix);
              svg.appendChild(filter);
              document.documentElement.appendChild(svg);
            }
            const execution = boost.id + ':' + boost.scriptVersion;
            if (boost.javascript && !executed.has(execution)) {
              executed.add(execution);
              try { (new Function(boost.javascript)).call(window); }
              catch (error) { console.error('User-authored Boost failed:', error); }
            }
          }
        })();
        """
    }

    static let scriptMarker = "// browser-prototype-owned-boosts-v1"
}

extension BrowserPage {
    func applyBoosts(controller: BoostController, profileID: UUID, completion: ((Error?) -> Void)? = nil) {
        do {
            let source = try controller.script(profileID: profileID)
            let content = webView.configuration.userContentController
            // WebKit has no individual remove-user-script API. Preserve every other script.
            let unrelated = content.userScripts.filter { !$0.source.hasPrefix(BoostController.scriptMarker) }
            content.removeAllUserScripts()
            unrelated.forEach { content.addUserScript($0) }
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            webView.evaluateJavaScript(source) { _, error in completion?(error) }
        } catch { completion?(error) }
    }

    func beginElementPicker(completion: @escaping (String?) -> Void) {
        BoostElementPicker.begin(in: webView, completion: completion)
    }

    func cancelElementPicker() {
        BoostElementPicker.cancel(in: webView)
    }
}

struct BoostEditor: View {
    @ObservedObject var controller: BoostController
    let profileID: UUID
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var name = "My Boost"
    @State private var css = ""
    @State private var javascript = ""
    @State private var scripting = false
    @State private var selectors = ""
    @State private var enabled = true
    @State private var confirmingDelete = false
    @State private var saved = false

    private var host: String { (url.host ?? "").lowercased() }
    private var matches: [BrowserBoost] { controller.boosts.filter { $0.profileID == profileID && $0.host == host } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Boosts").font(.title2.bold())
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Boost") { load(nil) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !matches.isEmpty {
                Picker("Saved Boost", selection: $selectedID) {
                    Text("New Boost").tag(UUID?.none)
                    ForEach(matches) { Text($0.name).tag(Optional($0.id)) }
                }.onChange(of: selectedID) { _, id in load(matches.first { $0.id == id }) }
            }
            HStack {
                TextField("Boost name", text: $name)
                Toggle("Enabled", isOn: $enabled)
            }
            Text("Custom CSS").font(.headline)
            TextEditor(text: $css).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
                .border(Color.secondary.opacity(0.25)).accessibilityLabel("Custom CSS")
            Text("Hide elements · one CSS selector per line").font(.caption)
            TextEditor(text: $selectors).font(.system(.body, design: .monospaced)).frame(height: 55)
                .border(Color.secondary.opacity(0.25)).accessibilityLabel("Hidden element selectors")
            Toggle("Run my JavaScript on this site", isOn: $scripting)
            if scripting {
                Text("Runs code you enter in this profile on this exact host. Reload the page to undo script effects.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $javascript).font(.system(.body, design: .monospaced)).frame(height: 90)
                    .border(Color.secondary.opacity(0.25)).accessibilityLabel("User-authored JavaScript")
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if selectedID != nil { Button("Delete Boost…", role: .destructive) { confirmingDelete = true } }
                Spacer()
                if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                Button("Save Boost") { save() }.keyboardShortcut("s", modifiers: .command)
                    .disabled(host.isEmpty || controller.recoveryRequired)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 640)
            .onAppear { if let first = matches.first { load(first) } }
            .alert("Delete this Boost?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let selectedID, controller.remove(id: selectedID, profileID: profileID) { load(nil) }
                }
            } message: { Text("Its saved CSS, selectors, and JavaScript will be removed. Reload to undo previous JavaScript effects.") }
    }

    private func load(_ boost: BrowserBoost?) {
        selectedID = boost?.id; name = boost?.name ?? "My Boost"; css = boost?.css ?? ""
        javascript = boost?.javascript ?? ""; scripting = boost?.javascript != nil
        selectors = boost?.hiddenSelectors.joined(separator: "\n") ?? ""; enabled = boost?.enabled ?? true
        saved = false
    }

    private func save() {
        let boost = BrowserBoost(id: selectedID ?? UUID(), profileID: profileID, host: host,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Boost" : name,
            enabled: enabled, css: css, javascript: scripting ? javascript : nil,
            hiddenSelectors: selectors.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if controller.save(boost) { selectedID = boost.id; saved = true }
    }
}
