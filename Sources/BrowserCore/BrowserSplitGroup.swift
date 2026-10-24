import Foundation

public enum BrowserSplitAxis: String, Codable, Equatable, Sendable { case horizontal, vertical }

/// Original persistent grouping model; tab identities and their profile ownership stay unchanged.
public struct BrowserSplitGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var spaceID: UUID
    public internal(set) var tabIDs: [UUID]
    public internal(set) var weights: [Double]
    public internal(set) var axis: BrowserSplitAxis

    static func validWeights(_ values: [Double], count: Int) -> Bool {
        values.count == count && values.allSatisfy { $0.isFinite && $0 > 0 } && abs(values.reduce(0, +) - 1) <= 1e-6
    }
}
