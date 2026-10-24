import Foundation

/// Comparison only for reset eligibility; never use the result as a navigation URL.
public enum PinnedURLComparison {
    public static func normalized(_ url: URL) -> URL {
        guard let original = URLComponents(string: url.absoluteString.lowercased()) else { return url }
        var components = original
        if components.scheme == nil, components.host == nil,
           let string = components.string,
           let withAuthority = URLComponents(string: "https://" + string) {
            components = withAuthority
        }
        if components.scheme == nil || components.scheme == "http" {
            components.scheme = "https"
        }
        if let host = components.host, host.lowercased().hasPrefix("www.") {
            components.host = host.split(separator: ".", omittingEmptySubsequences: true)
                .dropFirst().joined(separator: ".")
        }

        var trimPath = true
        if let fragment = components.fragment {
            if fragment.first == "!" {
                trimPath = false
                if fragment.last == "/" {
                    components.fragment = String(fragment.dropLast())
                }
            } else {
                components.fragment = nil
            }
        }
        if trimPath, components.path.last == "/" {
            // The pre-authority-fill path is intentional, including reconstruction fallback.
            components.path = String(original.path.dropLast())
        }

        if let items = components.queryItems {
            let retained = items.filter { !($0.value ?? "").isEmpty && !$0.name.hasPrefix("utm_") }
            if retained.isEmpty {
                components.queryItems = nil
            } else if retained.count != items.count {
                components.queryItems = retained
            }
        }
        return components.url ?? url
    }
}
