import Foundation

public enum BrowserAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public struct AppearanceColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum SpaceThemeWheel: String, Codable, CaseIterable, Sendable {
    case complimentary, analogous
}

public struct SpaceThemeSettings: Codable, Equatable, Sendable {
    public var colorCount: Int = 1
    public var wheel: SpaceThemeWheel = .complimentary
    public var intensity: Double = 0.8
    public init() {}
}

public struct SpaceAppearance: Codable, Equatable, Sendable {
    public var tint: AppearanceColor
    public var icon: String
    public var collapsedFolderIDs: Set<UUID>
    public var pinnedCollapsed: Bool
    public var theme: SpaceThemeSettings?

    public init(tint: AppearanceColor = AppearanceColor(red: 0.80, green: 0.81, blue: 0.90),
                icon: String = "house.fill", collapsedFolderIDs: Set<UUID> = [], pinnedCollapsed: Bool = false,
                theme: SpaceThemeSettings? = nil) {
        self.tint = tint
        self.icon = icon
        self.collapsedFolderIDs = collapsedFolderIDs
        self.pinnedCollapsed = pinnedCollapsed
        self.theme = theme
    }
}

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public private(set) var schemaVersion = 2
    public var sidebarWidth: Double = 252
    public var sidebarVisible = true
    public var appearance = BrowserAppearance.system
    public var spaces: [UUID: SpaceAppearance] = [:]

    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, sidebarWidth, sidebarVisible, appearance, spaces }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw AppearanceStoreError.unsupportedSchema(version) }
        // Migration is in memory only. AppearanceStore's successful atomic update
        // is the sole writer, including the first schema2 write.
        schemaVersion = 2
        sidebarWidth = try values.decode(Double.self, forKey: .sidebarWidth)
        sidebarVisible = try values.decode(Bool.self, forKey: .sidebarVisible)
        appearance = try values.decode(BrowserAppearance.self, forKey: .appearance)
        spaces = try values.decode([UUID: SpaceAppearance].self, forKey: .spaces)
    }
    public func space(_ id: UUID) -> SpaceAppearance { spaces[id] ?? SpaceAppearance() }
}

public enum AppearanceStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidValues

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Appearance preferences use unsupported schema version \(version)."
        case .invalidValues: "Appearance preferences contain invalid colors, icon names, or sidebar width."
        }
    }
}

/// One writer per file. A new snapshot is visible only after its atomic write succeeds.
public struct AppearanceStore: Sendable {
    public let fileURL: URL
    public private(set) var state: AppearancePreferences

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = AppearancePreferences()
            return
        }
        let decoded = try JSONDecoder().decode(AppearancePreferences.self, from: data)
        try Self.validate(decoded)
        state = decoded
    }

    public mutating func update(_ change: (inout AppearancePreferences) throws -> Void) throws {
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

    private static func validate(_ state: AppearancePreferences) throws {
        guard state.schemaVersion == 2 else { throw AppearanceStoreError.unsupportedSchema(state.schemaVersion) }
        let iconCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard state.sidebarWidth.isFinite, (210...360).contains(state.sidebarWidth),
              state.spaces.values.allSatisfy({ space in
                  [space.tint.red, space.tint.green, space.tint.blue, space.tint.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
                  (space.theme.map { (1...3).contains($0.colorCount) && $0.intensity.isFinite && (0...1).contains($0.intensity) } ?? true) &&
                  (AppearancePreferences.isEmojiIcon(space.icon) || (!space.icon.isEmpty && space.icon.utf8.count <= 128 &&
                   space.icon.unicodeScalars.allSatisfy { iconCharacters.contains($0) }))
              }) else { throw AppearanceStoreError.invalidValues }
    }
}

extension AppearancePreferences {
    /// One emoji (imported Arc Spaces use them as icons): a single character drawn as emoji by default
    /// or with the emoji variation selector, so plain digits and symbols don't count.
    public static func isEmojiIcon(_ icon: String) -> Bool {
        guard icon.count == 1, icon.utf8.count <= 32, let first = icon.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || icon.unicodeScalars.contains("\u{FE0F}")
    }
}
