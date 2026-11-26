import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import Testing

@testable import Convert

/// The numbers the Overview's charts draw, from made-up summaries and finished jobs.
@Suite struct OverviewChartsTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private static func outcome(before: Int64, after: Int64) -> JobOutcome {
        JobOutcome(
            output: URL(filePath: "/tmp/out.mov"), bytesBefore: before, bytesAfter: after, report: MetadataReport(),
            replacedOriginal: false)
    }

    private static func bucket(_ id: String, couldFree: Int64) -> SavingsBucket {
        SavingsBucket(
            id: id, quality: .uhd(.fps30), year: 2026, library: .photos, excludesShrunk: false, count: 1,
            bytes: couldFree * 2, couldFree: couldFree, itemIDs: [])
    }

    @Test func sizesPairNowWithAfterForEachLibraryThatHasVideos() {
        let empty = OverviewCharts(
            summary: OverviewSummary(photos: [], files: [], preset: .balanced), buckets: [], finished: [],
            calendar: Self.calendar)
        #expect(empty.sizes.isEmpty)
        #expect(!empty.hasSizes)
        #expect(!empty.hasHistory)
        #expect(empty.groups.isEmpty)

        let file = LibraryItem(
            id: UUID(), url: URL(filePath: "/Videos/a.mov"), byteSize: 5_000_000, duration: 10,
            pixelSize: CGSize(width: 1280, height: 720), frameRate: 30, captureDate: nil, badges: [],
            isAvailable: true, inventory: MetadataInventory())
        let charts = OverviewCharts(
            summary: OverviewSummary(photos: [], files: [file], preset: .balanced), buckets: [], finished: [],
            calendar: Self.calendar)
        #expect(charts.sizes.map(\.library) == ["Local Files"])
        #expect(charts.sizes[0].now == 5_000_000)
        #expect(charts.sizes[0].after <= charts.sizes[0].now)
        #expect(charts.hasSizes)
    }

    @Test func groupsAreTheBiggestSavingsFirstAndCapped() {
        let buckets =
            (1...8).map { Self.bucket("B\($0)", couldFree: Int64($0) * 1_000) } + [
                Self.bucket("none", couldFree: 0)
            ]
        let charts = OverviewCharts(
            summary: OverviewSummary(photos: [], files: [], preset: .balanced), buckets: buckets, finished: [],
            calendar: Self.calendar)
        #expect(charts.groups.count == OverviewCharts.listedGroups)
        #expect(charts.groups.map(\.bytes) == [8_000, 7_000, 6_000, 5_000, 4_000])
        #expect(!charts.groups.contains { $0.id == "none" })
    }

    @Test func finishedJobsAreGroupedByDayAndSavedBytesAccumulate() {
        let finished: [(addedOn: Date, outcome: JobOutcome)] = [
            (Self.date(3, hour: 9), Self.outcome(before: 1_000, after: 400)),
            (Self.date(3, hour: 20), Self.outcome(before: 500, after: 300)),
            (Self.date(1), Self.outcome(before: 2_000, after: 1_000)),
            // Bigger after than before saves nothing; it never subtracts.
            (Self.date(5), Self.outcome(before: 100, after: 150)),
        ]
        let charts = OverviewCharts(
            summary: OverviewSummary(photos: [], files: [], preset: .balanced), buckets: [], finished: finished,
            calendar: Self.calendar)
        #expect(charts.throughput.map(\.videos) == [1, 2, 1])
        #expect(charts.throughput.map(\.savedBytes) == [1_000, 800, 0])
        #expect(charts.savedOverTime.map(\.cumulativeBytes) == [1_000, 1_800, 1_800])
        #expect(charts.throughput.map(\.day) == charts.savedOverTime.map(\.day))
        #expect(charts.hasHistory)
    }
}
