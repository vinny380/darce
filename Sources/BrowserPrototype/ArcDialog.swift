import AppKit
import SwiftUI

/// Arc's in-window confirmation dialog (its DialogButton / DialogButtonStyle family): a card over a dimmed
/// window with the app mark, a title, and buttons that show their keys — Esc cancels, Return confirms.
struct DialogRequest: Identifiable {
    enum Role { case primary, destructive, cancel, secondary }
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let role: Role
        let run: () -> Void
    }
    let id = UUID()
    let title: String
    var message: String?
    /// An SF Symbol for the dialog's subject; nil shows D'arce's mark (as Arc shows its icon on "Quit Arc?").
    var symbol: String?
    let actions: [Action]
}

@MainActor
final class DialogCenter: ObservableObject {
    static let shared = DialogCenter()
    @Published private(set) var current: DialogRequest?
    private(set) weak var host: BrowserModel?

    /// Shows the dialog over `model`'s window, taking keyboard focus from the page so Esc and Return reach it.
    func present(_ request: DialogRequest, in model: BrowserModel) {
        host = model
        current = request
        if let window = BrowserWindows.shared.window(for: model) {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
        }
    }

    func dismiss() { current = nil }

    func perform(_ action: DialogRequest.Action) {
        dismiss()
        action.run()
    }
}

struct DialogOverlay: View {
    @ObservedObject var center: DialogCenter
    let model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let request = center.current, center.host === model {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { cancel(request) }
                    .transition(.opacity)
                card(request)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.18), value: center.current?.id)
    }

    private func cancel(_ request: DialogRequest) {
        if let action = request.actions.first(where: { $0.role == .cancel }) { center.perform(action) } else { center.dismiss() }
    }

    private func card(_ request: DialogRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let symbol = request.symbol {
                    Image(systemName: symbol).font(.system(size: 34, weight: .regular)).frame(width: 52, height: 52, alignment: .leading)
                } else { AppMark().frame(width: 52, height: 52) }
            }.padding(.bottom, 18)
            Text(request.title).font(.system(size: 19, weight: .semibold))
            if let message = request.message {
                Text(message).font(.system(size: 14)).opacity(0.75).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                ForEach(request.actions.filter { $0.role == .secondary }) { button($0) }
                Spacer(minLength: 16)
                ForEach(request.actions.filter { $0.role == .cancel }) { button($0) }
                ForEach(request.actions.filter { $0.role == .primary || $0.role == .destructive }) { button($0) }
            }.padding(.top, 34)
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .padding(28)
        .frame(minWidth: 460, maxWidth: 560)
        .fixedSize()
        .background(scheme == .dark ? Color(.sRGB, red: 0.08, green: 0.1, blue: 0.2) : Color(.sRGB, red: 0.98, green: 0.98, blue: 1),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.primary.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }

    private func button(_ action: DialogRequest.Action) -> some View {
        let filled = action.role == .primary || action.role == .destructive
        let fill: Color = switch action.role {
        case .primary: Color(.sRGB, red: 0.2, green: 0.22, blue: 0.96)
        case .destructive: Color(.sRGB, red: 1, green: 0.35, blue: 0.2)  // Arc's warning orange-red
        default: Color.primary.opacity(0.1)
        }
        return Button { center.perform(action) } label: {
            HStack(spacing: 8) {
                Text(action.title).font(.system(size: 14, weight: .medium)).lineLimit(1).fixedSize()
                if action.role == .cancel { Keycap { Text("ESC").font(.system(size: 10, weight: .bold)) } }
                if filled { Keycap { Image(systemName: "return").font(.system(size: 10, weight: .bold)) } }
            }
            .padding(.horizontal, 14).frame(height: 38)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(filled ? 0.2 : 0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DialogKey(role: action.role))
    }
}

/// Esc runs the cancel button and Return the primary one, like Arc's keycap hints say.
private struct DialogKey: ViewModifier {
    let role: DialogRequest.Role
    func body(content: Content) -> some View {
        switch role {
        case .cancel: content.keyboardShortcut(.cancelAction)
        case .primary, .destructive: content.keyboardShortcut(.defaultAction)
        case .secondary: content
        }
    }
}

private struct Keycap<Label: View>: View {
    @ViewBuilder let label: Label
    var body: some View {
        label.padding(.horizontal, 6).frame(height: 20).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// D'arce's mark: a glowing gradient tile, standing in for Arc's icon in its dialogs.
struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [Color(.sRGB, red: 0.33, green: 0.16, blue: 0.95), Color(.sRGB, red: 0.75, green: 0.18, blue: 0.85)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text("D’").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white))
            .shadow(color: Color(.sRGB, red: 0.6, green: 0.2, blue: 1).opacity(0.5), radius: 8)
    }
}

/// ⌘Q, like Arc: asks first (unless turned off), with "Quit, and don't ask again".
@MainActor
enum QuitConfirmation {
    /// Off for smoke and verification runs, which quit themselves.
    static var enabled = true

    static func request(primary: BrowserModel) {
        let model = BrowserWindows.shared.activeModel ?? primary
        guard enabled, model.settings.state.warnBeforeQuitting, BrowserWindows.shared.window(for: model)?.isVisible == true else {
            NSApplication.shared.terminate(nil)
            return
        }
        DialogCenter.shared.present(DialogRequest(title: "Quit D'arce?", actions: [
            .init(title: "Quit, and don't ask again", role: .secondary) {
                model.settings.update { $0.warnBeforeQuitting = false }
                NSApplication.shared.terminate(nil)
            },
            .init(title: "Cancel", role: .cancel) {},
            .init(title: "Quit", role: .primary) { NSApplication.shared.terminate(nil) },
        ]), in: model)
    }
}
