// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserPrototype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserTheme", targets: ["BrowserTheme"]),
        .executable(name: "ThemeRenderSmoke", targets: ["ThemeRenderSmoke"]),
        .executable(name: "ThemePaletteSmoke", targets: ["ThemePaletteSmoke"]),
        .executable(name: "ThemeMountedSmoke", targets: ["ThemeMountedSmoke"]),
        .executable(name: "BrowserPrototype", targets: ["BrowserPrototype"]),
    ],
    targets: [
        .target(name: "BrowserCore"),
        .target(name: "BrowserTheme"),
        .executableTarget(name: "ThemeRenderSmoke", dependencies: ["BrowserTheme"]),
        .executableTarget(name: "ThemePaletteSmoke", dependencies: ["BrowserTheme"]),
        .executableTarget(name: "ThemeMountedSmoke", dependencies: ["BrowserTheme"]),
        .executableTarget(name: "BrowserPrototype", dependencies: ["BrowserCore", "BrowserTheme"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    ]
)
