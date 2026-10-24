import BrowserCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsController: ObservableObject {
    @Published private(set) var state = BrowserSettings()
    @Published private(set) var errorMessage: String?
    private(set) var recoveryRequired = false
    private var store: BrowserSettingsStore?
    /// Lets the workspace push app-wide effects (Boosts, the global shortcut) when a setting changes.
    var onChange: ((BrowserSettings) -> Void)?

    init(directory: URL) {
        do {
            let loaded = try BrowserSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            store = loaded
            state = loaded.state
        } catch {
            recoveryRequired = true
            errorMessage = "Settings could not be loaded. Saving is disabled to preserve the original file. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func update(_ change: (inout BrowserSettings) -> Void) -> Bool {
        guard !recoveryRequired, var candidate = store else { return false }
        do {
            try candidate.update(change)
            store = candidate
            state = candidate.state
            errorMessage = nil
            onChange?(candidate.state)
            return true
        } catch {
            errorMessage = "Settings could not be saved: \(error.localizedDescription)"
            return false
        }
    }
}
