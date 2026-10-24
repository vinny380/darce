import Foundation

/// Ordinary sidebar tabs without integrated live-item data; does not execute a reset.
public enum SidebarResetEligibility {
    public static func isEligible(kind: TabKind, isEditing: Bool, savedURL: URL?, liveURL: URL?, canGoBack: Bool) -> Bool {
        guard kind == .pinned, !isEditing, canGoBack,
              let savedURL, let liveURL,
              savedURL != liveURL,
              PinnedURLComparison.normalized(savedURL) != PinnedURLComparison.normalized(liveURL) else {
            return false
        }
        let pattern = #"^(?:https?:\/\/)?(?:www\.)?instagram\.([^:\/\n\?]+)\/direct"#
        guard savedURL.absoluteString.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                            range: nil, locale: nil) != nil else {
            return true
        }
        return liveURL.absoluteString.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                            range: nil, locale: nil) == nil
    }
}
