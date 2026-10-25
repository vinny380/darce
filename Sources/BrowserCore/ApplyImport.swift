import Foundation

public enum ImportDestination: Equatable, Sendable {
    /// One D'arce profile per source profile (a fresh install reuses its own profile for the first).
    case newProfiles
    case existing(UUID)
}

public struct ImportOptions: Equatable, Sendable {
    public var spacesAndTabs = true
    public var bookmarks = true
    public var history = true
    public var cookies = true
    /// Clear the D'arce profile's cookies first. nil = only for profiles this import creates.
    public var replaceCookies: Bool?
    public var extensions = true
    public init() {}
}

public struct SpaceStyle: Equatable, Sendable {
    /// An SF Symbol name or a single emoji.
    public var icon: String?
    public var tint: AppearanceColor?
    public init(icon: String?, tint: AppearanceColor?) { self.icon = icon; self.tint = tint }
}

public struct ProfileHistory: Equatable, Sendable {
    public var profileID: UUID
    public var visits: [ImportedVisit]
}

/// What the app still has to do after the sidebar changes (Space looks, folder collapse, history), and what to report.
public struct ImportOutcome: Equatable, Sendable {
    public var spaceStyles: [UUID: SpaceStyle] = [:]
    public var collapsedFolderIDs: [UUID] = []
    public var history: [ProfileHistory] = []
    /// New items only: "spaces", "tabs", "folders", "favorites", "bookmarks". History is counted when it's merged.
    public var counts: [String: Int] = ["spaces": 0, "tabs": 0, "folders": 0, "favorites": 0, "bookmarks": 0]
    public var skipped: [String] = []
    public var firstSpaceID: UUID?
    /// Source profile key → the D'arce profile it went into, and which of those this import created.
    public var profileIDs: [String: UUID] = [:]
    public var newProfileIDs: Set<UUID> = []
    public init() {}
}

extension BrowserState {
    /// Only the untouched starter sidebar: one profile, "Personal" and "Work", nothing in them.
    public var isFresh: Bool {
        profiles.count == 1 && spaces.map(\.name) == ["Personal", "Work"] && tabs.isEmpty && folders.isEmpty && importedIDs.isEmpty
    }

    /// Adds everything new in `imported` to the sidebar. Items already imported, including ones the user has
    /// since deleted, are never added again; new items inside an already-imported Space or folder land in it.
    public mutating func applyImport(_ imported: [ImportedProfile], from browser: ImportBrowser,
                                     into destination: ImportDestination, options: ImportOptions) -> ImportOutcome {
        var outcome = ImportOutcome()
        let starter = isFresh ? Set(spaces.map(\.id)) : []
        let originalSpace = selectedSpaceID, originalTab = selectedTabID
        var reusedStarterProfile = starter.isEmpty
        for source in imported {
            outcome.skipped += source.skipped
            importProfile(source, from: browser, into: destination, options: options, starter: starter,
                          reusedStarterProfile: &reusedStarterProfile, outcome: &outcome)
        }
        finishImport()
        if outcome.firstSpaceID != nil {
            for id in starter { deleteSpace(id) }
        }
        if spaces.contains(where: { $0.id == originalSpace }) {
            if selectedSpaceID != originalSpace { selectSpace(originalSpace) }
            if selectedTabID != originalTab {
                if let originalTab, tabs.contains(where: { $0.id == originalTab }) { selectTab(originalTab) } else { clearSelection() }
            }
        } else if let first = outcome.firstSpaceID {
            selectSpace(first)
            clearSelection()
        }
        return outcome
    }

