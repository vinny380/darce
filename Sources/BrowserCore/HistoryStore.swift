import Foundation

public struct HistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    public var visitedAt: Date
    public let profileID: UUID
}

public struct HistoryGroup: Equatable, Sendable {
    public let day: Date
    public let records: [HistoryRecord]
}

public enum HistoryStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidRecords
    case unsupportedURL

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "History uses unsupported schema version \(version)."
        case .invalidRecords: "History contains invalid URLs, dates, or duplicate records."
        case .unsupportedURL: "Only HTTP and HTTPS pages can be recorded in history."
        }
    }
}

/// One writer per file. All mutations save before changing the in-memory snapshot.
public struct HistoryStore: Sendable {
    private struct FileContents: Codable {
        var schemaVersion = 1
        var records: [HistoryRecord] = []
    }

    public let fileURL: URL
    private var records: [HistoryRecord]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            records = []
            return
        }
        let contents = try JSONDecoder().decode(FileContents.self, from: data)
        guard contents.schemaVersion == 1 else {
            throw HistoryStoreError.unsupportedSchema(contents.schemaVersion)
        }
        try Self.validate(contents.records)
        records = contents.records
    }

    /// Imported visits in one write: known pages keep the newer visit, new pages are added. Returns how many are new.
    @discardableResult
    public mutating func merge(_ visits: [ImportedVisit], profileID: UUID) throws -> Int {
        var candidate = records
        var positions = Dictionary(candidate.indices.filter { candidate[$0].profileID == profileID }
            .map { (candidate[$0].url.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        for visit in visits where Self.allowed(visit.url) {
            let key = visit.url.absoluteString
            if let index = positions[key] {
                guard visit.visitedAt > candidate[index].visitedAt else { continue }
                candidate[index].visitedAt = visit.visitedAt
                if !visit.title.isEmpty { candidate[index].title = visit.title }
            } else {
                candidate.append(HistoryRecord(id: UUID(), url: visit.url, title: visit.title.isEmpty ? key : visit.title,
                                               visitedAt: visit.visitedAt, profileID: profileID))
                positions[key] = candidate.count - 1
                added += 1
            }
        }
        guard candidate != records else { return 0 }
        try commit(candidate)
        return added
    }

    public mutating func record(
        url: URL, title: String, profileID: UUID, visitedAt: Date = Date()
    ) throws {
        guard Self.allowed(url) else { throw HistoryStoreError.unsupportedURL }
        var candidate = records
        if let index = candidate.firstIndex(where: { $0.profileID == profileID && $0.url.absoluteString == url.absoluteString }) {
            guard visitedAt >= candidate[index].visitedAt else { return }
            candidate[index].visitedAt = visitedAt
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidate[index].title = title
            }
        } else {
            candidate.append(HistoryRecord(
                id: UUID(), url: url, title: title.isEmpty ? url.absoluteString : title,
                visitedAt: visitedAt, profileID: profileID
            ))
        }
        try commit(candidate)
    }

    public func search(_ query: String = "", profileID: UUID, limit: Int = 100) -> [HistoryRecord] {
        let boundedLimit = min(max(limit, 0), 500)
        guard boundedLimit > 0 else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(records.filter { record in
            record.profileID == profileID && words.allSatisfy { word in
                record.title.localizedStandardContains(word) || record.url.absoluteString.localizedStandardContains(word)
            }
        }.sorted {
            $0.visitedAt == $1.visitedAt ? $0.id.uuidString < $1.id.uuidString : $0.visitedAt > $1.visitedAt
        }.prefix(boundedLimit))
    }

    public func groups(
        matching query: String = "", profileID: UUID, limit: Int = 500, calendar: Calendar = .current
    ) -> [HistoryGroup] {
        let matches = search(query, profileID: profileID, limit: limit)
        let grouped = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.visitedAt) }
        return grouped.keys.sorted(by: >).map { HistoryGroup(day: $0, records: grouped[$0] ?? []) }
    }

    public mutating func remove(id: UUID, profileID: UUID) throws {
        try commit(records.filter { !($0.id == id && $0.profileID == profileID) })
    }

    /// Removes visits on or after `since`; nil removes this profile's complete history.
    public mutating func clear(profileID: UUID, since: Date? = nil) throws {
        try commit(records.filter { record in
            record.profileID != profileID || since.map { record.visitedAt < $0 } == true
        })
    }

    private mutating func commit(_ candidate: [HistoryRecord]) throws {
        guard candidate != records else { return }
        try Self.validate(candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileContents(records: candidate))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        records = candidate
    }

    private static func validate(_ records: [HistoryRecord]) throws {
        struct Key: Hashable { let profile: UUID; let url: String }
        var ids = Set<UUID>(), keys = Set<Key>()
        for record in records {
            guard allowed(record.url), record.visitedAt.timeIntervalSinceReferenceDate.isFinite,
                  ids.insert(record.id).inserted,
                  keys.insert(Key(profile: record.profileID, url: record.url.absoluteString)).inserted else {
                throw HistoryStoreError.invalidRecords
            }
        }
    }

    private static func allowed(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }
}
