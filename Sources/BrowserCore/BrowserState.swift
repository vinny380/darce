import Foundation

public enum TabKind: String, Codable, CaseIterable, Sendable {
    case favorite
    case pinned
    case today
    case archived
}

public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var name: String
}

public struct BrowserSpace: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var name: String
    public internal(set) var profileID: UUID
}

public struct BrowserFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var name: String
    public internal(set) var spaceID: UUID
    public internal(set) var parentID: UUID?
}

public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var spaceID: UUID
    public internal(set) var url: URL
    public internal(set) var title: String
    public internal(set) var customTitle: String?
    public internal(set) var kind: TabKind
    public internal(set) var folderID: UUID?
    public internal(set) var homeURL: URL?
    public internal(set) var lastActiveAt: Date
    public internal(set) var archivedAt: Date?

    init(id: UUID, spaceID: UUID, url: URL, title: String, kind: TabKind, now: Date) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.kind = kind
        lastActiveAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, url, title, customTitle, kind, folderID, homeURL, lastActiveAt, archivedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        url = try values.decode(URL.self, forKey: .url)
        title = try values.decode(String.self, forKey: .title)
        customTitle = try values.decodeIfPresent(String.self, forKey: .customTitle)
        kind = try values.decode(TabKind.self, forKey: .kind)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        homeURL = try values.decodeIfPresent(URL.self, forKey: .homeURL)
        if homeURL == nil && (kind == .pinned || kind == .favorite) { homeURL = url }
        // Old sessions have no activity clock; give them a full grace period on migration.
        lastActiveAt = try values.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? Date()
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

public struct BrowserState: Codable, Equatable, Sendable {
    public private(set) var schemaVersion = 5
    public private(set) var autoArchiveStartTime: Date?
    public private(set) var profiles: [BrowserProfile]
    public private(set) var spaces: [BrowserSpace]
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var folders: [BrowserFolder] = []
    public private(set) var splitGroups: [BrowserSplitGroup] = []
    public private(set) var selectedSpaceID: UUID
    public private(set) var selectedTabID: UUID?
    public private(set) var selectedTabBySpace: [UUID: UUID] = [:]