    private mutating func importProfile(_ source: ImportedProfile, from browser: ImportBrowser, into destination: ImportDestination,
                                        options: ImportOptions, starter: Set<UUID>, reusedStarterProfile: inout Bool,
                                        outcome: inout ImportOutcome) {
        let wantsSpaces = options.spacesAndTabs
            && (hasNew(source.spaces.flatMap { [ImportedItem.folder(key: $0.key, title: "", children: $0.pinned + $0.today)] })
                || hasNew(source.favorites))
        let wantsBookmarks = options.bookmarks && hasNew(source.bookmarks)
        let wantsHistory = options.history && !source.history.isEmpty
        let wantsCookies = options.cookies && source.cookieCount > 0
        guard wantsSpaces || wantsBookmarks || wantsHistory || wantsCookies else { return }

        let profileKey = "\(source.key):profile"
        let profileID: UUID
        switch destination {
        case .existing(let id):
            guard profiles.contains(where: { $0.id == id }) else { return }
            profileID = id
        case .newProfiles:
            if let known = importedIDs[profileKey] {
                guard profiles.contains(where: { $0.id == known }) else { return }
                profileID = known
            } else if !reusedStarterProfile {
                profileID = profiles[0].id
                renameProfile(profileID, name: source.name)
                reusedStarterProfile = true
                importedIDs[profileKey] = profileID
                outcome.newProfileIDs.insert(profileID)
            } else {
                profileID = addProfile(name: source.name)
                importedIDs[profileKey] = profileID
                outcome.newProfileIDs.insert(profileID)
            }
        }
        outcome.profileIDs[source.key] = profileID

        var firstSpace: UUID?
        func note(_ space: UUID, _ outcome: inout ImportOutcome) {
            firstSpace = firstSpace ?? space
            outcome.firstSpaceID = outcome.firstSpaceID ?? space
        }
        if options.spacesAndTabs {
            for space in source.spaces {
                guard let (spaceID, created) = resolve(space.key, exists: { state, id in state.spaces.contains { $0.id == id } },
                                                       create: { $0.makeSpace(space.name, profileID: profileID) }) else { continue }
                if created {
                    outcome.counts["spaces", default: 0] += 1
                    if space.icon != nil || space.tint != nil { outcome.spaceStyles[spaceID] = SpaceStyle(icon: space.icon, tint: space.tint) }
                }
                note(spaceID, &outcome)
                importItems(space.pinned, kind: .pinned, space: spaceID, folder: nil, counter: "tabs", outcome: &outcome)
                importItems(space.today, kind: .today, space: spaceID, folder: nil, counter: "tabs", outcome: &outcome)
            }
        }
        // Favorites and bookmarks need a Space in the profile: the first imported one, else one the user already
        // has (never a starter Space about to be removed), else a new one named after the profile.
        func homeSpace(_ state: inout BrowserState, _ outcome: inout ImportOutcome) -> UUID? {
            if let firstSpace { return firstSpace }
            if let existing = state.spaces.first(where: { $0.profileID == profileID && !starter.contains($0.id) })?.id {
                note(existing, &outcome)
                return existing
            }
            guard let (id, created) = state.resolve("\(source.key):space", exists: { state, id in state.spaces.contains { $0.id == id } },
                                                    create: { $0.makeSpace(source.name, profileID: profileID) }) else { return nil }
            if created { outcome.counts["spaces", default: 0] += 1 }
            note(id, &outcome)
            return id
        }
        if options.spacesAndTabs, hasNew(source.favorites), let space = homeSpace(&self, &outcome) {
            importItems(source.favorites, kind: .favorite, space: space, folder: nil, counter: "favorites", outcome: &outcome)
        }
        if wantsBookmarks, let space = homeSpace(&self, &outcome),
           let (container, created) = resolve("\(source.key):bookmarks", exists: { state, id in state.folders.contains { $0.id == id } },
                                              create: { $0.createFolder(name: "Bookmarks from \(browser.displayName)", spaceID: space) }) {
            if created {
                outcome.counts["folders", default: 0] += 1
                outcome.collapsedFolderIDs.append(container)
            }
            let containerSpace = folders.first { $0.id == container }?.spaceID ?? space
            importItems(source.bookmarks, kind: .pinned, space: containerSpace, folder: container, counter: "bookmarks", outcome: &outcome)
        }
        if case .newProfiles = destination, firstSpace == nil, !spaces.contains(where: { $0.profileID == profileID && !starter.contains($0.id) }) {
            _ = homeSpace(&self, &outcome)   // a new profile is unusable without a Space
        }
        if wantsHistory { outcome.history.append(ProfileHistory(profileID: profileID, visits: source.history)) }
    }

    private func hasNew(_ items: [ImportedItem]) -> Bool {
        items.contains { item in
            switch item {
            case .tab(let key, _, _): importedIDs[key] == nil
            case .folder(_, _, let children), .split(_, let children, _): hasNew(children)
            }
        }
    }

    /// The D'arce ID for `key`: the existing one, nil when the user deleted it, or a new one from `create`.
    private mutating func resolve(_ key: String, exists: (BrowserState, UUID) -> Bool,
                                  create: (inout BrowserState) -> UUID?) -> (UUID, created: Bool)? {
        if let known = importedIDs[key] { return exists(self, known) ? (known, false) : nil }
        guard let id = create(&self) else { return nil }
        importedIDs[key] = id
        return (id, true)
    }

    private mutating func makeSpace(_ name: String, profileID: UUID) -> UUID {
        let id = addSpace(name: name)
        assignSpaceProfile(id, profileID: profileID)
        return id
    }

    private mutating func makeTab(_ title: String, url: URL, kind: TabKind, space: UUID, folder: UUID?) -> UUID {
        appendImportedTab(title: title, url: url, kind: kind, spaceID: space, folderID: folder)
    }

    private mutating func importItems(_ items: [ImportedItem], kind: TabKind, space: UUID, folder: UUID?,
                                      counter: String, outcome: inout ImportOutcome) {
        for item in items {
            switch item {
            case .tab(let key, let title, let url):
                guard importedIDs[key] == nil else { continue }
                importedIDs[key] = makeTab(title, url: url, kind: kind, space: space, folder: folder)
                outcome.counts[counter, default: 0] += 1
            case .folder(let key, let title, let children):
                // Only pinned tabs live in folders; elsewhere a folder's tabs come in flat.
                guard kind == .pinned else {
                    importItems(children, kind: kind, space: space, folder: nil, counter: counter, outcome: &outcome)
                    continue
                }
                guard let (id, created) = resolve(key, exists: { state, id in state.folders.contains { $0.id == id } },
                                                  create: { $0.createFolder(name: title, spaceID: space, parentID: folder) }) else { continue }
                if created {
                    outcome.counts["folders", default: 0] += 1
                    outcome.collapsedFolderIDs.append(id)
                }
                importItems(children, kind: kind, space: space, folder: id, counter: counter, outcome: &outcome)
            case .split(let key, let panes, let vertical):
                // ponytail: an already-imported split isn't rebuilt; panes added to it later are skipped.
                guard importedIDs[key] == nil else { continue }
                var ids: [UUID] = []
                for case .tab(let paneKey, let title, let url) in panes where importedIDs[paneKey] == nil {
                    let id = makeTab(title, url: url, kind: kind, space: space, folder: folder)
                    importedIDs[paneKey] = id
                    ids.append(id)
                    outcome.counts[counter, default: 0] += 1
                }
                guard let first = ids.first else { continue }
                importedIDs[key] = first
                appendImportedSplit(Array(ids.prefix(4)), spaceID: space, vertical: vertical)
            }
        }
    }
}
