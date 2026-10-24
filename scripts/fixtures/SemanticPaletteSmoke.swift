import AppKit
import BrowserTheme
import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
var checks: [[String: Any]] = []
for item in oracle["cases"] as! [[String: Any]] {
    let name = item["name"] as! String
    let p = item["primarySRGB"] as! [Double]
    let palette = try ThemePalette.semantic(primarySRGB: SIMD4(p[0], p[1], p[2], p[3]))
    let actual = ["lightTitle": palette.lightTitle, "darkTitle": palette.darkTitle,
                  "lightMaxContrast": palette.lightMaxContrast, "darkMaxContrast": palette.darkMaxContrast]
    for (field, expected) in item["expected"] as! [String: [Double]] {
        let vector = actual[field]!
        let difference = (0..<4).map { abs(vector[$0] - expected[$0]) }.max()!
        checks.append(["name": name + "_" + field, "passed": difference <= 1e-10,
            "actual": (0..<4).map { vector[$0] }, "expected": expected, "maximum_error": difference])
    }
}
for component in 0..<4 {
    for (name, bad) in [("nan", Double.nan), ("inf", Double.infinity), ("negative", -0.01), ("above_one", 1.01)] {
        var value = SIMD4<Double>(0.5, 0.5, 0.5, 1); value[component] = bad
        var rejected = false
        do { _ = try ThemePalette.semantic(primarySRGB: value) }
        catch ThemePaletteError.invalidInput { rejected = true }
        checks.append(["name": "reject_\(component)_\(name)", "passed": rejected])
    }
}
// The semantic unit-range boundary must not restrict the existing wide-gamut layer API.
let layer = try ThemePalette.layer(primary: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1),
    colorCount: 1, wheel: .analogous, intensity: 0.8, dark: false)
checks.append(["name": "existing_p3_layer_preserved", "passed": layer.base[0].x > 1 && layer.base[0].y < 0])
let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output)
exit(passed ? 0 : 1)
