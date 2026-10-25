import Foundation

/// Reads Arc's `StorableSidebar.json`: Spaces, their pinned and open tabs, and Favorites, grouped by the
/// Arc profile that owns them. In that file, dictionaries keyed by IDs are flat `[key, value, …]` arrays,
/// and enums are `{"case": {"_0": payload}}`.
public enum ArcSidebarReader {
    public enum ReadError: Error { case unrecognizedFormat }

    public static func read(sidebar: URL, userData: URL) throws -> [ImportedProfile] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: sidebar)) as? [String: Any]
        guard let containers = (root?["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else {
            throw ReadError.unrecognizedFormat
        }
        let items = pairs(main["items"]).reduce(into: [String: [String: Any]]()) { result, pair in
            if let id = pair.0 as? String, let item = pair.1 as? [String: Any] { result[id] = item }
        }
        var profiles: [ImportedProfile] = []
        func profileIndex(_ reference: Any?) -> Int {
            let directory = directoryName(reference)
            if let index = profiles.firstIndex(where: { $0.key == "arc:\(directory)" }) { return index }
            let folder = userData.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            profiles.append(ImportedProfile(key: "arc:\(directory)", name: directory, directory: exists ? folder : nil))
            return profiles.count - 1
        }

        for (_, value) in pairs(main["spaces"]) {
            guard let space = value as? [String: Any], let id = space["id"] as? String else { continue }
            let index = profileIndex(space["profile"])
            let containers = Dictionary(pairs(space["containerIDs"]).compactMap { pair -> (String, String)? in
                guard let kind = pair.0 as? String, let id = pair.1 as? String else { return nil }
                return (kind, id)
            }, uniquingKeysWith: { first, _ in first })
            var skipped: [String] = []
            let pinned = children(of: containers["pinned"], items: items, skipped: &skipped)
            let today = children(of: containers["unpinned"], items: items, skipped: &skipped)
            let custom = space["customInfo"] as? [String: Any]
            let title = (space["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            profiles[index].spaces.append(ImportedSpace(
                key: "arc-space:\(id)", name: title ?? "Space",
                icon: icon(custom?["iconType"]),
                tint: tint(custom?["windowTheme"]), pinned: pinned, today: today))
            profiles[index].skipped += skipped
        }
        for (reference, container) in pairs(main["topAppsContainerIDs"]) {
            let index = profileIndex(reference)
            var skipped: [String] = []
            profiles[index].favorites += children(of: container as? String, items: items, skipped: &skipped)
            profiles[index].skipped += skipped
        }
        return profiles
    }

    private static func pairs(_ value: Any?) -> [(Any, Any)] {
        guard let array = value as? [Any] else { return [] }
        return stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }

    /// `{"default":{}}` is the "Default" folder; `{"custom":{"_0":{"directoryBasename":…}}}` names its own.
    private static func directoryName(_ reference: Any?) -> String {
        let custom = ((reference as? [String: Any])?["custom"] as? [String: Any])?["_0"] as? [String: Any]
        return (custom?["directoryBasename"] as? String).flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? "Default"
    }

    private static func children(of id: String?, items: [String: [String: Any]], skipped: inout [String]) -> [ImportedItem] {
        guard let id, let ids = items[id]?["childrenIds"] as? [String] else { return [] }
        return ids.compactMap { item(items[$0], items: items, skipped: &skipped) }
    }

    private static func item(_ item: [String: Any]?, items: [String: [String: Any]], skipped: inout [String]) -> ImportedItem? {
        guard let item, let id = item["id"] as? String, let data = item["data"] as? [String: Any] else { return nil }
        let key = "arc:\(id)", title = item["title"] as? String
        if let tab = data["tab"] as? [String: Any] {
            let name = title ?? tab["savedTitle"] as? String ?? ""
            let address = tab["savedURL"] as? String ?? ""
            guard let url = ImportURL.supported(address) else {
                skipped.append("“\(name.isEmpty ? address : name)”: D'arce can't open this kind of address")
                return nil
            }
            return .tab(key: key, title: name.isEmpty ? address : name, url: url)
        }
        if data["list"] != nil {
            return .folder(key: key, title: title ?? "Folder", children: children(of: id, items: items, skipped: &skipped))
        }
        if let split = data["splitView"] as? [String: Any] {
            let panes = children(of: id, items: items, skipped: &skipped)
            return .split(key: key, panes: panes, vertical: split["layoutOrientation"] as? String == "vertical")
        }
        if let easel = data["easel"] as? [String: Any] {
            skipped.append("Easel “\(title ?? easel["title"] as? String ?? "Untitled")”: its contents live in Arc's cloud")
        }
        return nil
    }

    /// A Space's icon is either one of Arc's named icons (mapped to an SF Symbol) or an emoji.
    private static func icon(_ value: Any?) -> String? {
        guard let icon = value as? [String: Any] else { return nil }
        if let emoji = (icon["emoji"] ?? icon["icon"]) as? String, AppearancePreferences.isEmojiIcon(emoji) { return emoji }
        return (icon["icon"] as? String).flatMap(symbol(forArcIcon:))
    }

    /// Arc's icon names, mapped to the closest SF Symbol. Unknown names keep D'arce's default icon.
    public static func symbol(forArcIcon name: String) -> String? {
        var base = name.lowercased()
        for affix in ["outline", "sharp"] where base.hasSuffix(affix) { base.removeLast(affix.count) }
        if base.hasPrefix("logo") { base.removeFirst(4) }
        return arcIcons[base]
    }

    private static let arcIcons: [String: String] = [
        "airplane": "airplane", "albums": "square.stack.fill", "apps": "square.grid.2x2.fill", "bandage": "bandage.fill",
        "barbell": "dumbbell.fill", "baseball": "baseball.fill", "book": "book.fill", "bookmark": "bookmark.fill",
        "briefcase": "briefcase.fill", "bulb": "lightbulb.fill", "calendar": "calendar", "camera": "camera.fill",
        "cart": "cart.fill", "chatbubbles": "bubble.left.and.bubble.right.fill", "checkbox": "checkmark.square.fill",
        "cloud": "cloud.fill", "code": "chevron.left.forwardslash.chevron.right", "colorpalette": "paintpalette.fill",
        "construct": "hammer.fill", "copy": "doc.on.doc.fill", "document": "doc.fill", "ellipse": "circle.fill",
        "figma": "paintbrush.pointed.fill", "filetray": "tray.fill", "flag": "flag.fill", "flash": "bolt.fill",
        "folder": "folder.fill", "gamecontroller": "gamecontroller.fill", "gift": "gift.fill",
        "github": "chevron.left.forwardslash.chevron.right", "globe": "globe", "grid": "square.grid.3x3.fill",
        "heart": "heart.fill", "home": "house.fill", "layers": "square.3.layers.3d", "leaf": "leaf.fill",
        "mail": "envelope.fill", "medical": "cross.case.fill", "moon": "moon.fill", "musicalnotes": "music.note",
        "notifications": "bell.fill", "people": "person.2.fill", "person": "person.fill", "planet": "globe.americas.fill",
        "receipt": "doc.text.fill", "restaurant": "fork.knife", "rocket": "paperplane.fill", "school": "graduationcap.fill",
        "search": "magnifyingglass", "shapes": "square.on.circle", "skull": "theatermasks.fill", "square": "square.fill",
        "star": "star.fill", "sunny": "sun.max.fill", "terminal": "terminal.fill", "thumbsup": "hand.thumbsup.fill",
        "train": "tram.fill", "triangle": "triangle.fill", "video": "video.fill", "videocam": "video.fill",
    ]

    private static func tint(_ theme: Any?) -> AppearanceColor? {
        var node: Any? = theme
        for key in ["background", "single", "_0", "style", "color", "_0", "blendedSingleColor", "_0", "color"] {
            node = (node as? [String: Any])?[key]
        }
        guard let color = node as? [String: Any],
              let red = color["red"] as? Double, let green = color["green"] as? Double, let blue = color["blue"] as? Double else { return nil }
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        return AppearanceColor(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }
}
