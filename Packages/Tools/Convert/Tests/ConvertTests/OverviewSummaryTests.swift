import AarikCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import PhotosLibrary
import Testing

@testable import Convert

/// The Overview's totals and "could free" at the current preset, on made-up videos (no files, no Photos).
@Suite struct OverviewSummaryTests {
    private static func inventory(width: Int, height: Int, fps: Double = 30, seconds: Double) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(items: [
            item("video.dimensions", "\(width)x\(height)"), item("video.frameRate", String(fps)),
            item("video.duration", String(seconds * 1000)),
        ])
    }

    private static func file(
        _ name: String, megabytes: Int64, width: Int = 3840, height: Int = 2160, available: Bool = true
    ) -> LibraryItem {
        LibraryItem(
            id: UUID(), url: URL(filePath: "/Videos/\(name)"), byteSize: megabytes * 1_000_000, duration: 10,
            pixelSize: CGSize(width: width, height: height), frameRate: 30, captureDate: nil, badges: [],
            isAvailable: available, inventory: inventory(width: width, height: height, seconds: 10))
    }

    private static func photo(
        _ name: String, megabytes: Int64, width: Double = 3840, height: Double = 2160, badges: Set<MediaBadge> = []
    ) -> LibraryItem {
        // What Photos gives: sizes and a frame rate, no inventory.
        LibraryItem(
            id: UUID(), source: .photos("\(name)/L0/001"), name: name, byteSize: megabytes * 1_000_000, duration: 10,
            pixelSize: CGSize(width: width, height: height), frameRate: 30, captureDate: nil, badges: badges,
            isAvailable: true, inventory: MetadataInventory())
    }

    @Test func aPhotosVideoIsEstimatedLikeTheSameFileWithAFullInventory() {
        let fromPhotos = Self.photo("a", megabytes: 500)
        let fromFile = Self.file("a", megabytes: 500)

        let photos = OverviewSummary(photos: [fromPhotos], files: [], preset: .balanced)
        let files = OverviewSummary(photos: [], files: [fromFile], preset: .balanced)

        #expect(photos.videos.couldFree > 0)
        #expect(photos.videos.couldFree == files.localFiles.couldFree)
        #expect(
            files.localFiles.couldFree
                == SavingsCalculator.couldFreeBytes(
                    for: [(byteSize: fromFile.byteSize, inventory: fromFile.inventory)], preset: .balanced))
    }

    @Test func totalsCountEveryVideoAndFreeOnlyWhatIsAvailableAndWorthConverting() {
        let big = Self.file("big.mov", megabytes: 800)
        let small = Self.file("small.mov", megabytes: 4, width: 1280, height: 720)  // already small
        let missing = Self.file("gone.mov", megabytes: 900, available: false)
        let photo = Self.photo("p.mov", megabytes: 400)

        let summary = OverviewSummary(photos: [photo], files: [big, small, missing], preset: .balanced)

        #expect(summary.videos.count == 1)
        #expect(summary.videos.bytes == 400_000_000)
        #expect(summary.localFiles.count == 3)
        #expect(summary.localFiles.bytes == 1_704_000_000)
        #expect(summary.localFiles.couldFree == OverviewSummary.couldFree(big, preset: .balanced, custom: nil))
        #expect(summary.localFiles.couldFree > 0)
        #expect(summary.totalCouldFree == summary.videos.couldFree + summary.localFiles.couldFree)
        // Neither the small video nor the missing one is worth listing.
        #expect(summary.biggest.count == 2)
    }

    @Test func theBiggestSavingsComeFirstFromBothLibrariesAndStopAtTen() {
        let files = (1...8).map { Self.file("f\($0).mov", megabytes: Int64($0) * 100) }
        let photos = (1...8).map { Self.photo("p\($0).mov", megabytes: Int64($0) * 100 + 50) }

        let summary = OverviewSummary(photos: photos, files: files, preset: .balanced)

        #expect(summary.biggest.count == 10)
        let saved = summary.biggest.map(\.couldFree)
        #expect(saved == saved.sorted(by: >))
        #expect(summary.biggest.first?.name == "p8.mov")
        #expect(summary.biggest.first?.library == .photos)
        #expect(summary.biggest.map(\.library).contains(.localFiles))
        #expect(Set(summary.biggest.map(\.id)).count == 10)
    }

    @Test func aPresetChosenForOneVideoChangesOnlyItsEstimate() {
        let first = Self.file("a.mov", megabytes: 500)
        let second = Self.file("b.mov", megabytes: 500)
        let plain = OverviewSummary(photos: [], files: [first, second], preset: .balanced)
        var overrides = PresetOverrides<UUID>()
        overrides.set(.smaller, for: [first.id], default: .balanced)

        let chosen = OverviewSummary(photos: [], files: [first, second], preset: .balanced, overrides: overrides)

        #expect(chosen.localFiles.couldFree > plain.localFiles.couldFree)
        let secondSaving = OverviewSummary.couldFree(second, preset: .balanced, custom: nil)
        #expect(chosen.biggest.first { $0.id == second.id }?.couldFree == secondSaving)
    }

    @Test func spatialPhotosVideosAreLeftOut() {
        let spatial = Self.photo("s.mov", megabytes: 500, badges: [.spatial])

        let summary = OverviewSummary(photos: [spatial], files: [], preset: .balanced)

        #expect(summary.videos.count == 1)
        #expect(summary.videos.couldFree == 0)
        #expect(summary.biggest.isEmpty)
    }

    @Test func savedSoFarIsTheSumOfWhatFinishedConversionsSaved() {
        func outcome(before: Int64, after: Int64) -> JobOutcome {
            JobOutcome(
                output: URL(filePath: "/out.mov"), bytesBefore: before, bytesAfter: after, report: MetadataReport(),
                replacedOriginal: false)
        }

        let summary = OverviewSummary(
            photos: [], files: [], preset: .balanced,
            completed: [
                outcome(before: 1000, after: 400), outcome(before: 500, after: 600), outcome(before: 90, after: 30),
            ])

        // A copy that came out bigger saved nothing; it never counts as negative.
        #expect(summary.savedBytes == 660)
    }

    @Test func nothingMakesAnEmptySummary() {
        let summary = OverviewSummary(photos: [], files: [], preset: .balanced)

        #expect(summary.videos == OverviewSummary.Totals())
        #expect(summary.localFiles == OverviewSummary.Totals())
        #expect(summary.biggest.isEmpty)
        #expect(summary.savedBytes == 0)
    }
}
