import Foundation

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case intro, bring, theme, defaultBrowser, welcome
}

/// The first-launch welcome's steps. Bring is there only when another browser can be imported, and the
/// default-browser ask only while D'arce isn't the default yet.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var steps: [OnboardingStep]
    public private(set) var current: OnboardingStep
    public private(set) var isFinished = false

    public init(hasBrowserToImport: Bool, isDefaultBrowser: Bool, resumeAt: OnboardingStep? = nil) {
        steps = OnboardingStep.allCases.filter {
            switch $0 {
            case .bring: hasBrowserToImport
            case .defaultBrowser: !isDefaultBrowser
            default: true
            }
        }
        // Resume at the saved step, or the next one that still exists (it may have dropped out since).
        let all = OnboardingStep.allCases
        if let resumeAt, let start = all.firstIndex(of: resumeAt),
           let step = all[start...].first(where: steps.contains) {
            current = step
        } else {
            current = .intro
        }
    }

    /// On a first launch, or to pick up where someone quit partway through; never once it's done.
    public static func shouldShow(firstLaunch: Bool, settings: BrowserSettings) -> Bool {
        !settings.onboardingCompleted && (firstLaunch || settings.onboardingStep != nil)
    }

    public var index: Int { steps.firstIndex(of: current) ?? 0 }

    public mutating func next() {
        if index + 1 < steps.count { current = steps[index + 1] } else { isFinished = true }
    }

    public mutating func back() {
        if index > 0 { current = steps[index - 1] }
    }

    public mutating func skipAll() { current = .welcome }
}
