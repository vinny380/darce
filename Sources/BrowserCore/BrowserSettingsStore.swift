import Foundation

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckDuckGo, google, bing, brave

    public var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave"
        }
    }

    public func searchURL(for query: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .duckDuckGo: components.host = "duckduckgo.com"; components.path = "/"
        case .google: components.host = "www.google.com"; components.path = "/search"
        case .bing: components.host = "www.bing.com"; components.path = "/search"
        case .brave: components.host = "search.brave.com"; components.path = "/search"
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search services treat unescaped '+' as a space even though URLComponents permits it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public enum AutoArchiveAge: String, Codable, CaseIterable, Sendable {
    case twelveHours, oneDay, sevenDays, thirtyDays, never

    public var name: String {
        switch self {
        case .twelveHours: "After 12 Hours"
        case .oneDay: "After 24 Hours"
        case .sevenDays: "After 7 Days"
        case .thirtyDays: "After 30 Days"
        case .never: "Never"
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .never: nil
        }
    }
}

public struct BrowserSettings: Codable, Equatable, Sendable {
    public private(set) var schemaVersion = 1
    public var searchEngine = SearchEngine.duckDuckGo
    public var autoArchiveAge = AutoArchiveAge.twelveHours
    public private(set) var autoArchiveAgeByProfile: [UUID: AutoArchiveAge]?
    public var pinnedExternalLinksOpenPeek = true
    public var defaultZoom: Double = 1
    // Added with the Arc-style Settings window. Stored as optionals so older settings files still decode;
    // nil means the default named in each accessor.
    private var searchEngineByProfile: [UUID: SearchEngine]?
    private var shiftClickPeek: Bool?
    private var optionCommandClickMini: Bool?
    private var externalLinksMini: Bool?
    private var globalMiniShortcut: Bool?
    private var boosts: Bool?
    private var haptics: Bool?
    private var fullURL: Bool?

    public init() {}

    public func searchEngine(forProfile id: UUID) -> SearchEngine { searchEngineByProfile?[id] ?? searchEngine }

    public mutating func setSearchEngine(_ engine: SearchEngine?, forProfile id: UUID) {
        var overrides = searchEngineByProfile ?? [:]
        overrides[id] = engine
        searchEngineByProfile = overrides.isEmpty ? nil : overrides
    }

    /// Shift-click a link to preview it in a Peek.
    public var shiftClickOpensPeek: Bool { get { shiftClickPeek ?? true } set { shiftClickPeek = newValue } }
    /// ⌥⌘-click a link to open it in a mini window.
    public var optionCommandClickOpensMiniWindow: Bool { get { optionCommandClickMini ?? true } set { optionCommandClickMini = newValue } }
    /// Links from other apps (when D'arce is the default browser) open in a mini window instead of a tab.
    public var externalLinksOpenInMiniWindow: Bool { get { externalLinksMini ?? true } set { externalLinksMini = newValue } }
    /// ⌥⌘N opens a mini window from any app. Off by default: it would take over Finder's New Smart Folder.
    public var globalMiniWindowShortcut: Bool { get { globalMiniShortcut ?? false } set { globalMiniShortcut = newValue } }
    public var boostsEnabled: Bool { get { boosts ?? true } set { boosts = newValue } }
    /// A tap from the trackpad when a dragged tab lands.
    public var hapticFeedback: Bool { get { haptics ?? true } set { haptics = newValue } }
    /// The sidebar's address field shows the whole URL rather than the site name.
    public var showFullURL: Bool { get { fullURL ?? false } set { fullURL = newValue } }

    public func autoArchiveAge(forProfile id: UUID) -> AutoArchiveAge {
        autoArchiveAgeByProfile?[id] ?? autoArchiveAge
    }

    public mutating func setAutoArchiveAge(_ age: AutoArchiveAge?, forProfile id: UUID) {
        var overrides = autoArchiveAgeByProfile ?? [:]
        overrides[id] = age
        autoArchiveAgeByProfile = overrides.isEmpty ? nil : overrides
    }
}

public enum BrowserSettingsError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidZoom

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Browser settings use unsupported schema version \(version)."
        case .invalidZoom: "Default zoom must be a finite number from 25% to 300%."
        }
    }
}

/// A single writer publishes its candidate only after validation and an atomic filesystem write.
public struct BrowserSettingsStore: Sendable {
    public let fileURL: URL
    public private(set) var state: BrowserSettings

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = BrowserSettings()
            return
        }
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: data)
        try Self.validate(decoded)
        state = decoded
    }

    public mutating func update(_ change: (inout BrowserSettings) throws -> Void) throws {
        var candidate = state
        try change(&candidate)
        try Self.validate(candidate)
        guard candidate != state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        state = candidate
    }

    private static func validate(_ state: BrowserSettings) throws {
        guard state.schemaVersion == 1 else { throw BrowserSettingsError.unsupportedSchema(state.schemaVersion) }
        guard state.defaultZoom.isFinite, (0.25...3).contains(state.defaultZoom) else { throw BrowserSettingsError.invalidZoom }
    }
}
