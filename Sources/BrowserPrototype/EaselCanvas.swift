import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Arc's Easel: a canvas in the content area with a big editable title and a tool bar at the bottom left —
/// select, image, text, ellipse, rectangle, arrow, draw, and capture from an open tab.
enum EaselTool: String, CaseIterable, Identifiable {
    case select, image, text, ellipse, rectangle, arrow, draw, capture
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .image: "photo"
        case .text: "textformat"
        case .ellipse: "circle"
        case .rectangle: "square"
        case .arrow: "arrow.up.right"
        case .draw: "scribble"
        case .capture: "camera.viewfinder"
        }
    }
    var help: String {
        switch self {
        case .select: "Select and move (V)"
        case .image: "Add an image"
        case .text: "Text (T)"
        case .ellipse: "Ellipse (O)"
        case .rectangle: "Rectangle (R)"
        case .arrow: "Arrow (A)"
        case .draw: "Draw (D)"
        case .capture: "Capture a tab"
        }
    }
}

struct EaselCanvas: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var documents: DocumentController
    let documentID: UUID
    let tabID: UUID
    @Environment(\.colorScheme) private var scheme
    @State private var tool = EaselTool.select
    @State private var color: String?
    @State private var draft: Draft?
    @State private var selection: UUID?
    @State private var moving: CGSize = .zero
    @State private var resizing: CGSize = .zero
    @State private var editingText: UUID?
    @State private var textDraft = ""
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var canvasFocused: Bool
    @FocusState private var textFocused: Bool

    private struct Draft { var start: CGPoint; var end: CGPoint; var points: [CGPoint] }
    static let palette = ["#F5F5F7", "#1D1D1F", "#FF5A5F", "#F1A23C", "#55B948", "#017AFF", "#860EFF"]

    private var profileID: UUID { model.state.profileID(forTab: tabID) ?? model.state.selectedProfileID }
    private var document: BrowserDocument? { _ = documents.revision; return documents.document(documentID, profileID: profileID) }
    private var ink: String { color ?? (scheme == .dark ? "#F5F5F7" : "#1D1D1F") }

    var body: some View {
        if let document {
            ZStack(alignment: .bottom) {
                GeometryReader { viewport in
                    ScrollView([.horizontal, .vertical]) {
                        canvas(document, minSize: viewport.size)
                    }.scrollIndicators(.automatic)
                }
                HStack(alignment: .bottom) {
                    toolbar
                    Spacer()
                    Button { export() } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium)).frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).help("Export this Easel")
                }.padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { title = document.title }
            .onChange(of: documentID) { _, _ in title = self.document?.title ?? ""; selection = nil; editingText = nil }
        } else {
            ContentUnavailableView("Easel Unavailable", systemImage: "scribble.variable",
                                   description: Text("This Easel was deleted or belongs to another profile."))
        }
    }

    // MARK: Canvas

    private func canvas(_ document: BrowserDocument, minSize: CGSize) -> some View {
        let width = max(minSize.width, (document.cards.map { $0.x + $0.width }.max() ?? 0) + 400)
        let height = max(minSize.height, (document.cards.map { $0.y + $0.height }.max() ?? 0) + 400)
        return ZStack(alignment: .topLeading) {
            // Background: where new items are drawn or placed.
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged(drawChanged).onEnded(drawEnded))
            TextField("Untitled Easel", text: $title)
                .textFieldStyle(.plain).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
                .focused($titleFocused).frame(width: min(600, width - 80))
                .position(x: minSize.width / 2, y: 70)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            ForEach(document.cards) { card in item(card) }
            if let draft { draftView(draft) }
        }
        .frame(width: width, height: height)
        .focusable().focusEffectDisabled().focused($canvasFocused)
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(characters: .letters) { press in
            guard editingText == nil, !titleFocused, let next = Self.shortcut(press.characters) else { return .ignored }
            tool = next
            return .handled
        }
        .onPasteCommand(of: [.png, .tiff, .image, .fileURL, .plainText]) { providers in paste(providers) }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in drop(providers, at: location) }
    }

    private static func shortcut(_ key: String) -> EaselTool? {
        switch key.lowercased() {
        case "v": .select
        case "t": .text
        case "o": .ellipse
        case "r": .rectangle
        case "a": .arrow
        case "d": .draw
        default: nil
        }
    }

    @ViewBuilder private func item(_ card: DocumentCard) -> some View {
        let selected = selection == card.id
        let offset = selected ? moving : .zero
        let size = CGSize(width: card.width + (selected ? resizing.width : 0), height: card.height + (selected ? resizing.height : 0))
        ZStack(alignment: .topLeading) {
            content(card, size: size)
            if selected && editingText != card.id {
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .padding(-6).allowsHitTesting(false)
                if card.content.isResizable {
                    Circle().fill(.white).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: size.width + 6, y: size.height + 6)
                        .gesture(DragGesture().onChanged { resizing = $0.translation }.onEnded { _ in commitResize(card) })
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .contentShape(Rectangle())
        .offset(x: card.x + offset.width, y: card.y + offset.height)
        .allowsHitTesting(tool == .select)
        .onTapGesture(count: 2) { if case .text(let text) = card.content { beginEditing(card.id, text: text) } }
        .onTapGesture { selection = card.id; canvasFocused = true; finishEditing() }
        .gesture(editingText == card.id ? nil : DragGesture(minimumDistance: 3)
            .onChanged { value in selection = card.id; moving = value.translation }
            .onEnded { _ in commitMove(card) })
        .contextMenu {
            Button("Delete", role: .destructive) { documents.deleteCard(card.id, from: documentID, profileID: profileID) }
        }
    }

    @ViewBuilder private func content(_ card: DocumentCard, size: CGSize) -> some View {
        switch card.content {
        case .text(let text):
            if editingText == card.id {
                TextEditor(text: $textDraft).font(.system(size: 18)).scrollContentBackground(.hidden)
                    .frame(width: size.width, height: size.height)
                    .focused($textFocused)
                    // Type straight away after placing text, as in Arc.
                    .onAppear { DispatchQueue.main.async { textFocused = true } }
                    .onDisappear { finishEditing() }
            } else {
                Text(text.isEmpty ? "Text" : text).font(.system(size: 18)).foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        case .capture:
            if let image = documents.image(documentID: documentID, cardID: card.id, profileID: profileID) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
        case .shape(let kind, let color):
            Group {
                if kind == .rectangle { RoundedRectangle(cornerRadius: 8).stroke(Color(hex: color), lineWidth: 3) }
                else { Ellipse().stroke(Color(hex: color), lineWidth: 3) }
            }.frame(width: size.width, height: size.height)
        case .arrow(let from, let to, let color):
            ArrowShape(from: CGPoint(x: from.x, y: from.y), to: CGPoint(x: to.x, y: to.y))
                .stroke(Color(hex: color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        case .stroke(let points, let color):
            Path { path in path.addLines(points.map { CGPoint(x: $0.x, y: $0.y) }) }
                .stroke(Color(hex: color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    @ViewBuilder private func draftView(_ draft: Draft) -> some View {
        let rect = CGRect(start: draft.start, end: draft.end)
        let style = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        switch tool {
        case .rectangle: RoundedRectangle(cornerRadius: 8).stroke(Color(hex: ink), style: style).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        case .ellipse: Ellipse().stroke(Color(hex: ink), style: style).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        case .arrow: ArrowShape(from: draft.start, to: draft.end).stroke(Color(hex: ink), style: style)
        case .draw: Path { $0.addLines(draft.points) }.stroke(Color(hex: ink), style: style)
        default: EmptyView()
        }
    }

    // MARK: Drawing

    private func drawChanged(_ value: DragGesture.Value) {
        switch tool {
        case .rectangle, .ellipse, .arrow, .draw:
            if draft == nil { draft = Draft(start: value.startLocation, end: value.location, points: [value.startLocation]) }
            draft?.end = value.location
            if tool == .draw { draft?.points.append(value.location) }
        default: break
        }
    }

    private func drawEnded(_ value: DragGesture.Value) {
        defer { draft = nil }
        switch tool {
        case .select:
            selection = nil
            finishEditing()
            canvasFocused = true
        case .text:
            let id = documents.addCard(.text(""), to: documentID, profileID: profileID,
                                       frame: CGRect(x: value.location.x, y: value.location.y, width: 260, height: 80))
            tool = .select
            if let id { selection = id; beginEditing(id, text: "") }
        case .rectangle, .ellipse:
            guard let draft else { return }
            let rect = CGRect(start: draft.start, end: draft.end)
            guard rect.width > 4 || rect.height > 4 else { return }
            let shape: ShapeKind = tool == .rectangle ? .rectangle : .ellipse
            selection = documents.addCard(.shape(shape, color: ink), to: documentID, profileID: profileID, frame: rect)
            tool = .select
        case .arrow:
            guard let draft else { return }
            let rect = CGRect(start: draft.start, end: draft.end)
            guard hypot(rect.width, rect.height) > 8 else { return }
            let from = DrawingPoint(x: draft.start.x - rect.minX, y: draft.start.y - rect.minY)
            let to = DrawingPoint(x: draft.end.x - rect.minX, y: draft.end.y - rect.minY)
            selection = documents.addCard(.arrow(from: from, to: to, color: ink), to: documentID, profileID: profileID, frame: rect)
            tool = .select
        case .draw:
            guard let draft, draft.points.count > 1 else { return }
            let xs = draft.points.map(\.x), ys = draft.points.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let points = draft.points.map { DrawingPoint(x: $0.x - rect.minX, y: $0.y - rect.minY) }
            documents.addCard(.stroke(points, color: ink), to: documentID, profileID: profileID, frame: rect)
        case .image, .capture: break
        }
    }

    private func commitMove(_ card: DocumentCard) {
        defer { moving = .zero }
        guard moving != .zero else { return }
        _ = documents.updateCard(card, documentID: documentID, profileID: profileID,
                                 x: max(0, card.x + moving.width), y: max(0, card.y + moving.height), width: card.width, height: card.height)
    }

    private func commitResize(_ card: DocumentCard) {
        defer { resizing = .zero }
        let minimum: CGFloat = card.content.isDrawing ? 8 : 40
        _ = documents.updateCard(card, documentID: documentID, profileID: profileID, x: card.x, y: card.y,
                                 width: max(minimum, card.width + resizing.width), height: max(minimum, card.height + resizing.height))
    }

    private func deleteSelection() {
        guard let selection, editingText == nil, !titleFocused else { return }
        documents.deleteCard(selection, from: documentID, profileID: profileID)
        self.selection = nil
    }

    // MARK: Text and title

    private func beginEditing(_ id: UUID, text: String) {
        finishEditing()
        textDraft = text
        editingText = id
    }

    private func finishEditing() {
        guard let id = editingText else { return }
        editingText = nil
        // A text box left empty disappears, rather than leaving a stray "Text" placeholder.
        if textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            documents.deleteCard(id, from: documentID, profileID: profileID)
            if selection == id { selection = nil }
        } else {
            _ = documents.updateTextCards(documentID, profileID: profileID, values: [id: textDraft])
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, trimmed != document.title else { return }
        _ = documents.rename(documentID, profileID: profileID, title: trimmed)
        let saved = self.document?.title ?? "Untitled Easel"
        title = saved
        model.stateUpdate { $0.updateTab(tabID, title: saved) }
    }

    // MARK: Images, capture, paste, drop

    private func addImage(_ image: NSImage, at point: CGPoint? = nil) {
        guard let png = Self.png(image) else { documents.report("That image couldn't be added."); return }
        guard let id = documents.addCapture(documentID, profileID: profileID, png: png),
              let card = documents.document(documentID, profileID: profileID)?.cards.first(where: { $0.id == id }) else { return }
        let scale = min(1, 480 / max(image.size.width, 1), 360 / max(image.size.height, 1))
        let size = CGSize(width: max(120, image.size.width * scale), height: max(80, image.size.height * scale))
        let origin = point ?? CGPoint(x: 120 + Double(card.id.hashValue & 0x3F), y: 160)
        _ = documents.updateCard(card, documentID: documentID, profileID: profileID, x: origin.x, y: origin.y, width: size.width, height: size.height)
        selection = id
        tool = .select
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for (index, url) in panel.urls.enumerated() {
            if let image = NSImage(contentsOf: url) { addImage(image, at: CGPoint(x: 140 + index * 40, y: 180 + index * 40)) }
        }
    }

    private func capture(_ page: BrowserPage) {
        Task {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(1600, max(1, page.webView.bounds.width)))
            guard let image = try? await page.webView.takeSnapshot(configuration: configuration) else {
                documents.report("That tab couldn't be captured. Open it once, then try again.")
                return
            }
            addImage(image)
        }
    }

    private func paste(_ providers: [NSItemProvider]) {
        if let image = NSImage(pasteboard: .general) { addImage(image); return }
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            selection = documents.addCard(.text(text), to: documentID, profileID: profileID, frame: CGRect(x: 160, y: 200, width: 320, height: 120))
        }
    }

    private func drop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in addImage(image, at: location) }
            }
        }
        return handled
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func export() {
        guard let html = documents.exportHTML(documentID, profileID: profileID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (document?.title ?? "Easel") + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(html.utf8).write(to: url, options: .atomic) } catch { documents.report(error.localizedDescription) }
    }

    // MARK: Tool bar

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(EaselTool.allCases) { option in
                if option == .capture {
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 22).padding(.horizontal, 3)
                    Menu {
                        let pages = model.loadedPagesInOrder
                        if pages.isEmpty { Text("Open a website tab to capture it") }
                        ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                            Button(page.webView.title?.isEmpty == false ? page.webView.title! : (page.webView.url?.host ?? "Tab")) { capture(page) }
                        }
                    } label: { toolLabel(option) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(option.help)
                } else {
                    Button {
                        if option == .image { chooseImages() } else { tool = option; finishEditing() }
                    } label: { toolLabel(option) }
                    .buttonStyle(.plain).help(option.help)
                }
            }
            Menu {
                ForEach(Self.palette, id: \.self) { hex in
                    Button { color = hex } label: { Label(hex, systemImage: hex == ink ? "checkmark.circle.fill" : "circle.fill") }
                }
            } label: {
                Circle().fill(Color(hex: ink)).overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                    .frame(width: 18, height: 18).frame(width: 34, height: 34)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Color for new shapes and drawings")
        }
        .padding(4)
        .background(Color(.sRGB, red: 0.1, green: 0.1, blue: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(.white)
    }

    private func toolLabel(_ option: EaselTool) -> some View {
        Image(systemName: option.symbol).font(.system(size: 15, weight: .medium)).frame(width: 34, height: 34)
            .background(tool == option ? Color(.sRGB, red: 0.2, green: 0.22, blue: 0.96) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x), head: CGFloat = 14
        for side in [-1.0, 1.0] {
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x - head * cos(angle + side * .pi / 7), y: to.y - head * sin(angle + side * .pi / 7)))
        }
        return path
    }
}

private extension CGRect {
    init(start: CGPoint, end: CGPoint) {
        self.init(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

private extension DocumentCardContent {
    var isResizable: Bool {
        switch self {
        case .text, .capture, .shape: true
        case .arrow, .stroke: false
        }
    }
    var isDrawing: Bool {
        switch self {
        case .shape, .arrow, .stroke: true
        case .text, .capture: false
        }
    }
}

extension Color {
    /// "#RRGGBB" from an Easel item.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