    public init() {
        let profile = BrowserProfile(id: UUID(), name: "Default")
        profiles = [profile]
        let personal = BrowserSpace(id: UUID(), name: "Personal", profileID: profile.id)
        spaces = [personal, BrowserSpace(id: UUID(), name: "Work", profileID: profile.id)]
        selectedSpaceID = personal.id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, splitGroups, autoArchiveStartTime, profiles, spaces, tabs, folders, selectedSpaceID, selectedTabID, selectedTabBySpace
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...5).contains(version) else {
            throw BrowserStateFileError.unsupportedSchema(version)
        }
        if version < 3 {
            struct LegacySpace: Decodable { let id: UUID; let name: String }
            // Stable across repeated reads before the migrated session is first saved.
            let profile = BrowserProfile(id: UUID(uuidString: "7618E265-C11D-4FAE-91C9-EEA3F59F54CB")!, name: "Default")
            profiles = [profile]
            spaces = try values.decode([LegacySpace].self, forKey: .spaces).map {
                BrowserSpace(id: $0.id, name: $0.name, profileID: profile.id)
            }
        } else {
            profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
            spaces = try values.decode([BrowserSpace].self, forKey: .spaces)
        }
        splitGroups = version >= 5 ? try values.decode([BrowserSplitGroup].self, forKey: .splitGroups) : []
        autoArchiveStartTime = try values.decodeIfPresent(Date.self, forKey: .autoArchiveStartTime)
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        folders = try values.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
        selectedSpaceID = try values.decode(UUID.self, forKey: .selectedSpaceID)
        selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        selectedTabBySpace = try values.decodeIfPresent([UUID: UUID].self, forKey: .selectedTabBySpace) ?? [:]
        if version == 1, let selectedTabID { selectedTabBySpace[selectedSpaceID] = selectedTabID }
    }

    /// Projects shared content into one window without recording activity or changing another window.
    public func applying(windowSelection: BrowserWindowSelection) -> BrowserState {
        var result = self
        if spaces.contains(where: { $0.id == windowSelection.selectedSpaceID }) {
            result.selectedSpaceID = windowSelection.selectedSpaceID
        }
        result.selectedTabBySpace = windowSelection.selectedTabBySpace.filter { spaceID, tabID in
            spaces.contains(where: { $0.id == spaceID }) && tabs.contains { $0.id == tabID && isVisible($0, in: spaceID) }
        }
        if let selected = windowSelection.selectedTabID {
            result.selectedTabID = result.visibleTabs.contains(where: { $0.id == selected }) ? selected : result.visibleTabs.first?.id
        } else {
            result.selectedTabID = nil
        }
        result.selectedTabBySpace[result.selectedSpaceID] = result.selectedTabID
        return result
    }

    public var visibleTabs: [BrowserTab] {
        [.favorite, .pinned, .today].flatMap { kind in
            tabs.filter { $0.kind == kind && isVisible($0, in: selectedSpaceID) }
        }
    }

    public var selectedTab: BrowserTab? { visibleTabs.first { $0.id == selectedTabID } }

    public var selectedProfileID: UUID {
        spaces.first { $0.id == selectedSpaceID }!.profileID
    }

    public func profileID(forTab id: UUID) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        return spaces.first { $0.id == tab.spaceID }?.profileID
    }

    @discardableResult
    public mutating func addProfile(name: String) -> UUID {
        let profile = BrowserProfile(id: UUID(), name: cleaned(name, fallback: "Untitled Profile"))
        profiles.append(profile)
        return profile.id
    }

    public mutating func renameProfile(_ id: UUID, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = cleaned(name, fallback: "Untitled Profile")
    }

    /// Reassigns every tab in the Space, including archived tabs, without transferring cookies.
    /// Callers must recreate cached renderers if their resolved profile ID changes.
    @discardableResult
    public mutating func assignSpaceProfile(_ id: UUID, profileID: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }),
              let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        spaces[index].profileID = profileID
        repairSelection()
        return true
    }

    @discardableResult
    public mutating func addSpace(name: String) -> UUID {
        let space = BrowserSpace(id: UUID(), name: cleaned(name, fallback: "Untitled Space"), profileID: selectedProfileID)
        spaces.append(space)
        return space.id
    }

    public mutating func renameSpace(_ id: UUID, name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = cleaned(name, fallback: "Untitled Space")
    }

    /// Removes only the Space container; all contents retain their IDs and profile ownership.
    @discardableResult
    public mutating func removeSpace(_ id: UUID, movingContentsTo destinationID: UUID) -> Bool {
        guard spaces.count > 1, id != destinationID,
              let source = spaces.first(where: { $0.id == id }),
              let destination = spaces.first(where: { $0.id == destinationID }),
              source.profileID == destination.profileID else { return false }
        for index in tabs.indices where tabs[index].spaceID == id { tabs[index].spaceID = destinationID }
        for index in folders.indices where folders[index].spaceID == id { folders[index].spaceID = destinationID }
        for index in splitGroups.indices where splitGroups[index].spaceID == id { splitGroups[index].spaceID = destinationID }
        spaces.removeAll { $0.id == id }
        selectedTabBySpace.removeValue(forKey: id)
        if selectedSpaceID == id { selectedSpaceID = destinationID }
        repairSelection()
        return true
    }

    @discardableResult
    public mutating func createFolder(name: String, spaceID: UUID, parentID: UUID? = nil) -> UUID? {
        guard spaces.contains(where: { $0.id == spaceID }),
              parentID == nil || folders.contains(where: { $0.id == parentID && $0.spaceID == spaceID }) else { return nil }
        let folder = BrowserFolder(id: UUID(), name: cleaned(name, fallback: "Untitled Folder"), spaceID: spaceID, parentID: parentID)
        folders.append(folder)
        return folder.id
    }

    public mutating func renameFolder(_ id: UUID, name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = cleaned(name, fallback: "Untitled Folder")
    }

    /// Deletes only this folder; its direct children and pins move to its parent.
    @discardableResult
    public mutating func deleteFolder(_ id: UUID) -> Bool {
        guard let removed = folders.first(where: { $0.id == id }) else { return false }
        for index in folders.indices where folders[index].parentID == id { folders[index].parentID = removed.parentID }
        for index in tabs.indices where tabs[index].folderID == id { tabs[index].folderID = removed.parentID }
        folders.removeAll { $0.id == id }
        return true
    }

    @discardableResult
    public mutating func moveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }),
              parentID == nil || folders.contains(where: { $0.id == parentID && $0.spaceID == folders[index].spaceID }) else { return false }
        var ancestor = parentID
        var visited: Set<UUID> = [id]
        while let current = ancestor {
            guard visited.insert(current).inserted else { return false }
            ancestor = folders.first { $0.id == current }?.parentID
        }
        folders[index].parentID = parentID
        return true
    }

    @discardableResult
    public mutating func openTab(url: URL, title: String? = nil, now: Date = Date()) -> UUID {
        let tab = BrowserTab(id: UUID(), spaceID: selectedSpaceID, url: url,
                             title: title ?? url.host ?? url.absoluteString, kind: .today, now: now)
        tabs.append(tab)
        selectedTabID = tab.id
        selectedTabBySpace[selectedSpaceID] = tab.id
        return tab.id
    }

    @discardableResult
    public mutating func renameTab(_ id: UUID, title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs[index].customTitle = name
        tabs[index].title = name
        return true
    }

    /// Copies the current URL and pin metadata into the same owning Space/profile.
    /// Archived tabs must be restored before duplication.
    @discardableResult
    public mutating func duplicateTab(_ id: UUID, now: Date = Date()) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].kind != .archived else { return nil }
        let original = tabs[index]
        var copy = BrowserTab(id: UUID(), spaceID: original.spaceID, url: original.url,
                              title: original.title, kind: original.kind, now: now)
        copy.customTitle = original.customTitle
        copy.folderID = original.folderID
        copy.homeURL = original.homeURL
        tabs.insert(copy, at: index + 1)
        selectTab(copy.id, now: now)
        return copy.id
    }

    public mutating func selectSpace(_ id: UUID, now: Date = Date()) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        selectedTabID = selectedTabBySpace[id]
        repairSelection()
        if let selectedTabID { touch(selectedTabID, now: now) }
    }

    public mutating func clearSelection() {
        selectedTabID = nil
        selectedTabBySpace.removeValue(forKey: selectedSpaceID)
    }

    public mutating func selectTab(_ id: UUID, now: Date = Date()) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind != .archived else { return }
        if !isVisible(tab, in: selectedSpaceID) { selectedSpaceID = tab.spaceID }
        selectedTabID = id
        selectedTabBySpace[selectedSpaceID] = id
        touch(id, now: now)
    }

    public mutating func setKind(_ id: UUID, kind: TabKind, now: Date = Date()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if kind == .archived && tabs[index].kind != .today { return }
        if kind == .pinned || kind == .favorite {
            if tabs[index].homeURL == nil { tabs[index].homeURL = tabs[index].url }
        } else { tabs[index].homeURL = nil }
        if kind != .pinned { tabs[index].folderID = nil }
        tabs[index].kind = kind
        tabs[index].archivedAt = kind == .archived ? now : nil
        repairSelection()
    }

    public mutating func archiveTab(_ id: UUID, now: Date = Date()) { setKind(id, kind: .archived, now: now) }

    /// Explicit split close includes saved pins; ordinary archive still protects them.
    public mutating func closePane(_ id: UUID, from groupID: UUID, now: Date = Date()) {
        guard let group = selectedSplitGroup, group.id == groupID,
              let removedIndex = group.tabIDs.firstIndex(of: id),
              let index = tabs.firstIndex(where: { $0.id == id && $0.kind != .archived }) else { return }
        let survivors = group.tabIDs.filter { $0 != id }
        let replacement = selectedTabID == id && !survivors.isEmpty
            ? survivors[min(removedIndex, survivors.count - 1)] : nil
        tabs[index].kind = .archived
        tabs[index].archivedAt = now
        tabs[index].folderID = nil
        repairSelection()
        if let replacement { selectTab(replacement, now: now) }
    }

    public mutating func restoreTab(_ id: UUID, select: Bool = true, now: Date = Date()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].kind == .archived else { return }
        tabs[index].kind = .today
        tabs[index].url = tabs[index].homeURL ?? tabs[index].url
        tabs[index].homeURL = nil
        tabs[index].archivedAt = nil
        if select { selectTab(id, now: now) }
    }

    public mutating func moveTab(_ id: UUID, to spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }),
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].spaceID != spaceID { tabs[index].folderID = nil }
        tabs[index].spaceID = spaceID
        repairSelection()
    }

    @discardableResult
    public mutating func moveTab(_ id: UUID, into folderID: UUID?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].kind != .archived else { return false }
        if let folderID {
            guard let folder = folders.first(where: { $0.id == folderID }) else { return false }
            tabs[index].spaceID = folder.spaceID
            setKind(id, kind: .pinned)
        }
        tabs[index].folderID = folderID
        repairSelection()
        return true
    }

    @discardableResult
    public mutating func reorderTab(_ id: UUID, before targetID: UUID?) -> Bool {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[source]
        let siblings = tabs.filter {
            $0.kind == tab.kind && isVisible($0, in: tab.spaceID) && $0.folderID == tab.folderID
        }
        if let targetID, !siblings.contains(where: { $0.id == targetID }) { return false }
        if targetID == id { return true }
        tabs.remove(at: source)
        let destination: Int
        if let targetID, let index = tabs.firstIndex(where: { $0.id == targetID }) {
            destination = index
        } else {
            let siblingIDs = Set(siblings.map(\.id))
            destination = tabs.lastIndex(where: { siblingIDs.contains($0.id) }).map { $0 + 1 } ?? min(source, tabs.count)
        }
        tabs.insert(tab, at: destination)
        return true
    }

    /// Drag and drop: the tab joins a section of the selected Space (Favorites, Pinned or a folder, Today) and
    /// lands before `targetID`, or at the section's end. Validates first, so a rejected drop changes nothing.
    @discardableResult
    public mutating func placeTab(_ id: UUID, kind: TabKind, folderID: UUID?, before targetID: UUID?) -> Bool {
        guard kind != .archived, let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].kind != .archived else { return false }
        if targetID == id { return true }
        let folderID = kind == .pinned ? folderID : nil
        if let targetID {
            guard let target = tabs.first(where: { $0.id == targetID }), target.kind == kind, target.folderID == folderID,
                  isVisible(target, in: selectedSpaceID) else { return false }
        }
        if let folderID, !folders.contains(where: { $0.id == folderID && $0.spaceID == selectedSpaceID }) { return false }
        _ = removeFromSplit(id)  // dragging a pane somewhere else takes it out of its split
        if tabs[index].kind != kind { setKind(id, kind: kind) }
        // Favorites are shared across a profile's Spaces; everything else belongs to the Space it was dropped in.
        if kind != .favorite || !isVisible(tabs[index], in: selectedSpaceID) { tabs[index].spaceID = selectedSpaceID }
        tabs[index].folderID = folderID
        return reorderTab(id, before: targetID)
    }

    public mutating func resetPinnedTab(_ id: UUID, now: Date = Date()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].kind == .pinned || tabs[index].kind == .favorite,
              let home = tabs[index].homeURL else { return }
        tabs[index].url = home
        touch(id, now: now)
    }

    public mutating func initializeAutoArchiveClock(now: Date = Date()) {
        guard autoArchiveStartTime == nil, now.timeIntervalSinceReferenceDate.isFinite else { return }
        autoArchiveStartTime = now
    }

    @discardableResult
    public mutating func autoArchive(olderThan age: TimeInterval?, now: Date = Date(), protecting additionalIDs: Set<UUID> = []) -> [UUID] {
        if let age, !age.isFinite || age < 0 { return [] }
        return autoArchive(now: now, protecting: additionalIDs) { _ in age }
    }

    @discardableResult
    public mutating func autoArchive(settings: BrowserSettings, now: Date = Date(), protecting additionalIDs: Set<UUID> = []) -> [UUID] {
        let agesBySpace = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, settings.autoArchiveAge(forProfile: $0.profileID)) })
        return autoArchive(now: now, protecting: additionalIDs) { tab in
            (agesBySpace[tab.spaceID] ?? settings.autoArchiveAge).interval
        }
    }

    private mutating func autoArchive(now: Date, protecting additionalIDs: Set<UUID>, ageForTab: (BrowserTab) -> TimeInterval?) -> [UUID] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        initializeAutoArchiveClock(now: now)
        guard let start = autoArchiveStartTime else { return [] }
        let protected = Set(selectedTabBySpace.values).union(displayedTabIDs).union(additionalIDs)
        let expired = tabs.filter { tab in
            guard tab.kind == .today, !protected.contains(tab.id),
                  let age = ageForTab(tab), age.isFinite, age >= 0 else { return false }
            return now.timeIntervalSince(start) > age && now.timeIntervalSince(tab.lastActiveAt) > age
        }.map(\.id)
        for id in expired { archiveTab(id, now: now) }
        return expired
    }

    public mutating func updateTab(_ id: UUID, url: URL? = nil, title: String? = nil, now: Date = Date()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url { tabs[index].url = url }
        if let title, tabs[index].customTitle == nil { tabs[index].title = title }
        if selectedTabID == id { touch(id, now: now) }
    }

    private mutating func touch(_ id: UUID, now: Date) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].lastActiveAt = now
    }

    private func cleaned(_ name: String, fallback: String) -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    private func isVisible(_ tab: BrowserTab, in spaceID: UUID) -> Bool {
        guard tab.kind != .archived else { return false }
        if tab.kind != .favorite { return tab.spaceID == spaceID }
        guard let owner = spaces.first(where: { $0.id == tab.spaceID }),
              let destination = spaces.first(where: { $0.id == spaceID }) else { return false }
        return owner.profileID == destination.profileID
    }

    private mutating func repairSelection() {
        repairSplits()
        selectedTabBySpace = selectedTabBySpace.filter { space, tab in
            tabs.contains { $0.id == tab && isVisible($0, in: space) }
        }
        if selectedTab == nil { selectedTabID = visibleTabs.first?.id }
        selectedTabBySpace[selectedSpaceID] = selectedTabID
    }

    func validate() throws {
        guard schemaVersion == 5 else { throw BrowserStateFileError.unsupportedSchema(schemaVersion) }
        let spaceIDs = Set(spaces.map(\.id)), tabIDs = Set(tabs.map(\.id)), folderIDs = Set(folders.map(\.id))
        let profileIDs = Set(profiles.map(\.id))
        guard !profiles.isEmpty, profileIDs.count == profiles.count,
              spaces.allSatisfy({ profileIDs.contains($0.profileID) }),
              !spaces.isEmpty, spaceIDs.count == spaces.count, tabIDs.count == tabs.count,
              folderIDs.count == folders.count, spaceIDs.isDisjoint(with: tabIDs),
              spaceIDs.isDisjoint(with: folderIDs), tabIDs.isDisjoint(with: folderIDs),
              spaceIDs.contains(selectedSpaceID), selectedTabID == nil || selectedTab != nil,
              tabs.allSatisfy({ tab in
                  spaceIDs.contains(tab.spaceID) && (tab.folderID == nil ||
                    (tab.kind == .pinned && folders.contains { $0.id == tab.folderID && $0.spaceID == tab.spaceID }))
              }),
              selectedTabBySpace.allSatisfy({ space, tab in
                  spaceIDs.contains(space) && tabs.contains {
                      $0.id == tab && isVisible($0, in: space)
                  }
              }) else { throw BrowserStateFileError.invalidReferences }
        try validateSplits()
        for folder in folders {
            guard spaceIDs.contains(folder.spaceID) else { throw BrowserStateFileError.invalidReferences }
            var ancestor = folder.parentID
            var visited: Set<UUID> = [folder.id]
            while let current = ancestor {
                guard visited.insert(current).inserted,
                      let parent = folders.first(where: { $0.id == current && $0.spaceID == folder.spaceID }) else {
                    throw BrowserStateFileError.invalidReferences
                }
                ancestor = parent.parentID
            }
        }
    }
}

