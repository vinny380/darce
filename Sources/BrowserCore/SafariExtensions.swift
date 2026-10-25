import Foundation

/// A Safari web extension that ships inside a Mac app (an `.appex` in the app's `Contents/PlugIns`).
public struct SafariExtensionBundle: Equatable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let appName: String
    public let url: URL
    public var id: String { identifier }
}

/// Safari extensions installed on this Mac. D'arce runs Safari's extension engine, so these load as they are.
public enum SafariExtensions {
    public static let extensionPoint = "com.apple.Safari.web-extension"

    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Apps directly in each folder, or one folder down (e.g. /Applications/Utilities), by extension name.
    public static func installed(in roots: [URL] = defaultRoots) -> [SafariExtensionBundle] {
        let files = FileManager.default
        func children(_ folder: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        var apps: [URL] = []
        for root in roots {
            for item in children(root) {
                if item.pathExtension == "app" { apps.append(item) }
                else if item.hasDirectoryPath { apps += children(item).filter { $0.pathExtension == "app" } }
            }
        }
        var found: [SafariExtensionBundle] = []
        for app in apps {
            for appex in children(app.appendingPathComponent("Contents/PlugIns")) where appex.pathExtension == "appex" {
                guard let data = try? Data(contentsOf: appex.appendingPathComponent("Contents/Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == extensionPoint,
                      let identifier = plist["CFBundleIdentifier"] as? String,
                      !found.contains(where: { $0.identifier == identifier }) else { continue }
                let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
                    ?? appex.deletingPathExtension().lastPathComponent
                found.append(SafariExtensionBundle(identifier: identifier, name: name,
                                                   appName: app.deletingPathExtension().lastPathComponent, url: appex))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
