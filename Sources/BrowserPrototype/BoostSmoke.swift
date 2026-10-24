import AppKit
import BrowserCore
import Foundation
import WebKit

@MainActor
func runBoostSmoke(page: BrowserPage, controller: BoostController, profileID: UUID) async -> [String: Bool] {
    // Uses a synthetic navigation so actual URL host checks run, without a network request.
    page.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://boost-fixture.invalid/")!), responseHTML: "<title>Boost Fixture</title><main id='boost-fixture'>Text</main><aside id='boost-hidden'>Advertisement</aside><i id='boost-icon' style='font-family: FixtureIcons'>star</i>")
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
    // Arc's editor controls: font (sparing icon fonts), case, size, colors and zaps all reach the page.
    var styled = BrowserBoost(profileID: profileID, host: "boost-fixture.invalid", name: "My Boost", hiddenSelectors: ["#boost-hidden"])
    styled.font = "Courier"
    styled.textCase = .uppercase
    styled.textSize = .large
    styled.colors = BoostColors(hue: 120, saturation: 0.8, invertLightness: true)
    checks["boost_editor_save"] = controller.save(styled)
    _ = await apply()
    checks["boost_editor_font_applies"] = await js("getComputedStyle(document.querySelector('#boost-fixture')).fontFamily")?.contains("Courier") == true
    // Icon fonts set their own family; Arc's rule must not replace it (icons would turn into words).
    checks["boost_editor_font_spares_icons"] = await js("getComputedStyle(document.querySelector('#boost-icon')).fontFamily")?.contains("FixtureIcons") == true
    checks["boost_editor_case_applies"] = await js("getComputedStyle(document.querySelector('#boost-fixture')).textTransform") == "uppercase"
    checks["boost_editor_size_applies"] = await js("String(getComputedStyle(document.documentElement).zoom)") == "1.25"
    let filter = await js("getComputedStyle(document.documentElement).filter")
    let matrix = await js("String(!!document.querySelector('svg[data-darce-boost-colors] feColorMatrix'))")
    checks["boost_editor_colors_apply"] = filter?.contains("url") == true && matrix == "true"
    checks["boost_editor_zap_applies"] = await js("getComputedStyle(document.querySelector('#boost-hidden')).display") == "none"
    // Live color changes: the rendered page must follow each new color, not stay on the first one.
    // WebKit only snapshots a page that's in a window, so it gets an offscreen one for the check.
    let previousSuperview = page.webView.superview
    let stage = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    stage.isReleasedWhenClosed = false
    page.webView.removeFromSuperview()
    page.webView.frame = stage.contentLayoutRect
    stage.contentView?.addSubview(page.webView)
    stage.orderBack(nil)
    func renderedPixel() async -> (red: Double, green: Double)? {
        guard let image = try? await page.webView.takeSnapshot(configuration: nil),
              let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let color = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent))
    }
    styled.colors = BoostColors(hue: 120, saturation: 1)
    _ = controller.save(styled); _ = await apply()
    try? await Task.sleep(for: .milliseconds(150))
    let green = await renderedPixel()
    styled.colors = BoostColors(hue: 0, saturation: 1)
    _ = controller.save(styled); _ = await apply()
    try? await Task.sleep(for: .milliseconds(150))
    let red = await renderedPixel()
    page.webView.removeFromSuperview()
    stage.close()
    previousSuperview?.addSubview(page.webView)
    checks["boost_editor_colors_update_live"] = green.map { $0.green > $0.red } == true && red.map { $0.red > $0.green } == true
    styled.colors = nil
    _ = controller.save(styled); _ = await apply()
    checks["boost_editor_color_reset_removes_filter"] = await js("String(!!document.querySelector('svg[data-darce-boost-colors]'))") == "false"
    _ = controller.remove(id: styled.id, profileID: profileID)
    _ = controller.remove(id: boost.id, profileID: profileID)
    _ = controller.remove(id: wrongHost.id, profileID: profileID)
    _ = controller.remove(id: wrongProfile.id, profileID: wrongProfile.profileID)
    _ = await apply()
    return checks
}
