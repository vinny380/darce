import AppKit
import BrowserCore
import SwiftUI

/// Debug: `--premiere-demo <dir>` plays the welcome by itself on a made-up Arc profile, for recording launch videos.
/// It sizes the window, waits for `<dir>/go` (the recorder creates it once it's capturing), then walks every step.
/// Site icons come from `<dir>/icons/<host>.png`.
enum PremiereDemo {
    @MainActor
    static func play(_ browserModel: BrowserModel, directory: URL) {
        // Recorded from behind other windows: keep App Nap from throttling the frames.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording the welcome")
        Task { @MainActor in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            try? await Task.sleep(for: .milliseconds(600))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                window.setContentSize(NSSize(width: 1280, height: 800))
                window.center()
                // Hidden windows get throttled and drop frames: float on top (over full-screen apps too) without taking focus.
                window.level = .floating
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.orderFrontRegardless()
            }
            let go = directory.appendingPathComponent("go")
            while !FileManager.default.fileExists(atPath: go.path) { try? await Task.sleep(for: .milliseconds(20)) }

            let premiere = PremiereModel(browserModel: browserModel, installed: [.arc], isDefaultBrowser: false,
                                         prefetched: [profile(icons: directory.appendingPathComponent("icons"))])
            premiere.onFinish = { [weak browserModel] in
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.45)) { browserModel?.premiere = nil }
            }
            browserModel.premiere = premiere

            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await wait(3.4); premiere.next()                       // intro → Bring
            await wait(2.0); premiere.runImport()
            await wait(2.4); premiere.next()                       // → Pick a color
            await wait(1.5)
            for color in premiere.arcTints.dropFirst() + PremiereModel.curatedTints.prefix(3) {
                premiere.pick(color); await wait(1.15)
            }
            if let first = premiere.arcTints.first { premiere.pick(first) }
            await wait(1.4); premiere.next()                       // → default browser
            await wait(2.0); premiere.next()                       // "Not now" → Welcome home
            await wait(3.6); premiere.finish()
            await wait(3)
        }
    }

    private static func profile(icons: URL) -> ImportedProfile {
        let site = { (title: String, address: String) in
            ImportedItem.tab(key: UUID().uuidString, title: title, url: URL(string: address)!)
        }
        var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
        profile.favorites = [
            site("GitHub", "https://github.com/"), site("Figma", "https://www.figma.com/"), site("Linear", "https://linear.app/"),
            site("Gmail", "https://mail.google.com/"), site("YouTube", "https://www.youtube.com/"), site("Notion", "https://www.notion.so/"),
        ]
        let studio = [site("Onboarding — Figma", "https://www.figma.com/design"), site("Launch plan", "https://www.notion.so/launch"),
                      site("Roadmap · Linear", "https://linear.app/roadmap")]
        profile.spaces = [
            ImportedSpace(key: "studio", name: "Studio", tint: AppearanceColor(red: 0.56, green: 0.39, blue: 0.70),
                          pinned: studio + (1...9).map { site("Reference \($0)", "https://www.are.na/\($0)") }),
            ImportedSpace(key: "personal", name: "Personal", tint: AppearanceColor(red: 0.36, green: 0.45, blue: 0.70),
                          pinned: (1...8).map { site("Read later \($0)", "https://example.com/\($0)") }),
            ImportedSpace(key: "side", name: "Side project", tint: AppearanceColor(red: 0.30, green: 0.58, blue: 0.52),
                          pinned: (1...5).map { site("Notes \($0)", "https://example.org/\($0)") }),
        ]
        profile.bookmarks = (1...214).map { site("Bookmark \($0)", "https://example.net/\($0)") }
        let now = Date()
        profile.history = (0..<8_412).map {
            ImportedVisit(url: URL(string: "https://example.com/page/\($0)")!, title: "Page \($0)", visitedAt: now.addingTimeInterval(Double(-$0) * 600))
        }
        for case .tab(_, _, let url) in profile.favorites + studio {
            if let host = url.host, let data = try? Data(contentsOf: icons.appendingPathComponent("\(host).png")) { profile.icons[url.absoluteString] = data }
        }
        return profile
    }
}
