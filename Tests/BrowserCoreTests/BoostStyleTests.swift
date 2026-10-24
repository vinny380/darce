import Foundation
import Testing
@testable import BrowserCore

/// Arc-style Boost controls turned into page CSS and a color matrix. Each test names the bug it catches.
private func boost(_ change: (inout BrowserBoost) -> Void = { _ in }) -> BrowserBoost {
    var value = BrowserBoost(profileID: UUID(), host: "example.com", name: "My Boost")
    change(&value)
    return value
}

private func apply(_ matrix: [Double], _ rgb: [Double]) -> [Double] {
    (0..<3).map { row in (0..<3).reduce(matrix[row * 5 + 4]) { $0 + matrix[row * 5 + $1] * rgb[$1] } }
}

private func close(_ a: [Double], _ b: [Double]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.02 } }

@Test func emptyBoostChangesNothing() {
    #expect(BoostStyle.css(for: boost()) == "")
    #expect(BoostStyle.colorMatrix(for: boost()) == nil)
}

@Test func fontSkipsIconFontsLikeArc() {
    let css = BoostStyle.css(for: boost { $0.font = "Futura" })
    #expect(css.contains(#"*:not(i, .material-symbols-outlined, .material-icons) { font-family: "Futura" !important; }"#))
}

@Test func fontNamesCantBreakOutOfTheRule() {
    #expect(BoostStyle.css(for: boost { $0.font = #"Futura"; } body { display: none"# }) == "")
}

@Test func caseAndSizeBecomeCSS() {
    let css = BoostStyle.css(for: boost { $0.textCase = .uppercase; $0.textSize = .large })
    #expect(css.contains("text-transform: uppercase !important;"))
    #expect(css.contains("zoom: 1.25"))
    #expect(!BoostStyle.css(for: boost { $0.textSize = .normal }).contains("zoom"))
}

@Test func colorMapsPageLightToPrimaryAndDarkToSecondary() throws {
    let colors = BoostColors(hue: 120, saturation: 0.8)
    let matrix = try #require(BoostStyle.colorMatrix(for: boost { $0.colors = colors }))
    // Grays land exactly on the tints: keeping some original color must not lighten an inverted background.
    #expect(close(apply(matrix, [1, 1, 1]), colors.lightRGB))
    #expect(close(apply(matrix, [0, 0, 0]), colors.darkRGB))
}

@Test func invertLightnessTurnsLightPagesDark() throws {
    let colors = BoostColors(hue: 120, saturation: 0.8, invertLightness: true)
    let matrix = try #require(BoostStyle.colorMatrix(for: boost { $0.colors = colors }))
    #expect(close(apply(matrix, [1, 1, 1]), colors.darkRGB))  // a white page background comes out as the dark tint
    #expect(close(apply(matrix, [0, 0, 0]), colors.lightRGB))
}

@Test func originalColorsSurviveAsSaturationOnly() throws {
    let matrix = try #require(BoostStyle.colorMatrix(for: boost { $0.colors = BoostColors(hue: 120, saturation: 0) }))
    let red = apply(matrix, [1, 0, 0])
    #expect(red[0] > red[1] && red[0] > red[2])  // a red link stays reddish under the tint
}

@Test func boostsSavedBeforeTheseControlsStillLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let legacy = #"{"schemaVersion":1,"boosts":[{"id":"\#(UUID().uuidString)","profileID":"\#(UUID().uuidString)","host":"example.com","name":"Old","enabled":true,"css":"body{}","hiddenSelectors":[".ad"]}]}"#
    try Data(legacy.utf8).write(to: url)
    let loaded = try BoostStore(fileURL: url).boosts
    #expect(loaded.count == 1 && loaded[0].font == nil && loaded[0].colors == nil)
}
