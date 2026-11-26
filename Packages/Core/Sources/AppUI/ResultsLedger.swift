import AppCore
import SwiftUI

/// One day of a results list: its title and what its rows saved.
public struct LedgerDay<Row> {
    public let day: Date
    public let title: String
    public let rows: [Row]
    /// Bytes the day's rows freed.
    public let savedBytes: Int64
}

extension LedgerDay: Sendable where Row: Sendable {}

/// Groups finished rows by day, newest day first and rows in the order given, as a Screen Time summary does.
public enum ResultsLedger {
    /// `date` is when a row happened and `saved` what it freed (0 for a row that freed nothing).
    public static func days<Row>(
        _ rows: [Row], date: (Row) -> Date, saved: (Row) -> Int64, now: Date = AppClock.now,
        calendar: Calendar = .current
    ) -> [LedgerDay<Row>] {
        var order: [Date] = []
        var byDay: [Date: [Row]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: date(row))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row)
        }
        return order.sorted(by: >).map { day in
            let members = byDay[day] ?? []
            return LedgerDay(
                day: day, title: title(for: day, now: now, calendar: calendar), rows: members,
                savedBytes: members.reduce(0) { $0 + saved($1) })
        }
    }

    /// What each of the last `count` days saved, oldest first, with a zero for a day with no rows: the bars of a
    /// week chart.
    public static func lastDays<Row>(
        _ days: [LedgerDay<Row>], count: Int = 7, now: Date = AppClock.now, calendar: Calendar = .current
    ) -> [(day: Date, savedBytes: Int64)] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, days.first { calendar.isDate($0.day, inSameDayAs: day) }?.savedBytes ?? 0)
        }
    }

    /// "Today", "Yesterday", or "Monday, 24 Nov".
    public static func title(for day: Date, now: Date = AppClock.now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).month(.abbreviated)
            .day()
        style.locale = calendar.locale ?? .current
        return day.formatted(style)
    }
}

/// How much a conversion saved, as a capsule: green "−67%". It reads "No change" when nothing was saved.
public struct SavingsBadge: View {
    let before: Int64
    let after: Int64

    public init(before: Int64, after: Int64) {
        self.before = before
        self.after = after
    }

    /// "−67%"; "No change" when nothing was freed; nil when there is nothing to compare.
    public static func text(before: Int64, after: Int64) -> String? {
        guard before > 0 else { return nil }
        guard after < before else { return "No change" }
        return ByteFormat.savedPercent(before: before, after: after)
    }

    public var body: some View {
        if let text = Self.text(before: before, after: after) {
            let saved = after < before
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(saved ? Color.green : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background((saved ? Color.green : Color.secondary).opacity(0.15), in: .capsule)
                .accessibilityLabel(saved ? "Saved \(text.dropFirst())" : text)
        }
    }
}
