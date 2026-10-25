import Foundation

public enum DocumentKind: String, Codable, CaseIterable, Sendable { case note, easel }

public enum DocumentCardContent: Codable, Equatable, Sendable {
    case text(String)
    case capture(filename: String, altText: String)
    // Arc's Easel drawing tools. Points are relative to the card's origin; colors are "#RRGGBB".
    case shape(ShapeKind, color: String)
    case arrow(from: DrawingPoint, to: DrawingPoint, color: String)
    case stroke([DrawingPoint], color: String)

    /// Drawn items can be thin (a straight arrow has no height); text and images keep a readable minimum.
    var isDrawing: Bool {
        switch self {
        case .shape, .arrow, .stroke: true
        case .text, .capture: false
        }
    }

    var color: String? {
        switch self {
        case .shape(_, let color), .arrow(_, _, let color), .stroke(_, let color): color
        case .text, .capture: nil
        }
    }
}

public enum ShapeKind: String, Codable, Sendable { case rectangle, ellipse }

public struct DrawingPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct DocumentCard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var content: DocumentCardContent
    public internal(set) var x: Double
    public internal(set) var y: Double
    public internal(set) var width: Double
    public internal(set) var height: Double
}

public struct BrowserDocument: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let kind: DocumentKind
    public internal(set) var title: String
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var trashedAt: Date?
    public internal(set) var text: String
    public internal(set) var cards: [DocumentCard]
}

public enum DocumentStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int), invalidRecords, notFound, wrongKind, invalidPNG

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Documents use unsupported schema version \(version)."
        case .invalidRecords: "Documents contain invalid identities, image references, dates, or card positions."
        case .notFound: "This document is unavailable in the current profile."
        case .wrongKind: "This action is unavailable for this document or card."
        case .invalidPNG: "The capture is not a supported PNG image."
        }
    }
}

