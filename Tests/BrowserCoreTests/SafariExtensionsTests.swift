import Foundation
import Testing
@testable import BrowserCore

/// Finding Safari web extensions inside installed apps. Each test names the bug it catches.
func fakeApp(_ name: String, in folder: URL, extensions: [(name: String, id: String, point: String)]) throws {
    let app = folder.appendingPathComponent("\(name).app/Contents")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    for item in extensions {
        let appex = app.appendingPathComponent("PlugIns/\(item.name).appex/Contents")
        try FileManager.default.createDirectory(at: appex.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": item.id, "CFBundleDisplayName": item.name,
                                    "NSExtension": ["NSExtensionPointIdentifier": item.point]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: appex.appendingPathComponent("Info.plist"))
        try Data(#"{"manifest_version":3,"name":"\#(item.name)","version":"1.0"}"#.utf8)
            .write(to: appex.appendingPathComponent("Resources/manifest.json"))
    }
}

@Test func findsSafariWebExtensionsInsideApps() throws {
    let folder = try TemporaryDirectory()
    try fakeApp("Shield", in: folder.url, extensions: [("Shield Extension", "com.example.shield.ext", "com.apple.Safari.web-extension")])
    try fakeApp("Widgets", in: folder.url, extensions: [("Widget", "com.example.widget", "com.apple.widgetkit-extension")])
    try fakeApp("Plain", in: folder.url, extensions: [])
    let found = SafariExtensions.installed(in: [folder.url])
    #expect(found.map(\.identifier) == ["com.example.shield.ext"])
    #expect(found.first?.name == "Shield Extension" && found.first?.appName == "Shield")
}

@Test func findsAppsOneFolderDown() throws {
    let folder = try TemporaryDirectory()
    let utilities = folder.url.appendingPathComponent("Utilities")
    try fakeApp("Nested", in: utilities, extensions: [("Nested Ext", "com.example.nested", "com.apple.Safari.web-extension")])
    #expect(SafariExtensions.installed(in: [folder.url]).map(\.identifier) == ["com.example.nested"])
}

@Test func missingFoldersFindNothing() {
    #expect(SafariExtensions.installed(in: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]).isEmpty)
}
