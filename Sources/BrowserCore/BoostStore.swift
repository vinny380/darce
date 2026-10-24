import Foundation

public struct BrowserBoost: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let host: String
    public var name: String
    public var enabled: Bool
    public var css: String
    public var javascript: String?
    public var hiddenSelectors: [String]

    public init(id: UUID = UUID(), profileID: UUID, host: String, name: String, enabled: Bool = true, css: String = "", javascript: String? = nil, hiddenSelectors: [String] = []) {
        self.id = id
        self.profileID = profileID
        self.host = host.lowercased()
        self.name = name
        self.enabled = enabled
        self.css = css
        self.javascript = javascript
        self.hiddenSelectors = hiddenSelectors
    }
}

public enum BoostStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidBoost
    case recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Boosts use unsupported schema version \(version)."
        case .invalidBoost: "Boosts contain duplicate identities, an invalid host, or excessive content."
        case .recoveryRequired: "Boost saving is disabled to preserve an unreadable existing file."
        }
    }
}

public struct BoostStore: Sendable {
    private struct FileContents: Codable {
        var schemaVersion = 1
        var boosts: [BrowserBoost] = []
    }
    public let fileURL: URL
    public private(set) var boosts: [BrowserBoost]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { boosts = []; return }
        let file = try JSONDecoder().decode(FileContents.self, from: data)
        guard file.schemaVersion == 1 else { throw BoostStoreError.unsupportedSchema(file.schemaVersion) }
        try Self.validate(file.boosts)
        boosts = file.boosts
    }

    public func matching(profileID: UUID, host: String) -> [BrowserBoost] {
        boosts.filter { $0.profileID == profileID && $0.host == host.lowercased() && $0.enabled }
    }

    public mutating func save(_ boost: BrowserBoost) throws {
        var candidate = boosts
        if let index = candidate.firstIndex(where: { $0.id == boost.id }) {
            guard candidate[index].profileID == boost.profileID, candidate[index].host == boost.host else { throw BoostStoreError.invalidBoost }
            candidate[index] = boost
        } else { candidate.append(boost) }
        try commit(candidate)
    }

    public mutating func remove(id: UUID, profileID: UUID) throws {
        try commit(boosts.filter { !($0.id == id && $0.profileID == profileID) })
    }

    private mutating func commit(_ candidate: [BrowserBoost]) throws {
        guard candidate != boosts else { return }
        try Self.validate(candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileContents(boosts: candidate))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        boosts = candidate
    }

    private static func validate(_ boosts: [BrowserBoost]) throws {
        var ids = Set<UUID>()
        guard boosts.count <= 1000 else { throw BoostStoreError.invalidBoost }
        for boost in boosts {
            guard ids.insert(boost.id).inserted,
                  !boost.host.isEmpty, boost.host == boost.host.lowercased(),
                  !boost.host.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
                  boost.css.utf8.count <= 1_048_576, (boost.javascript?.utf8.count ?? 0) <= 1_048_576,
                  boost.hiddenSelectors.count <= 1000,
                  boost.hiddenSelectors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }) else { throw BoostStoreError.invalidBoost }
        }
    }
}
