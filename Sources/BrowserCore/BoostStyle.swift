import Foundation

/// Arc's color wheel scheme: the page is recolored from dark to light along two tints taken from the pad
/// (primaryHueDegrees, primarySaturation, secondaryHueOffset, invertLightness).
public struct BoostColors: Codable, Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var secondaryHueOffset: Double
    public var invertLightness: Bool

    public init(hue: Double, saturation: Double, secondaryHueOffset: Double = 30, invertLightness: Bool = false) {
        self.hue = hue
        self.saturation = min(1, max(0, saturation))
        self.secondaryHueOffset = secondaryHueOffset
        self.invertLightness = invertLightness
    }

    /// How much of the page's own colorfulness survives (Arc's "Original Saturation"; its default wasn't
    /// recovered). Only color differences are kept, never brightness, so inverting stays dark.
    public static let preserved = 0.35

    /// Where page whites land, and where page blacks land.
    public var lightRGB: [Double] { Self.rgb(hue: hue, saturation: saturation, lightness: 0.9) }
    public var darkRGB: [Double] { Self.rgb(hue: hue + secondaryHueOffset, saturation: saturation, lightness: 0.12) }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> [Double] {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return [r + m, g + m, b + m]
    }
}

public enum BoostCase: String, Codable, CaseIterable, Sendable {
    case capitalize, uppercase, lowercase
}

/// Arc's text zoom levels; their factors weren't recovered, so these are D'arce's.
public enum BoostTextSize: String, Codable, CaseIterable, Sendable {
    case small, normal, medium, large, larger
    public var factor: Double {
        switch self {
        case .small: 0.9
        case .normal: 1
        case .medium: 1.1
        case .large: 1.25
        case .larger: 1.5
        }
    }
}

/// Turns a Boost's editor controls into page CSS and a color matrix, the way Arc applies them.
public enum BoostStyle {
    /// Arc's selector: every element except the common icon fonts, so icons don't turn into letters.
    static let textSelector = "*:not(i, .material-symbols-outlined, .material-icons)"
    /// The SVG filter's id, unique to the colors: WebKit keeps showing a filter while CSS points at the same id,
    /// so reusing one id would freeze the page on the first color picked.
    public static func filterID(for boost: BrowserBoost) -> String? {
        guard let matrix = colorMatrix(for: boost) else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a over the rounded matrix
        for value in matrix.map({ String(format: "%.4f", $0) }).joined(separator: " ").utf8 {
            hash = (hash ^ UInt64(value)) &* 0x100000001b3
        }
        return "darce-boost-" + String(hash, radix: 16)
    }

    /// Arc's Boost fonts, in its stored order, plus the label font next to its Size/Case controls.
    public static let fonts = ["Helvetica Neue", "Avenir", "Futura", "DIN Alternate", "PT Mono", "Courier", "Times New Roman",
                               "Charter", "Baskerville", "Hoefler Text", "Palatino", "Chalkboard", "SignPainter",
                               "Snell Roundhand", "Papyrus", "Apple Chancery", "Luminari", "Wingdings", "Arial Rounded MT Bold"]

    public static func css(for boost: BrowserBoost) -> String {
        var rules: [String] = []
        if let font = boost.font, isSafeFontName(font) {
            rules.append("\(textSelector) { font-family: \"\(font)\" !important; }")
        }
        if let textCase = boost.textCase {
            rules.append("\(textSelector) { text-transform: \(textCase.rawValue) !important; }")
        }
        if let size = boost.textSize, size != .normal {
            rules.append("html { zoom: \(size.factor) !important; }")
        }
        if let id = filterID(for: boost) {
            rules.append("html { filter: url(#\(id)) !important; }")
        }
        return rules.joined(separator: "\n")
    }

    /// A 4×5 color matrix (like Arc's native color filter): luminance maps from the dark tint to the light one
    /// (reversed when inverting), plus some of the page's own saturation (its color minus its gray).
    public static func colorMatrix(for boost: BrowserBoost) -> [Double]? {
        guard let colors = boost.colors else { return nil }
        let weights = [0.2126, 0.7152, 0.0722]
        let (from, to) = colors.invertLightness ? (colors.lightRGB, colors.darkRGB) : (colors.darkRGB, colors.lightRGB)
        let keep = BoostColors.preserved
        var matrix: [Double] = []
        for row in 0..<3 {
            let span = to[row] - from[row]
            let chroma = (0..<3).map { ($0 == row ? 1.0 : 0.0) - weights[$0] }
            matrix += (0..<3).map { span * weights[$0] + keep * chroma[$0] } + [0, from[row]]
        }
        return matrix + [0, 0, 0, 1, 0]
    }

    /// Font names come from a fixed list, but they're written into CSS, so only plain names pass.
    static func isSafeFontName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
    }
}
