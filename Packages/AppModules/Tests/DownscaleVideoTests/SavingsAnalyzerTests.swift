import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import Testing

@testable import DownscaleVideo

/// Groups of videos by quality, year and library, on made-up videos (no files, no Photos).
@Suite struct SavingsAnalyzerTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int = 6) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)) ?? .distantPast
    }

    private static func inventory(width: Int, height: Int, fps: Double, seconds: Double) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(items: [
            item("video.dimensions", "\(width)x\(height)"), item("video.frameRate", String(fps)),
            item("video.duration", String(seconds * 1000)),
        ])
    }

    private static func file(
        megabytes: Int64, year: Int? = 2024, fps: Double = 30, width: Int = 3840, height: Int = 2160,
        available: Bool = true
    ) -> LibraryItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: "/Videos/\(UUID().uuidString).mov"), byteSize: megabytes * 1_000_000,
            duration: 10, pixelSize: CGSize(width: width, height: height), frameRate: fps,
            captureDate: year.map { date($0) }, badges: [], isAvailable: available,
            inventory: inventory(width: width, height: height, fps: fps, seconds: 10))
    }

    private static func photo(megabytes: Int64, year: Int? = 2024, fps: Double = 30) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(UUID().uuidString), name: "IMG.MOV", byteSize: megabytes * 1_000_000,
            duration: 10, pixelSize: CGSize(width: 3840, height: 2160), frameRate: fps,
            captureDate: year.map { date($0) }, badges: [], isAvailable: true, inventory: MetadataInventory())
    }

    private static func buckets(
        photos: [LibraryItem] = [], files: [LibraryItem] = [], preset: Preset = .balanced,
        shrunk: Set<UUID> = []
    ) -> [SavingsBucket] {
        SavingsAnalyzer.buckets(
            photos: photos, files: files, preset: preset, shrunk: shrunk, calendar: calendar)
    }

    @Test func videosGroupByQualityYearAndLibrary() {
        let photos = [
            Self.photo(megabytes: 500, year: 2024), Self.photo(megabytes: 700, year: 2024),
            Self.photo(megabytes: 600, year: 2023), Self.photo(megabytes: 600, year: 2024, fps: 60),
        ]
        let files = [Self.file(megabytes: 400, year: 2024)]

        let buckets = Self.buckets(photos: photos, files: files)

        #expect(buckets.count == 4)
        let main = buckets.first { $0.library == .photos && $0.year == 2024 && $0.quality.title == "4K30" }
        #expect(main?.count == 2)
        #expect(main?.bytes == 1_200_000_000)
        #expect(main?.itemIDs.count == 2)
        #expect(buckets.contains { $0.library == .localFiles && $0.year == 2024 && $0.count == 1 })
        #expect(buckets.contains { $0.year == 2023 && $0.library == .photos })
        #expect(buckets.contains { $0.quality.title == "4K60" })
    }

    @Test func savingsAreTheOverviewsOwnEstimate() {
        let photos = [Self.photo(megabytes: 500), Self.photo(megabytes: 900, year: 2022)]
        let files = [Self.file(megabytes: 800), Self.file(megabytes: 300, year: 2021)]

        let buckets = Self.buckets(photos: photos, files: files)
        let summary = OverviewSummary(photos: photos, files: files, preset: .balanced)

        #expect(buckets.reduce(0) { $0 + $1.couldFree } == summary.totalCouldFree)
        #expect(summary.totalCouldFree > 0)
        // Another preset changes the estimate the same way for both.
        let smaller = SavingsAnalyzer.buckets(photos: photos, files: files, preset: .smaller, calendar: Self.calendar)
        let smallerSummary = OverviewSummary(photos: photos, files: files, preset: .smaller)
        #expect(smaller.reduce(0) { $0 + $1.couldFree } == smallerSummary.totalCouldFree)
    }

    @Test func theBiggestSavingFirstWithRankIDsAndAStableOrder() {
        let photos = [
            Self.photo(megabytes: 300, year: 2020), Self.photo(megabytes: 2000, year: 2022),
            Self.photo(megabytes: 900, year: 2021),
        ]

        let first = Self.buckets(photos: photos)
        let second = Self.buckets(photos: photos.reversed())

        #expect(first.map(\.year) == [2022, 2021, 2020])
        #expect(first.map(\.id) == ["B1", "B2", "B3"])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.year) == second.map(\.year))
        #expect(zip(first, first.dropFirst()).allSatisfy { $0.couldFree >= $1.couldFree })
    }

    @Test func shrunkLocalVideosUndatedOnesAndNothingToFreeAreLeftOut() {
        let shrunk = Self.file(megabytes: 900)
        let kept = Self.file(megabytes: 500)
        let undated = Self.file(megabytes: 900, year: nil)
        let alreadySmall = Self.file(megabytes: 4, year: 2020, fps: 30, width: 1280, height: 720)
        let missing = Self.file(megabytes: 900, year: 2019, available: false)
        // A Photos video with the same id as a shrunk file is not affected: shrunk applies to Local Files.
        let photo = Self.photo(megabytes: 400)

        let buckets = Self.buckets(
            photos: [photo], files: [shrunk, kept, undated, alreadySmall, missing], shrunk: [shrunk.id])

        let local = buckets.filter { $0.library == .localFiles }
        #expect(local.count == 1)
        #expect(local.first?.count == 1)
        #expect(local.first?.itemIDs == [kept.id])
        #expect(local.first?.excludesShrunk == true)
        #expect(buckets.first { $0.library == .photos }?.excludesShrunk == false)
        // 720p has nothing to free; the unavailable video frees nothing.
        #expect(!buckets.contains { $0.year == 2020 || $0.year == 2019 })
    }

    @Test func presetOverridesChangeAVideosEstimate() {
        let item = Self.file(megabytes: 900)
        var overrides = PresetOverrides<UUID>()
        overrides.set(.smaller, for: [item.id], default: .balanced)

        let base = Self.buckets(files: [item])
        let overridden = SavingsAnalyzer.buckets(
            photos: [], files: [item], preset: .balanced, overrides: overrides, calendar: Self.calendar)

        #expect(base.first?.couldFree == OverviewSummary.couldFree(item, preset: .balanced, custom: nil))
        #expect(overridden.first?.couldFree == OverviewSummary.couldFree(item, preset: .smaller, custom: nil))
    }

    @Test func titleAndDetailNameOnlyAggregates() {
        let bucket = Self.buckets(photos: [Self.photo(megabytes: 800)]).first
        #expect(bucket?.title == "4K30 from 2024")
        #expect(bucket?.detail.hasPrefix("Photos · 1 video · 800 MB · could free about") == true)
    }

    @Test func aBucketsIdentityNamesItsGroupNotItsRank() {
        let photos = [Self.photo(megabytes: 900, year: 2022), Self.photo(megabytes: 300, year: 2021)]
        let first = Self.buckets(photos: photos)
        // A bigger group arrives and takes rank 1: the others keep their identity but not their id.
        let more = Self.buckets(photos: photos + [Self.photo(megabytes: 4000, year: 2020)])
        #expect(first.map(\.identity) == ["photos-2022-4K30", "photos-2021-4K30"])
        #expect(more.map(\.identity).dropFirst() == first.map(\.identity)[...])
        #expect(first.first?.id == "B1" && more.first(where: { $0.year == 2022 })?.id == "B2")
    }

    @Test func undatedVideosThatCouldFreeSomethingAreCountedSeparately() {
        let undated = Self.file(megabytes: 900, year: nil)
        let shrunk = Self.file(megabytes: 900, year: nil)
        let small = Self.file(megabytes: 4, year: nil, width: 1280, height: 720)
        let missing = Self.file(megabytes: 900, year: nil, available: false)
        let dated = Self.file(megabytes: 900)

        let count = SavingsAnalyzer.undatedCount(
            photos: [Self.photo(megabytes: 500, year: nil)], files: [undated, shrunk, small, missing, dated],
            preset: .balanced, shrunk: [shrunk.id])

        // The Photos video and the one undated file: not the shrunk, the small, the missing or the dated one.
        #expect(count == 2)
    }
}
