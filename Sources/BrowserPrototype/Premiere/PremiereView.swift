import AppKit
import BrowserCore
import SwiftUI

/// The first-launch welcome. It covers the whole window; when it's done it dissolves and the browser is there.
struct PremiereView: View {
    @ObservedObject var model: PremiereModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: OnboardingStep { model.flow.current }

    var body: some View {
        ZStack {
            PremiereBackground(tint: model.tint)
            content
                .id(step)
                .transition(stepTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 64)
            VStack {
                HStack(spacing: 6) {
                    Spacer()
                    Button(action: model.toggleMute) {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace)).frame(width: 30, height: 26)
                    }
                    .buttonStyle(QuietButtonStyle()).help(model.muted ? "Play music (M)" : "Mute music (M)")
                    .accessibilityLabel(model.muted ? "Play music" : "Mute music")
                    if step != .welcome {
                        Button("Skip setup", action: model.skipSetup).buttonStyle(QuietButtonStyle()).help("Go straight to D’arce (⌥esc)")
                    }
                }
                Spacer()
                ProgressPills(steps: model.flow.steps, current: step)
            }
            .padding(.top, 14).padding(.trailing, 18).padding(.bottom, 26)
            keyboard
        }
        .foregroundStyle(Color(white: 0.97))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9), value: step)
        .onAppear(perform: model.appeared)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.setActive(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.setActive(true) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro: PremiereIntro(model: model)
        case .bring: PremiereBring(model: model)
        case .theme: PremiereTheme(model: model)
        case .defaultBrowser: PremiereDefaultBrowser(model: model)
        case .welcome: PremiereWelcome(model: model)
        }
    }

    /// In from the side we're heading to (springy), out the other way (quicker), softened with blur.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let towards = CGFloat(model.direction)
        return .asymmetric(
            insertion: .modifier(active: StepPhase(x: 28 * towards, scale: 0.985, blur: 10, opacity: 0), identity: .settled),
            removal: .modifier(active: StepPhase(x: -22 * towards, scale: 0.99, blur: 8, opacity: 0), identity: .settled)
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)))
    }

    /// esc skips this step, ⌥esc skips setup, ⌘[ goes back, M mutes.
    private var keyboard: some View {
        ZStack {
            Button("") { escape() }.keyboardShortcut(.cancelAction)
            Button("") { model.skipSetup() }.keyboardShortcut(.escape, modifiers: .option)
            Button("") { model.back() }.keyboardShortcut("[", modifiers: .command)
            Button("") { model.toggleMute() }.keyboardShortcut("m", modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func escape() {
        switch step {
        case .bring where !model.importing && !model.imported: model.startFresh()
        case .welcome: model.finish()
        default: model.next()
        }
    }
}

// MARK: - Pieces

struct StepPhase: ViewModifier {
    var x: CGFloat, scale: CGFloat, blur: CGFloat, opacity: Double
    static let settled = StepPhase(x: 0, scale: 1, blur: 0, opacity: 1)
    func body(content: Content) -> some View {
        content.offset(x: x).scaleEffect(scale).blur(radius: blur).opacity(opacity)
    }
}

/// Text that sharpens into place a beat after the one before it.
struct Rise: ViewModifier {
    var index: Int
    var blur: CGFloat = 6
    var distance: CGFloat = 10
    var start = 0.12
    var spacing = 0.06
    var duration = 0.64
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .blur(radius: shown || reduceMotion ? 0 : blur)
            .onAppear {
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: reduceMotion ? 0.3 : duration).delay(start + Double(index) * spacing)) {
                    shown = true
                }
            }
    }
}

extension View {
    func rise(_ index: Int) -> some View { modifier(Rise(index: index)) }
}

/// One flat, rich field of the Space's color; picking a swatch repaints it.
struct PremiereBackground: View {
    var tint: AppearanceColor

    var body: some View {
        // Richer than the raw tint: pushed away from grey, then deepened so white text sits well on it.
        let gray = 0.3 * tint.red + 0.59 * tint.green + 0.11 * tint.blue
        let rich = { (value: Double) in min(max((gray + (value - gray) * 1.45) * 0.6, 0), 1) }
        return Color(.sRGB, red: rich(tint.red), green: rich(tint.green), blue: rich(tint.blue))
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.6), value: tint)
            .overlay(MeshGradientView(tint: tint)) // the flat color stays underneath if Metal is unavailable
            .ignoresSafeArea()
    }
}

