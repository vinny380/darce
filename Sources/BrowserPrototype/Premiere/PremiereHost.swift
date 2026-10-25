import AppKit
import BrowserCore
import SwiftUI

struct BrowserToast: Equatable {
    var title: String
    var message: String
    /// "Change timing…" opens the auto-archive setting.
    var offersArchiveSettings = false
}

extension BrowserModel {
    static var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Shows the welcome (first launch, resuming, or Help → Show Welcome).
    /// `quiet` keeps the music off (screenshot runs).
    func showPremiere(resumeAt: OnboardingStep? = nil, quiet: Bool = false) {
        guard premiere == nil else { return }
        let premiere = PremiereModel(browserModel: self, installed: ImportSources.installed(home: FileManager.default.homeDirectoryForCurrentUser),
                                     isDefaultBrowser: Self.isDefaultBrowser, resumeAt: resumeAt, music: !quiet)
        premiere.onFinish = { [weak self] in
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.45)) { self?.premiere = nil }
        }
        self.premiere = premiere
    }

    /// The first time tabs tidy themselves away, say so once.
    func noteArchived(_ count: Int) {
        guard count > 0, !settings.state.archiveExplained else { return }
        _ = settings.update { $0.archiveExplained = true }
        let tabs = count == 1 ? "1 tab" : "\(count) tabs"
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            toast = BrowserToast(title: "We tidied up",
                                 message: "\(tabs) you hadn't used in \(settings.state.autoArchiveAge.name.lowercased()) went to the Archive. ⇧⌘T brings one back.",
                                 offersArchiveSettings: true)
        }
    }
}

/// The toast's look: a small card that rises in near the bottom of the sidebar.
struct ToastCard: View {
    var toast: BrowserToast
    var dismiss: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(toast.title).font(.system(size: 13, weight: .semibold))
            Text(toast.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Got it", action: dismiss).controlSize(.small)
                if toast.offersArchiveSettings { Button("Change timing…", action: openSettings).buttonStyle(.link).controlSize(.small) }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
    }
}