public struct DocumentStore: Sendable {
    private struct Manifest: Codable {
        var schemaVersion = 1
        var documents: [BrowserDocument]
    }
    private let directory: URL
    private var contents: [BrowserDocument]
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var imagesURL: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory.appendingPathComponent("documents", isDirectory: true)
        let data: Data
        do { data = try Data(contentsOf: self.directory.appendingPathComponent("manifest.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            contents = []
            return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw DocumentStoreError.unsupportedSchema(manifest.schemaVersion) }
        try Self.validate(manifest.documents)
        for document in manifest.documents {
            for card in document.cards {
                if case .capture(let filename, _) = card.content {
                    try Self.validateCapturePNG(Data(contentsOf: self.directory.appendingPathComponent("images/" + filename)))
                }
            }
        }
        contents = manifest.documents
    }

    public func documents(profileID: UUID, includeTrashed: Bool = false) -> [BrowserDocument] {
        contents.filter { $0.profileID == profileID && (includeTrashed || $0.trashedAt == nil) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    public func document(_ id: UUID, profileID: UUID, includeTrashed: Bool = false) -> BrowserDocument? {
        contents.first { $0.id == id && $0.profileID == profileID && (includeTrashed || $0.trashedAt == nil) }
    }

    @discardableResult
    public mutating func create(kind: DocumentKind, title: String, profileID: UUID, now: Date = Date()) throws -> UUID {
        let value = BrowserDocument(id: UUID(), profileID: profileID, kind: kind,
                                    title: Self.title(title, kind: kind), createdAt: now, updatedAt: now,
                                    text: "", cards: [])
        try commit(contents + [value])
        return value.id
    }

    public mutating func rename(_ id: UUID, profileID: UUID, title: String) throws {
        try modify(id, profileID: profileID) { $0.title = Self.title(title, kind: $0.kind) }
    }

    public mutating func updateNote(_ id: UUID, profileID: UUID, text: String) throws {
        try modify(id, profileID: profileID) {
            guard $0.kind == .note else { throw DocumentStoreError.wrongKind }
            $0.text = text
        }
    }

    public mutating func updateTextCards(_ id: UUID, profileID: UUID, values: [UUID: String]) throws {
        try modify(id, profileID: profileID) { document in
            guard document.kind == .easel else { throw DocumentStoreError.wrongKind }
            for (cardID, text) in values {
                guard let index = document.cards.firstIndex(where: { $0.id == cardID }),
                      case .text = document.cards[index].content else { throw DocumentStoreError.wrongKind }
                document.cards[index].content = .text(text)
            }
        }
    }

    @discardableResult
    public mutating func addTextCard(documentID: UUID, profileID: UUID, text: String = "") throws -> UUID {
        let id = UUID()
        try modify(documentID, profileID: profileID) { document in
            guard document.kind == .easel else { throw DocumentStoreError.wrongKind }
            document.cards.append(Self.card(id: id, content: .text(text), index: document.cards.count))
        }
        return id
    }

    @discardableResult
    public mutating func addCaptureCard(documentID: UUID, profileID: UUID, png: Data, altText: String) throws -> UUID {
        let index = try index(documentID, profileID: profileID)
        guard contents[index].kind == .easel else { throw DocumentStoreError.wrongKind }
        try Self.validateCapturePNG(png)
        let id = UUID(), filename = id.uuidString + ".png"
        let fileURL = imagesURL.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try png.write(to: fileURL, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try modify(documentID, profileID: profileID) { document in
                document.cards.append(Self.card(id: id, content: .capture(filename: filename, altText: altText), index: document.cards.count))
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return id
    }

    /// Places a text or drawn item at a position (images go through `addCaptureCard`, which stores the PNG).
    @discardableResult
    public mutating func addCard(_ content: DocumentCardContent, documentID: UUID, profileID: UUID,
                                 x: Double, y: Double, width: Double, height: Double) throws -> UUID {
        if case .capture = content { throw DocumentStoreError.wrongKind }
        let id = UUID()
        try modify(documentID, profileID: profileID) { document in
            guard document.kind == .easel else { throw DocumentStoreError.wrongKind }
            document.cards.append(DocumentCard(id: id, content: content, x: x, y: y, width: width, height: height))
        }
        return id
    }

    /// Removes an item; an image's file goes with it.
    public mutating func deleteCard(_ cardID: UUID, documentID: UUID, profileID: UUID) throws {
        var removedFile: String?
        try modify(documentID, profileID: profileID) { document in
            guard let index = document.cards.firstIndex(where: { $0.id == cardID }) else { throw DocumentStoreError.notFound }
            if case .capture(let filename, _) = document.cards[index].content { removedFile = filename }
            document.cards.remove(at: index)
        }
        if let removedFile { try? FileManager.default.removeItem(at: imagesURL.appendingPathComponent(removedFile)) }
    }

    public mutating func updateCard(_ cardID: UUID, documentID: UUID, profileID: UUID,
                                    x: Double, y: Double, width: Double, height: Double) throws {
        try modify(documentID, profileID: profileID) { document in
            guard let index = document.cards.firstIndex(where: { $0.id == cardID }) else { throw DocumentStoreError.notFound }
            document.cards[index].x = x
            document.cards[index].y = y
            document.cards[index].width = width
            document.cards[index].height = height
        }
    }

    public mutating func trash(_ id: UUID, profileID: UUID) throws {
        try modify(id, profileID: profileID) { $0.trashedAt = max(Date(), $0.updatedAt) }
    }

    public mutating func restore(_ id: UUID, profileID: UUID) throws {
        try modify(id, profileID: profileID, includeTrashed: true) { $0.trashedAt = nil }
    }

    public func imageData(documentID: UUID, cardID: UUID, profileID: UUID) throws -> Data {
        let documentIndex = try index(documentID, profileID: profileID, includeTrashed: true)
        guard let card = contents[documentIndex].cards.first(where: { $0.id == cardID }),
              case .capture(let filename, _) = card.content else { throw DocumentStoreError.notFound }
        return try Data(contentsOf: imagesURL.appendingPathComponent(filename))
    }

    public func exportHTML(_ id: UUID, profileID: UUID) throws -> String {
        let value = contents[try index(id, profileID: profileID)]
        let body: String
        if value.kind == .note {
            body = "<main class=\"note\"><h1>\(Self.escape(value.title))</h1><pre>\(Self.escape(value.text))</pre></main>"
        } else {
            let width = max(1000, value.cards.map { $0.x + $0.width + 40 }.max() ?? 0)
            let height = max(700, value.cards.map { $0.y + $0.height + 40 }.max() ?? 0)
            var cards: [String] = []
            for card in value.cards {
                let content: String
                switch card.content {
                case .text(let text): content = "<pre>\(Self.escape(text))</pre>"
                case .capture(_, let altText):
                    let bytes = try imageData(documentID: id, cardID: card.id, profileID: profileID)
                    content = "<img src=\"data:image/png;base64,\(bytes.base64EncodedString())\" alt=\"\(Self.escape(altText))\">"
                case .shape, .arrow, .stroke:
                    // Colors are validated "#RRGGBB" and points are numbers, so this SVG carries no page input.
                    cards.append("<svg class=\"drawing\" style=\"left:\(card.x)px;top:\(card.y)px\" width=\"\(card.width + 8)\" height=\"\(card.height + 8)\">\(Self.svg(card))</svg>")
                    continue
                }
                cards.append("<section class=\"card\" style=\"left:\(card.x)px;top:\(card.y)px;width:\(card.width)px;height:\(card.height)px\">\(content)</section>")
            }
            body = "<h1>\(Self.escape(value.title))</h1><main class=\"easel\" style=\"width:\(width)px;height:\(height)px\">\(cards.joined())</main>"
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>\(Self.escape(value.title))</title><style>body{font:16px system-ui,sans-serif;background:#f3f3f5;color:#171717;margin:24px}h1{font-size:24px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;margin:0}.note{max-width:800px;margin:auto;padding:32px;background:white}.note h1{margin-top:0}.easel{position:relative}.card{position:absolute;box-sizing:border-box;overflow:auto;padding:16px;background:white;border:1px solid #ddd;border-radius:12px}.card img{display:block;width:100%;height:100%;object-fit:contain}.drawing{position:absolute;overflow:visible}</style></head><body>\(body)</body></html>
        """
    }

    private func index(_ id: UUID, profileID: UUID, includeTrashed: Bool = false) throws -> Int {
        guard let index = contents.firstIndex(where: { $0.id == id && $0.profileID == profileID && (includeTrashed || $0.trashedAt == nil) }) else {
            throw DocumentStoreError.notFound
        }
        return index
    }

    private mutating func modify(_ id: UUID, profileID: UUID, includeTrashed: Bool = false,
                                 change: (inout BrowserDocument) throws -> Void) throws {
        let index = try index(id, profileID: profileID, includeTrashed: includeTrashed)
        var candidate = contents
        try change(&candidate[index])
        candidate[index].updatedAt = max(Date(), candidate[index].updatedAt)
        try commit(candidate)
    }

    private mutating func commit(_ candidate: [BrowserDocument]) throws {
        try Self.validate(candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Manifest(documents: candidate))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: manifestURL, options: .atomic)
        contents = candidate
    }

    private static func title(_ input: String, kind: DocumentKind) -> String {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? (kind == .note ? "Untitled Note" : "Untitled Easel") : cleaned
    }

    private static func card(id: UUID, content: DocumentCardContent, index: Int) -> DocumentCard {
        DocumentCard(id: id, content: content, x: Double(40 + (index % 8) * 35), y: Double(40 + (index % 8) * 35), width: 300, height: 220)
    }

    private static func validate(_ values: [BrowserDocument]) throws {
        var identities: Set<UUID> = []
        for document in values {
            guard identities.insert(document.id).inserted, !document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  document.createdAt.timeIntervalSince1970.isFinite, document.updatedAt.timeIntervalSince1970.isFinite,
                  document.updatedAt >= document.createdAt,
                  document.trashedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= document.createdAt }) ?? true,
                  document.kind == .note ? document.cards.isEmpty : document.text.isEmpty else { throw DocumentStoreError.invalidRecords }
            for card in document.cards {
                let (minWidth, minHeight): (Double, Double) = card.content.isDrawing ? (0, 0) : (120, 80)
                guard identities.insert(card.id).inserted,
                      [card.x, card.y, card.width, card.height].allSatisfy(\.isFinite),
                      (0...20_000).contains(card.x), (0...20_000).contains(card.y),
                      (minWidth...4000).contains(card.width), (minHeight...4000).contains(card.height),
                      card.content.color.map(Self.isHexColor) ?? true else { throw DocumentStoreError.invalidRecords }
                if case .stroke(let points, _) = card.content {
                    guard points.count <= 20_000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw DocumentStoreError.invalidRecords }
                }
                if case .capture(let filename, _) = card.content {
                    guard filename == card.id.uuidString + ".png" else { throw DocumentStoreError.invalidRecords }
                }
            }
        }
    }

    private static func svg(_ card: DocumentCard) -> String {
        let stroke = "fill=\"none\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        switch card.content {
        case .shape(.rectangle, let color):
            return "<rect x=\"2\" y=\"2\" width=\"\(card.width)\" height=\"\(card.height)\" rx=\"8\" stroke=\"\(color)\" \(stroke)/>"
        case .shape(.ellipse, let color):
            return "<ellipse cx=\"\(card.width / 2 + 2)\" cy=\"\(card.height / 2 + 2)\" rx=\"\(card.width / 2)\" ry=\"\(card.height / 2)\" stroke=\"\(color)\" \(stroke)/>"
        case .arrow(let from, let to, let color):
            return "<line x1=\"\(from.x + 2)\" y1=\"\(from.y + 2)\" x2=\"\(to.x + 2)\" y2=\"\(to.y + 2)\" stroke=\"\(color)\" \(stroke)/>"
        case .stroke(let points, let color):
            let path = points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\($0.element.x + 2) \($0.element.y + 2)" }.joined(separator: " ")
            return "<path d=\"\(path)\" stroke=\"\(color)\" \(stroke)/>"
        case .text, .capture:
            return ""
        }
    }

    static func isHexColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }

    public static func validateCapturePNG(_ data: Data) throws {
        guard data.count >= 33, data.count <= 40 * 1024 * 1024,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { throw DocumentStoreError.invalidPNG }
        let header = Array(data.prefix(24))
        guard Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { throw DocumentStoreError.invalidPNG }
        func dimension(_ offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let width = dimension(16), height = dimension(20)
        guard (1...32_768).contains(width), (1...32_768).contains(height),
              UInt64(width) * UInt64(height) <= 64_000_000 else { throw DocumentStoreError.invalidPNG }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
