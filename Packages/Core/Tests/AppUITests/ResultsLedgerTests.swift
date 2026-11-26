import Foundation
import Testing

@testable import AppUI

/// The day groups of the results lists and the savings badge text.
@Suite struct ResultsLedgerTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15)) ?? .now

    private static func at(daysAgo: Int, hour: Int = 9) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private struct Row {
        var date: Date
        var saved: Int64
    }

    private static func days(_ rows: [Row]) -> [LedgerDay<Row>] {
        ResultsLedger.days(rows, date: \.date, saved: \.saved, now: now, calendar: calendar)
    }

    @Test func rowsGroupByDayNewestFirstWithEachDaysSavings() {
        let rows = [
            Row(date: Self.at(daysAgo: 1), saved: 300), Row(date: Self.at(daysAgo: 0, hour: 8), saved: 100),
            Row(date: Self.at(daysAgo: 0, hour: 14), saved: 50), Row(date: Self.at(daysAgo: 5), saved: 0),
        ]
        let days = Self.days(rows)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Saturday, Nov 21"])
        #expect(days.map(\.savedBytes) == [150, 300, 0])
        #expect(days.map(\.rows.count) == [2, 1, 1])
        // Rows keep the order they were given inside a day.
        #expect(days[0].rows.map(\.saved) == [100, 50])
    }

    @Test func theWeekChartHasABarForEveryDayEvenWithNothingSaved() {
        let days = Self.days([Row(date: Self.at(daysAgo: 0), saved: 100), Row(date: Self.at(daysAgo: 2), saved: 40)])
        let week = ResultsLedger.lastDays(days, count: 7, now: Self.now, calendar: Self.calendar)
        #expect(week.count == 7)
        #expect(week.map(\.savedBytes) == [0, 0, 0, 0, 40, 0, 100])
        #expect(week.first?.day == Self.calendar.startOfDay(for: Self.at(daysAgo: 6)))
    }

    @Test func noRowsMakeNoDays() {
        #expect(Self.days([]).isEmpty)
    }

    @MainActor @Test func badgeTextSaysHowMuchWasSaved() {
        #expect(SavingsBadge.text(before: 1000, after: 330) == "\u{2212}67%")
        #expect(SavingsBadge.text(before: 1000, after: 1000) == "No change")
        #expect(SavingsBadge.text(before: 1000, after: 1200) == "No change")
        #expect(SavingsBadge.text(before: 0, after: 0) == nil)
    }
}
