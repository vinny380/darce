import Foundation

/// What a browser import found, independent of the browser it came from. Every item carries a key
/// unique to its source (e.g. "arc:<itemID>") so importing again never duplicates it.
public indirect enum ImportedItem: Equatable, Sendable {
    case tab(key: String, title: String, url: URL)
    case folder(key: String, title: String, children: [ImportedItem])
    /// Panes are `.tab`s shown side by side.
    case split(key: String, panes: [ImportedItem], vertical: Bool)
}

public struct ImportedSpace: Equatable, Sendable {
    public var key: String
    public var name: String
    /// An SF Symbol name or a single emoji.
    public var icon: String?
    public var tint: AppearanceColor?
    public var pinned: [ImportedItem]
    public var today: [ImportedItem]

    public init(key: String, name: String, icon: String? = nil, tint: AppearanceColor? = nil,
                pinned: [ImportedItem] = [], today: [ImportedItem] = []) {
        self.key = key; self.name = name; self.icon = icon; self.tint = tint; self.pinned = pinned; self.today = today
    }
}

public struct ImportedVisit: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var visitedAt: Date

    public init(url: URL, title: String, visitedAt: Date) { self.url = url; self.title = title; self.visitedAt = visitedAt }
}

/// An extension the person installed from the Chrome Web Store.
public struct ImportedExtension: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The unpacked extension in the browser's profile, used when the Web Store has no package for it.
    public var files: URL?

    public init(id: String, name: String, files: URL?) { self.id = id; self.name = name; self.files = files }
}

/// A cookie read from another browser, decrypted, ready to hand to WebKit.
public struct ImportedCookie: Equatable, Sendable {
    public var domain: String
    public var name: String
    public var value: String
    public var path: String
    /// nil for a session cookie.
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    /// "lax", "strict", or nil.
    public var sameSite: String?

    public init(domain: String, name: String, value: String, path: String, expires: Date?, secure: Bool, httpOnly: Bool, sameSite: String?) {
        self.domain = domain; self.name = name; self.value = value; self.path = path
        self.expires = expires; self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
    }
}

public struct ImportedProfile: Equatable, Sendable {
    /// e.g. "arc:Default", "chrome:Profile 1".
    public var key: String
    public var name: String
    /// The browser's own profile folder, or nil when it isn't on this Mac.
    public var directory: URL?
    /// Arc only.
    public var spaces: [ImportedSpace] = []
    public var favorites: [ImportedItem] = []
    /// Already rooted: bookmark bar items, then "Other Bookmarks" / "Mobile Bookmarks" folders.
    public var bookmarks: [ImportedItem] = []
    public var history: [ImportedVisit] = []
    /// Human-readable lines for "Didn't come over".
    public var skipped: [String] = []

    public init(key: String, name: String, directory: URL?) { self.key = key; self.name = name; self.directory = directory }
}

enum ImportURL {
    /// Only addresses a D'arce tab can open (it doesn't open local files).
    static func supported(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? url : nil }
        return string == "about:blank" ? url : nil
    }
}