struct ProgressPills: View {
    var steps: [OnboardingStep]
    var current: OnboardingStep

    var body: some View {
        let index = steps.firstIndex(of: current) ?? 0
        HStack(spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, _ in
                Capsule()
                    .fill(Color.white.opacity(offset == index ? 0.9 : offset < index ? 0.55 : 0.25))
                    .frame(width: offset == index ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.75), value: current)
        .accessibilityElement().accessibilityLabel("Step \(index + 1) of \(steps.count)")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.16))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14), value: configuration.isPressed)
    }
}

struct LinkButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.66))
            .padding(.vertical, 10).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct QuietButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.5))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct Caption: View {
    var text: String
    var body: some View { Text(text).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.55)) }
}

struct StepTitle: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 30, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }
}

struct StepSubtitle: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(Color.white.opacity(0.68))
            .frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Steps

struct PremiereIntro: View {
    @ObservedObject var model: PremiereModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                ForEach(Array("D’arce".enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .modifier(Rise(index: index, blur: 14, distance: 14, start: 0.12, spacing: 0.07, duration: 0.9))
                }
            }
            .font(.system(size: 76, weight: .semibold))
            .accessibilityElement().accessibilityLabel("D’arce")
            Text("Arc’s best ideas, rebuilt for your Mac.")
                .font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.68))
                .modifier(Rise(index: 0, start: 0.75))
            Button("Get started", action: model.next).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .modifier(Rise(index: 1, start: 0.75))
        }
    }
}

struct PremiereBring: View {
    @ObservedObject var model: PremiereModel
    @State private var choosing = false

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 16) {
                StepTitle(text: model.bringTitle).rise(0)
                StepSubtitle(text: "Spaces, tabs and sign-ins, right where you left them. Nothing leaves this Mac.").rise(1)
                rows.rise(2)
                actions.rise(3)
                if model.installed.count > 1, !model.importing, !model.imported {
                    Menu {
                        ForEach(model.installed, id: \.self) { browser in Button(browser.displayName) { model.choose(browser) } }
                    } label: { Text("Import from another browser").font(.system(size: 12.5)) }
                    .menuStyle(.borderlessButton).fixedSize().opacity(0.6).rise(4)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            PreviewSidebar(model: model, filled: model.state(.spaces) == .done || model.state(.favorites) == .done || model.imported)
        }
        .frame(maxWidth: 900)
    }

    @ViewBuilder private var rows: some View {
        if model.nothingToImport {
            Text(model.readError ?? "\(model.browser?.shortName ?? "That browser") has nothing D’arce can bring over yet.")
                .font(.system(size: 14.5)).foregroundStyle(Color.white.opacity(0.7)).padding(.vertical, 8)
        } else if model.profiles == nil {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking at \(model.browser?.shortName ?? "your browser")…").opacity(0.7) }
                .font(.system(size: 15)).padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.availableRows, id: \.self) { row in
                    ImportRow(model: model, row: row)
                    if row == .cookies, model.isOn(.cookies), !model.imported {
                        Text("macOS asks for your password once to read these.")
                            .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.55)).padding(.leading, 52).padding(.bottom, 4)
                    }
                    if row == .extensions, choosing, !model.importing, !model.imported {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.extensions, id: \.id) { item in
                                Toggle(item.name, isOn: Binding(get: { !model.options.excludedExtensionIDs.contains(item.id) },
                                                                set: { if $0 { model.options.excludedExtensionIDs.remove(item.id) }
                                                                       else { model.options.excludedExtensionIDs.insert(item.id) } }))
                                    .toggleStyle(.checkbox).font(.system(size: 13))
                            }
                        }
                        .padding(.leading, 52).padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if model.availableRows.contains(.extensions), !model.importing, !model.imported {
                    Button(choosing ? "Done choosing" : "Choose extensions…") {
                        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.3)) { choosing.toggle() }
                    }
                    .buttonStyle(LinkButtonStyle()).padding(.leading, 46)
                }
                ForEach(model.problems.prefix(3), id: \.self) { problem in
                    Text(problem).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 14) {
            if model.imported {
                Button("Continue", action: model.next).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else if model.nothingToImport {
                Button("Start fresh", action: model.startFresh).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(model.importing ? "Bringing it over…" : "Bring it over", action: model.runImport)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(model.importing || model.profiles == nil)
                if !model.importing { Button("Start fresh", action: model.startFresh).buttonStyle(LinkButtonStyle()) }
            }
        }
        .padding(.top, 4)
    }
}

