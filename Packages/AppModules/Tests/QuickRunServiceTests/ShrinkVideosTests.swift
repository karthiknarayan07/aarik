import AppCore
import CoreGraphics
import DownscaleVideo
import Foundation
import LocalLibrary
import MediaEngine
import PhotosLibrary
import Testing

@testable import QuickRunService

/// A library that is just a list, standing in for Local Files and for Photos.
@MainActor
private final class FakeCollection: MediaCollection {
    var items: [LibraryItem]
    var revision = 0
    var isScanning = false

    init(_ items: [LibraryItem]) { self.items = items }
}

@MainActor
private final class FakeSources: ShrinkVideosSources {
    let local: FakeCollection
    let photos: FakeCollection?
    private(set) var localReads = 0
    private(set) var photosReads = 0

    init(local: [LibraryItem] = [], photos: [LibraryItem]? = nil) {
        self.local = FakeCollection(local)
        self.photos = photos.map(FakeCollection.init)
    }

    func localLibrary() async -> any MediaCollection {
        localReads += 1
        return local
    }

    func photosLibrary() async -> (any MediaCollection)? {
        photosReads += 1
        return photos
    }
}

private enum Calendars {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

@Suite @MainActor struct ShrinkVideosTests {
    /// 25 November 2026, noon UTC.
    private nonisolated static let now = Calendars.date(2026, 11, 25)

    @MainActor private struct Harness {
        let fixture: QuickRunFixture
        let queue = FakeQueue()
        let notifier = FakeNotifier()
        let sources: FakeSources
        let shrink: ShrinkVideos
        let quickRun: QuickRun

        init(
            local: (QuickRunFixture) throws -> [LibraryItem] = { _ in [] }, photos: [LibraryItem]? = nil,
            startsQueue: Bool = true, lossy: Set<String> = []
        ) throws {
            fixture = try QuickRunFixture()
            let items = try local(fixture)
            sources = FakeSources(local: items, photos: photos)
            let clock = FakeClock()
            let store = QuickRunStore(fileURL: fixture.storeURL, now: clock.now)
            // Every file reads as a clean 4K clip, except the named ones, whose depth data would be lost.
            let sourcesByURL = Dictionary(
                uniqueKeysWithValues: items.compactMap { item in
                    item.fileURL.map {
                        ($0, lossy.contains($0.lastPathComponent) ? QuickRunFixture.lossy : QuickRunFixture.clean)
                    }
                })
            quickRun = QuickRun(
                queue: queue, store: store, notifier: notifier, inspector: FakeInspector(sources: sourcesByURL),
                settings: {
                    QuickRunSettings(preset: .balanced, saveLocation: SaveLocation(), startsQueue: startsQueue)
                },
                now: { clock.now })
            shrink = ShrinkVideos(
                sources: sources, quickRun: quickRun, now: { ShrinkVideosTests.now }, calendar: Calendars.utc)
        }
    }

    private static func fileItem(
        _ fixture: QuickRunFixture, _ name: String, size: CGSize = CGSize(width: 3840, height: 2160),
        captured: Date? = nil, available: Bool = true
    ) throws -> LibraryItem {
        LibraryItem(
            id: UUID(), url: try fixture.file(name), byteSize: QuickRunFixture.bigSize, duration: 60, pixelSize: size,
            frameRate: 30, captureDate: captured, badges: [], isAvailable: available, inventory: MetadataInventory())
    }

    private static func photoItem(
        _ id: String, captured: Date, badges: Set<MediaBadge> = [], size: CGSize = CGSize(width: 3840, height: 2160)
    ) -> LibraryItem {
        LibraryItem(
            id: UUID(), source: .photos(id), name: "\(id).MOV", byteSize: QuickRunFixture.bigSize, duration: 60,
            pixelSize: size, frameRate: 30, captureDate: captured, badges: badges, isAvailable: true,
            inventory: MetadataInventory())
    }

    private func settings(of job: Job) throws -> DownscaleJobSettings {
        try JSONDecoder().decode(DownscaleJobSettings.self, from: job.settings)
    }

