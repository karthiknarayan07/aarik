import AppCore
import Foundation

/// The numbers behind the Overview, made once from the summary, the savings groups and the finished jobs as a
/// `SavingsSnapshot` (what the cache keeps), and read back from one for drawing. Nothing here reads a file or estimates
/// a video.
public struct OverviewCharts: Sendable, Equatable {
    /// One library's size before converting and what it would be after.
    public struct SizePair: Sendable, Equatable, Identifiable {
        public let library: String
        public let now: Int64
        public let after: Int64
        public var id: String { library }
    }

    /// What converting one group of videos would free.
    public struct GroupSaving: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let bytes: Int64
    }

    /// The space saved by everything converted up to the end of a day.
    public struct SavedPoint: Sendable, Equatable, Identifiable {
        public let day: Date
        public let cumulativeBytes: Int64
        public var id: Date { day }
    }

    /// Videos converted that day, and what they freed.
    public struct DayThroughput: Sendable, Equatable, Identifiable {
        public let day: Date
        public let videos: Int
        public let savedBytes: Int64
        public var id: Date { day }
    }

    /// How many groups the savings chart lists.
    public static let listedGroups = 5

    public let sizes: [SizePair]
    public let groups: [GroupSaving]
    public let savedOverTime: [SavedPoint]
    public let throughput: [DayThroughput]
    public let couldFree: Int64
    public let totalBytes: Int64
    public let savedBytes: Int64
    public let conversions: Int
    /// When the numbers were made.
    public let updatedAt: Date

    public var hasSizes: Bool { sizes.contains { $0.now > 0 } }
    public var hasHistory: Bool { !throughput.isEmpty }

    /// What the conversions of the calendar month holding `now` freed.
    public func savedThisMonth(calendar: Calendar = .current, now: Date = AppClock.now) -> Int64 {
        throughput.filter { calendar.isDate($0.day, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.savedBytes }
    }

    /// The share of the library that would be left after converting, 0 to 1.
    public var afterFraction: Double {
        totalBytes > 0 ? Double(max(0, totalBytes - couldFree)) / Double(totalBytes) : 1
    }

    /// What `couldFree` would be as a share of the library, 0 to 1.
    public var freeFraction: Double { 1 - afterFraction }

    public init(snapshot: SavingsSnapshot) {
        sizes = snapshot.libraries.map {
            SizePair(library: $0.name, now: $0.bytes, after: max(0, $0.bytes - $0.couldFree))
        }
        groups = snapshot.groups.map { GroupSaving(id: $0.id, title: $0.title, bytes: $0.bytes) }
        throughput = snapshot.days.sorted { $0.day < $1.day }.map {
            DayThroughput(day: $0.day, videos: $0.videos, savedBytes: $0.savedBytes)
        }
        var total: Int64 = 0
        savedOverTime = throughput.map { day in
            total += day.savedBytes
            return SavedPoint(day: day.day, cumulativeBytes: total)
        }
        couldFree = snapshot.couldFree
        totalBytes = snapshot.totalBytes
        savedBytes = snapshot.savedBytes
        conversions = snapshot.conversions
        updatedAt = snapshot.updatedAt
    }

    /// `finished` are the jobs that completed, with the day each was added (the queue doesn't record when a job
    /// ended); days follow `calendar`.
    public init(
        summary: OverviewSummary, buckets: [SavingsBucket], finished: [(addedOn: Date, outcome: JobOutcome)],
        calendar: Calendar = .current
    ) {
        self.init(
            snapshot: Self.snapshot(summary: summary, buckets: buckets, finished: finished, calendar: calendar))
    }

    public static func snapshot(
        summary: OverviewSummary, buckets: [SavingsBucket], finished: [(addedOn: Date, outcome: JobOutcome)],
        calendar: Calendar = .current, now: Date = AppClock.now
    ) -> SavingsSnapshot {
        var libraries: [SavingsSnapshot.Library] = []
        if summary.videos.count > 0 {
            libraries.append(
                .init(
                    name: "Videos in Photos", count: summary.videos.count, bytes: summary.videos.bytes,
                    couldFree: summary.videos.couldFree))
        }
        if summary.localFiles.count > 0 {
            libraries.append(
                .init(
                    name: "Local Files", count: summary.localFiles.count, bytes: summary.localFiles.bytes,
                    couldFree: summary.localFiles.couldFree))
        }
        let groups = buckets.filter { $0.couldFree > 0 }
            .sorted { $0.couldFree > $1.couldFree }
            .prefix(listedGroups)
            .map { SavingsSnapshot.Group(id: $0.id, title: $0.title, bytes: $0.couldFree) }

        var perDay: [Date: (videos: Int, saved: Int64)] = [:]
        for entry in finished {
            let day = calendar.startOfDay(for: entry.addedOn)
            perDay[day, default: (0, 0)].videos += 1
            perDay[day, default: (0, 0)].saved += max(0, entry.outcome.bytesBefore - entry.outcome.bytesAfter)
        }
        let days = perDay.keys.sorted().map {
            SavingsSnapshot.Day(day: $0, videos: perDay[$0]!.videos, savedBytes: perDay[$0]!.saved)
        }
        return SavingsSnapshot(
            updatedAt: now, libraries: libraries, groups: Array(groups), days: days, savedBytes: summary.savedBytes,
            conversions: finished.count)
    }
}
