import AppKit
import BrowserCore
import Foundation
import WebKit

@MainActor
func runNativeSemanticColorsSmoke(model: BrowserModel, directory: URL) async throws -> [String: Bool] {
    model.open(URL(string: "about:blank")!)
    let fallback = model.state.selectedTabID!
    let address = URL(string: "https://semantic-fixture.invalid/icon")!
    model.open(address)
    let image = model.state.selectedTabID!
    let page = model.page(for: image)!
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='16' height='32' fill='#ff0000'/><rect x='16' width='16' height='32' fill='#0000ff'/></svg>"
    let icon = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    page.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<title>Semantic icon</title><link rel='icon' href='\(icon)'>")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && (page.webView.url != address || page.webView.title != "Semantic icon" || page.webView.isLoading) {
        try await Task.sleep(for: .milliseconds(25))
    }
    var fetched: Bool?
    model.favicons.refresh(from: page, profileID: model.state.selectedProfileID) { fetched = $0 }
    let iconDeadline = Date().addingTimeInterval(5)
    while fetched == nil && Date() < iconDeadline { try await Task.sleep(for: .milliseconds(25)) }
    var checks = try await runSemanticRowSmoke(model: model, ids: [fallback, image], directory: directory)
    checks["semantic_real_favicon_loaded"] = fetched == true
    return checks
}
