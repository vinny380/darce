import AppKit
import BrowserCore
import BrowserTheme
import Combine
import SwiftUI

@MainActor
final class AppearanceController: ObservableObject {
    @Published private(set) var state = AppearancePreferences()
    @Published private(set) var errorMessage: String?
    private(set) var recoveryRequired = false
    private var store: AppearanceStore?
    private var defaultSemanticPalette: ThemeSemanticPalette?
    private var semanticPalettes: [UUID: (tint: AppearanceColor, palette: ThemeSemanticPalette)] = [:]

    init(directory: URL) {
        errorMessage = refreshSemanticPalettes(for: state)
        do {
            let loaded = try AppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
            store = loaded
            errorMessage = refreshSemanticPalettes(for: loaded.state)
            state = loaded.state
        } catch {
            recoveryRequired = true
            errorMessage = "Appearance could not be loaded. Saving is disabled to preserve the original file. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func update(_ change: (inout AppearancePreferences) -> Void) -> Bool {
        guard !recoveryRequired, var candidate = store else { return false }
        do {
            try candidate.update(change)
            store = candidate
            errorMessage = refreshSemanticPalettes(for: candidate.state)
            state = candidate.state
            return true
        } catch {
            errorMessage = "Appearance could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func semanticPalette(forSpace id: UUID) -> ThemeSemanticPalette? {
        semanticPalettes[id]?.palette ?? defaultSemanticPalette
    }

    /// Recompute only changed tints, before publishing state. Rendering, selection
    /// and hover paths only read this cache; they never mutate the model.
    private func refreshSemanticPalettes(for preferences: AppearancePreferences) -> String? {
        func palette(_ tint: AppearanceColor) throws -> ThemeSemanticPalette {
            try ThemePalette.semantic(primarySRGB: SIMD4(tint.red, tint.green, tint.blue, tint.alpha))
        }
        semanticPalettes = semanticPalettes.filter { preferences.spaces[$0.key] != nil }
        do {
            if defaultSemanticPalette == nil { defaultSemanticPalette = try palette(SpaceAppearance().tint) }
            for (id, appearance) in preferences.spaces where semanticPalettes[id]?.tint != appearance.tint {
                semanticPalettes.removeValue(forKey: id)
                semanticPalettes[id] = (appearance.tint, try palette(appearance.tint))
            }
            return nil
        } catch {
            return "The Space text colors could not be displayed: \(error.localizedDescription)"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch state.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func color(forSpace id: UUID) -> Color {
        let tint = state.space(id).tint
        return Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue, opacity: tint.alpha)
    }

    func setTint(_ color: Color, forSpace id: UUID) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            errorMessage = "The selected color could not be converted to sRGB."
            return
        }
        let tint = AppearanceColor(red: min(1, max(0, rgb.redComponent)),
                                   green: min(1, max(0, rgb.greenComponent)),
                                   blue: min(1, max(0, rgb.blueComponent)))
        update { $0.spaces[id, default: SpaceAppearance()].tint = tint }
    }

    func background(forSpace id: UUID, scheme: ColorScheme) -> some View {
        ThemeBackgroundView(appearance:state.space(id),dark:scheme == .dark) { [weak self] error in
            let message = "The Space theme could not be displayed: \(error)"
            if self?.errorMessage != message { self?.errorMessage = message }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

struct AppearanceView: View {
    @ObservedObject var controller: AppearanceController
    let spaceID: UUID
    let spaceName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private let icons: [(symbol: String, label: String)] = [
        ("house.fill", "Home"), ("briefcase.fill", "Work"), ("book.fill", "Reading"), ("leaf.fill", "Leaf"),
        ("heart.fill", "Heart"), ("globe", "Globe"), ("star.fill", "Star"), ("bolt.fill", "Lightning"),
        ("paintpalette.fill", "Art"), ("terminal.fill", "Terminal"), ("music.note", "Music"), ("airplane", "Travel"),
        ("camera.fill", "Photography"), ("gamecontroller.fill", "Games"), ("graduationcap.fill", "Learning"), ("flame.fill", "Flame")
    ]

    private func updateTheme(_ change: (inout SpaceThemeSettings) -> Void) {
        controller.update { preferences in
            var settings = preferences.space(spaceID).theme ?? SpaceThemeSettings()
            change(&settings)
            preferences.spaces[spaceID,default:SpaceAppearance()].theme = settings
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Customize \(spaceName)").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 10) {
                Image(systemName: controller.state.space(spaceID).icon).font(.title2)
                Text(spaceName).font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(24).frame(height: 100)
            .background {
                controller.background(forSpace:spaceID,scheme:scheme).clipShape(RoundedRectangle(cornerRadius:14))
            }
            Form {
                Section("Space Theme") {
                    ColorPicker("Color", selection: Binding(
                        get: { controller.color(forSpace: spaceID) },
                        set: { controller.setTint($0, forSpace: spaceID) }
                    ), supportsOpacity: false)
                    Picker("Colors", selection: Binding(
                        get: { (controller.state.space(spaceID).theme ?? SpaceThemeSettings()).colorCount },
                        set: { count in updateTheme { $0.colorCount = count } }
                    )) {
                        Text("One").tag(1); Text("Two").tag(2); Text("Three").tag(3)
                    }.pickerStyle(.segmented)
                    Picker("Harmony", selection: Binding(
                        get: { (controller.state.space(spaceID).theme ?? SpaceThemeSettings()).wheel },
                        set: { wheel in updateTheme { $0.wheel = wheel } }
                    )) {
                        Text("Complementary").tag(SpaceThemeWheel.complimentary)
                        Text("Analogous").tag(SpaceThemeWheel.analogous)
                    }
                    .disabled((controller.state.space(spaceID).theme ?? SpaceThemeSettings()).colorCount == 1)
                    Slider(value:Binding(
                        get: { (controller.state.space(spaceID).theme ?? SpaceThemeSettings()).intensity },
                        set: { intensity in updateTheme { $0.intensity = intensity } }
                    ),in:0...1,step:0.01) { Text("Intensity") }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                            ForEach(icons, id: \.symbol) { icon in
                                Button {
                                    controller.update { $0.spaces[spaceID, default: SpaceAppearance()].icon = icon.symbol }
                                } label: {
                                    Image(systemName: icon.symbol).frame(width: 34, height: 32)
                                        .background(controller.state.space(spaceID).icon == icon.symbol ? Color.accentColor.opacity(0.2) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain).help(icon.label).accessibilityLabel(icon.label)
                                .accessibilityAddTraits(controller.state.space(spaceID).icon == icon.symbol ? .isSelected : [])
                            }
                        }
                    }
                }
                Section("All Spaces") {
                    Picker("Appearance", selection: Binding(
                        get: { controller.state.appearance },
                        set: { appearance in controller.update { $0.appearance = appearance } }
                    )) {
                        Text("System").tag(BrowserAppearance.system)
                        Text("Light").tag(BrowserAppearance.light)
                        Text("Dark").tag(BrowserAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show Sidebar", isOn: Binding(
                        get: { controller.state.sidebarVisible },
                        set: { visible in controller.update { $0.sidebarVisible = visible } }
                    ))
                    HStack {
                        Slider(value: Binding(
                            get: { controller.state.sidebarWidth },
                            set: { width in controller.update { $0.sidebarWidth = width } }
                        ), in: 210...360, step: 1) { Text("Sidebar Width") }
                        Text("\(Int(controller.state.sidebarWidth)) pt").monospacedDigit().frame(width: 55, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(controller.recoveryRequired)
        }
        .padding(20)
        .frame(width: 460, height: 690)
        .preferredColorScheme(controller.preferredColorScheme)
    }
}
