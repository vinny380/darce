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
    @State private var viewport = EaselViewport()
    @State private var viewSize: CGSize = .zero
    @State private var lastPan: CGSize?
    @State private var placedViewport = false

    private struct Draft { var start: CGPoint; var end: CGPoint; var points: [CGPoint] }
    static let palette = ["#F5F5F7", "#1D1D1F", "#FF5A5F", "#F1A23C", "#55B948", "#017AFF", "#860EFF"]

    private var profileID: UUID { model.state.profileID(forTab: tabID) ?? model.state.selectedProfileID }
    private var document: BrowserDocument? { _ = documents.revision; return documents.document(documentID, profileID: profileID) }
    private var ink: String { color ?? (scheme == .dark ? "#F5F5F7" : "#1D1D1F") }

    var body: some View {
        if let document {
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    canvas(document)
                        .onAppear { viewSize = geometry.size; placeViewport(document) }
                        .onChange(of: geometry.size) { _, size in viewSize = size }
                }
                .clipped()
                HStack(alignment: .bottom, spacing: 8) {
                    toolbar
                    Spacer()
                    zoomControls
                    Button { export() } label: {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium)).frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).help("Export this Easel")
                }.padding(14)
            }
            .onAppear { model.easelZoom = { zoomCommand($0) } }
            .onDisappear { model.easelZoom = nil }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { title = document.title }
            .onChange(of: documentID) { _, _ in
                title = self.document?.title ?? ""; selection = nil; editingText = nil
                placedViewport = false
                if let document = self.document { placeViewport(document) }
            }
        } else {
            ContentUnavailableView("Easel Unavailable", systemImage: "scribble.variable",
                                   description: Text("This Easel was deleted or belongs to another profile."))
        }
    }

    // MARK: Canvas

    private func canvas(_ document: BrowserDocument) -> some View {
        ZStack(alignment: .topLeading) {
            // Empty canvas: draw or place new items, or drag to pan with the select tool.
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged(drawChanged).onEnded(drawEnded))
            // The infinite canvas: items at canvas positions, scaled and moved by the viewport.
            ZStack(alignment: .topLeading) {
                ForEach(document.cards) { card in item(card) }
                if let draft { draftView(draft) }
            }
            .frame(width: 1, height: 1, alignment: .topLeading)
            .scaleEffect(viewport.scale, anchor: .topLeading)
            .offset(x: viewport.offset.x, y: viewport.offset.y)
            TextField("Untitled Easel", text: $title)
                .textFieldStyle(.plain).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
                .focused($titleFocused).frame(maxWidth: 600).padding(.top, 48)
                .frame(maxWidth: .infinity)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        }
        .coordinateSpace(.named(Self.space))
        .background(CanvasInput(onScroll: scrolled, onMagnify: magnified, onSmartMagnify: smartMagnified))
        .focusable().focusEffectDisabled().focused($canvasFocused)
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(characters: .letters.union(.punctuationCharacters).union(.symbols)) { press in
            guard editingText == nil, !titleFocused else { return .ignored }
            switch press.characters {
            case "!": zoomToFit(); return .handled
            case ")": zoomTo100(); return .handled
            default:
                guard let next = Self.shortcut(press.characters) else { return .ignored }
                tool = next
                return .handled
            }
        }
        .onPasteCommand(of: [.png, .tiff, .image, .fileURL, .plainText]) { providers in paste(providers) }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in drop(providers, at: viewport.toCanvas(location)) }
    }

    private static let space = "easel"

    // MARK: Viewport

    /// On opening: everything in view (zooming out if needed), or the canvas origin near the top-left for a new Easel.
    private func placeViewport(_ document: BrowserDocument) {
        guard !placedViewport, viewSize != .zero else { return }
        placedViewport = true
        if let bounds = Self.bounds(document.cards) { viewport.fit(bounds, in: viewSize, padding: 120) }
        else { viewport = EaselViewport(scale: 1, offset: CGPoint(x: 40, y: 120)) }
    }

    private static func bounds(_ cards: [DocumentCard]) -> CGRect? {
        cards.map { CGRect(x: $0.x, y: $0.y, width: max($0.width, 1), height: max($0.height, 1)) }.reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func scrolled(_ delta: CGSize, _ zoom: Bool, _ location: CGPoint) {
        if zoom { animateViewport(false) { viewport.zoom(by: exp(delta.height / 200), around: location) } }
        else { viewport.pan(by: delta) }
    }

    private func magnified(_ magnification: CGFloat, _ location: CGPoint) {
        viewport.zoom(by: 1 + magnification, around: location)
    }

    /// Two-finger double-tap, like Safari: fit everything, or back to 100% if already fitted.
    private func smartMagnified(_ location: CGPoint) {
        if abs(viewport.scale - 1) < 0.01 { zoomToFit() } else { animateViewport { viewport.zoom(by: 1 / viewport.scale, around: location) } }
    }

    private func zoomToFit() {
        guard let document, let bounds = Self.bounds(document.cards) else { return }
        animateViewport { viewport.fit(bounds, in: viewSize, padding: 120) }
    }

    private func zoomTo100() {
        animateViewport { viewport.zoom(by: 1 / viewport.scale, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }
    }

    /// ⌘+ / ⌘− / ⌘0 from the View menu while this Easel is showing.
    private func zoomCommand(_ step: Int) {
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        if step == 0 { zoomTo100() } else { animateViewport { viewport.zoom(by: step > 0 ? 1.25 : 0.8, around: center) } }
    }

    private func animateViewport(_ animated: Bool = true, _ change: () -> Void) {
        withAnimation(animated ? .smooth(duration: 0.25) : nil, change)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { zoomCommand(-1) } label: { Image(systemName: "minus").frame(width: 30, height: 40) }.help("Zoom Out (⌘−)")
            Menu {
                Button("Zoom to Fit  ⇧1") { zoomToFit() }
                Button("Zoom to 100%  ⇧0") { zoomTo100() }
            } label: {
                Text("\(Int((viewport.scale * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 48, height: 40)
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { zoomCommand(1) } label: { Image(systemName: "plus").frame(width: 30, height: 40) }.help("Zoom In (⌘+)")
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .gesture(DragGesture(coordinateSpace: .named(Self.space)).onChanged { value in
                            resizing = CGSize(width: value.translation.width / viewport.scale, height: value.translation.height / viewport.scale)
                        }.onEnded { _ in commitResize(card) })
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .contentShape(Rectangle())
        .offset(x: card.x + offset.width, y: card.y + offset.height)
        .allowsHitTesting(tool == .select)
        .onTapGesture(count: 2) { if case .text(let text) = card.content { beginEditing(card.id, text: text) } }
        .onTapGesture { selection = card.id; canvasFocused = true; finishEditing() }
        .gesture(editingText == card.id ? nil : DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                selection = card.id
                moving = CGSize(width: value.translation.width / viewport.scale, height: value.translation.height / viewport.scale)
            }
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
        let start = viewport.toCanvas(value.startLocation), location = viewport.toCanvas(value.location)
        switch tool {
        case .rectangle, .ellipse, .arrow, .draw:
            if draft == nil { draft = Draft(start: start, end: location, points: [start]) }
            draft?.end = location
            if tool == .draw { draft?.points.append(location) }
        case .select:
            // Dragging empty canvas pans it.
            let previous = lastPan ?? .zero
            viewport.pan(by: CGSize(width: value.translation.width - previous.width, height: value.translation.height - previous.height))
            lastPan = value.translation
        default: break
        }
    }

    private func drawEnded(_ value: DragGesture.Value) {
        defer { draft = nil; lastPan = nil }
        let location = viewport.toCanvas(value.location)
        switch tool {
        case .select:
            if hypot(value.translation.width, value.translation.height) < 3 { selection = nil }
            finishEditing()
            canvasFocused = true
        case .text:
            let id = documents.addCard(.text(""), to: documentID, profileID: profileID,
                                       frame: CGRect(x: location.x, y: location.y, width: 260, height: 80))
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
                                 x: card.x + moving.width, y: card.y + moving.height, width: card.width, height: card.height)
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
        let center = viewport.toCanvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        let origin = point ?? CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
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
            let center = viewport.toCanvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
            if let image = NSImage(contentsOf: url) { addImage(image, at: CGPoint(x: center.x - 200 + Double(index) * 40, y: center.y - 150 + Double(index) * 40)) }
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
            let center = viewport.toCanvas(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
            selection = documents.addCard(.text(text), to: documentID, profileID: profileID, frame: CGRect(x: center.x - 160, y: center.y - 60, width: 320, height: 120))
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

/// Trackpad and mouse input for the infinite canvas: two-finger scroll pans (⌘ or a mouse wheel's ⌘-scroll zooms),
/// pinch zooms, two-finger double-tap toggles fit. Watches events over this view only; never takes clicks.
private struct CanvasInput: NSViewRepresentable {
    let onScroll: (CGSize, Bool, CGPoint) -> Void
    let onMagnify: (CGFloat, CGPoint) -> Void
    let onSmartMagnify: (CGPoint) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onSmartMagnify = onSmartMagnify
    }

    final class InputView: NSView {
        var onScroll: ((CGSize, Bool, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onSmartMagnify: ((CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return false }
            switch event.type {
            case .scrollWheel:
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                let zoom = event.modifierFlags.contains(.command)
                onScroll?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor), zoom, location)
            case .magnify: onMagnify?(event.magnification, location)
            case .smartMagnify: onSmartMagnify?(location)
            default: return false
            }
            return true
        }

    }
}