/// A switch before the import; a check that draws itself once that part has come over.
struct ImportRow: View {
    @ObservedObject var model: PremiereModel
    var row: PremiereModel.Row
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.importing || model.imported {
                    Tick(state: model.state(row))
                } else {
                    Toggle("", isOn: Binding(get: { model.isOn(row) }, set: { model.setOn(row, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            .frame(width: 34, alignment: .leading)
            Text(model.title(row)).font(.system(size: 15)).opacity(model.isOn(row) ? 1 : 0.5)
            Spacer(minLength: 12)
            Text(model.detail(row)).font(.system(size: 15)).monospacedDigit().foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.white.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityElement(children: .combine)
    }
}

struct Tick: View {
    var state: PremiereModel.RowState
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(state == .done ? 0 : 0.35), lineWidth: 1.5)
            Circle().fill(state == .failed ? Color.white.opacity(0.25) : .white).scaleEffect(state == .done || state == .failed ? 1 : 0.6)
                .opacity(state == .done || state == .failed ? 1 : 0)
            if state == .working {
                ProgressView().controlSize(.mini).tint(.white)
            }
            CheckShape().trim(from: 0, to: state == .done ? 1 : 0)
                .stroke(Color(red: 0.11, green: 0.08, blue: 0.16), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 10)
            if state == .failed { Image(systemName: "minus").font(.system(size: 10, weight: .bold)) }
        }
        .frame(width: 20, height: 20)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: state)
        .accessibilityLabel(state == .done ? "Done" : state == .failed ? "Didn't come over" : state == .working ? "Bringing over" : "")
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

/// The person's own sidebar in miniature, filling in as their things come over.
struct PreviewSidebar: View {
    @ObservedObject var model: PremiereModel
    var filled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(filled ? (model.previewFavorites.first?.url.host ?? "Search or Enter URL…") : "Search or Enter URL…")
                .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 12)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(0..<6, id: \.self) { index in
                    let favorite = index < model.previewFavorites.count ? model.previewFavorites[index] : nil
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.1)).frame(height: 46)
                        .overlay {
                            if let favorite {
                                Group {
                                    if let icon = favorite.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                                    else { Text(String(favorite.title.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold)) }
                                }
                                .frame(width: 18, height: 18)
                                .scaleEffect(filled ? 1 : 0.6).opacity(filled ? 1 : 0)
                                .animation(.spring(response: 0.5, dampingFraction: 0.68).delay(Double(index) * 0.05), value: filled)
                            }
                        }
                }
            }
            if let space = model.previewSpace {
                Text(space.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7)).padding(.top, 6)
                    .opacity(filled ? 1 : 0)
                ForEach(Array(space.tabs.enumerated()), id: \.offset) { index, tab in
                    HStack(spacing: 9) {
                        Group {
                            if let icon = tab.icon { Image(nsImage: icon).resizable() } else { RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.35)) }
                        }.frame(width: 15, height: 15)
                        Text(tab.title).font(.system(size: 13)).lineLimit(1)
                    }
                    .frame(height: 30).padding(.horizontal, 8)
                    .opacity(filled ? 1 : 0).offset(x: filled ? 0 : -10)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.3 + Double(index) * 0.06), value: filled)
                }
            }
            if !filled {
                Text("Your sidebar will fill in here.").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.38))
                    .frame(maxWidth: .infinity).padding(.top, 40).transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(width: 300, height: 420)
        .background(Color.white.opacity(reduceTransparency ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .accessibilityElement().accessibilityLabel("Preview of your sidebar")
    }
}