    // MARK: - Parameters to overrides

    @Test func nothingGivenChangesNothing() throws {
        #expect(try ShrinkVideosRequest().overrides() == QuickRunOverrides())
    }

    @Test(arguments: [
        (ShrinkQuality.high, Preset.high), (.balanced, .balanced), (.smaller, .smaller),
    ])
    func qualityIsThePreset(quality: ShrinkQuality, preset: Preset) throws {
        #expect(try ShrinkVideosRequest(quality: quality).overrides().preset == preset)
    }

    @Test func formatIsTheCodec() throws {
        #expect(try ShrinkVideosRequest(format: .hevc).overrides().codec == .hevcKeepHDR)
        #expect(try ShrinkVideosRequest(format: .h264).overrides().codec == .h264Compatible)
        #expect(try ShrinkVideosRequest().overrides().codec == nil)
    }

    @Test func nextToOriginalOverridesASavedFolder() throws {
        let location = try ShrinkVideosRequest(destination: .nextToOriginal).overrides().saveLocation
        #expect(location?.choice == .nextToOriginal)
        #expect(location?.destination == .nextToOriginal)
    }

    @Test func folderNeedsAFolder() {
        #expect(throws: ShrinkVideosError.folderNeeded) {
            try ShrinkVideosRequest(destination: .folder).overrides()
        }
    }

