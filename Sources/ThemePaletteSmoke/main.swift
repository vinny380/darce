import AppKit
import BrowserTheme
import Foundation

@MainActor func run() -> Int32 {
    guard CommandLine.arguments.count == 2 else {
        print("Usage: ThemePaletteSmoke <fresh-output-directory>")
        return 2
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    var checks: [[String: Any]] = []
    var device = "not initialized"
    func check(_ name: String, _ pass: Bool) {
        checks.append(["name": name, "pass": pass])
    }
    func vector(_ name: String, _ actual: SIMD4<Float>, _ expected: SIMD4<Float>, tolerance: Float = 0.00002) {
        let error = (0..<4).map { abs(actual[$0] - expected[$0]) }.max()!
        checks.append(["name": name, "pass": error.isFinite && error <= tolerance,
                       "actual": (0..<4).map { actual[$0] }, "expected": (0..<4).map { expected[$0] },
                       "tolerance": tolerance, "maximumError": error])
    }
    func p3(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
    }
    func expected(_ color: NSColor) throws -> SIMD4<Float> {
        guard let converted = color.usingColorSpace(.extendedSRGB) else { throw ThemePaletteError.conversionFailed }
        return SIMD4(Float(converted.redComponent), Float(converted.greenComponent),
                     Float(converted.blueComponent), Float(converted.alphaComponent))
    }
    func save(_ name: String, _ image: ThemeImage) throws {
        try image.writePNG(to: output.appendingPathComponent(name + ".png"))
        try image.writeHalfFloats(to: output.appendingPathComponent(name + ".rgba16f"))
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = try ThemeRenderer()
        device = renderer.deviceName
        // Expected companions are analytical P3 RGB values, not a second copy of HSL code.
        for wheel in ThemeWheel.allCases {
            for count in 1...3 {
                let label = "red_\(wheel.rawValue)_\(count)"
                let layer = try ThemePalette.layer(primary: p3(1,0,0), colorCount: count,
                                                   wheel: wheel, intensity: 0.8, dark: false)
                check(label + "_shape", layer.base.count == min(count,2) && layer.overlay.count == (count == 3 ? 2 : 0))
                vector(label + "_primary", layer.base[0], try expected(p3(1,0,0)))
                if count > 1 {
                    let second = wheel == .analogous ? p3(1,2.0/3,0) : (count == 2 ? p3(0,1,1) : p3(0,1,0.5))
                    vector(label + "_second", layer.base[1], try expected(second))
                }
                if count == 3 {
                    vector(label + "_clear", layer.overlay[0], .zero, tolerance: 0)
                    vector(label + "_third", layer.overlay[1], try expected(wheel == .analogous ? p3(1,0,2.0/3) : p3(0,0.5,1)))
                }
                let image = try renderer.render(ThemeFrame(width: 64,height: 64,layers: [layer]))
                try save(label,image)
                check(label + "_gpu_finite", image.halfFloats.allSatisfy { $0.isFinite })
                if count > 1 {
                    let top = image.pixel(x: 0,y: 0), bottom = image.pixel(x: 63,y: 63)
                    check(label + "_gpu_gradient", (0..<3).contains { abs(top[$0]-bottom[$0]) > 0.01 })
                }
            }
        }
        // Both companions must start at primary hue, including crossing the hue wrap.
        let magenta = try ThemePalette.layer(primary: p3(1,0,1),colorCount: 3,wheel: .analogous,intensity: 1,dark: true)
        vector("wrapped_magenta_second",magenta.base[1],try expected(p3(1,0,1.0/3)))
        vector("independent_magenta_third",magenta.overlay[1],try expected(p3(1.0/3,0,1)))
        let neutral = try ThemePalette.layer(primary: p3(0.5,0.5,0.5),colorCount: 3,wheel: .complimentary,intensity: 0.8,dark: false)
        for (index,color) in (neutral.base + [neutral.overlay[1]]).enumerated() {
            vector("neutral_no_spurious_hue_\(index)",color,try expected(p3(0.5,0.5,0.5)))
        }
        let wide = try ThemePalette.layer(primary: p3(1,0,0),colorCount: 1,wheel: .analogous,intensity: 1,dark: true)
        check("p3_outside_srgb_preserved",wide.base[0].x > 1 && wide.base[0].y < 0)
        let extended = NSColor(colorSpace: .extendedSRGB, components: [1.15,-0.12,0.3,0.37], count: 4)
        let extendedLayer = try ThemePalette.layer(primary: extended,colorCount: 1,wheel: .analogous,intensity: 0.8,dark: true)
        vector("extended_primary_preserved",extendedLayer.base[0],SIMD4(1.15,-0.12,0.3,0.37))
        let translucent = try ThemePalette.layer(primary: p3(1,0,0,0.37),colorCount: 3,wheel: .complimentary,intensity: 0.8,dark: true)
        for (index,color) in (translucent.base + [translucent.overlay[1]]).enumerated() {
            check("source_alpha_preserved_\(index)",abs(color.w-0.37) < 0.000001)
        }
        for dark in [false,true] {
            for intensity in [0.0,0.8,1.0] {
                for white in [false,true] {
                    let name = "neutral_gpu_\(dark)_\(intensity)_\(white)"
                    let value: CGFloat = white ? 1 : 0
                    let layer = try ThemePalette.layer(primary: p3(value,value,value),colorCount: 1,
                                                       wheel: .complimentary,intensity: intensity,dark: dark)
                    let a = Float(intensity*0.55+0.2), u = min(a,0.5)*(dark ? 0.35 : 1)
                    vector(name + "_underlay",layer.underlay,SIMD4(dark ? 0 : 1,dark ? 0 : 1,dark ? 0 : 1,u))
                    check(name + "_alpha",abs(layer.alpha-a) < 0.000001)
                    let image = try renderer.render(ThemeFrame(width: 32,height: 32,layers: [layer]))
                    try save(name,image)
                    let premultiplied = (white ? a : 0) + (dark ? 0 : u*(1-a))
                    vector(name,image.pixel(x: 15,y: 15),SIMD4(premultiplied,premultiplied,premultiplied,a+u*(1-a)),tolerance: 0.003)
                }
            }
        }
        let transparentPrimary = try ThemePalette.layer(primary: p3(1,1,1,0),colorCount: 1,wheel: .analogous,intensity: 0.8,dark: false)
        let transparentImage = try renderer.render(ThemeFrame(width: 32,height: 32,layers: [transparentPrimary]))
        try save("transparent_primary",transparentImage)
        vector("transparent_primary_exposes_underlay",transparentImage.pixel(x: 15,y: 15),SIMD4(0.5,0.5,0.5,0.5),tolerance: 0.003)
        for count in [Int.min,0,4,Int.max] {
            var rejected = false
            do { _ = try ThemePalette.layer(primary: p3(1,0,0),colorCount: count,wheel: .complimentary,intensity: 0.8,dark: false) }
            catch ThemePaletteError.invalidInput { rejected = true }
            check("reject_count_\(count)",rejected)
        }
        for (name,intensity) in [("negative",-0.01),("above_one",1.01),("nan",Double.nan),("infinity",Double.infinity)] {
            var rejected = false
            do { _ = try ThemePalette.layer(primary: p3(1,0,0),colorCount: 2,wheel: .analogous,intensity: intensity,dark: false) }
            catch ThemePaletteError.invalidInput { rejected = true }
            check("reject_intensity_"+name,rejected)
        }
        var conversionRejected = false
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1,height: 1)))
        do { _ = try ThemePalette.layer(primary: pattern,colorCount: 2,wheel: .analogous,intensity: 0.8,dark: false) }
        catch ThemePaletteError.conversionFailed { conversionRejected = true }
        check("reject_pattern_conversion",conversionRejected)
    } catch {
        checks.append(["name": "fatal", "pass": false, "error": String(describing: error)])
    }
    let pass = !checks.isEmpty && checks.allSatisfy { $0["pass"] as? Bool == true }
    let result: [String: Any] = ["pass": pass, "checks": checks, "device": device,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "scope": "Real AppKit color conversion and independent offscreen Metal renderer",
        "artifacts": "PNG inspection exports and authoritative RGBA16Float buffers; no proprietary assets"]
    do {
        try JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("result.json"),options: .atomic)
    } catch { print("Cannot write result.json: \(error)"); return 1 }
    print("Theme palette checks: \(checks.filter { $0["pass"] as? Bool == true }.count)/\(checks.count); \(output.path)")
    return pass ? 0 : 1
}
exit(run())
