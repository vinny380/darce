import Foundation

/// Selection belongs to a window; browser content and profile ownership belong to the workspace.
public struct BrowserWindowSelection: Equatable, Sendable {
    public var selectedSpaceID: UUID
    public var selectedTabID: UUID?
    public var selectedTabBySpace: [UUID: UUID]

    public init(state: BrowserState) {
        selectedSpaceID = state.selectedSpaceID
        selectedTabID = state.selectedTabID
        selectedTabBySpace = state.selectedTabBySpace
    }
}

public enum BrowserWorkspaceError: Error, LocalizedError {
    case unknownWindow
    case reentrantMutation

    public var errorDescription: String? {
        switch self {
        case .unknownWindow: "The browser window is no longer open."
        case .reentrantMutation: "A workspace mutation cannot start another workspace mutation."
        }
    }
}

/// One instance per session file. Main-actor transactions always start from the latest shared state.
@MainActor
public final class BrowserWorkspaceStore {
    public let fileURL: URL
    public let isVolatile: Bool
    public private(set) var state: BrowserState
    private var windows: [UUID: BrowserWindowSelection] = [:]
    private var observers: [UUID: (BrowserState) -> Void] = [:]
    private var isUpdating = false

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        isVolatile = false
        state = try BrowserStateFile.read(from: fileURL)
    }

    /// Explicit recovery path: all windows share a fresh in-memory workspace; the unreadable file is never written.
    public init(preservingUnreadableFile fileURL: URL) {
        self.fileURL = fileURL
        isVolatile = true
        state = BrowserState()
    }

    @discardableResult
    public func openWindow(selection: BrowserWindowSelection? = nil) -> UUID {
        let id = UUID()
        windows[id] = BrowserWindowSelection(state: selection.map { state.applying(windowSelection: $0) } ?? state)
        return id
    }

    public func closeWindow(_ id: UUID) {
        windows.removeValue(forKey: id)
        observers.removeValue(forKey: id)
    }

    public func state(for windowID: UUID) -> BrowserState? {
        windows[windowID].map { state.applying(windowSelection: $0) }
    }

    /// Does not send an initial event; callers read state(for:) when constructing their window.
    @discardableResult
    public func observe(windowID: UUID, _ observer: @escaping (BrowserState) -> Void) -> Bool {
        guard windows[windowID] != nil else { return false }
        observers[windowID] = observer
        return true
    }

    public func update(windowID: UUID, _ mutation: (inout BrowserState) -> Void) throws {
        guard try commit(windowID: windowID, mutation) else { return }
        // Read current projections at delivery time: an earlier callback may perform a later transaction.
        for id in Array(observers.keys) {
            if let observer = observers[id], let snapshot = state(for: id) { observer(snapshot) }
        }
    }

    public var protectedTabIDs: Set<UUID> {
        windows.values.reduce(into: Set<UUID>()) { result, selection in
            result.formUnion(selection.selectedTabBySpace.values)
            result.formUnion(state.applying(windowSelection: selection).displayedTabIDs)
        }
    }

    @discardableResult
    public func autoArchive(windowID: UUID, olderThan age: TimeInterval?, now: Date = Date(), protecting additionalIDs: Set<UUID> = []) throws -> [UUID] {
        let protected = protectedTabIDs.union(additionalIDs)
        var archived: [UUID] = []
        try update(windowID: windowID) { candidate in
            archived = candidate.autoArchive(olderThan: age, now: now, protecting: protected)
        }
        return archived
    }

    @discardableResult
    public func autoArchive(windowID: UUID, settings: BrowserSettings, now: Date = Date(), protecting additionalIDs: Set<UUID> = []) throws -> [UUID] {
        let protected = protectedTabIDs.union(additionalIDs)
        var archived: [UUID] = []
        try update(windowID: windowID) { candidate in
            archived = candidate.autoArchive(settings: settings, now: now, protecting: protected)
        }
        return archived
    }

    private func commit(windowID: UUID, _ mutation: (inout BrowserState) -> Void) throws -> Bool {
        guard !isUpdating else { throw BrowserWorkspaceError.reentrantMutation }
        guard let initial = state(for: windowID) else { throw BrowserWorkspaceError.unknownWindow }
        isUpdating = true
        defer { isUpdating = false }
        var candidate = initial
        mutation(&candidate)
        guard windows[windowID] != nil else { throw BrowserWorkspaceError.unknownWindow }
        guard candidate != initial else { return false }
        if !isVolatile { try BrowserStateFile.write(candidate, to: fileURL) }
        state = candidate
        windows[windowID] = BrowserWindowSelection(state: candidate)
        for id in Array(windows.keys) {
            if let selection = windows[id] {
                windows[id] = BrowserWindowSelection(state: candidate.applying(windowSelection: selection))
            }
        }
        return true
    }
}
