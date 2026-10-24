import Foundation

extension BrowserState {
    /// Tests-first baseline stub. Root owns the red run before cache implementation.
    public func savedFaviconPNG(forTab id: UUID) -> Data? {
        nil
    }

    /// Returns whether the saved cache changed, not whether an unchanged image was admissible.
    /// Tests-first baseline stub; no persistence or admission behavior is implemented yet.
    @discardableResult
    public mutating func updateSavedFavicon(_ id: UUID, profileID: UUID, png: Data?,
                                            liveURL: URL?, canGoBack: Bool, hasLoaded: Bool) -> Bool {
        false
    }
}
