import AppKit
import BrowserCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var errorMessage: String?
    private(set) var recoveryRequired = false
    private var store: DocumentStore?
    private var images: [UUID: NSImage] = [:]

    init(directory: URL) {
        do { store = try DocumentStore(directory: directory) }
        catch {
            recoveryRequired = true
            errorMessage = "Documents could not be loaded. Saving is disabled to preserve the original files. \(error.localizedDescription)"
        }
    }

    func documents(profileID: UUID, includeTrashed: Bool = false) -> [BrowserDocument] {
        store?.documents(profileID: profileID, includeTrashed: includeTrashed) ?? []
    }

    func document(_ id: UUID, profileID: UUID, includeTrashed: Bool = false) -> BrowserDocument? {
        store?.document(id, profileID: profileID, includeTrashed: includeTrashed)
    }

    @discardableResult
    func create(kind: DocumentKind, profileID: UUID) -> UUID? {
        change { try $0.create(kind: kind, title: "", profileID: profileID) }
    }

    @discardableResult
    func rename(_ id: UUID, profileID: UUID, title: String) -> Bool {
        change { try $0.rename(id, profileID: profileID, title: title); return true } ?? false
    }

    @discardableResult
    func updateNote(_ id: UUID, profileID: UUID, text: String) -> Bool {
        change { try $0.updateNote(id, profileID: profileID, text: text); return true } ?? false
    }

    @discardableResult
    func updateTextCards(_ id: UUID, profileID: UUID, values: [UUID: String]) -> Bool {
        change { try $0.updateTextCards(id, profileID: profileID, values: values); return true } ?? false
    }

    @discardableResult
    func addTextCard(_ id: UUID, profileID: UUID) -> UUID? {
        change { try $0.addTextCard(documentID: id, profileID: profileID) }
    }

    @discardableResult
    func addCapture(_ id: UUID, profileID: UUID, png: Data) -> UUID? {
        do { try DocumentStore.validateCapturePNG(png) }
        catch { report(error.localizedDescription); return nil }
        guard NSImage(data: png) != nil else { report("The page capture could not be read as an image."); return nil }
        return change { try $0.addCaptureCard(documentID: id, profileID: profileID, png: png, altText: "Static page capture") }
    }

    @discardableResult
    func updateCard(_ card: DocumentCard, documentID: UUID, profileID: UUID,
                    x: Double, y: Double, width: Double, height: Double) -> Bool {
        change { try $0.updateCard(card.id, documentID: documentID, profileID: profileID, x: x, y: y, width: width, height: height); return true } ?? false
    }

    @discardableResult
    func trash(_ id: UUID, profileID: UUID) -> Bool {
        change { try $0.trash(id, profileID: profileID); return true } ?? false
    }

    @discardableResult
    func restore(_ id: UUID, profileID: UUID) -> Bool {
        change { try $0.restore(id, profileID: profileID); return true } ?? false
    }

    func image(documentID: UUID, cardID: UUID, profileID: UUID) -> NSImage? {
        guard document(documentID, profileID: profileID, includeTrashed: true)?.cards.contains(where: { $0.id == cardID }) == true else { return nil }
        if let image = images[cardID] { return image }
        guard let data = try? store?.imageData(documentID: documentID, cardID: cardID, profileID: profileID),
              let image = NSImage(data: data) else { return nil }
        images[cardID] = image
        return image
    }

    func exportHTML(_ id: UUID, profileID: UUID) -> String? {
        do { return try store?.exportHTML(id, profileID: profileID) }
        catch { report(error.localizedDescription); return nil }
    }

    func report(_ message: String) { errorMessage = message }

    private func change<Value>(_ operation: (inout DocumentStore) throws -> Value) -> Value? {
        guard !recoveryRequired, var candidate = store else { return nil }
        do {
            let result = try operation(&candidate)
            store = candidate
            revision += 1
            errorMessage = nil
            return result
        } catch {
            errorMessage = "Document could not be saved: \(error.localizedDescription)"
            return nil
        }
    }
}

