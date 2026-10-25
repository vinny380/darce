import Foundation
@testable import BrowserCore

/// Builds Arc's sidebar file the way Arc writes it: dictionaries keyed by IDs are flat
/// `[key, value, …]` arrays, and enums are `{"case": {"_0": payload}}`.
struct ArcSidebarFixture {
    private var spaces: [Any] = []
    private var items: [Any] = []
    private var topApps: [Any] = []
    private var next = 0

    static var defaultProfile: [String: Any] { ["default": [String: Any]()] }
    static func customProfile(_ directory: String) -> [String: Any] {
        ["custom": ["_0": ["directoryBasename": directory, "machineID": "fixture"]]]
    }

    private mutating func newID(_ prefix: String) -> String { next += 1; return "\(prefix)-\(next)" }

    /// A node to place in a container: a tab, a folder ("list"), or a split.
    indirect enum Node {
        case tab(String, String)                 // title, url
        case folder(String, [Node])
        case split([Node], vertical: Bool)
    }

    @discardableResult
    private mutating func add(_ node: Node, parent: String) -> String {
        let id = newID("item")
        var children: [String] = []
        let data: [String: Any]
        var title: Any = NSNull()
        switch node {
        case .tab(let name, let url):
            data = ["tab": ["savedURL": url, "savedTitle": name]]
        case .folder(let name, let nodes):
            title = name
            data = ["list": [String: Any]()]
            children = nodes.map { add($0, parent: id) }
        case .split(let nodes, let vertical):
            data = ["splitView": ["layoutOrientation": vertical ? "vertical" : "horizontal"]]
            children = nodes.map { add($0, parent: id) }
        }
        items += [id, ["id": id, "parentID": parent, "childrenIds": children, "title": title, "data": data] as [String: Any]]
        return id
    }

    private mutating func container(_ type: [String: Any], nodes: [Node]) -> String {
        let id = newID("container")
        let children = nodes.map { add($0, parent: id) }
        items += [id, ["id": id, "parentID": NSNull(), "childrenIds": children, "title": NSNull(),
                       "data": ["itemContainer": ["containerType": type]]] as [String: Any]]
        return id
    }

    @discardableResult
    mutating func space(title: String?, profile: [String: Any] = defaultProfile, icon: [String: String]? = nil,
                        color: (Double, Double, Double)? = nil, pinned: [Node] = [], today: [Node] = []) -> String {
        let id = newID("space")
        let pinnedID = container(["spaceItems": ["_0": id]], nodes: pinned)
        let todayID = container(["spaceItems": ["_0": id]], nodes: today)
        var custom: [String: Any] = [:]
        if let icon { custom["iconType"] = icon }
        if let color {
            let rgb: [String: Any] = ["red": color.0, "green": color.1, "blue": color.2, "alpha": 1, "colorSpace": "extendedSRGB"]
            custom["windowTheme"] = ["background": ["single": ["_0": ["style": ["color": ["_0": [
                "blendedSingleColor": ["_0": ["color": rgb]]]]]]]]]
        }
        spaces += [id, ["id": id, "title": title as Any? ?? NSNull(), "profile": profile,
                        "containerIDs": ["pinned", pinnedID, "unpinned", todayID], "customInfo": custom] as [String: Any]]
        return id
    }

    mutating func favorites(_ nodes: [Node], profile: [String: Any] = defaultProfile) {
        topApps += [profile, container(["topApps": ["_0": profile]], nodes: nodes)]
    }

    func data() throws -> Data {
        let root: [String: Any] = ["version": 1, "sidebar": ["containers": [
            ["global": [String: Any]()],
            ["spaces": spaces, "items": items, "topAppsContainerIDs": topApps],
        ]]]
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// The standard fixture: "Work" (emoji, color, nested pins, a split, one Today tab, one unsupported pin),
    /// an unnamed Space, a Space on a custom profile that isn't on disk, and two Favorites.
    static func standard() -> ArcSidebarFixture {
        var fixture = ArcSidebarFixture()
        fixture.space(title: "Work", icon: ["icon": "planet"], color: (0.2, 0.4, 0.6), pinned: [
            .tab("Mail", "https://mail.example/"),
            .folder("Docs", [.tab("Spec", "https://docs.example/spec"), .folder("Deep", [.tab("Note", "https://docs.example/note")])]),
            .split([.tab("Left", "https://left.example/"), .tab("Right", "https://right.example/")], vertical: false),
            .tab("Bad", "javascript:alert(1)"),
            .tab("Local", "file:///Users/me/report.pdf"),
        ], today: [.tab("News", "https://news.example/")])
        fixture.space(title: nil, icon: ["emoji": "🚀"])
        fixture.space(title: "Side", profile: customProfile("Profile 9"), pinned: [.tab("Side", "https://side.example/")])
        fixture.favorites([.tab("Calendar", "https://calendar.example/"), .tab("Chat", "https://chat.example/")])
        return fixture
    }
}

/// A throwaway directory removed when the test's value goes away.
final class TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("darce-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
