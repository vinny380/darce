import AppKit
import BrowserCore
import SwiftUI

// Preimplementation integration failures: layout/focus remounts live pages; pane removal
// deletes a tab; a layout save fails to restore; actual responder focus targets the wrong tab.
@MainActor
func runSplitSmoke(directory: URL) async throws -> [String: Bool] {
    let directory = directory.appendingPathComponent("persistent-splits")
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var ids: [UUID] = []
    for index in 0..<4 {
        model.open(URL(string: "https://split-\(index).invalid")!)
        ids.append(model.state.selectedTabID!)
    }
    let pages = ids.map { model.page(for: $0)! }
    for (index, page) in pages.enumerated() {
        page.webView.stopLoading()
        page.webView.loadHTMLString("<title>Split \(index)</title><input id='draft' value='draft-\(index)'><script>window.splitToken=\(index+100)</script>", baseURL: nil)
    }
    for _ in 0..<100 {
        if pages.enumerated().allSatisfy({ $0.element.webView.title == "Split \($0.offset)" }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    model.select(ids[0])
    for id in ids.dropFirst() { model.split(id) }
    let group = model.state.selectedSplitGroup!
    let host = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1180, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView = NSHostingView(rootView: BrowserWindow(model: model))
    host.makeKeyAndOrderFront(nil)
    defer { host.orderOut(nil); host.contentView = nil; model.suspendWindow() }
    try await Task.sleep(for: .milliseconds(150))
    var result = ["split_four_panes_mounted": pages.allSatisfy { $0.webView.window === host }]
    let focused = host.makeFirstResponder(pages[2].webView)
    try await Task.sleep(for: .milliseconds(100))
    result["split_actual_responder_updates_focus"] = focused && model.state.selectedTabID == ids[2] && model.state.selectedSplitGroup?.id == group.id
    model.focusPane(ids[0])
    model.focusPane(ids[3])
    result["split_header_focus_targets_latest_renderer"] = model.state.selectedTabID == ids[3] && host.firstResponder === pages[3].webView
    model.stateUpdate {
        _ = $0.resizeSplit(group.id, weights: [0.1, 0.2, 0.3, 0.4])
        _ = $0.setSplitAxis(group.id, axis: .vertical)
        _ = $0.reorderSplit(group.id, tabIDs: ids.reversed())
    }
    try await Task.sleep(for: .milliseconds(100))
    result["split_layout_preserves_renderer_identity"] = zip(ids, pages).allSatisfy { model.page(for: $0.0) === $0.1 && $0.1.webView.window === host }
    var intact = true
    for (index, page) in pages.enumerated() {
        let token = try await page.webView.evaluateJavaScript("window.splitToken") as? Int
        let draft = try await page.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        intact = intact && token == index+100 && draft == "draft-\(index)"
    }
    result["split_layout_preserves_live_form_and_script_state"] = intact
    if let view = host.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("split-layout.png"))
        }
    }
    let reopened = try BrowserStateFile.read(from: model.sessionURL)
    result["split_layout_restores_from_disk"] = reopened.selectedSplitGroup?.tabIDs == Array(ids.reversed()) && reopened.selectedSplitGroup?.weights == [0.4, 0.3, 0.2, 0.1] && reopened.selectedSplitGroup?.axis == .vertical
    model.select(ids[1])
    model.separatePane(ids[1], from: group.id)
    try await Task.sleep(for: .milliseconds(100))
    result["split_remove_preserves_tab_and_page"] = model.state.tabs.contains { $0.id == ids[1] && $0.kind == .today } && model.page(for: ids[1]) === pages[1] && model.state.splitGroups.first { $0.id == group.id }?.tabIDs.count == 3
    result["split_separate_selects_live_ordinary_tab"] = model.state.selectedTabID == ids[1] && model.state.selectedSplitGroup == nil && pages[1].webView.window === host
    let separatedToken = try await pages[1].webView.evaluateJavaScript("window.splitToken") as? Int
    let separatedDraft = try await pages[1].webView.evaluateJavaScript("document.getElementById('draft').value") as? String
    result["split_separate_preserves_document_state"] = separatedToken == 101 && separatedDraft == "draft-1"
    let separated = try BrowserStateFile.read(from: model.sessionURL)
    result["split_separate_persists_remaining_group"] = separated.selectedTabID == ids[1] && separated.splitGroups.first { $0.id == group.id }?.tabIDs == [ids[3], ids[2], ids[0]]
    model.select(ids[3])
    model.separatePane(ids[0], from: group.id)
    result["split_separate_other_pane_preserves_focus"] = model.state.selectedTabID == ids[3] && model.state.selectedSplitGroup?.tabIDs == [ids[3], ids[2]]
    model.separateAllPanes()
    result["split_dissolve_preserves_all_tabs"] = model.state.splitGroups.isEmpty && model.state.tabs.count == 4 && zip(ids,pages).allSatisfy { model.page(for: $0.0) === $0.1 }
    model.select(ids[0]); model.split(ids[1])
    let current = model.state, bytes = try Data(contentsOf: model.sessionURL)
    model.separatePane(ids[1], from: group.id)
    let afterStale = try Data(contentsOf: model.sessionURL)
    result["split_stale_separation_preserves_new_group"] = model.state == current && afterStale == bytes
    model.separateAllPanes()
    return result
}