struct DocumentsView: View {
    @ObservedObject var controller: DocumentController
    let profileID: UUID
    let captureCurrentPage: @MainActor () async -> Data?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var editorProfileID: UUID?
    @State private var noteText = ""
    @State private var cardTexts: [UUID: String] = [:]
    @State private var showTrash = false
    @State private var renamedID: UUID?
    @State private var renameText = ""
    @State private var pendingTrash: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var capturing = false

    private var selected: BrowserDocument? {
        selectedID.flatMap { controller.document($0, profileID: profileID, includeTrashed: true) }
    }

    private var hasUnsavedChanges: Bool {
        guard let selected, selected.trashedAt == nil else { return false }
        if selected.kind == .note { return noteText != selected.text }
        return selected.cards.contains {
            if case .text(let original) = $0.content { return cardTexts[$0.id].map { $0 != original } ?? false }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes & Easels").font(.title2.bold())
                Spacer()
                Menu("New") {
                    Button("Note") { create(.note) }
                    Button("Easel") { create(.easel) }
                }.disabled(controller.recoveryRequired)
                Button("Export HTML…") { exportSelected() }.disabled(selected == nil || selected?.trashedAt != nil)
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            if let error = controller.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                library.frame(width: 230)
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 650)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .onChange(of: noteText) { _, _ in scheduleSave() }
        .onChange(of: cardTexts) { _, _ in scheduleSave() }
        .onChange(of: profileID) { _, _ in
            if flush() { clearSelection() }
        }
        .onDisappear { _ = flush() }
        .alert("Rename Document", isPresented: Binding(get: { renamedID != nil }, set: { if !$0 { renamedID = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renamedID { _ = controller.rename(renamedID, profileID: profileID, title: renameText) }
                renamedID = nil
            }
            Button("Cancel", role: .cancel) { renamedID = nil }
        }
        .confirmationDialog("Move this document to Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard flush(), let id = pendingTrash else { return }
                if controller.trash(id, profileID: profileID), selectedID == id { clearSelection() }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { Text("You can restore it from Trash. Its text and captured images will be kept.") }
    }

    private var library: some View {
        VStack(spacing: 12) {
            Picker("Documents", selection: Binding(get: { showTrash }, set: { trash in
                guard flush() else { return }
                showTrash = trash
                clearSelection()
            })) {
                Text("Library").tag(false)
                Text("Trash").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.top, 14)
            let documents = controller.documents(profileID: profileID, includeTrashed: showTrash)
                .filter { showTrash ? $0.trashedAt != nil : $0.trashedAt == nil }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(documents) { document in
                        Button { open(document) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: document.kind == .note ? "note.text" : "rectangle.3.group")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.title).fontWeight(.medium).lineLimit(2)
                                    Text(document.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == document.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            if document.trashedAt != nil {
                                Button("Restore") { if controller.restore(document.id, profileID: profileID) { showTrash = false; open(document) } }
                            } else {
                                Button("Rename…") { renamedID = document.id; renameText = document.title }
                                Button("Move to Trash…", role: .destructive) { pendingTrash = document.id }
                            }
                        }
                    }
                    if documents.isEmpty { Text(showTrash ? "Trash is empty" : "Create a Note or Easel to get started.").foregroundStyle(.secondary).font(.callout).padding(18) }
                }.padding(.horizontal, 8)
            }
        }.background(.bar)
    }