extension BrowserState {
    public var selectedSplitGroup: BrowserSplitGroup? {
        guard let selectedTabID else { return nil }
        return splitGroups.first { $0.spaceID == selectedSpaceID && $0.tabIDs.contains(selectedTabID) }
    }

    public var displayedTabIDs: [UUID] { selectedSplitGroup?.tabIDs ?? selectedTabID.map { [$0] } ?? [] }

    @discardableResult
    public mutating func addToSplit(_ tabID: UUID) -> Bool {
        guard let selectedTabID, selectedTabID != tabID, visibleTabs.contains(where: { $0.id == tabID }) else { return false }
        if let group = selectedSplitGroup, let index = splitGroups.firstIndex(where: { $0.id == group.id }) {
            if group.tabIDs.contains(tabID) { return true }
            guard group.tabIDs.count < 4, !splitGroups.contains(where: { $0.tabIDs.contains(tabID) }) else { return false }
            let newWeight = 1 / Double(group.tabIDs.count + 1)
            splitGroups[index].weights = group.weights.map { $0 * (1 - newWeight) } + [newWeight]
            splitGroups[index].tabIDs.append(tabID)
        } else {
            guard !splitGroups.contains(where: { $0.tabIDs.contains(tabID) || $0.tabIDs.contains(selectedTabID) }) else { return false }
            splitGroups.append(BrowserSplitGroup(id: UUID(), spaceID: selectedSpaceID, tabIDs: [selectedTabID, tabID], weights: [0.5, 0.5], axis: .horizontal))
        }
        return true
    }

