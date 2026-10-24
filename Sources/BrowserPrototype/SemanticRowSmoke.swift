import AppKit
import BrowserCore
import SwiftUI

// Owned mounted evidence exercises the actual row caller in each product shell.
private struct SemanticRowsFixture: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var appearance: AppearanceController
    let ids: [UUID]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<2) { column in
                VStack(spacing: 3) {
                    ForEach(ids, id: \.self) { id in
                        if let tab = model.state.tabs.first(where: { $0.id == id }) {
                            BrowserSidebar(model: model, appearance: appearance,
                                showArchive: .constant(false), showNewSpace: .constant(false),
                                showNewFolder: .constant(false)).tabRow(tab)
                        }
                    }
                }.padding(8).frame(width: 252)
                    .background(column == 0 ? Color(white: 0.18) : Color(white: 0.82))
            }
        }.preferredColorScheme(appearance.preferredColorScheme)
    }
}

@MainActor
func runSemanticRowSmoke(model: BrowserModel, ids: [UUID], directory: URL) async throws -> [String: Bool] {
    let appearance = model.appearance
    let first = model.state.selectedSpaceID
    guard let second = model.state.spaces.first(where: { $0.id != first })?.id, ids.count == 2 else {
        return ["semantic_fixture_setup": false]
    }
    model.stateUpdate { state in
        for id in ids { state.updateTab(id, title: "MMMMMMMMMMMM") }
    }
    model.select(ids[0])
    let content = SemanticRowsFixture(model: model, appearance: appearance, ids: ids)
    let view = NSHostingView(rootView: content)
    view.frame = NSRect(x: 0, y: 0, width: 504, height: 95)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    var checks: [String: Bool] = [:]
    var observations: [[String: Any]] = []
    let cases: [(String, UUID, AppearanceColor, BrowserAppearance, [Double], [Double])] = [
        ("lavender-light", first, AppearanceColor(red: 0.8, green: 0.81, blue: 0.9), .light,
         [0.088, 0.0968, 0.176], [0.293333333333, 0.322666666667, 0.586666666667]),
        ("lavender-dark", first, AppearanceColor(red: 0.8, green: 0.81, blue: 0.9), .dark,
         [0.894, 0.8984, 0.938], [0.933333333333, 0.936666666667, 0.966666666667]),
        ("red-light", first, AppearanceColor(red: 1, green: 0, blue: 0), .light,
         [0.21, 0, 0], [0.7, 0, 0]),
        ("blue-space-light", second, AppearanceColor(red: 0, green: 0, blue: 1), .light,
         [0, 0, 0.3], [0, 0, 1]),
        ("return-red-dark", first, AppearanceColor(red: 1, green: 0, blue: 0), .dark,
         [0.955, 0.85, 0.85], [1, 0.92, 0.92]),
        ("return-red-light", first, AppearanceColor(red: 1, green: 0, blue: 0), .light,
         [0.21, 0, 0], [0.7, 0, 0])
    ]
    for (name, space, tint, mode, title, icon) in cases {
        checks[name + "_appearance_saved"] = appearance.update {
            $0.spaces[space, default: SpaceAppearance()].tint = tint
            $0.appearance = mode
        }
        model.selectSpace(space)
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        guard let pixels = bitmap.converting(to: .sRGB, renderingIntent: .default) else { throw CocoaError(.fileReadCorruptFile) }
        let scaleX = Double(bitmap.pixelsWide) / view.bounds.width
        let scaleY = Double(bitmap.pixelsHigh) / view.bounds.height
        func count(_ rgb: [Double], _ rectangle: NSRect, tolerance: Double = 0.018) -> Int {
            var total = 0
            for y in Int(rectangle.minY * scaleY)..<Int(rectangle.maxY * scaleY) {
                for x in Int(rectangle.minX * scaleX)..<Int(rectangle.maxX * scaleX) {
                    guard let c = pixels.colorAt(x: x, y: y) else { continue }
                    if abs(c.redComponent-rgb[0]) < tolerance && abs(c.greenComponent-rgb[1]) < tolerance
                        && abs(c.blueComponent-rgb[2]) < tolerance { total += 1 }
                }
            }
            return total
        }
        var counts: [String: Int] = [:]
        for column in 0..<2 {
            for row in 0..<2 {
                let value = count(title, NSRect(x: 44+252*column, y: 8+41*row, width: 175, height: 38))
                let key = name + "_opaque_title_c\(column)_r\(row)"
                checks[key] = value >= 12; counts[key] = value
            }
            let fallback = count(icon, NSRect(x: 17+252*column, y: 15, width: 18, height: 24))
            checks[name + "_fallback_c\(column)"] = fallback >= 6
            counts["fallback_\(column)"] = fallback
            let iconRect = NSRect(x: 17+252*column, y: 56, width: 18, height: 24)
            let red = count([1,0,0], iconRect, tolerance: 0.06)
            let blue = count([0,0,1], iconRect, tolerance: 0.06)
            checks[name + "_favicon_original_c\(column)"] = red >= 12 && blue >= 12
            counts["favicon_red_\(column)"] = red; counts["favicon_blue_\(column)"] = blue
        }
        observations.append(["case": name, "expected_title": title, "expected_icon": icon,
                             "pixel_counts": counts, "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh]])
    }
    let prior = appearance.state
    checks["semantic_invalid_tint_rejected"] = !appearance.update {
        $0.spaces[first, default: SpaceAppearance()].tint.red = .nan
    } && appearance.state == prior
    checks["semantic_fixture_complete"] = true
    try JSONSerialization.data(withJSONObject: ["checks": checks, "observations": observations], options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("semantic-pixels.json"))
    return checks
}
