import AppKit
import BrowserCore
import SwiftUI

/// What ⌥⌘N shows, like Little Arc: Arc's command bar on its own, floating over whatever you're doing.
/// Picking a row opens it in a mini window, or in the mini window whose address pill summoned it.
struct LauncherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let url: URL
    /// An SF Symbol for rows that aren't a site (search); sites show their favicon.
    var symbol: String?
}

@MainActor
enum MiniLauncher {
    /// Nothing typed: Favorites and pinned tabs, then recent sites. Typed: go/search first, then matching tabs and
    /// history. One row per site.
    static func items(for query: String, model: BrowserModel) -> [LauncherItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [LauncherItem] = []
        var hosts = Set<String>()
        func add(_ url: URL, _ title: String) {
            guard let host = url.host?.lowercased(), hosts.insert(host).inserted else { return }
            items.append(LauncherItem(id: url.absoluteString, title: siteName(title, host: host), detail: displayHost(host), url: url))
        }
        if !text.isEmpty, let url = model.destination(text) {
            let engine = model.settings.state.searchEngine(forProfile: model.state.selectedProfileID)
            let isSearch = url.host == engine.searchURL(for: "q").host && !text.lowercased().contains(url.host ?? "\u{0}")
            items.append(LauncherItem(id: "go", title: text, detail: isSearch ? "Search \(engine.name)" : "Go to website",
                                      url: url, symbol: isSearch ? "magnifyingglass" : "globe"))
            if !isSearch, let host = url.host?.lowercased() { hosts.insert(host) }
        }
        let tabs = model.state.visibleTabs
        let saved = tabs.filter { $0.kind == .favorite || $0.kind == .pinned }
        for tab in text.isEmpty ? saved : tabs {
            let title = tab.customTitle ?? tab.title
            if text.isEmpty || title.localizedCaseInsensitiveContains(text) || tab.url.absoluteString.localizedCaseInsensitiveContains(text) {
                add(tab.homeURL ?? tab.url, title)
            }
        }
        for record in model.history?.search(text, profileID: model.state.selectedProfileID, limit: 200) ?? [] { add(record.url, record.title) }
        return Array(items.prefix(text.isEmpty ? 6 : 8))
    }

    static func choose(_ item: LauncherItem, target: MiniBrowser?, model: BrowserModel) {
        if let target { target.navigate(item.url) }
        else { MiniWindows.shared.open(url: item.url, model: model) }
    }

    private static func displayHost(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    /// "GitHub · Change is constant. GitHub keeps you ahead." → "GitHub": Arc lists sites by name, not page title.
    /// Picks the title segment that names the site (matches the domain), else keeps the title as is.
    static func siteName(_ title: String, host: String) -> String {
        let site = displayHost(host).split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "·|—–")).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1, let name = parts.first(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == site }) { return name }
        return title.isEmpty ? displayHost(host) : title
    }
}

/// Borderless so only the rounded bar shows; it still takes keyboard focus.
final class MiniLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MiniLauncherView: View {
    @ObservedObject var model: BrowserModel
    let target: MiniBrowser?
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selected = 0

    private var items: [LauncherItem] { MiniLauncher.items(for: query, model: model) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).frame(width: 24)
                CommandInput(text: $query, scheme: scheme, submit: { choose(selected) },
                             move: { delta in selected = min(max(0, selected + delta), max(0, items.count - 1)) },
                             cancel: close)
                    .frame(height: 32)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plain).help("Close (esc)")
            }
            .padding(.horizontal, 18).frame(height: 64)
            if !items.isEmpty {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5).padding(.horizontal, 11)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in row(item, selected: index == selected)
                        .onTapGesture { choose(index) }.onHover { if $0 { selected = index } }
                    }
                }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            }
        }
        .foregroundStyle(Palette.color("CommandBarTextPrimary", scheme: scheme))
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(scheme == .dark ? AnyShapeStyle(Color(.sRGB, red: 23 / 255, green: 23 / 255, blue: 24 / 255)) : AnyShapeStyle(.regularMaterial))
        }
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(scheme == .dark ? 0.23 : 0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
        .frame(width: 520)
        .padding(40)  // room for the shadow inside the transparent panel
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
                else {
                    SiteIcon(controller: model.favicons, url: item.url, profileID: model.state.selectedProfileID, size: 18)
                }
            }
            .frame(width: 28, height: 28)
            (Text(item.title).foregroundStyle(selected ? Color.white : Palette.color("CommandBarTextPrimary", scheme: scheme))
             + Text("  —  \(item.detail)").foregroundStyle(selected ? Color.white.opacity(0.7) : Palette.color("CommandBarTextSecondary", scheme: scheme)))
                .font(.system(size: 15, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor : .clear).padding(2)
        }
        .contentShape(Rectangle())
    }

    private func choose(_ index: Int) {
        let items = items
        guard items.indices.contains(index) else { return }
        close()
        MiniLauncher.choose(items[index], target: target, model: model)
    }
}