    @Test func aFolderBecomesABookmarkedSaveLocation() throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let location = try #require(
            try ShrinkVideosRequest(destination: .folder, folder: fixture.directory).overrides().saveLocation)
        #expect(location.choice == .folder)
        #expect(location.folder == fixture.directory)
        guard case .folder = location.destination else {
            Issue.record("expected a folder destination")
            return
        }
    }

    @Test func aFolderThatCannotBeBookmarkedIsRefused() {
        let gone = URL(filePath: "/nonexistent-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(throws: ShrinkVideosError.folderUnavailable) {
            try ShrinkVideosRequest(destination: .folder, folder: gone).overrides()
        }
    }

    @Test func replaceIsNotAChoice() {
        #expect(ShrinkDestination.allCases == [.nextToOriginal, .folder])
    }

    // MARK: - Parameters to filters

    @Test func dateRangesCoverWhatTheirNamesSay() {
        let now = Self.now
        let calendar = Calendars.utc
        let lastMonth = ShrinkDateRange.lastMonth.range(now: now, calendar: calendar)
        #expect(lastMonth.lowerBound == Calendars.date(2026, 10, 1, 0))
        #expect(lastMonth.upperBound == Calendars.date(2026, 11, 1, 0).addingTimeInterval(-1))
        let thisYear = ShrinkDateRange.thisYear.range(now: now, calendar: calendar)
        #expect(thisYear.lowerBound == Calendars.date(2026, 1, 1, 0))
        #expect(thisYear.upperBound == Calendars.date(2027, 1, 1, 0).addingTimeInterval(-1))
        let lastYear = ShrinkDateRange.lastYear.range(now: now, calendar: calendar)
        #expect(lastYear.lowerBound == Calendars.date(2025, 1, 1, 0))
        #expect(lastYear.upperBound == Calendars.date(2026, 1, 1, 0).addingTimeInterval(-1))
        let week = ShrinkDateRange.pastWeek.range(now: now, calendar: calendar)
        #expect(week.lowerBound == Calendars.date(2026, 11, 18, 0))
        #expect(week.upperBound == now)
        let quarter = ShrinkDateRange.pastThreeMonths.range(now: now, calendar: calendar)
        #expect(quarter.lowerBound == Calendars.date(2026, 8, 25, 0))
    }

    @Test func lastMonthInJanuaryIsDecemberOfTheYearBefore() {
        let range = ShrinkDateRange.lastMonth.range(now: Calendars.date(2027, 1, 10), calendar: Calendars.utc)
        #expect(range.lowerBound == Calendars.date(2026, 12, 1, 0))
        #expect(range.upperBound == Calendars.date(2027, 1, 1, 0).addingTimeInterval(-1))
    }

    @Test func resolutionsAreEveryFrameRateOfTheResolution() {
        #expect(ShrinkResolution.uhd.buckets.count == FrameRateTier.allCases.count)
        #expect(ShrinkResolution.uhd.buckets.contains(.uhd(.fps60)))
        #expect(!ShrinkResolution.uhd.buckets.contains(.fullHD(.fps30)))
        #expect(ShrinkResolution.fullHD.buckets.contains(.fullHD(.fps24)))
    }

    @Test func selectionUsesTheGridsFiltersAndLeavesOutMissingFiles() throws {
        let harness = try Harness { fixture in
            [
                try Self.fileItem(fixture, "a.mov", captured: Calendars.date(2026, 10, 15)),
                try Self.fileItem(fixture, "b.mov", captured: Calendars.date(2026, 9, 15)),
                try Self.fileItem(
                    fixture, "c.mov", size: CGSize(width: 1920, height: 1080), captured: Calendars.date(2026, 10, 20)),
                try Self.fileItem(fixture, "d.mov", captured: Calendars.date(2026, 10, 2), available: false),
                try Self.fileItem(fixture, "e.mov", captured: nil),
            ]
        }
        defer { harness.fixture.remove() }

        let request = ShrinkVideosRequest(dateRange: .lastMonth, resolution: .uhd)
        let names = harness.shrink.select(from: harness.sources.local, request: request).map(\.name)

        #expect(names == ["a.mov"])
    }

    // MARK: - Running

    @Test func selectionByDateAndResolutionQueuesOnlyTheMatches() async throws {
        let harness = try Harness { fixture in
            [
                try Self.fileItem(fixture, "a.mov", captured: Calendars.date(2026, 10, 15)),
                try Self.fileItem(fixture, "b.mov", captured: Calendars.date(2026, 9, 15)),
            ]
        }
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(
            ShrinkVideosRequest(dateRange: .lastMonth, resolution: .uhd, waitForCompletion: false))

        guard case .queued(let receipt, _) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(outcome.outputs == nil)
        #expect(receipt.queuedJobIDs.count == 1)
        let jobs = await harness.queue.jobs
        #expect(jobs.map(\.source.lastPathComponent) == ["a.mov"])
    }

    @Test func parametersReachTheJobs() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(
            ShrinkVideosRequest(files: [url], quality: .smaller, format: .h264, waitForCompletion: false))

        #expect(outcome.message == "Queued 1 video. A notification says when they're done.")
        let job = try #require(await harness.queue.jobs.first)
        let settings = try settings(of: job)
        #expect(settings.preset == .smaller)
        #expect(settings.saveTo == .nextToOriginal)
        let custom = try #require(settings.custom)
        #expect(custom.codec == .h264Compatible)
        let balanced = Preset.smaller.spec(for: QuickRunFixture.clean.inventory, byteSize: QuickRunFixture.bigSize)
        #expect(custom.averageBitRate == Int((Double(balanced.averageBitRate) * 1.6).rounded()))
        #expect(custom.targetShortSide == balanced.targetShortSide)
    }

    @Test func hevcLeavesTheJobOnThePresetSpec() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        _ = await harness.shrink.perform(ShrinkVideosRequest(files: [url], format: .hevc, waitForCompletion: false))

        let job = try #require(await harness.queue.jobs.first)
        #expect(try settings(of: job).custom == nil)
    }

    @Test func filesWinOverTheSelection() async throws {
        var chosen: URL!
        let harness = try Harness { fixture in
            let matching = try Self.fileItem(fixture, "matching.mov", captured: Calendars.date(2026, 10, 15))
            let given = try Self.fileItem(fixture, "given.mov", captured: nil)
            chosen = given.fileURL
            return [matching, given]
        }
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(
            ShrinkVideosRequest(
                files: [chosen], dateRange: .lastMonth, resolution: .uhd, source: .photos, waitForCompletion: false))

        guard case .queued = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        // Only the file given is converted, though it matches none of the selection; no library is read.
        let jobs = await harness.queue.jobs
        #expect(jobs.map(\.source.lastPathComponent) == ["given.mov"])
        #expect(harness.sources.localReads == 0)
        #expect(harness.sources.photosReads == 0)
    }

    @Test func anEmptyMatchSaysSoAndQueuesNothing() async throws {
        let harness = try Harness { fixture in
            [try Self.fileItem(fixture, "old.mov", captured: Calendars.date(2020, 1, 1))]
        }
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(dateRange: .lastMonth))

        #expect(outcome == .nothingMatched)
        #expect(outcome.message == "No videos matched, so nothing was queued.")
        #expect(await harness.queue.jobs.isEmpty)
        #expect(await harness.notifier.notices.isEmpty)
    }

    @Test func nothingGivenAsksForVideos() async throws {
        let harness = try Harness()
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(quality: .high))

        #expect(outcome == .needsVideos)
        #expect(harness.sources.localReads == 0)
        #expect(await harness.queue.jobs.isEmpty)
    }

    @Test func aBadFolderStopsBeforeAnythingIsQueued() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(files: [url], destination: .folder))

        #expect(outcome == .failed(.folderNeeded))
        #expect(await harness.queue.jobs.isEmpty)
    }

    // MARK: - Photos

    @Test func photosWithoutAccessFailsPlainlyAndQueuesNothing() async throws {
        let harness = try Harness(photos: nil)
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(resolution: .uhd, source: .photos))

        #expect(outcome == .photosAccessNeeded)
        #expect(outcome.message.contains("Photos"))
        #expect(harness.sources.photosReads == 1)
        #expect(await harness.queue.jobs.isEmpty)
    }

    @Test func photosVideosAreQueuedAsNewVideosAndNeverReplace() async throws {
        let harness = try Harness(photos: [
            Self.photoItem("A/L0/001", captured: Calendars.date(2026, 10, 3)),
            Self.photoItem("B/L0/001", captured: Calendars.date(2026, 10, 4), badges: [.cinematic]),
            Self.photoItem("C/L0/001", captured: Calendars.date(2026, 3, 4)),
        ])
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(
            ShrinkVideosRequest(quality: .high, dateRange: .lastMonth, source: .photos, waitForCompletion: false))

        guard case .queued(let receipt, _) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        let jobs = await harness.queue.jobs
        #expect(jobs.map(\.toolID) == [DownscaleTool.photosToolID])
        #expect(jobs.compactMap { PhotoAssetURL.identifier(from: $0.source) } == ["A/L0/001"])
        let settings = try settings(of: try #require(jobs.first))
        #expect(settings.photosDestination == .newAsset)
        #expect(settings.preset == .high)
        // The Cinematic video would lose its depth data, so it is skipped with the reason.
        #expect(receipt.skipped.count == 1)
        #expect(receipt.skipped.first?.reason.contains("Cinematic") == true)
    }

    @Test func h264IsRefusedForPhotos() async throws {
        let harness = try Harness(photos: [Self.photoItem("A/L0/001", captured: Calendars.date(2026, 10, 3))])
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(format: .h264, source: .photos))

        #expect(outcome == .failed(.h264NotForPhotos))
        #expect(await harness.queue.jobs.isEmpty)
    }

    // MARK: - Waiting

    @Test func waitingReturnsTheOutputsOfTheRun() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        await harness.quickRun.start()
        let run = Task { await harness.shrink.perform(ShrinkVideosRequest(files: [url])) }
        for _ in 0..<200 where await harness.queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // Not done yet: the action is still waiting.
        await Task.yield()
        await harness.queue.completeAll()
        let outcome = await run.value

        guard case .queued = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(outcome.outputs?.map(\.lastPathComponent) == ["out.mov"])
        #expect(outcome.message == "Shrank 1 video.")
        // The run's one notification is posted by the queue watcher, a moment after the action returns.
        for _ in 0..<200 where await harness.notifier.notices.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await harness.notifier.notices.count == 1)
    }

    @Test func theAppIsToldAboutQueuedJobsBeforeTheActionWaits() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }
        var told: [QuickRunReceipt] = []

        // Nothing finishes this job until the test says so, so the action is still waiting when the app is told.
        let run = Task { @MainActor in
            await harness.shrink.perform(ShrinkVideosRequest(files: [url]), didQueue: { told.append($0) })
        }
        for _ in 0..<200 where told.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told.map(\.queuedJobIDs.count) == [1])
        await harness.queue.completeAll()
        _ = await run.value
    }

    @Test func aWaitEndsWhenTheQueueIsPausedAndNothingIsRunning() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let run = Task { await harness.shrink.perform(ShrinkVideosRequest(files: [url])) }
        for _ in 0..<200 where await harness.queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // Pausing is not a queue change; the wait notices on its next check.
        await harness.queue.setPaused(true)
        let outcome = await run.value

        guard case .queued(_, .paused) = outcome else {
            Issue.record("expected a paused wait, got \(outcome)")
            return
        }
        #expect(outcome.message == "Queued 1 video. The queue is paused, so they'll convert when you resume it.")
    }

    @Test func aPausedQueueDoesNotEndAWaitWhileTheRunsJobIsRunning() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let run = Task { await harness.shrink.perform(ShrinkVideosRequest(files: [url])) }
        for _ in 0..<200 where await harness.queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let job = try #require(await harness.queue.jobs.first)
        await harness.queue.finish(job.id, with: .running(progress: 0.5))
        await harness.queue.setPaused(true)
        try await Task.sleep(for: .milliseconds(100))
        await harness.queue.completeAll()
        let outcome = await run.value

        #expect(outcome.outputs?.count == 1)
    }

    @Test func aWaitEndsWhenTheQueueStops() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let run = Task { await harness.shrink.perform(ShrinkVideosRequest(files: [url])) }
        for _ in 0..<200 where await harness.queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await harness.queue.stop()
        let outcome = await run.value

        guard case .queued(_, .interrupted) = outcome else {
            Issue.record("expected an interrupted wait, got \(outcome)")
            return
        }
        #expect(outcome.message == "Queued 1 video. The app quit first, so they'll continue when it opens again.")
    }

    @Test func aFailedJobIsNotCountedAsShrunk() async throws {
        var url: URL!
        let harness = try Harness(local: { fixture in
            let item = try Self.fileItem(fixture, "a.mov")
            url = item.fileURL
            return [item]
        })
        defer { harness.fixture.remove() }

        let run = Task { await harness.shrink.perform(ShrinkVideosRequest(files: [url])) }
        for _ in 0..<200 where await harness.queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let job = try #require(await harness.queue.jobs.first)
        await harness.queue.finish(job.id, with: .failed(reason: "no"))
        let outcome = await run.value

        #expect(outcome.message == "Nothing was converted.")
    }

    @Test func unknownFrameRatePhotosAreMatchedByTheirSize() throws {
        let harness = try Harness()
        defer { harness.fixture.remove() }
        func item(_ id: String, _ size: CGSize, fps: Double) -> LibraryItem {
            LibraryItem(
                id: UUID(), source: .photos(id), name: id, byteSize: 1, duration: 1, pixelSize: size, frameRate: fps,
                captureDate: nil, badges: [], isAvailable: true, inventory: MetadataInventory())
        }
        let collection = FakeCollection([
            item("4k-no-index", CGSize(width: 3840, height: 2160), fps: 0),
            item("1080-no-index", CGSize(width: 1920, height: 1080), fps: 0),
            item("4k-indexed", CGSize(width: 3840, height: 2160), fps: 60),
            item("720", CGSize(width: 1280, height: 720), fps: 0),
        ])

        let uhd = harness.shrink.select(from: collection, request: ShrinkVideosRequest(resolution: .uhd))
        #expect(Set(uhd.map(\.name)) == ["4k-no-index", "4k-indexed"])
        let fullHD = harness.shrink.select(from: collection, request: ShrinkVideosRequest(resolution: .fullHD))
        #expect(fullHD.map(\.name) == ["1080-no-index"])
    }

    @Test func dataOnlyVideosGoWhereTheRequestRedirectsThem() throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let redirected = try ShrinkVideosRequest(redirectedFolder: fixture.directory).overrides()
        #expect(redirected.saveLocation?.folder == fixture.directory)
        let nextTo = try ShrinkVideosRequest(destination: .nextToOriginal, redirectedFolder: fixture.directory)
            .overrides()
        #expect(nextTo.saveLocation?.folder == fixture.directory)
        // A folder the user chose wins.
        let chosen = fixture.directory.appending(path: "chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let wins = try ShrinkVideosRequest(destination: .folder, folder: chosen, redirectedFolder: fixture.directory)
            .overrides()
        #expect(wins.saveLocation?.folder == chosen)
    }

    @Test func photosGetANoteWhenTheSavedSaveToIsNotForThem() async throws {
        let fixture = try QuickRunFixture()
        defer { fixture.remove() }
        let queue = FakeQueue()
        var location = SaveLocation()
        try location.setFolder(fixture.directory)
        let saved = location
        let quickRun = QuickRun(
            queue: queue, store: QuickRunStore(fileURL: fixture.storeURL), notifier: FakeNotifier(),
            inspector: FakeInspector(sources: [:]),
            settings: { QuickRunSettings(preset: .balanced, saveLocation: saved) })

        let receipt = await quickRun.runPhotos(
            [QuickRunPhotoVideo(assetID: "A/L0/001", name: "A.MOV", isCinematic: false, isHDR: false)],
            overrides: nil)

        #expect(receipt.queuedJobIDs.count == 1)
        #expect(receipt.notes == ["Saved as new videos in Photos: the Save to folder is for files."])
    }

    @Test func notWaitingReturnsAtOnceWithNoOutputs() async throws {
        var urls: [URL] = []
        let harness = try Harness(local: { fixture in
            let items = [try Self.fileItem(fixture, "a.mov"), try Self.fileItem(fixture, "b.mov")]
            urls = items.compactMap(\.fileURL)
            return items
        })
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(files: urls, waitForCompletion: false))

        guard case .queued(let receipt, _) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(outcome.outputs == nil)
        #expect(receipt.queuedJobIDs.count == 2)
        #expect(outcome.message == "Queued 2 videos. A notification says when they're done.")
    }

    @Test func waitingIsSkippedWhenTheQueueDoesNotStart() async throws {
        var url: URL!
        let harness = try Harness(
            local: { fixture in
                let item = try Self.fileItem(fixture, "a.mov")
                url = item.fileURL
                return [item]
            }, startsQueue: false)
        defer { harness.fixture.remove() }

        // Would hang if it waited: nothing ever finishes this job.
        let outcome = await harness.shrink.perform(ShrinkVideosRequest(files: [url], waitForCompletion: true))

        guard case .queued = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(outcome.outputs == nil)
        #expect(outcome.message == "Queued 1 video. The queue is paused, so they'll convert when you resume it.")
    }

    @Test func skippedVideosAreCounted() async throws {
        var urls: [URL] = []
        let harness = try Harness(
            local: { fixture in
                let items = [try Self.fileItem(fixture, "a.mov"), try Self.fileItem(fixture, "lossy.mov")]
                urls = items.compactMap(\.fileURL)
                return items
            }, lossy: ["lossy.mov"])
        defer { harness.fixture.remove() }

        let outcome = await harness.shrink.perform(ShrinkVideosRequest(files: urls, waitForCompletion: false))

        guard case .queued(let receipt, _) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(receipt.queuedJobIDs.count == 1)
        #expect(receipt.skipped.map(\.url) == [urls[1]])
        #expect(outcome.message == "Queued 1 video. A notification says when they're done. 1 skipped.")
    }
}
