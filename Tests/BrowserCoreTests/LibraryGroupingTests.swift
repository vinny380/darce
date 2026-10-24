import Foundation
import Testing
@testable import BrowserCore

/// Library lists are grouped like Arc's ("2 days ago", "1 week ago", "1 month ago"). Each test names the bug it catches.
private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private let now = ISO8601DateFormatter().date(from: "2026-10-24T20:00:00Z")!
private func ago(days: Int, hours: Int = 0) -> Date { now.addingTimeInterval(-Double(days * 86_400 + hours * 3_600)) }
private func label(_ date: Date) -> String { LibraryGroup<Date>.label(for: date, now: now, calendar: calendar) }

@Test func calendarDaysNotRolling24Hours() {
    #expect(label(ago(days: 0, hours: 3)) == "Today")
    #expect(label(ago(days: 0, hours: 21)) == "Yesterday")  // 23:00 the day before
    #expect(label(ago(days: 2)) == "2 days ago")
    #expect(label(ago(days: 6)) == "6 days ago")
}

@Test func weeksThenMonthsThenYears() {
    #expect(label(ago(days: 7)) == "1 week ago")
    #expect(label(ago(days: 13)) == "1 week ago")
    #expect(label(ago(days: 14)) == "2 weeks ago")
    #expect(label(ago(days: 31)) == "1 month ago")
    #expect(label(ago(days: 75)) == "2 months ago")
    #expect(label(ago(days: 400)) == "1 year ago")
}

@Test func futureDatesCountAsToday() {
    #expect(label(now.addingTimeInterval(3_600)) == "Today")  // a clock change must not invent a group
}

@Test func groupingKeepsNewestFirstAndOneHeaderPerLabel() {
    let dates = [ago(days: 5), ago(days: 0), ago(days: 2), ago(days: 2, hours: 3), ago(days: 9)]
    let groups = LibraryGroup.group(dates, date: { $0 }, now: now, calendar: calendar)
    #expect(groups.map(\.label) == ["Today", "2 days ago", "5 days ago", "1 week ago"])
    #expect(groups[1].items == [ago(days: 2), ago(days: 2, hours: 3)])
}
