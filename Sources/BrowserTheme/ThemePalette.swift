import AppKit
import Foundation

public enum ThemeWheel: String, CaseIterable, Sendable {
    case complimentary
    case analogous
}

public enum ThemePaletteError: Error, Sendable {
    case invalidInput
    case conversionFailed
}

public struct ThemeSemanticPalette: Equatable, Sendable {
    public let lightTitle: SIMD4<Double>
    public let darkTitle: SIMD4<Double>
    public let lightMaxContrast: SIMD4<Double>
    public let darkMaxContrast: SIMD4<Double>
}

/// Independent palette producer for explicit caller settings, not a default Space theme.
public enum ThemePalette {
    /// Normal sidebar colors for the stored, unit-range sRGB primary. This has a
    /// narrower input contract than the wide-gamut gradient producer below.
    public static func semantic(primarySRGB primary: SIMD4<Double>) throws -> ThemeSemanticPalette {
        guard (0..<4).allSatisfy({ primary[$0].isFinite && (0...1).contains(primary[$0]) }) else {
            throw ThemePaletteError.invalidInput
        }
        let dark = try stepped(primary, luminance: 0...0.1)
        let light = try stepped(primary, luminance: 0.85...0.95)
        return ThemeSemanticPalette(
            lightTitle: SIMD4(dark.x * 0.30, dark.y * 0.30, dark.z * 0.30, 1),
            darkTitle: SIMD4(0.85 + dark.x * 0.15, 0.85 + dark.y * 0.15, 0.85 + dark.z * 0.15, 1),
            lightMaxContrast: dark, darkMaxContrast: light)
    }

    private static func luminance(_ color: SIMD4<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    private static func stepped(_ primary: SIMD4<Double>, luminance range: ClosedRange<Double>) throws -> SIMD4<Double> {
        let initial = luminance(primary)
        if range.contains(initial) { return primary }
        // Keep the initial direction even when one step crosses the entire band.
        let increasing = initial < range.lowerBound
        var result = primary
        for _ in 0..<128 {
            let coordinates = try hsl(result)
            let lightness = min(1, max(0, coordinates.z + (increasing ? 0.01 : -0.01)))
            guard lightness != coordinates.z else { throw ThemePaletteError.invalidInput }
            let color = rgb(hue: coordinates.x, saturation: coordinates.y, lightness: lightness)
            result = SIMD4(color.x, color.y, color.z, primary.w)
            let value = luminance(result)
            if increasing ? value >= range.lowerBound : value <= range.upperBound { return result }
        }
        throw ThemePaletteError.invalidInput
    }

    public static func layer(primary: NSColor, colorCount: Int, wheel: ThemeWheel,
                             intensity: Double, dark: Bool) throws -> ThemeLayer {
        guard (1...3).contains(colorCount), intensity.isFinite, (0...1).contains(intensity) else {
            throw ThemePaletteError.invalidInput
        }
        // Preserve the original primary's actual conversion; do not round-trip it through HSL.
        var colors = [try endpoint(primary)]
        if colorCount > 1 {
            guard let p3 = primary.usingColorSpace(.displayP3) else {
                throw ThemePaletteError.conversionFailed
            }
            let rgba = try components(p3)
            let coordinates = try hsl(rgba)
            let offsets: [Double]
            switch (wheel, colorCount) {
            case (.complimentary, 2): offsets = [180]
            case (.complimentary, _): offsets = [150,210]
            case (.analogous, 2): offsets = [40]
            case (.analogous, _): offsets = [40,-40]
            }
            for degrees in offsets {
                var hue = (coordinates.x + degrees/360).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
                let rgb = rgb(hue: hue,saturation: coordinates.y,lightness: coordinates.z)
                guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else {
                    throw ThemePaletteError.invalidInput
                }
                let rotated = NSColor(displayP3Red: CGFloat(rgb.x),green: CGFloat(rgb.y),
                                      blue: CGFloat(rgb.z),alpha: CGFloat(rgba.w))
                colors.append(try endpoint(rotated))
            }
        }
        let alpha = intensity*0.55+0.2
        let underlayAlpha = min(alpha,0.5)*(dark ? 0.35 : 1)
        let underlayRGB: Float = dark ? 0 : 1
        return ThemeLayer(base: Array(colors.prefix(2)),
                          overlay: colorCount == 3 ? [.zero,colors[2]] : [],
                          alpha: Float(alpha),
                          underlay: SIMD4(underlayRGB,underlayRGB,underlayRGB,Float(underlayAlpha)))
    }

    /// Called only after conversion to an RGB NSColorSpace, avoiding component access on patterns.
    private static func components(_ color: NSColor) throws -> SIMD4<Double> {
        let result = SIMD4(Double(color.redComponent),Double(color.greenComponent),
                           Double(color.blueComponent),Double(color.alphaComponent))
        guard (0..<4).allSatisfy({ result[$0].isFinite }), (0...1).contains(result.w) else {
            throw ThemePaletteError.invalidInput
        }
        return result
    }

    private static func endpoint(_ color: NSColor) throws -> SIMD4<Float> {
        guard let converted = color.usingColorSpace(.extendedSRGB) else {
            throw ThemePaletteError.conversionFailed
        }
        let rgba = try components(converted)
        let result = SIMD4(Float(rgba.x),Float(rgba.y),Float(rgba.z),Float(rgba.w))
        guard (0..<4).allSatisfy({ result[$0].isFinite }) else {
            throw ThemePaletteError.invalidInput
        }
        return result
    }

    private static func hsl(_ rgba: SIMD4<Double>) throws -> SIMD3<Double> {
        let maximum = max(rgba.x,max(rgba.y,rgba.z)), minimum = min(rgba.x,min(rgba.y,rgba.z))
        let lightness = (maximum+minimum)/2
        let delta = maximum-minimum
        if delta == 0 { return SIMD3(0,0,lightness) }
        let saturation = delta/(lightness > 0.5 ? 2-maximum-minimum : maximum+minimum)
        let sector: Double
        if maximum == rgba.x { sector = (rgba.y-rgba.z)/delta }
        else if maximum == rgba.y { sector = (rgba.z-rgba.x)/delta+2 }
        else { sector = (rgba.x-rgba.y)/delta+4 }
        let hue = sector/6
        guard hue.isFinite, saturation.isFinite, lightness.isFinite else {
            throw ThemePaletteError.invalidInput
        }
        return SIMD3(hue,saturation,lightness)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> SIMD3<Double> {
        if saturation == 0 { return SIMD3(repeating: lightness) }
        let q = lightness > 0.5 ? lightness+saturation-lightness*saturation : lightness*(1+saturation)
        let p = 2*lightness-q
        func channel(_ value: Double) -> Double {
            var t = value
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0/6 { return p+(q-p)*6*t }
            if t < 0.5 { return q }
            if t < 2.0/3 { return p+(q-p)*(2.0/3-t)*6 }
            return p
        }
        return SIMD3(channel(hue+1.0/3),channel(hue),channel(hue-1.0/3))
    }
}
