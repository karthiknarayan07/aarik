import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import Testing

@testable import Convert
@testable import ConvertUI

/// The chips, tile badge, predicted-savings gauge and storage bar, on made-up videos.
@Suite struct LibraryInsightTests {
    private static func inventory(
        width: Int, height: Int, fps: Double, seconds: Double, location: Bool = false
    ) -> MetadataInventory {
        func item(_ key: String, _ category: MetadataCategory, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: category, displayName: key, value: value)
        }
        var items = [
            item("video.dimensions", .video, "\(width)x\(height)"), item("video.frameRate", .video, String(fps)),
            item("video.duration", .video, String(seconds * 1000)),
        ]
        if location { items.append(item("qt.location", .location, "1,2")) }
        return MetadataInventory(items: items)
    }

    private static func video(
        megabytes: Int64, width: Int = 3840, height: Int = 2160, fps: Double = 60, seconds: Double = 10,
        badges: Set<MediaBadge> = [], location: Bool = false, available: Bool = true
    ) -> VideoItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: "/Videos/\(UUID().uuidString).mov"), byteSize: megabytes * 1_000_000,
            duration: seconds, pixelSize: CGSize(width: width, height: height), frameRate: fps, captureDate: nil,
            badges: badges, isAvailable: available,
            inventory: inventory(width: width, height: height, fps: fps, seconds: seconds, location: location))
    }

    @Test func chipsListQualityThenFeaturesThenLocation() {
        let item = Self.video(megabytes: 500, badges: [.dolbyVision, .hdr, .k4], location: true)
        #expect(LibraryInsight.chips(for: item).map(\.title) == ["4K60", "Dolby Vision", "HDR", "Location"])
        #expect(
            LibraryInsight.chips(for: Self.video(megabytes: 50, width: 1920, height: 1080, fps: 30)).map(\.title) == [
                "1080p30"
            ])
    }

    @Test func aTileGetsABadgeOnlyWhenConvertingWouldShrinkIt() {
        let big = Self.video(megabytes: 800)
        let badge = LibraryInsight.savingsBadge(for: big, preset: .balanced)
        #expect(badge?.hasPrefix("\u{2212}") == true)
        let tiny = Self.video(megabytes: 1, width: 1280, height: 720, fps: 30, seconds: 2)
        #expect(LibraryInsight.savingsBadge(for: tiny, preset: .balanced) == nil)
        #expect(
            LibraryInsight.savingsBadge(for: Self.video(megabytes: 800, available: false), preset: .balanced) == nil)
    }

    @Test func predictionSumsWhatChangesAndCountsWhatStays() throws {
        let big = Self.video(megabytes: 800)
        let tiny = Self.video(megabytes: 1, width: 1280, height: 720, fps: 30, seconds: 2)
        let prediction = try #require(LibraryInsight.prediction(for: [big, tiny], preset: { _ in .balanced }))
        #expect(prediction.count == 2)
        #expect(prediction.keptCount == 1)
        #expect(prediction.before == 801_000_000)
        #expect(prediction.after < prediction.before)
        #expect(prediction.fraction > 0 && prediction.fraction < 1)
        #expect(
            LibraryInsight.prediction(for: [Self.video(megabytes: 5, available: false)], preset: { _ in .balanced })
                == nil)
    }

    @Test func theStorageBarSplitsWhatCouldBeFreedByQualityAndKeepsTheSmallOnesApart() {
        let items = [
            Self.video(megabytes: 800, badges: [.hdr]), Self.video(megabytes: 600),
            Self.video(megabytes: 300, width: 1920, height: 1080, fps: 30, seconds: 40),
            Self.video(megabytes: 1, width: 1280, height: 720, fps: 30, seconds: 2),
            Self.video(megabytes: 900, available: false),
        ]
        let breakdown = StorageBreakdown.make(items: items, preset: { _ in .balanced })
        func segment(_ category: StorageCategory) -> StorageBreakdown.Segment? {
            breakdown.segments.first { $0.category == category }
        }
        #expect(segment(.hdr4K)?.count == 1)
        #expect(segment(.sdr4K)?.count == 1)
        #expect(segment(.alreadySmall)?.bytes == 1_000_000)
        #expect(segment(.alreadySmall)?.count == 1)
        #expect(
            breakdown.couldFree == breakdown.visible.filter { $0.category != .alreadySmall }.reduce(0) { $0 + $1.bytes }
        )
        #expect(breakdown.total == breakdown.couldFree + 1_000_000, "the missing video is left out")
        #expect(!breakdown.isEmpty)
        #expect(breakdown.spoken.contains("4K HDR"))
    }

    @Test func anEmptyLibraryHasAnEmptyBar() async {
        #expect(StorageBreakdown.make(items: [], preset: { _ in .balanced }).isEmpty)
        let breakdown = await StorageBreakdown.make(pairs: [(Self.video(megabytes: 800), Preset.balanced)])
        #expect(breakdown.couldFree > 0)
    }
}
