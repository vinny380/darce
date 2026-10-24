import Foundation

public enum BrowserStateFileError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidReferences

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Browser state uses unsupported schema version \(version)."
        case .invalidReferences:
            "Browser state contains duplicate IDs, invalid folders, missing Spaces or profiles, or an invalid tab selection."
        }
    }
}

public enum BrowserStateFile {
    public static func read(from url: URL) throws -> BrowserState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return BrowserState()
        }
        let state = try JSONDecoder().decode(BrowserState.self, from: data)
        try state.validate()
        return state
    }

    public static func write(_ state: BrowserState, to url: URL) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
