import Foundation

public enum Grouping: String, Sendable, CaseIterable { case year, month, none }
public enum Sort: String, Sendable, CaseIterable { case biggestFirst, newestFirst }

/// A titled run of items, for example everything captured in one month.
public struct ItemGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [LibraryItem]
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }
}

/// Filters, sorts and groups items. Groups run newest first (undated last); `sort` orders the items inside them.
enum LibraryGrouper {
    static let unknownTitle = "Unknown date"

    static func groups(
        _ items: [LibraryItem], by grouping: Grouping, sort: Sort, filter: MediaBadge?,
        calendar: Calendar = .current
    ) -> [ItemGroup] {
        let kept = items.filter { filter == nil || $0.badges.contains(filter!) }.sorted { lhs, rhs in
            switch sort {
            case .biggestFirst:
                if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            case .newestFirst:
                if lhs.captureDate != rhs.captureDate {
                    return (lhs.captureDate ?? .distantPast) > (rhs.captureDate ?? .distantPast)
                }
            }
            return lhs.url.path < rhs.url.path
        }
        if kept.isEmpty { return [] }
        if grouping == .none { return [ItemGroup(id: "all", title: "All videos", items: kept)] }
        // One style for the whole pass; Foundation caches the formatter behind it.
        let monthStyle = Date.FormatStyle(
            locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: calendar.timeZone
        ).month(.wide).year()

        var buckets: [String: [LibraryItem]] = [:]
        var order: [String] = []
        for item in kept {
            let key = key(for: item.captureDate, grouping: grouping, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        // Keys are fixed-width (`2025-03`, `2025`) so a string sort is a date sort; "unknown" goes last.
        return order.sorted { lhs, rhs in
            if lhs == "unknown" { return false }
            if rhs == "unknown" { return true }
            return lhs > rhs
        }.map { key in
            ItemGroup(
                id: key, title: title(for: key, grouping: grouping, calendar: calendar, style: monthStyle),
                items: buckets[key] ?? [])
        }
    }

    private static func key(for date: Date?, grouping: Grouping, calendar: Calendar) -> String {
        guard let date else { return "unknown" }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 0
        return grouping == .year ? String(format: "%04d", year) : String(format: "%04d-%02d", year, parts.month ?? 0)
    }

    private static func title(
        for key: String, grouping: Grouping, calendar: Calendar, style: Date.FormatStyle
    ) -> String {
        if key == "unknown" { return unknownTitle }
        if grouping == .year { return key }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return key }
        return date.formatted(style)
    }
}
