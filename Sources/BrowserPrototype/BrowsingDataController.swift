import BrowserCore
import Combine
import Foundation

@MainActor
final class BrowsingDataController: ObservableObject {
    @Published private(set) var isClearing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionMessage: String?
    @Published private(set) var lastProfileID: UUID?
    private let backend: any BrowsingDataBackend
    private let prepareRenderers: @MainActor (UUID) async throws -> Void
    private let finishRenderers: @MainActor (UUID) -> Void
    private let clearHistory: @MainActor (UUID) throws -> Void

    init(backend: any BrowsingDataBackend,
         prepareRenderers: @escaping @MainActor (UUID) async throws -> Void,
         finishRenderers: @escaping @MainActor (UUID) -> Void,
         clearHistory: @escaping @MainActor (UUID) throws -> Void) {
        self.backend = backend
        self.prepareRenderers = prepareRenderers
        self.finishRenderers = finishRenderers
        self.clearHistory = clearHistory
    }

    @discardableResult
    func clear(_ request: BrowsingDataRequest) async -> Bool {
        guard !isClearing else { return false }
        lastProfileID = request.profileID
        completionMessage = nil
        errorMessage = nil
        guard !request.categories.isEmpty else { errorMessage = BrowsingDataError.emptySelection.localizedDescription; return false }
        isClearing = true
        var prepared = false
        var clearedWebsiteData = false
        defer {
            if prepared { finishRenderers(request.profileID) }
            isClearing = false
        }
        do {
            if request.requiresRendererReset {
                prepared = true
                try await prepareRenderers(request.profileID)
            }
            try await backend.clear(request)
            clearedWebsiteData = request.requiresRendererReset
            if request.categories.contains(.history) { try clearHistory(request.profileID) }
            completionMessage = "The selected browsing data has been cleared."
            return true
        } catch {
            errorMessage = clearedWebsiteData
                ? "Website data was cleared, but browsing history could not be cleared: \(error.localizedDescription)"
                : "Browsing data could not be cleared: \(error.localizedDescription)"
            return false
        }
    }
}
