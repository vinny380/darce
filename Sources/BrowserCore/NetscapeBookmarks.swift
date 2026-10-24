import Foundation

/// An independent tree; import never mutates browser sessions or assigns profiles.
public indirect enum BookmarkNode: Equatable, Sendable {
    case bookmark(title: String, url: URL)
    case folder(title: String, children: [BookmarkNode])

    public var title: String {
        switch self { case .bookmark(let title, _), .folder(let title, _): title }
    }
    public var url: URL? {
        if case .bookmark(_, let url) = self { return url }
        return nil
    }
    public var children: [BookmarkNode]? {
        if case .folder(_, let children) = self { return children }
        return nil
    }
}

public struct BookmarkImportIssue: Equatable, Sendable {
    public let title: String
    public let reason: String
}

public struct BookmarkImportResult: Equatable, Sendable {
    public let roots: [BookmarkNode]
    public let issues: [BookmarkImportIssue]
}

public enum BookmarkFileError: Error, LocalizedError {
    case tooLarge
    case invalidStructure(String)
    case unsupportedURL(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Bookmark file exceeds the 8 MiB, 50,000 element, or 64 folder depth limit."
        case .invalidStructure(let detail): "Bookmark file has invalid structure: \(detail)"
        case .unsupportedURL(let url): "Bookmark URL must use HTTP or HTTPS: \(url)"
        }
    }
}

public enum NetscapeBookmarks {
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxNodes = 50_000

    public static func read(from url: URL) throws -> BookmarkImportResult {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw BookmarkFileError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> BookmarkImportResult {
        guard data.count <= maxBytes else { throw BookmarkFileError.tooLarge }
        // Inspect list delimiters before tidy repairs malformed input. Omitted DT/P endings
        // are valid Netscape HTML, but an incomplete folder tree must not silently import.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let stripped = text.replacingOccurrences(of: "(?s)<!--.*?-->|<script\\b[^>]*>.*?</script\\s*>|<style\\b[^>]*>.*?</style\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        let pattern = try NSRegularExpression(pattern: "<\\s*(/?)\\s*dl\\b[^>]*>", options: [.caseInsensitive])
        var depth = 0, count = 0
        for match in pattern.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
            let closing = match.range(at: 1).length > 0
            depth += closing ? -1 : 1
            count += closing ? 0 : 1
            guard depth >= 0 else { throw BookmarkFileError.invalidStructure("unmatched closing DL") }
            guard depth <= 65 else { throw BookmarkFileError.tooLarge }
        }
        guard depth == 0, count > 0 else { throw BookmarkFileError.invalidStructure("missing or unclosed DL") }
        let document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        var elements = 0
        var lists: [XMLElement] = []
        func visit(_ node: XMLNode, insideList: Bool, depth: Int) throws {
            guard depth < 256 else { throw BookmarkFileError.tooLarge }
            elements += 1
            guard elements <= maxNodes else { throw BookmarkFileError.tooLarge }
            let isList = node.name?.lowercased() == "dl"
            if isList, !insideList, let element = node as? XMLElement { lists.append(element) }
            for child in node.children ?? [] { try visit(child, insideList: insideList || isList, depth: depth + 1) }
        }
        try visit(document, insideList: false, depth: 0)
        guard !lists.isEmpty else { throw BookmarkFileError.invalidStructure("no bookmark lists") }
        var issues: [BookmarkImportIssue] = []
        let roots = try lists.flatMap { try parseList($0, depth: 0, issues: &issues) }
        return BookmarkImportResult(roots: roots, issues: issues)
    }

    private static func parseList(_ list: XMLElement, depth: Int, issues: inout [BookmarkImportIssue]) throws -> [BookmarkNode] {
        guard depth <= 64 else { throw BookmarkFileError.tooLarge }
        var nodes: [BookmarkNode] = [], pendingFolder: String?
        func consume(_ node: XMLNode) throws {
            guard let element = node as? XMLElement else { return }
            switch element.name?.lowercased() {
            case "h3":
                guard pendingFolder == nil else { throw BookmarkFileError.invalidStructure("folder missing its DL") }
                let title = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { issues.append(BookmarkImportIssue(title: "", reason: "Empty folder name replaced with Untitled Folder.")) }
                pendingFolder = title.isEmpty ? "Untitled Folder" : title
            case "dl":
                guard let title = pendingFolder else { throw BookmarkFileError.invalidStructure("nested DL without a folder heading") }
                pendingFolder = nil
                nodes.append(.folder(title: title, children: try parseList(element, depth: depth + 1, issues: &issues)))
            case "a":
                guard pendingFolder == nil else { throw BookmarkFileError.invalidStructure("folder heading followed by a link without a DL") }
                let title = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let address = element.attributes?.first { $0.name?.lowercased() == "href" }?.stringValue ?? ""
                guard let url = URL(string: address), allowed(url) else {
                    issues.append(BookmarkImportIssue(title: title, reason: "Skipped missing or unsupported URL: \(address)"))
                    return
                }
                nodes.append(.bookmark(title: title.isEmpty ? address : title, url: url))
            case "script", "style":
                return
            case "dd" where element.children?.contains(where: { $0.name?.lowercased() == "h3" || $0.name?.lowercased() == "dl" }) == false:
                // DD descriptions may contain arbitrary links that are not bookmarks.
                return
            default:
                for child in element.children ?? [] { try consume(child) }
            }
        }
        for child in list.children ?? [] { try consume(child) }
        guard pendingFolder == nil else { throw BookmarkFileError.invalidStructure("folder missing its DL") }
        return nodes
    }

    public static func write(_ roots: [BookmarkNode], to url: URL) throws {
        let data = try export(roots)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func export(_ roots: [BookmarkNode]) throws -> Data {
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">", "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>"]
        var count = 0
        func append(_ nodes: [BookmarkNode], depth: Int) throws {
            guard depth <= 64 else { throw BookmarkFileError.tooLarge }
            let pad = String(repeating: "    ", count: depth + 1)
            for node in nodes {
                count += 1
                guard count <= maxNodes else { throw BookmarkFileError.tooLarge }
                switch node {
                case .bookmark(let title, let url):
                    guard allowed(url) else { throw BookmarkFileError.unsupportedURL(url.absoluteString) }
                    lines.append("\(pad)<DT><A HREF=\"\(escape(url.absoluteString))\">\(escape(title))</A>")
                case .folder(let title, let children):
                    lines.append("\(pad)<DT><H3>\(escape(title))</H3>")
                    lines.append("\(pad)<DL><p>")
                    try append(children, depth: depth + 1)
                    lines.append("\(pad)</DL><p>")
                }
            }
        }
        try append(roots, depth: 0)
        lines.append("</DL><p>")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= maxBytes else { throw BookmarkFileError.tooLarge }
        return data
    }

    private static func allowed(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