struct PremiereTheme: View {
    @ObservedObject var model: PremiereModel
    @Namespace private var knob

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 16) {
                StepTitle(text: "Pick a color.").rise(0)
                StepSubtitle(text: model.themeSubtitle).rise(1)
                VStack(alignment: .leading, spacing: 12) {
                    if !model.arcTints.isEmpty {
                        Caption(text: "From your Arc")
                        swatches(model.arcTints).padding(.bottom, 6)
                    }
                    swatches(PremiereModel.curatedTints)
                }.rise(2)
                appearance.rise(3)
                HStack(spacing: 14) {
                    Button("Looks good", action: model.next).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    Button("Choose later", action: model.next).buttonStyle(LinkButtonStyle())
                }.padding(.top, 4).rise(4)
            }
            .frame(maxWidth: 440, alignment: .leading)
            PreviewSidebar(model: model, filled: true)
        }
        .frame(maxWidth: 900)
    }

    private func swatches(_ colors: [AppearanceColor]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                let selected = color == model.tint
                Button { model.pick(color) } label: {
                    Circle()
                        .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15)))
                        .frame(width: 34, height: 34)
                        .padding(5)
                        .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 1 : 0), lineWidth: 2))
                        .scaleEffect(selected ? 1.04 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selected)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(selected ? "Selected color" : "Color")
            }
        }
    }

    private var appearance: some View {
        HStack(spacing: 0) {
            ForEach([(BrowserAppearance.system, "Auto"), (.light, "Light"), (.dark, "Dark")], id: \.0) { mode, title in
                Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { model.mode = mode } } label: {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(model.mode == mode ? Color(red: 0.11, green: 0.08, blue: 0.16) : Color.white.opacity(0.7))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background {
                            if model.mode == mode { RoundedRectangle(cornerRadius: 8).fill(.white).matchedGeometryEffect(id: "knob", in: knob) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain).accessibilityLabel("Appearance")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14), value: configuration.isPressed)
    }
}

struct PremiereDefaultBrowser: View {
    @ObservedObject var model: PremiereModel

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 16) {
                StepTitle(text: "Make D’arce your browser?").rise(0)
                StepSubtitle(text: "Links from Messages, Slack and Mail open in a small window. One click keeps the page.").rise(1)
                HStack(spacing: 14) {
                    if model.defaultState == .done {
                        Button("Continue", action: model.next).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Make default", action: model.makeDefault).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .disabled(model.defaultState == .asking)
                        Button("Not now", action: model.next).buttonStyle(LinkButtonStyle())
                    }
                }.padding(.top, 4).rise(2)
                Text(note).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.55))
                    .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: model.defaultState).rise(3)
            }
            .frame(maxWidth: 440, alignment: .leading)
            LinkIllustration(opened: model.defaultState == .done)
        }
        .frame(maxWidth: 900)
    }

    private var note: String {
        switch model.defaultState {
        case .idle, .asking: "macOS will ask you to confirm."
        case .done: "Done. Links open in D’arce now."
        case .declined: "No problem. It’s in Settings whenever you want it."
        }
    }
}

/// A link in a chat bubble that, once D'arce is the browser, opens in a small window.
struct LinkIllustration: View {
    var opened: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            (Text("this is the one i was talking about ") + Text("figma.com/file/launch…").underline())
                .font(.system(size: 14)).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(width: 230, alignment: .leading)
                .background(Color.white.opacity(0.14), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18))
                .offset(y: 40)
            VStack(alignment: .leading, spacing: 8) {
                Text("figma.com").font(.system(size: 12, weight: .semibold))
                ForEach([1.0, 0.6, 1.0, 0.6], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.88)).frame(width: 186 * width, height: 8)
                }
            }
            .foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.16))
            .padding(12)
            .frame(width: 210, height: 150, alignment: .topLeading)
            .background(Color(red: 0.965, green: 0.953, blue: 0.98), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
            .scaleEffect(opened ? 1 : 0.7, anchor: .topLeading)
            .offset(x: opened ? 110 : 50, y: opened ? 140 : 80)
            .opacity(opened ? 1 : 0)
            .animation(.spring(response: 0.56, dampingFraction: 0.78), value: opened)
        }
        .frame(width: 320, height: 300, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

struct PremiereWelcome: View {
    @ObservedObject var model: PremiereModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome home.").font(.system(size: 44, weight: .semibold)).rise(0)
            Text(model.welcomeSubtitle).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.68)).rise(1)
            Button("Open D’arce") { model.finish() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .padding(.top, 6).rise(2)
        }
    }
}
