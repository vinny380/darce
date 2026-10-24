import BrowserCore
import Combine
import Foundation
import WebKit

/// Owns every shared writer; BrowserModel instances own only window state and renderers.
@MainActor
final class BrowserWorkspaceSession: ObservableObject {
    private static var sessions: [URL: WeakWorkspaceSession] = [:]

    static func open(directory: URL, ephemeralWebsiteData: Bool = false, downloadsDirectory: URL? = nil) -> BrowserWorkspaceSession {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = sessions[key]?.value { return existing }
        let session = BrowserWorkspaceSession(directory: key, ephemeralWebsiteData: ephemeralWebsiteData, downloadsDirectory: downloadsDirectory)
        sessions[key] = WeakWorkspaceSession(session)
        return session
    }

    let store: BrowserWorkspaceStore
    let documents: DocumentController
    let settings: SettingsController
    let appearance: AppearanceController
    let boosts: BoostController
    let downloads: DownloadManager
    let favicons = FaviconController()
    let loadError: String?
    @Published private(set) var history: HistoryStore?
    @Published private(set) var clearingProfiles: Set<UUID> = []
    private let ephemeralWebsiteData: Bool
    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private var models: [UUID: WeakBrowserModel] = [:]
    private var observations: Set<AnyCancellable> = []

    private init(directory: URL, ephemeralWebsiteData: Bool = false, downloadsDirectory: URL? = nil) {
        self.ephemeralWebsiteData = ephemeralWebsiteData
        let file = directory.appendingPathComponent("session.json")
        var errors: [String] = []
        do { store = try BrowserWorkspaceStore(fileURL: file) }
        catch {
            store = BrowserWorkspaceStore(preservingUnreadableFile: file)
            errors.append("Session could not be loaded. Saving is disabled to preserve the original file. \(error.localizedDescription)")
        }
        documents = DocumentController(directory: directory)
        settings = SettingsController(directory: directory)
        appearance = AppearanceController(directory: directory)
        boosts = BoostController(directory: directory)
        downloads = DownloadManager(directory: directory, downloadsDirectory: downloadsDirectory)
        do { history = try HistoryStore(fileURL: directory.appendingPathComponent("history.json")) }
        catch { errors.append("History could not be loaded and will not be overwritten: \(error.localizedDescription)") }
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        appearance.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        boosts.onChange = { [weak self] in self?.liveModels.forEach { $0.refreshBoosts() } }
        boosts.globallyEnabled = settings.state.boostsEnabled
        settings.onChange = { [weak self] state in
            guard let self else { return }
            GlobalMiniWindowShortcut.shared.setEnabled(state.globalMiniWindowShortcut)
            guard self.boosts.globallyEnabled != state.boostsEnabled else { return }
            self.boosts.globallyEnabled = state.boostsEnabled
            self.liveModels.forEach { $0.refreshBoosts() }
        }
    }

    private var liveModels: [BrowserModel] { models.values.compactMap(\.value) }
    var displayedSplitTabIDs: Set<UUID> { Set(liveModels.flatMap { $0.state.displayedTabIDs }) }

    func register(_ model: BrowserModel) { models[model.windowID] = WeakBrowserModel(model) }
    func unregister(windowID: UUID) { models.removeValue(forKey: windowID); store.closeWindow(windowID) }

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if let existing = stores[profileID] { return existing }
        let value = ephemeralWebsiteData || store.isVolatile ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: profileID)
        stores[profileID] = value
        return value
    }

    func updateHistory(_ change: (inout HistoryStore) throws -> Void) throws {
        guard var candidate = history else { throw BrowsingDataError.profileUnavailable }
        try change(&candidate)
        history = candidate
    }

    lazy var browsingData = BrowsingDataController(
        backend: WebKitBrowsingDataBackend { [weak self] profileID in
            guard let self, self.store.state.profiles.contains(where: { $0.id == profileID }) else {
                throw BrowsingDataError.profileUnavailable
            }
            return self.dataStore(for: profileID)
        },
        prepareRenderers: { [weak self] profileID in
            guard let self else { throw BrowsingDataError.profileUnavailable }
            guard self.store.state.profiles.contains(where: { $0.id == profileID }) else { throw BrowsingDataError.profileUnavailable }
            guard self.dataStore(for: profileID).identifier == profileID else { throw BrowsingDataError.wrongDataStore }
            self.clearingProfiles.insert(profileID)
            // Gate all windows before the first await, so none can recreate a renderer during deletion.
            for model in self.liveModels { try await model.prepareBrowsingDataRemoval(profileID) }
        },
        finishRenderers: { [weak self] profileID in
            guard let self else { return }
            self.clearingProfiles.remove(profileID)
            for model in self.liveModels { model.finishBrowsingDataRemoval(profileID) }
        },
        clearHistory: { [weak self] profileID in
            guard let self else { throw BrowsingDataError.profileUnavailable }
            try self.updateHistory { try $0.clear(profileID: profileID) }
        }
    )
}

@MainActor
private final class WeakBrowserModel {
    weak var value: BrowserModel?
    init(_ value: BrowserModel) { self.value = value }
}

@MainActor
private final class WeakWorkspaceSession {
    weak var value: BrowserWorkspaceSession?
    init(_ value: BrowserWorkspaceSession) { self.value = value }
}
