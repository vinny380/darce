import AppKit
import BrowserCore
import SwiftUI

/// Arc's Boost editor: a panel docked at the right of the page that restyles the current site live — colors
/// from a pad, a font, text size and case, zapped elements, and custom code.
struct BoostPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var boosts: BoostController
    let host: String
    let profileID: UUID
    @Environment(\.colorScheme) private var scheme
    @State private var history: [BrowserBoost?] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var showingAdvanced = false

    private var boost: BrowserBoost? { boosts.boosts.first { $0.profileID == profileID && $0.host == host } }

    /// Every control edits this site's Boost (creating "My Boost" on first change) and saves, so the page updates live.
    private func edit(_ change: (inout BrowserBoost) -> Void) {
        history.append(boost)
        var value = boost ?? BrowserBoost(profileID: profileID, host: host, name: "My Boost")
        change(&value)
        if !boosts.save(value) { history.removeLast() }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        if let previous { boosts.save(previous) } else if let boost { boosts.remove(id: boost.id, profileID: profileID) }
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            ColorPad(colors: boost?.colors) { colors in edit { $0.colors = colors } }
            HStack(spacing: 10) {
                squareButton(boost?.colors?.invertLightness == true ? "lightbulb.fill" : "lightbulb", "Invert lightness",
                             active: boost?.colors?.invertLightness == true) {
                    edit { var colors = $0.colors ?? BoostColors(hue: 230, saturation: 0); colors.invertLightness.toggle(); $0.colors = colors }
                }
                squareButton("slider.horizontal.3", "Advanced color controls", active: showingAdvanced) { showingAdvanced.toggle() }
                    .popover(isPresented: $showingAdvanced, arrowEdge: .bottom) { advancedControls }
                squareButton("nosign", "Reset to original colors") { edit { $0.colors = nil } }.disabled(boost?.colors == nil)
            }
            fontGrid
            HStack(spacing: 10) {
                wideButton(boost?.textSize.map(Self.sizeName) ?? "Size", help: "Change text size") {
                    edit { $0.textSize = Self.next($0.textSize ?? .normal, in: BoostTextSize.allCases) }
                }
                wideButton(boost?.textCase.map(Self.caseName) ?? "Case", help: "Change text case") {
                    edit { $0.textCase = Self.nextCase($0.textCase) }
                }
            }
            zapRow
            Button { model.panel = .boosts } label: {
                HStack { Text("Code").font(.system(size: 15, weight: .semibold)); Spacer(); Image(systemName: "curlybraces") }
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Edit this Boost's CSS and JavaScript")
        }
        .padding(16).padding(.top, -6)
        .frame(width: 272)
        .background(scheme == .dark ? Color(.sRGB, red: 0.15, green: 0.15, blue: 0.16) : Color(.sRGB, red: 0.98, green: 0.984, blue: 1),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .alert("Rename this Boost", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { let name = newName.trimmingCharacters(in: .whitespaces); if !name.isEmpty { edit { $0.name = name } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete this Boost?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let boost { boosts.remove(id: boost.id, profileID: profileID) }
                history = []
                model.boostPanelOpen = false
            }
        } message: { Text("This can't be undone.") }
    }

    private var header: some View {
        HStack {
            Button { model.boostPanelOpen = false } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Done")
            Spacer()
            Menu {
                Button("Rename this Boost…") { newName = boost?.name ?? "My Boost"; renaming = true }
                Button("Reset all Edits") { edit { $0.colors = nil; $0.font = nil; $0.textCase = nil; $0.textSize = nil; $0.hiddenSelectors = [] } }
                    .disabled(boost == nil)
                Divider()
                Button("Delete this Boost…", role: .destructive) { confirmingDelete = true }.disabled(boost == nil)
            } label: {
                HStack(spacing: 6) {
                    Text(boost?.name ?? "My Boost").font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            Button(action: undo) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .semibold))
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(history.isEmpty).help("Undo")
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, -16) }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color scheme").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { (boost?.colors?.secondaryHueOffset ?? 30) >= 90 ? 180.0 : 30.0 },
                set: { offset in edit { var colors = $0.colors ?? BoostColors(hue: 230, saturation: 0.6); colors.secondaryHueOffset = offset; $0.colors = colors } })) {
                Text("Analogous").tag(30.0)
                Text("Complementary").tag(180.0)
            }.pickerStyle(.segmented).labelsHidden()
        }.padding(14).frame(width: 240)
    }

    private var fontGrid: some View {
        let cells: [String?] = [nil] + BoostStyle.fonts
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, font in
                let selected = boost?.font == font
                Button { edit { $0.font = font } } label: {
                    Text("Aa").font(font.map { .custom($0, size: 15) } ?? .system(size: 15))
                        .foregroundStyle(.primary.opacity(selected ? 0.9 : 0.55))
                        .frame(width: 38, height: 34)
                        .background(selected ? Color.primary.opacity(0.1) : .clear, in: Circle())
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(font ?? "Website's font")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }

    private var zapRow: some View {
        let zaps = boost?.hiddenSelectors ?? []
        return Button {
            model.boostPanelZapping = true
            model.pickBoostElement { selector in edit { $0.hiddenSelectors.append(selector) } }
        } label: {
            HStack {
                Text("Zap").font(.system(size: 15, weight: .semibold))
                Spacer()
                if zaps.isEmpty { Image(systemName: "bolt.fill") } else { Text("\(zaps.count)").font(.system(size: 15, weight: .semibold)) }
            }
            .padding(.horizontal, 16).frame(height: 44)
            .foregroundStyle(zaps.isEmpty ? Color.primary : Color.white)
            .background(zaps.isEmpty ? Color.primary.opacity(0.07) : Color(.sRGB, red: 0.13, green: 0.13, blue: 0.14),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Click an element on the page to hide it")
        .contextMenu {
            ForEach(Array(zaps.enumerated()), id: \.offset) { index, selector in
                Button("Unzap \(selector)") { edit { $0.hiddenSelectors.remove(at: index) } }
            }
            if !zaps.isEmpty { Divider(); Button("Restore All") { edit { $0.hiddenSelectors = [] } } }
        }
    }

    private func squareButton(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(maxWidth: .infinity).frame(height: 44)
                .background(.primary.opacity(active ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }

    private func wideButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }

    private static func next<T: Equatable>(_ value: T, in all: [T]) -> T {
        all[((all.firstIndex(of: value) ?? 0) + 1) % all.count]
    }

    private static func nextCase(_ value: BoostCase?) -> BoostCase? {
        switch value {
        case nil: .capitalize
        case .capitalize: .uppercase
        case .uppercase: .lowercase
        case .lowercase: nil
        }
    }

    private static func sizeName(_ size: BoostTextSize) -> String { size == .normal ? "Size" : size.rawValue.capitalized }
    private static func caseName(_ value: BoostCase) -> String {
        switch value {
        case .capitalize: "Aa Bb"
        case .uppercase: "AA"
        case .lowercase: "aa"
        }
    }
}

/// Arc's color pad: drag anywhere — angle picks the hue, distance from the center picks how strongly the page is
/// tinted. The big puck is the light tint; the small dark one follows at the secondary hue.
private struct ColorPad: View {
    let colors: BoostColors?
    let onChange: (BoostColors) -> Void
    private let ring: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2 - ring - 16
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(colors == nil
                          ? AnyShapeStyle(AngularGradient(colors: [.gray, .white, .gray, .black.opacity(0.6), .gray], center: .center))
                          : AnyShapeStyle(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 1) }, center: .center)))
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)).padding(ring)
                DotGrid().padding(ring + 6).opacity(0.5)
                if let colors {
                    puck(at: point(hue: colors.hue + colors.secondaryHueOffset, strength: colors.saturation * 0.7, center: center, radius: radius),
                         fill: Color(rgb: colors.darkRGB), size: 30)
                    puck(at: point(hue: colors.hue, strength: colors.saturation, center: center, radius: radius),
                         fill: Color(hue: colors.hue / 360, saturation: colors.saturation, brightness: 0.75), size: 44)
                } else {
                    puck(at: CGPoint(x: center.x + 18, y: center.y + 22), fill: Color(white: 0.2), size: 30)
                    puck(at: CGPoint(x: center.x + 34, y: center.y - 6), fill: Color(white: 0.45), size: 44)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                let hue = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                var next = colors ?? BoostColors(hue: hue, saturation: 0)
                next.hue = hue
                next.saturation = min(1, max(0.05, hypot(dx, dy) / radius))
                onChange(next)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .help("Color wheel: drag to tint this site")
    }

    private func point(hue: Double, strength: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = hue * .pi / 180
        return CGPoint(x: center.x + cos(angle) * radius * strength, y: center.y + sin(angle) * radius * strength)
    }

    private func puck(at point: CGPoint, fill: Color, size: CGFloat) -> some View {
        Circle().fill(fill).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .position(point)
    }
}

/// Arc's DotGrid backdrop (8pt tile).
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 4
            while x < size.width {
                var y: CGFloat = 4
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)), with: .color(.primary.opacity(0.18)))
                    y += 8
                }
                x += 8
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension Color {
    init(rgb: [Double]) { self.init(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]) }
}
