import AppKit
import BrowserCore
import BrowserTheme
import SwiftUI

/// Decorative background shared by WebKit and Chromium shells.
struct ThemeBackgroundView: NSViewRepresentable {
    let appearance: SpaceAppearance
    let dark: Bool
    let onFailure: (String) -> Void

    func makeNSView(context: Context) -> ThemeMetalView { ThemeMetalView() }
    func updateNSView(_ view: ThemeMetalView, context: Context) {
        view.onFailure = onFailure
        let tint = appearance.tint
        let options = appearance.theme ?? SpaceThemeSettings()
        do {
            let color = NSColor(srgbRed:tint.red,green:tint.green,blue:tint.blue,alpha:tint.alpha)
            let layer = try ThemePalette.layer(primary:color,colorCount:options.colorCount,
                wheel:options.wheel == .analogous ? .analogous : .complimentary,
                intensity:options.intensity,dark:dark)
            view.update(theme:layer)
        } catch {
            let message = String(describing:error)
            DispatchQueue.main.async { onFailure(message) }
        }
    }
}
