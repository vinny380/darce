import AppKit
import BrowserCore
import SwiftUI

/// Debug: `--premiere-demo <dir>` stages the welcome for recording a launch video, on a made-up Arc profile.
/// The window waits invisibly, centered at 1280×800; activating the app (a click on its Dock icon) is the launch:
/// the welcome appears and plays as if D'arce had just opened. A recorder then drives it with real clicks.
/// Site icons come from `<dir>/icons/<host>.png`.
enum PremiereDemo {
    @MainActor
    static func play(_ browserModel: BrowserModel, directory: URL) {
        Task { @MainActor in
            var found: NSWindow?
            while found == nil {
                try? await Task.sleep(for: .milliseconds(100))
                found = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
            }
            guard let window = found else { return }
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            window.alphaValue = 0
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
            let premiere = PremiereModel(browserModel: browserModel, installed: [.arc], isDefaultBrowser: false,
                                         prefetched: [profile(icons: directory.appendingPathComponent("icons"))])
            premiere.onFinish = { [weak browserModel] in
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.45)) { browserModel?.premiere = nil }
            }
            browserModel.premiere = premiere
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
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