    @ViewBuilder private var editor: some View {
        if let document = selected {
            if document.trashedAt != nil {
                VStack(spacing: 16) {
                    Text(document.title).font(.title2)
                    Text("This document is in Trash.").foregroundStyle(.secondary)
                    Button("Restore") {
                        if controller.restore(document.id, profileID: profileID) { showTrash = false; open(document) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(document.title).font(.headline).lineLimit(1)
                        Text(hasUnsavedChanges ? "Unsaved changes" : "Saved").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Rename") { renamedID = document.id; renameText = document.title }
                        if document.kind == .easel {
                            Button("Add Text") { if flush() { _ = controller.addTextCard(document.id, profileID: profileID) } }
                            Button(capturing ? "Capturing…" : "Capture Current Page") { capture(document) }.disabled(capturing)
                        }
                    }.padding(14)
                    Divider()
                    if document.kind == .note {
                        TextEditor(text: $noteText).font(.system(size: 15)).padding(14).accessibilityLabel("Note text")
                    } else { easel(document) }
                }.disabled(controller.recoveryRequired)
            }
        } else {
            ContentUnavailableView("Notes & Easels", systemImage: "note.text", description: Text("Choose a document, or create a Note or Easel."))
        }
    }

    private func easel(_ document: BrowserDocument) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                ForEach(document.cards) { card in
                    EaselCardView(card: card, text: Binding(
                        get: {
                            if let draft = cardTexts[card.id] { return draft }
                            if case .text(let text) = card.content { return text }
                            return ""
                        },
                        set: { cardTexts[card.id] = $0 }
                    ), image: controller.image(documentID: document.id, cardID: card.id, profileID: profileID)) { x, y, width, height in
                        controller.updateCard(card, documentID: document.id, profileID: profileID, x: x, y: y, width: width, height: height)
                    }
                }
            }
            .frame(width: max(1600, document.cards.map { $0.x + $0.width + 120 }.max() ?? 0),
                   height: max(1000, document.cards.map { $0.y + $0.height + 120 }.max() ?? 0))
        }
    }

    private func create(_ kind: DocumentKind) {
        guard flush(), let id = controller.create(kind: kind, profileID: profileID),
              let document = controller.document(id, profileID: profileID) else { return }
        showTrash = false
        open(document)
    }

    private func open(_ document: BrowserDocument) {
        guard flush() else { return }
        selectedID = document.id
        editorProfileID = profileID
        noteText = document.text
        cardTexts = Dictionary(uniqueKeysWithValues: document.cards.compactMap { card in
            if case .text(let text) = card.content { return (card.id, text) }
            return nil
        })
    }

    private func clearSelection() {
        saveTask?.cancel()
        selectedID = nil
        editorProfileID = nil
        noteText = ""
        cardTexts = [:]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard hasUnsavedChanges else { return }
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = flush()
        }
    }

    @discardableResult
    private func flush() -> Bool {
        saveTask?.cancel()
        guard let id = selectedID, let owner = editorProfileID,
              let document = controller.document(id, profileID: owner) else { return true }
        if document.kind == .note {
            return noteText == document.text || controller.updateNote(id, profileID: owner, text: noteText)
        }
        let changed = cardTexts.filter { cardID, text in
            guard let card = document.cards.first(where: { $0.id == cardID }), case .text(let saved) = card.content else { return false }
            return saved != text
        }
        return changed.isEmpty || controller.updateTextCards(id, profileID: owner, values: changed)
    }

    private func close() { if flush() { dismiss() } }

    private func capture(_ document: BrowserDocument) {
        guard flush() else { return }
        let owner = profileID
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            guard let png = await captureCurrentPage() else { controller.report("Open a page before capturing it into this Easel."); return }
            _ = controller.addCapture(document.id, profileID: owner, png: png)
        }
    }

    private func exportSelected() {
        guard flush(), let document = selected,
              let html = controller.exportHTML(document.id, profileID: profileID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = document.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(html.utf8).write(to: url, options: .atomic) }
        catch { controller.report("HTML could not be exported: \(error.localizedDescription)") }
    }
}

private struct EaselCardView: View {
    let card: DocumentCard
    @Binding var text: String
    let image: NSImage?
    let saveGeometry: (Double, Double, Double, Double) -> Bool
    @State private var drag = CGSize.zero
    @State private var resize = CGSize.zero
    private var width: CGFloat { CGFloat(card.width) + resize.width }
    private var height: CGFloat { CGFloat(card.height) + resize.height }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal")
                Text(isText ? "Text" : "Static Capture").font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary).padding(10).contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                drag = CGSize(width: min(20_000 - card.x, max(-card.x, value.translation.width)),
                              height: min(20_000 - card.y, max(-card.y, value.translation.height)))
            }.onEnded { _ in
                _ = saveGeometry(card.x + drag.width, card.y + drag.height, card.width, card.height)
                drag = .zero
            })
            .accessibilityLabel("Move card")
            Divider()
            Group {
                if isText { TextEditor(text: $text).font(.system(size: 14)).padding(8).accessibilityLabel("Card text") }
                else if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
                else { ContentUnavailableView("Capture Unavailable", systemImage: "photo") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).padding(7).background(.regularMaterial)
                .contentShape(Rectangle()).accessibilityLabel("Resize card")
                .gesture(DragGesture().onChanged { value in
                    resize = CGSize(width: min(4000 - card.width, max(120 - card.width, value.translation.width)),
                                    height: min(4000 - card.height, max(80 - card.height, value.translation.height)))
                }.onEnded { _ in
                    _ = saveGeometry(card.x, card.y, width, height)
                    resize = .zero
                })
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .offset(x: card.x + drag.width, y: card.y + drag.height)
    }

    private var isText: Bool { if case .text = card.content { true } else { false } }
}

