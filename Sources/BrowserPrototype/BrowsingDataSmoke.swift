import BrowserCore
import Foundation
import WebKit

/// Real WebKit stores and the local HTTP fixture; never uses a user's profile UUID.
@MainActor
func runBrowsingDataSmoke(base: URL, directory: URL) async throws -> [String: Bool] {
    let first = UUID(), second = UUID()
    let stores = [first: WKWebsiteDataStore(forIdentifier: first), second: WKWebsiteDataStore(forIdentifier: second)]
    var views: [UUID: WKWebView] = [:]
    var prepared: [UUID] = [], finished: [UUID] = []
    var checks: [String: Bool] = [:]
    var history = try HistoryStore(fileURL: directory.appendingPathComponent("browsing-data-\(UUID().uuidString)/history.json"))
    for id in [first, second] { try history.record(url: base, title: "Clear fixture", profileID: id) }

    func load(_ id: UUID, seed: Bool = false) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = stores[id]!
        let view = WKWebView(frame: .zero, configuration: configuration)
        views[id] = view
        view.load(URLRequest(url: base.appendingPathComponent(seed ? "seed" : "inspect")))
        for _ in 0..<400 {
            if !view.isLoading && view.title == "Native Services Fixture" { return view }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "BrowsingDataSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture page did not load"])
    }
    func hasCookie(_ id: UUID) async -> Bool {
        await stores[id]!.httpCookieStore.allCookies().contains { $0.name == "darce_fixture" }
    }
    func hasStorage(_ view: WKWebView) async throws -> Bool {
        try await view.evaluateJavaScript("localStorage.getItem('clear_fixture') === 'retained'") as? Bool == true
    }
    func hasCache(_ view: WKWebView) async throws -> Bool {
        try await view.callAsyncJavaScript("return await caches.has('clear-fixture');", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    }
    for id in [first, second] {
        let view = try await load(id, seed: true)
        _ = try await view.evaluateJavaScript("localStorage.setItem('clear_fixture','retained'); sessionStorage.setItem('clear_fixture','retained')")
        _ = try await view.callAsyncJavaScript("const cache = await caches.open('clear-fixture'); await cache.put('/clear-fixture-resource', new Response('retained')); return true;", arguments: [:], in: nil, contentWorld: .page)
        _ = await stores[id]!.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    }
    let firstCookie = await hasCookie(first)
    let secondCookie = await hasCookie(second)
    let firstStorage = try await hasStorage(views[first]!)
    let secondStorage = try await hasStorage(views[second]!)
    let firstCache = try await hasCache(views[first]!)
    let secondCache = try await hasCache(views[second]!)
    checks["clear fixture establishes two independent cookie/storage/cache stores"] = firstCookie && secondCookie && firstStorage && secondStorage && firstCache && secondCache
    let backend = WebKitBrowsingDataBackend { id in
        guard let store = stores[id] else { throw BrowsingDataError.profileUnavailable }
        return store
    }
    let controller = BrowsingDataController(backend: backend, prepareRenderers: { id in
        prepared.append(id)
        if let view = views.removeValue(forKey: id) { try await unloadForBrowsingDataRemoval(view) }
    }, finishRenderers: { finished.append($0) }, clearHistory: { id in try history.clear(profileID: id) })
    let oldFirst = views[first]!
    let other = views[second]!
    let cacheCleared = await controller.clear(.init(profileID: first, categories: [.cache]))
    let afterCache = try await load(first)
    let cacheAbsent = try await !hasCache(afterCache)
    let storagePresent = try await hasStorage(afterCache)
    let cookiePresent = await hasCookie(first)
    checks["cache-only clear preserves selected-profile cookies and storage"] = cacheCleared && cacheAbsent && storagePresent && cookiePresent
    checks["clearing replaces only selected-profile renderer"] = oldFirst !== afterCache && views[second] === other && prepared == [first] && finished == [first]

    let siteCleared = await controller.clear(.init(profileID: first, categories: [.cookies, .siteStorage]))
    let afterSite = try await load(first)
    let storageAbsent = try await !hasStorage(afterSite)
    let sessionAbsent = try await afterSite.evaluateJavaScript("sessionStorage.getItem('clear_fixture') === null") as? Bool == true
    let cookieAbsent = await !hasCookie(first)
    checks["cookies and website storage disappear from fresh renderer"] = siteCleared && storageAbsent && sessionAbsent && cookieAbsent
    let otherStorage = try await hasStorage(other)
    let otherCache = try await hasCache(other)
    let otherCookie = await hasCookie(second)
    checks["clear preserves other profile cookies storage and cache"] = otherStorage && otherCache && otherCookie
    checks["history remains until explicitly selected"] = history.search(profileID: first).count == 1 && history.search(profileID: second).count == 1

    let historyCleared = await controller.clear(.init(profileID: first, categories: [.history]))
    checks["history-only clear is profile-scoped and preserves renderers"] = historyCleared && history.search(profileID: first).isEmpty && history.search(profileID: second).count == 1 && views[first] === afterSite && prepared == [first, first]
    let wrongBackend = WebKitBrowsingDataBackend { _ in stores[second]! }
    do {
        try await wrongBackend.clear(.init(profileID: first, categories: [.cookies, .siteStorage]))
        checks["mismatched store rejected before data removal"] = false
    } catch BrowsingDataError.wrongDataStore {
        let retainedCookie = await hasCookie(second)
        let retainedStorage = try await hasStorage(other)
        checks["mismatched store rejected before data removal"] = retainedCookie && retainedStorage
    }
    let emptyRejected = await !controller.clear(.init(profileID: first, categories: []))
    checks["empty clear does not reset renderers"] = emptyRejected && prepared == [first, first]

    // Force an actual manifest write failure without destroying the fixture's original bytes.
    try history.record(url: base, title: "History save failure fixture", profileID: first)
    let originalHistory = try Data(contentsOf: history.fileURL)
    let retainedHistory = history.fileURL.appendingPathExtension("retained")
    try FileManager.default.moveItem(at: history.fileURL, to: retainedHistory)
    try FileManager.default.createDirectory(at: history.fileURL, withIntermediateDirectories: false)
    let partialRejected = await !controller.clear(.init(profileID: first, categories: [.cache, .history]))
    let savedHistory = try Data(contentsOf: retainedHistory)
    checks["history save failure reports partial completion and preserves original history"] = partialRejected && controller.errorMessage?.contains("Website data was cleared") == true && history.search(profileID: first).count == 1 && originalHistory == savedHistory && prepared == [first, first, first] && finished == prepared
    try FileManager.default.removeItem(at: history.fileURL) // Empty fixture-created obstruction only.
    try FileManager.default.moveItem(at: retainedHistory, to: history.fileURL)

    // Fixture-owned stores only; leave no test cookies behind.
    for view in views.values { try await unloadForBrowsingDataRemoval(view) }
    views.removeAll()
    for store in stores.values { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    return checks
}
