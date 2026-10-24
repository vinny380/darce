import AppKit
import Carbon.HIToolbox

/// Shortcuts printed with a shifted character (⌘+, ⌃⇧+, ⌃⇧-): users press the physical =/+ and -/_ keys with
/// or without Shift, and a menu bound to "+" doesn't reliably see ⌘=. Matching the key itself makes all variants
/// work, as in Arc, whatever the keyboard layout prints on that key.
@MainActor
enum ShortcutAliases {
    enum Action: Equatable { case zoomIn, addSplit, closeSplitPane }

    static func action(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Action? {
        let mods = flags.intersection([.command, .control, .option, .shift])
        switch Int(keyCode) {
        case kVK_ANSI_Equal where mods == .command || mods == [.command, .shift]: return .zoomIn
        case kVK_ANSI_Equal where mods == [.control, .shift]: return .addSplit
        case kVK_ANSI_Minus where mods == [.control, .shift]: return .closeSplitPane
        default: return nil
        }
    }

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = action(keyCode: event.keyCode, flags: event.modifierFlags) else { return event }
            return MainActor.assumeIsolated { perform(action) } ? nil : event
        }
    }

    /// True when handled; otherwise the key goes on to the page (a mini window or other window, for example).
    private static func perform(_ action: Action) -> Bool {
        if let session = PrivateBrowserWindows.shared.activeSession {
            guard action == .zoomIn, let page = session.selectedPage else { return false }
            page.webView.pageZoom = min(3, page.webView.pageZoom + 0.1)
            return true
        }
        guard let model = BrowserWindows.shared.activeModel else { return false }
        switch action {
        case .zoomIn:
            guard let page = model.selectedPage else { return false }
            page.webView.pageZoom = min(3, page.webView.pageZoom + 0.1)
        case .addSplit:
            guard model.state.selectedTab != nil, (model.state.selectedSplitGroup?.tabIDs.count ?? 0) < 4 else { return false }
            model.commandMode = .split
        case .closeSplitPane:
            guard model.state.selectedSplitGroup != nil else { return false }
            model.closeSelectedPane()
        }
        return true
    }
}

/// The physical-key matching above: each printed shortcut, with and without Shift; nothing else is taken.
@MainActor
func runShortcutAliasSmoke() -> [String: Bool] {
    let equal = UInt16(kVK_ANSI_Equal), minus = UInt16(kVK_ANSI_Minus)
    return [
        "shortcut_cmd_equal_zooms_in": ShortcutAliases.action(keyCode: equal, flags: .command) == .zoomIn,
        "shortcut_cmd_plus_zooms_in": ShortcutAliases.action(keyCode: equal, flags: [.command, .shift]) == .zoomIn,
        "shortcut_ctrl_shift_plus_adds_split": ShortcutAliases.action(keyCode: equal, flags: [.control, .shift]) == .addSplit,
        "shortcut_ctrl_shift_minus_closes_split_pane": ShortcutAliases.action(keyCode: minus, flags: [.control, .shift]) == .closeSplitPane,
        "shortcut_cmd_minus_left_to_zoom_out_menu": ShortcutAliases.action(keyCode: minus, flags: .command) == nil,
        "shortcut_plain_equal_left_to_page": ShortcutAliases.action(keyCode: equal, flags: []) == nil,
        "shortcut_option_cmd_equal_not_taken": ShortcutAliases.action(keyCode: equal, flags: [.command, .option]) == nil,
    ]
}