/// Isolated native fixture; the caller's real document library is never touched.
@MainActor
func runDocumentsSmoke(directory: URL) -> [String: Bool] {
    let fixture = directory.appendingPathComponent("documents-smoke-" + UUID().uuidString, isDirectory: true)
    let profile = UUID(), other = UUID()
    let controller = DocumentController(directory: fixture)
    var checks: [String: Bool] = [:]
    guard let note = controller.create(kind: .note, profileID: profile),
          let easel = controller.create(kind: .easel, profileID: profile),
          let text = controller.addTextCard(easel, profileID: profile),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        return ["documents native fixture creation": false]
    }
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemPurple, atX: x, y: y) } }
    guard let png = bitmap.representation(using: .png, properties: [:]),
          let capture = controller.addCapture(easel, profileID: profile, png: png),
          let card = controller.document(easel, profileID: profile)?.cards.first(where: { $0.id == text }) else {
        return ["documents native PNG capture creation": false]
    }
    checks["documents native controller saves note and Easel edits"] =
        controller.rename(note, profileID: profile, title: "Saved Note") &&
        controller.updateNote(note, profileID: profile, text: "<script>plain text</script>") &&
        controller.updateTextCards(easel, profileID: profile, values: [text: "Positioned text card"]) &&
        controller.updateCard(card, documentID: easel, profileID: profile, x: 88, y: 96, width: 360, height: 240)
    checks["documents native capture renders from owned PNG"] = controller.image(documentID: easel, cardID: capture, profileID: profile) != nil
    checks["documents native library enforces profile ownership"] = controller.documents(profileID: other).isEmpty &&
        controller.document(note, profileID: other) == nil && controller.image(documentID: easel, cardID: capture, profileID: other) == nil
    let restored = DocumentController(directory: fixture)
    checks["documents native controller restores durable library"] = restored.document(note, profileID: profile)?.text == "<script>plain text</script>" &&
        restored.document(easel, profileID: profile)?.cards.count == 2 &&
        restored.document(easel, profileID: profile)?.cards.first(where: { $0.id == text })?.x == 88
    let trashed = restored.trash(easel, profileID: profile)
    let hidden = restored.document(easel, profileID: profile) == nil
    let recovered = restored.restore(easel, profileID: profile)
    checks["documents native Trash restores every card and capture"] = trashed && hidden && recovered &&
        restored.document(easel, profileID: profile)?.cards.count == 2 && restored.image(documentID: easel, cardID: capture, profileID: profile) != nil
    let exported = restored.exportHTML(note, profileID: profile)
    checks["documents native HTML export escapes note text"] = exported?.contains("&lt;script&gt;plain text&lt;/script&gt;") == true && exported?.contains("<script>") == false
    do {
        let corruptDirectory = fixture.appendingPathComponent("corrupt", isDirectory: true)
        let manifest = corruptDirectory.appendingPathComponent("documents/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{preserve damaged documents".utf8)
        try bytes.write(to: manifest)
        let protected = DocumentController(directory: corruptDirectory)
        let refused = protected.create(kind: .note, profileID: profile) == nil
        let unchanged = try Data(contentsOf: manifest) == bytes
        checks["documents native recovery preserves corrupt manifest"] = protected.recoveryRequired && refused && unchanged
    } catch { checks["documents native recovery preserves corrupt manifest"] = false }
    return checks
}
