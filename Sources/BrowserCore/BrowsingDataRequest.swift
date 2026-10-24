import Foundation

public enum BrowsingDataCategory: String, Codable, CaseIterable, Sendable {
    case cookies, cache, siteStorage, history

    public var title: String {
        switch self {
        case .cookies: "Cookies"
        case .cache: "Cached Images and Files"
        case .siteStorage: "Website Storage and Offline Data"
        case .history: "Browsing History"
        }
    }
}

public struct BrowsingDataRequest: Equatable, Sendable {
    public let profileID: UUID
    public let categories: Set<BrowsingDataCategory>

    public init(profileID: UUID, categories: Set<BrowsingDataCategory>) {
        self.profileID = profileID
        self.categories = categories
    }

    public var requiresRendererReset: Bool {
        !categories.intersection([.cookies, .cache, .siteStorage]).isEmpty
    }
}

public enum BrowsingDataError: Error, LocalizedError {
    case emptySelection, wrongDataStore, operationInProgress, rendererDidNotStop, profileUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Choose at least one category to clear."
        case .wrongDataStore: "The website-data store does not match the requested profile. Nothing was cleared."
        case .operationInProgress: "A browsing-data clear is already in progress."
        case .rendererDidNotStop: "An open page could not be unloaded. Website data was not cleared."
        case .profileUnavailable: "The selected profile is unavailable."
        }
    }
}

@MainActor
public protocol BrowsingDataBackend {
    func clear(_ request: BrowsingDataRequest) async throws
}
