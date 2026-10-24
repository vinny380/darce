import BrowserCore
import Foundation
import WebKit

@MainActor
struct WebKitBrowsingDataBackend: BrowsingDataBackend {
    let dataStore: @MainActor (UUID) throws -> WKWebsiteDataStore

    func clear(_ request: BrowsingDataRequest) async throws {
        guard !request.categories.isEmpty else { throw BrowsingDataError.emptySelection }
        let store = try dataStore(request.profileID)
        guard store.identifier == request.profileID else { throw BrowsingDataError.wrongDataStore }
        var types: Set<String> = []
        if request.categories.contains(.cookies) { types.insert(WKWebsiteDataTypeCookies) }
        if request.categories.contains(.cache) {
            types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
            if #unavailable(macOS 26.2) { types.insert(WKWebsiteDataTypeOfflineWebApplicationCache) }
        }
        if request.categories.contains(.siteStorage) {
            types.formUnion([WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeLocalStorage,
                             WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeIndexedDBDatabases,
                             WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFileSystem,
                             WKWebsiteDataTypeMediaKeys, WKWebsiteDataTypeHashSalt])
        }
        if request.categories.contains(.history) { types.insert(WKWebsiteDataTypeSearchFieldRecentSearches) }
        try Task.checkCancellation()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}

/// Stops the old page from immediately restoring storage after a clear.
@MainActor
func unloadForBrowsingDataRemoval(_ webView: WKWebView) async throws {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.configuration.userContentController.removeAllUserScripts()
    webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
    for _ in 0..<300 {
        if !webView.isLoading, webView.url?.absoluteString == "about:blank" { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BrowsingDataError.rendererDidNotStop
}

extension BrowserPage {
    @MainActor
    func prepareForBrowsingDataRemoval() async throws {
        onNavigate = nil
        onVisit = nil
        onFinish = nil
        onNewTab = nil
        onDownload = nil
        onLink = nil
        cancelElementPicker()
        try await unloadForBrowsingDataRemoval(webView)
    }
}
