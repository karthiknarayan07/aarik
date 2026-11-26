import AppCore
import CoreGraphics
import Foundation
import LocalLibrary
import MediaEngine
import PhotosLibrary
import Testing

@testable import Convert
@testable import ConvertUI

/// The queue's time left and before → after sizes, on made-up jobs (no files, no Photos).
@Suite struct QueueTimingTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func job(_ progress: Double?, id: UUID = UUID()) -> Job {
        Job(
            id: id, toolID: ConvertTool.toolID, source: URL(filePath: "/Videos/a.mov"), sourceBookmark: Data(),
            settings: (try? JSONEncoder().encode(ConvertJobSettings(saveTo: .nextToOriginal))) ?? Data(),
            state: progress.map { .running(progress: $0) } ?? .queued)
    }

    @Test func noEstimateUntilThereIsEnoughHistory() {
        let id = UUID()
        var timeline = ProgressTimeline()
        timeline.observe([Self.job(0.1, id: id)], now: Self.start)
        #expect(timeline.remaining(for: id) == nil)
        timeline.observe([Self.job(0.11, id: id)], now: Self.start.addingTimeInterval(5))
        #expect(timeline.remaining(for: id) == nil, "1% in 5 s is too little to trust")
        timeline.observe([Self.job(0.5, id: id)], now: Self.start.addingTimeInterval(1))
        #expect(timeline.remaining(for: id) == nil, "under the minimum elapsed time")
    }

    @Test func remainingFollowsThePaceSeen() throws {
        let id = UUID()
        var timeline = ProgressTimeline()
        timeline.observe([Self.job(0.0, id: id)], now: Self.start)
        timeline.observe([Self.job(0.25, id: id)], now: Self.start.addingTimeInterval(10))
        #expect(timeline.fullDuration(for: id) == 40)
        #expect(try #require(timeline.remaining(for: id)) == 30)
    }

    @Test func aJobThatStoppedRunningIsForgottenAndABackwardStepStartsOver() {
        let id = UUID()
        var timeline = ProgressTimeline()
        timeline.observe([Self.job(0.0, id: id)], now: Self.start)
        timeline.observe([Self.job(0.5, id: id)], now: Self.start.addingTimeInterval(10))
        #expect(timeline.remaining(for: id) != nil)
        // A new phase counts from 0 again.
        timeline.observe([Self.job(0.01, id: id)], now: Self.start.addingTimeInterval(11))
        #expect(timeline.remaining(for: id) == nil)
        timeline.observe([Self.job(nil, id: id)], now: Self.start.addingTimeInterval(12))
        #expect(timeline.fullDuration(for: id) == nil)
    }

    @Test func totalTimeAddsTheWaitingVideosAtTheRunningPace() throws {
        let id = UUID()
        var timeline = ProgressTimeline()
        let running = Self.job(0.5, id: id)
        timeline.observe([Self.job(0.0, id: id)], now: Self.start)
        timeline.observe([running], now: Self.start.addingTimeInterval(20))
        // Whole run 40 s: 20 s left, plus two waiting at 40 s each.
        #expect(try #require(timeline.totalRemaining(running: [running], waitingCount: 2)) == 100)
        #expect(ProgressTimeline().totalRemaining(running: [running], waitingCount: 2) == nil)
    }

    @Test func timeLeftIsWordedInMinutesAndHours() {
        #expect(TimeLeftText.string(20) == "Less than a minute")
        #expect(TimeLeftText.string(61) == "About 2 min")
        #expect(TimeLeftText.string(300) == "About 5 min")
        #expect(TimeLeftText.string(3600) == "About 1 hr")
        #expect(TimeLeftText.string(4800) == "About 1 hr 20 min")
    }

    private static func inventory() -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(items: [
            item("video.dimensions", "3840x2160"), item("video.frameRate", "30"), item("video.duration", "10000"),
        ])
    }

    @Test func sizesComeFromTheItemTheJobWasAddedFrom() throws {
        let item = LibraryItem(
            id: UUID(), url: URL(filePath: "/Videos/a.mov"), byteSize: 400_000_000, duration: 10,
            pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30, captureDate: nil, badges: [],
            isAvailable: true, inventory: Self.inventory())
        let sizes = try #require(QueueSizes.sizes(for: Self.job(nil), in: [item]))
        #expect(sizes.before == 400_000_000)
        #expect(try #require(sizes.after) < 400_000_000)
        #expect(sizes.text.contains("→ about"))
        #expect(QueueSizes.sizes(for: Self.job(nil), in: []) == nil)
    }

    @Test func aPhotosJobFindsItsItemByIdentifier() throws {
        let item = LibraryItem(
            id: UUID(), source: .photos("ABC/L0/001"), name: "IMG.MOV", byteSize: 100, duration: 10,
            pixelSize: CGSize(width: 3840, height: 2160), frameRate: 30, captureDate: nil, badges: [],
            isAvailable: true, inventory: MetadataInventory())
        var job = Self.job(nil)
        job.source = PhotoAssetURL.url(for: "ABC/L0/001")
        let sizes = try #require(QueueSizes.sizes(for: job, in: [item]))
        #expect(sizes.before == 100)
        #expect(sizes.after == nil)
        #expect(sizes.text == ByteFormatForTests.string(100))
    }
}

private enum ByteFormatForTests {
    static func string(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}
