import Foundation

/// The Library's date headers, like Arc's: Today, Yesterday, "3 days ago", "1 week ago", "2 months ago".
/// Days are calendar days, so something from late last night is "Yesterday", not "Today".
public struct LibraryGroup<Item> {
    public let label: String
    public var items: [Item]

    public static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return plural(days, "day")
        case 7..<31: return plural(days / 7, "week")
        case 31..<365: return plural(max(1, days / 30), "month")
        default: return plural(days / 365, "year")
        }
    }

    /// Newest first, one group per label, in the order the labels first appear.
    public static func group(_ items: [Item], date: (Item) -> Date, now: Date = Date(), calendar: Calendar = .current) -> [LibraryGroup<Item>] {
        var groups: [LibraryGroup<Item>] = []
        for item in items.sorted(by: { date($0) > date($1) }) {
            let label = label(for: date(item), now: now, calendar: calendar)
            if groups.last?.label == label { groups[groups.count - 1].items.append(item) }
            else { groups.append(LibraryGroup(label: label, items: [item])) }
        }
        return groups
    }
}
