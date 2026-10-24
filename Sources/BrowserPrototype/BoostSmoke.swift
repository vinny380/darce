import BrowserCore
import Foundation
import WebKit

@MainActor
func runBoostSmoke(page: BrowserPage, controller: BoostController, profileID: UUID) async -> [String: Bool] {
    // Uses a synthetic navigation so actual URL host checks run, without a network request.
    page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://boost-fixture.invalid/")!), responseHTML: "<title>Boost Fixture</title><main id='boost-fixture'>Text</main><aside id='boost-hidden'>Advertisement</aside>")
    for _ in 0..<100 {
        if page.webView.title == "Boost Fixture", !page.webView.isLoading { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    func apply() async -> Bool {
        await withCheckedContinuation { continuation in
            page.applyBoosts(controller: controller, profileID: profileID) { continuation.resume(returning: $0 == nil) }
        }
    }
    func js(_ source: String) async -> String? { try? await page.webView.evaluateJavaScript(source) as? String }
    var checks: [String: Bool] = [:]
    var boost = BrowserBoost(profileID: profileID, host: "boost-fixture.invalid", name: "Smoke", css: "#boost-fixture {color:rgb(17,34,51)!important;}", javascript: "window.boostSmokeRuns = (window.boostSmokeRuns || 0) + 1;", hiddenSelectors: ["#boost-hidden"])
    let unrelated = WKUserScript(source: "window.unrelatedScriptSurvives = true", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    page.webView.configuration.userContentController.addUserScript(unrelated)
    checks["boost_save"] = controller.save(boost)
    checks["boost_apply"] = await apply()
    checks["boost_css_applies"] = await js("getComputedStyle(document.querySelector('#boost-fixture')).color") == "rgb(17, 34, 51)"
    checks["boost_element_hiding_applies"] = await js("getComputedStyle(document.querySelector('#boost-hidden')).display") == "none"
    _ = await apply()
    checks["boost_script_runs_once_per_document"] = await js("String(window.boostSmokeRuns)") == "1"
    checks["boost_preserves_unrelated_user_scripts"] = page.webView.configuration.userContentController.userScripts.contains { $0.source == unrelated.source }
    boost.enabled = false
    _ = controller.save(boost); _ = await apply()
    checks["boost_disable_restores_styles"] = await js("getComputedStyle(document.querySelector('#boost-fixture')).color") != "rgb(17, 34, 51)"
    checks["boost_disable_restores_hidden_element"] = await js("getComputedStyle(document.querySelector('#boost-hidden')).display") != "none"
    let wrongHost = BrowserBoost(profileID: profileID, host: "other-fixture.invalid", name: "Wrong Host", css: "#boost-fixture {color:rgb(17,34,51)!important;}")
    let wrongProfile = BrowserBoost(profileID: UUID(), host: "boost-fixture.invalid", name: "Wrong Profile", css: "#boost-fixture {color:rgb(17,34,51)!important;}")
    _ = controller.save(wrongHost); _ = controller.save(wrongProfile); _ = await apply()
    checks["boost_exact_host_and_profile_guard"] = await js("getComputedStyle(document.querySelector('#boost-fixture')).color") != "rgb(17, 34, 51)"
    _ = controller.remove(id: boost.id, profileID: profileID)
    _ = controller.remove(id: wrongHost.id, profileID: profileID)
    _ = controller.remove(id: wrongProfile.id, profileID: wrongProfile.profileID)
    _ = await apply()
    return checks
}
