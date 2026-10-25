import AppKit
import BrowserCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Arc's Library (⇧⌘L, or the sidebar's bottom-left button): it takes over the sidebar with a rail of categories
/// and a searchable list grouped by date. ← returns to the tabs.
enum LibraryCategory: String, CaseIterable, Identifiable {
    case media, downloads, easels, spaces, boosts, archivedTabs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: "Media"
        case .downloads: "Downloads"
        case .easels: "Easels"
        case .spaces: "Spaces"
        case .boosts: "Boosts"
        case .archivedTabs: "Archived Tabs"
        }
    }
    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle.fill"
        case .easels: "scribble.variable"
        case .spaces: "rectangle.stack"
        case .boosts: "wand.and.sparkles"
        case .archivedTabs: "archivebox"
        }
    }
    var searchPrompt: String { "Search \(title)…" }
}

struct LibraryView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var documents: DocumentController
    @ObservedObject var boosts: BoostController
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var downloadFilter = DownloadKind.all

    var body: some View {
        HStack(spacing: 0) {
            rail
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(model.libraryCategory.searchPrompt, text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if model.libraryCategory == .downloads || model.libraryCategory == .media {
                        Menu {
                            Picker("Show", selection: $downloadFilter) {
                                ForEach(DownloadKind.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.inline)
                        } label: {
                            Label("Filter", systemImage: "line.3.horizontal.decrease.circle").font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 10).frame(height: 36)
                                .background(Palette.color("SidebarItemBackground", scheme: scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                }
                ScrollView { content.padding(.bottom, 12) }.scrollIndicators(.hidden)
            }
            .padding(.top, 38).padding(.trailing, 8)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .onChange(of: model.libraryCategory) { _, _ in query = "" }
    }

    private var rail: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 40)
            ForEach(LibraryCategory.allCases) { category in
                let selected = model.libraryCategory == category
                VStack(spacing: 6) {
                    Image(systemName: category.symbol).font(.system(size: 20))
                        .foregroundStyle(selected && category == .downloads ? Color.accentColor : .primary.opacity(0.8))
                    Text(category.title).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center)
                }
                .frame(width: 84, height: 72)
                .background(selected ? Palette.color("SidebarItemHovered", scheme: scheme) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.libraryCategory = category }
                .accessibilityAddTraits(.isButton).accessibilityLabel(category.title)
            }
            Spacer()
            Button { model.libraryOpen = false } label: {
                Image(systemName: "arrow.left").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Back to tabs (⇧⌘L)").padding(.bottom, 12)
        }
        .padding(.horizontal, 6).frame(width: 96)
    }

    @ViewBuilder private var content: some View {
        switch model.libraryCategory {
        case .downloads: downloadsList
        case .media: mediaGrid
        case .easels: easelsList
        case .spaces: spacesList
        case .boosts: boostsList
        case .archivedTabs: archivedList
        }
    }

    private func matches(_ texts: String?...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || texts.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }

    private func header(_ label: String) -> some View {
        Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 2).padding(.leading, 6)
    }

    private func empty(_ text: String) -> some View {
        Text(query.isEmpty ? text : "No matches").font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: Downloads and media

    private var profileDownloads: [DownloadRecord] { downloads.records(for: model.state.selectedProfileID) }

    private var downloadsList: some View {
        let items = profileDownloads.filter { downloadFilter.includes($0) && matches($0.filename, $0.sourceURL?.host) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { empty("Files you download will appear here.") }
            ForEach(LibraryGroup.group(items, date: \.createdAt), id: \.label) { group in
                header(group.label)
                ForEach(group.items) { record in
                    LibraryRow(title: record.filename, subtitle: Self.describe(record)) {
                        FileThumbnail(url: record.destinationURL, size: 34)
                    }
                    .onTapGesture { if let url = record.destinationURL { NSWorkspace.shared.open(url) } }
                    .contextMenu {
                        Button("Open") { if let url = record.destinationURL { NSWorkspace.shared.open(url) } }.disabled(record.destinationURL == nil)
                        Button("Show in Finder") { downloads.reveal(record.id) }.disabled(record.destinationURL == nil)
                        if let source = record.sourceURL { Button("Copy Download Link") { Self.copy(source.absoluteString) } }
                    }
                }
            }
        }
    }

    private var mediaGrid: some View {
        let images = profileDownloads.filter { record in
            DownloadKind.images.includes(record) && matches(record.filename, record.sourceURL?.host)
                && record.destinationURL.map { FileManager.default.fileExists(atPath: $0.path) } == true  // skip files deleted since
        }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if images.isEmpty { empty("Images you download will appear here.") }
            ForEach(LibraryGroup.group(images, date: \.createdAt), id: \.label) { group in
                header(group.label)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(group.items) { record in
                        FileThumbnail(url: record.destinationURL, size: 120)
                            .frame(maxWidth: .infinity).frame(height: 110)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .help(record.filename)
                            .onTapGesture { if let url = record.destinationURL { NSWorkspace.shared.open(url) } }
                            .contextMenu { Button("Show in Finder") { downloads.reveal(record.id) } }
                    }
                }
            }
        }
    }

    /// "PDF from docusign.com", like Arc.
    static func describe(_ record: DownloadRecord) -> String {
        if record.status != .completed { return record.status.rawValue.capitalized }
        let type = UTType(filenameExtension: (record.filename as NSString).pathExtension)
        let kind = type.flatMap { $0.conforms(to: .pdf) ? "PDF" : $0.conforms(to: .image) ? "Image" : $0.conforms(to: .diskImage) ? "Disk Image" : $0.localizedDescription } ?? "Download"
        guard let host = record.sourceURL?.host else { return kind }
        return "\(kind) from \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
    }

    // MARK: Easels, Spaces, Boosts, Archived Tabs

    private var easelsList: some View {
        let items = documents.documents(profileID: model.state.selectedProfileID).filter { matches($0.title, $0.text) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { empty("Easels and notes you make will appear here.") }
            ForEach(LibraryGroup.group(items, date: \.updatedAt), id: \.label) { group in
                header(group.label)
                ForEach(group.items) { document in
                    LibraryRow(title: document.title, subtitle: document.kind == .note ? "Note" : "Easel") {
                        Image(systemName: document.kind == .note ? "note.text" : "scribble.variable").font(.system(size: 18)).frame(width: 34, height: 34)
                    }
                    .onTapGesture {
                        if document.kind == .easel { model.openEasel(document.id); model.libraryOpen = false } else { model.panel = .documents }
                    }
                }
            }
        }
    }

    private var spacesList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.state.spaces.filter { matches($0.name) }) { space in
                let tabs = model.state.tabs.filter { $0.spaceID == space.id && $0.kind != .archived }.count
                LibraryRow(title: space.name, subtitle: tabs == 1 ? "1 tab" : "\(tabs) tabs",
                           selected: space.id == model.state.selectedSpaceID) {
                    Image(systemName: model.appearance.state.space(space.id).icon).font(.system(size: 17)).frame(width: 34, height: 34)
                }
                .onTapGesture { model.selectSpace(space.id); model.libraryOpen = false }
                .contextMenu { Button("Rename…") { model.spacePrompt = .rename(space.id) } }
            }
            Button("Manage Spaces…") { model.panel = .spaces }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .font(.system(size: 13, weight: .medium)).padding(.top, 14).padding(.leading, 8)
        }
    }

    private var boostsList: some View {
        let items = boosts.boosts.filter { $0.profileID == model.state.selectedProfileID && matches($0.name, $0.host) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { empty("Boosts you make will appear here. Open a site and choose New Boost.") }
            ForEach(items) { boost in
                LibraryRow(title: boost.name, subtitle: boost.host) {
                    SiteIcon(controller: model.favicons, url: URL(string: "https://\(boost.host)")!, profileID: boost.profileID, size: 18)
                        .frame(width: 34, height: 34)
                } accessory: {
                    Toggle("", isOn: Binding(get: { boost.enabled }, set: { var updated = boost; updated.enabled = $0; boosts.save(updated) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().help(boost.enabled ? "Turn off" : "Turn on")
                }
                .onTapGesture { if let url = URL(string: "https://\(boost.host)") { model.open(url); model.libraryOpen = false } }
                .contextMenu { Button("Delete Boost", role: .destructive) { boosts.remove(id: boost.id, profileID: boost.profileID) } }
            }
        }
    }

    private var archivedList: some View {
        let items = model.archivedTabs.filter { matches($0.customTitle ?? $0.title, $0.url.absoluteString) }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty { empty("Tabs you close are kept here, so you can bring them back.") }
            ForEach(LibraryGroup.group(items, date: { $0.archivedAt ?? $0.lastActiveAt }), id: \.label) { group in
                header(group.label)
                ForEach(group.items) { tab in
                    LibraryRow(title: tab.customTitle ?? tab.title, subtitle: tab.url.host ?? tab.url.absoluteString) {
                        SiteIcon(controller: model.favicons, url: tab.url, profileID: model.state.selectedProfileID, size: 18).frame(width: 34, height: 34)
                    } accessory: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .onTapGesture { model.restore(tab.id); model.select(tab.id); model.libraryOpen = false }
                    .help("Restore this tab")
                }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum DownloadKind: String, CaseIterable, Identifiable {
    case all, images, documents, diskImages, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Downloads"
        case .images: "Images"
        case .documents: "Documents"
        case .diskImages: "Disk Images & Archives"
        case .other: "Other"
        }
    }
    func includes(_ record: DownloadRecord) -> Bool {
        let type = UTType(filenameExtension: (record.filename as NSString).pathExtension)
        let image = type?.conforms(to: .image) == true
        let document = type.map { $0.conforms(to: .pdf) || $0.conforms(to: .text) || $0.conforms(to: .presentation) || $0.conforms(to: .spreadsheet) } == true
        let archive = type.map { $0.conforms(to: .diskImage) || $0.conforms(to: .archive) } == true
        switch self {
        case .all: return true
        case .images: return image
        case .documents: return document
        case .diskImages: return archive
        case .other: return !image && !document && !archive
        }
    }
}

private struct LibraryRow<Icon: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    var selected = false
    @ViewBuilder let icon: Icon
    @ViewBuilder var accessory: Accessory
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.horizontal, 8).frame(height: 50)
        .background(selected || hovered ? Palette.color("SidebarItemHovered", scheme: scheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

extension LibraryRow where Accessory == EmptyView {
    init(title: String, subtitle: String, selected: Bool = false, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, subtitle: subtitle, selected: selected, icon: icon, accessory: { EmptyView() })
    }
}

/// The file's own preview, like Finder and Arc, from Quick Look; a document icon while it loads or if there is none.
private struct FileThumbnail: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").font(.system(size: size * 0.5)).foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { image = nil; return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