    @discardableResult
    public mutating func resizeSplit(_ id: UUID, weights: [Double]) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }), BrowserSplitGroup.validWeights(weights, count: splitGroups[index].tabIDs.count) else { return false }
        splitGroups[index].weights = weights
        return true
    }

    @discardableResult
    public mutating func setSplitAxis(_ id: UUID, axis: BrowserSplitAxis) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }) else { return false }
        splitGroups[index].axis = axis
        return true
    }

    @discardableResult
    public mutating func reorderSplit(_ id: UUID, tabIDs: [UUID]) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }), tabIDs.count == splitGroups[index].tabIDs.count,
              Set(tabIDs) == Set(splitGroups[index].tabIDs) else { return false }
        let old = splitGroups[index]
        splitGroups[index].weights = tabIDs.map { old.weights[old.tabIDs.firstIndex(of: $0)!] }
        splitGroups[index].tabIDs = tabIDs
        return true
    }

    @discardableResult
    public mutating func removeFromSplit(_ tabID: UUID) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.tabIDs.contains(tabID) }),
              let member = splitGroups[index].tabIDs.firstIndex(of: tabID) else { return false }
        splitGroups[index].tabIDs.remove(at: member)
        splitGroups[index].weights.remove(at: member)
        if splitGroups[index].tabIDs.count < 2 { splitGroups.remove(at: index) }
        else { normalizeSplit(at: index) }
        return true
    }

    /// Drag and drop onto a sidebar tab: the dragged tab joins the target's split (or starts one) and takes focus.
    /// A pane dragged from another split leaves it. Validates first, so a rejected drop changes nothing.
    @discardableResult
    public mutating func splitTab(_ id: UUID, onto targetID: UUID) -> Bool {
        let visible = visibleTabs.map(\.id)
        guard id != targetID, visible.contains(id), visible.contains(targetID) else { return false }
        let targetGroup = splitGroups.first { $0.tabIDs.contains(targetID) }
        if targetGroup?.tabIDs.contains(id) == true { return true }
        guard (targetGroup?.tabIDs.count ?? 1) < 4 else { return false }
        _ = removeFromSplit(id)
        selectTab(targetID)
        guard addToSplit(id) else { return false }
        selectTab(id)
        return true
    }

    @discardableResult
    public mutating func dissolveSplit(_ id: UUID) -> Bool {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }) else { return false }
        splitGroups.remove(at: index)
        return true
    }

    private mutating func normalizeSplit(at index: Int) {
        let sum = splitGroups[index].weights.reduce(0, +)
        splitGroups[index].weights = splitGroups[index].weights.map { $0 / sum }
    }

    private mutating func repairSplits() {
        for index in splitGroups.indices.reversed() {
            let group = splitGroups[index]
            let retained = group.tabIDs.indices.filter { member in
                tabs.contains { $0.id == group.tabIDs[member] && isVisible($0, in: group.spaceID) }
            }
            guard retained.count != group.tabIDs.count else { continue }
            if retained.count < 2 { splitGroups.remove(at: index); continue }
            splitGroups[index].tabIDs = retained.map { group.tabIDs[$0] }
            splitGroups[index].weights = retained.map { group.weights[$0] }
            normalizeSplit(at: index)
        }
    }

    private func validateSplits() throws {
        var groupIDs: Set<UUID> = [], members: Set<UUID> = []
        let contentIDs = Set(tabs.map(\.id) + folders.map(\.id) + spaces.map(\.id))
        for group in splitGroups {
            guard groupIDs.insert(group.id).inserted, !contentIDs.contains(group.id),
                  spaces.contains(where: { $0.id == group.spaceID }), (2...4).contains(group.tabIDs.count),
                  BrowserSplitGroup.validWeights(group.weights, count: group.tabIDs.count) else { throw BrowserStateFileError.invalidReferences }
            for id in group.tabIDs {
                guard members.insert(id).inserted, tabs.contains(where: { $0.id == id && isVisible($0, in: group.spaceID) }) else { throw BrowserStateFileError.invalidReferences }
            }
        }
    }
}
