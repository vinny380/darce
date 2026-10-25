import Foundation
import Testing
@testable import BrowserCore

/// The first-launch welcome's steps. Each test names the bug it catches.
@Test func allStepsWhenABrowserIsFoundAndNotDefault() {
    let flow = OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: false)
    #expect(flow.steps == [.intro, .bring, .theme, .defaultBrowser, .welcome])
    #expect(flow.current == .intro && flow.index == 0)
}

@Test func noBrowserSkipsTheBringStep() {
    #expect(OnboardingFlow(hasBrowserToImport: false, isDefaultBrowser: false).steps == [.intro, .theme, .defaultBrowser, .welcome])
}

@Test func alreadyDefaultSkipsTheDefaultStep() {
    #expect(OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: true).steps == [.intro, .bring, .theme, .welcome])
}

@Test func nextWalksForwardAndFinishesAfterWelcome() {
    var flow = OnboardingFlow(hasBrowserToImport: false, isDefaultBrowser: true)
    flow.next(); #expect(flow.current == .theme)
    flow.next(); #expect(flow.current == .welcome && !flow.isFinished)
    flow.next(); #expect(flow.isFinished && flow.current == .welcome)
}

@Test func backFromFirstStepStays() {
    var flow = OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: false)
    flow.back()
    #expect(flow.current == .intro)
    flow.next(); flow.next(); flow.back()
    #expect(flow.current == .bring)
}

@Test func skipAllLandsOnWelcome() {
    var flow = OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: false)
    flow.skipAll()
    #expect(flow.current == .welcome && !flow.isFinished)
}

@Test func resumeStartsAtSavedStepOrNearestFollowingOne() {
    #expect(OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: false, resumeAt: .theme).current == .theme)
    // Became the default browser since quitting: resume moves on to the next step that still exists.
    #expect(OnboardingFlow(hasBrowserToImport: true, isDefaultBrowser: true, resumeAt: .defaultBrowser).current == .welcome)
    // The browser to import from was removed: resume at the step after it.
    #expect(OnboardingFlow(hasBrowserToImport: false, isDefaultBrowser: false, resumeAt: .bring).current == .theme)
}

@Test func newSettingsDecodeFromAnOldFile() throws {
    let old = try JSONEncoder().encode(BrowserSettings())
    var json = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
    for key in ["onboardingDone", "onboardingResume", "premiereMute", "archiveToastShown"] { json.removeValue(forKey: key) }
    let settings = try JSONDecoder().decode(BrowserSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(!settings.onboardingCompleted && settings.onboardingStep == nil && !settings.premiereMuted && !settings.archiveExplained)
    var changed = settings
    changed.onboardingCompleted = true
    changed.onboardingStep = .theme
    let round = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(changed))
    #expect(round.onboardingCompleted && round.onboardingStep == .theme)
}

@Test func welcomeShowsOnFirstLaunchOrToResumeOnly() {
    var settings = BrowserSettings()
    #expect(OnboardingFlow.shouldShow(firstLaunch: true, settings: settings))
    #expect(!OnboardingFlow.shouldShow(firstLaunch: false, settings: settings))
    settings.onboardingStep = .theme
    #expect(OnboardingFlow.shouldShow(firstLaunch: false, settings: settings))
    settings.onboardingCompleted = true
    #expect(!OnboardingFlow.shouldShow(firstLaunch: true, settings: settings))
}
