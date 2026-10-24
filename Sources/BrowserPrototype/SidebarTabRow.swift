import AppKit
import BrowserCore
import BrowserTheme
import SwiftUI

/// Shared geometry keeps the WebKit and Chromium shells on the same measured row pitch.
struct SidebarTabRow<Icon: View>: View {
    let tab: BrowserTab
    let selected: Bool
    var canReset: Bool = false
    var contentVisible: Bool = false
    var semanticPalette: ThemeSemanticPalette? = nil
    // Saved pin imagery is independent of the live page icon; nil uses that current icon.
    var resetIcon: Icon? = nil
    let icon: Icon
    let select: () -> Void
    let reset: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var iconHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Click targets are tap gestures, not Buttons: a macOS Button keeps the mouse, so the row could never be dragged.
            Group {
                if iconHovered && canReset, let resetIcon {
                    resetIcon.foregroundStyle(iconColor)
                } else { icon.foregroundStyle(iconColor) }
            }.frame(width: 24, height: 24).frame(width: 36, height: 38).contentShape(Rectangle())
                .onTapGesture { canReset ? reset() : select() }
                .help(canReset ? "Reset to Pinned URL" : tab.title)
                .accessibilityElement().accessibilityAddTraits(.isButton)
                .accessibilityLabel(canReset ? "Reset \(tab.title) to Pinned URL" : "Open \(tab.title)")
                .accessibilityAction { canReset ? reset() : select() }
                .onHover { iconHovered = $0 }
            Text(tab.title).font(.system(size: 14, weight: .regular)).lineLimit(1)
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 38).contentShape(Rectangle())
                .onTapGesture(perform: select)
                .accessibilityAddTraits(.isButton).accessibilityAction { select() }
            if hovered && tab.kind == .today {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .frame(width: 14, height: 14).frame(width: 25, height: 38)
                }.accessibilityLabel("Archive \(tab.title)")
            } else { Color.clear.frame(width: 8, height: 38) }
        }.buttonStyle(.plain).foregroundStyle(.primary.opacity(selected ? 0.90 : 0.75))
            // 38pt allocation + the existing 3pt list gap reproduces the measured 41pt pitch.
            .background {
                TabRowBackground(fill: background,
                    shadow: selected ? Palette.color("TabCellShadowSelected", scheme: scheme) : .clear)
                    .frame(height: 36).allowsHitTesting(false)
            }
            .onHover { hovered = $0 }.accessibilityElement(children: .contain)
            .accessibilityLabel("\(tab.title), \(tab.kind.rawValue)")
    }

    private func color(_ rgba: SIMD4<Double>) -> Color {
        Color(.sRGB, red: rgba.x, green: rgba.y, blue: rgba.z, opacity: rgba.w)
    }

    private var titleColor: Color {
        guard let semanticPalette else { return .primary.opacity(selected ? 0.90 : 0.75) }
        return color(scheme == .dark ? semanticPalette.darkTitle : semanticPalette.lightTitle)
    }

    private var iconColor: Color {
        guard let semanticPalette else { return .primary.opacity(selected ? 0.90 : 0.75) }
        return color(scheme == .dark ? semanticPalette.darkMaxContrast : semanticPalette.lightMaxContrast)
    }

    private var background: Color {
        if selected {
            return Palette.color("TabCellBackgroundCurrent", scheme: scheme)
        }
        if contentVisible { return Palette.color("TabCellBackgroundContentVisible", scheme: scheme) }
        return hovered ? Palette.color("SidebarItemHovered", scheme: scheme) : .clear
    }
}

/// Keep the recovered shadow in native layer coordinates and off the text/icons.
private struct TabRowBackground: NSViewRepresentable {
    let fill: Color
    let shadow: Color

    func makeNSView(context: Context) -> TabRowBackgroundView { TabRowBackgroundView() }

    func updateNSView(_ view: TabRowBackgroundView, context: Context) {
        view.fillLayer.backgroundColor = NSColor(fill).cgColor
        view.fillLayer.shadowColor = NSColor(shadow).cgColor
    }
}

private final class TabRowBackgroundView: NSView {
    // SwiftUI owns the hosting view's backing-layer shadow; keep ours independent.
    let fillLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fillLayer.cornerRadius = 12
        fillLayer.cornerCurve = .continuous
        fillLayer.masksToBounds = false
        fillLayer.shadowRadius = 1
        fillLayer.shadowOffset = CGSize(width: 0, height: -1)
        fillLayer.shadowOpacity = 1
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        fillLayer.shadowPath = CGPath(roundedRect: fillLayer.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
