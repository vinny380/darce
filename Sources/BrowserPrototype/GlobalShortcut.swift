import AppKit
import Carbon.HIToolbox

/// ⌥⌘N from any app opens a mini window (Settings → Links). Uses a Carbon hot key, which needs no
/// Accessibility permission and fires even when D'arce is in the background.
@MainActor
final class GlobalMiniWindowShortcut {
    static let shared = GlobalMiniWindowShortcut()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        if enabled, hotKey == nil { register() }
        if !enabled, let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    private func register() {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { MiniWindows.shared.open() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4441_5243), id: 1)  // "DARC"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
