import AppCore
import AppServices
import Foundation
import LocalLibrary
import MediaEngine
import PhotosLibrary
import Testing

@testable import Convert
@testable import ConvertUI

@Suite struct SavingsAndJobsTests {
    private func inventory(size: String, durationMs: Int = 60_000, extra: [MetadataItem] = []) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(
            items: [
                item("video.dimensions", size), item("video.frameRate", "30.00"),
                item("video.duration", String(durationMs)), item("audio.0.format", "aac "),
            ] + extra)
    }

    /// A file of `megabits` per second for 60 s.
    private func bytes(mbps: Double) -> Int64 { Int64(mbps * 1_000_000 * 60 / 8) }

    @Test func couldFreeExcludesKeptAsIs() {
        let big = (byteSize: bytes(mbps: 100), inventory: inventory(size: "3840x2160"))
        // Already small: a 720p clip below the balanced rate.
        let small = (byteSize: bytes(mbps: 3), inventory: inventory(size: "1280x720"))
        // Spatial video is refused, however big it is.
        let spatial = (
            byteSize: bytes(mbps: 100),
            inventory: inventory(
                size: "3840x2160",
                extra: [MetadataItem(key: "hdr.stereo", category: .hdr, displayName: "Stereo", value: "1")])
        )
        let estimate = Estimator.estimatedBytes(inventory: big.inventory, byteSize: big.byteSize, preset: .balanced)
        #expect(estimate < big.byteSize)

        let freed = SavingsCalculator.couldFreeBytes(for: [big, small, spatial], preset: .balanced)
        #expect(freed == big.byteSize - estimate)
        #expect(SavingsCalculator.couldFreeBytes(for: [small, spatial], preset: .balanced) == 0)
        #expect(SavingsCalculator.couldFreeBytes(for: [], preset: .smaller) == 0)
    }

    @Test func couldFreeUsesACustomSpecWhenGiven() {
        let big = (byteSize: bytes(mbps: 100), inventory: inventory(size: "3840x2160"))
        let custom = DownscaleSpec(targetShortSide: 720, averageBitRate: 4_000_000)
        let estimate = Estimator.estimatedBytes(inventory: big.inventory, byteSize: big.byteSize, spec: custom)
        #expect(SavingsCalculator.couldFreeBytes(for: [big], preset: .high, custom: custom) == big.byteSize - estimate)
    }

    @Test func estimatesListEveryPresetWithItsDecision() {
        let big = inventory(size: "3840x2160")
        let rows = SavingsCalculator.estimates(byteSize: bytes(mbps: 100), inventory: big)
        #expect(rows.map(\.preset) == Preset.allCases)
        for row in rows {
            #expect(row.estimatedBytes != nil)
            #expect((row.savedFraction ?? 0) > 0)
        }
        let small = SavingsCalculator.estimates(byteSize: bytes(mbps: 3), inventory: inventory(size: "1280x720"))
        #expect(
            small.first { $0.preset == .balanced }?.decision == .keptAsIs(reason: "Already small", code: .alreadySmall))
        #expect(small.first { $0.preset == .balanced }?.estimatedBytes == nil)
    }

    @Test func addSelectionCreatesOneJobPerItemWithPreset() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jobfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try (1...3).map { index in
            let url = folder.appending(path: "clip-\(index).mov")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
        let settings = ConvertJobSettings(preset: .smaller, saveTo: .nextToOriginal)

        let batch = JobFactory.makeJobs(for: urls, settings: settings)
        let jobs = batch.jobs

        #expect(batch.skipped.isEmpty)
        #expect(jobs.count == 3)
        #expect(jobs.map(\.source) == urls)
        #expect(Set(jobs.map(\.id)).count == 3)
        for job in jobs {
            #expect(job.toolID == ConvertTool.toolID)
            #expect(job.state == .queued)
            let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
            #expect(decoded == settings)
            var stale = false
            let resolved = try URL(
                resolvingBookmarkData: job.sourceBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            #expect(resolved.standardizedFileURL.path == job.source.standardizedFileURL.path)
        }
    }

    @Test func jobsCarryCustomSpecAndDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jobfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "clip.mov")
        try Data([1]).write(to: url)
        let settings = ConvertJobSettings(
            preset: .high, saveTo: .replace, custom: DownscaleSpec(targetShortSide: 720, averageBitRate: 3_000_000))

        let jobs = JobFactory.makeJobs(for: [url], settings: settings).jobs
        let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: try #require(jobs.first).settings)
        #expect(decoded == settings)
    }

    @Test func fileThatCantBeBookmarkedIsSkippedAndReportedOthersStillGetJobs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jobfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let present = folder.appending(path: "clip.mov")
        try Data([1]).write(to: present)
        let missing = folder.appending(path: "missing.mov")

        let batch = JobFactory.makeJobs(
            for: [missing, present], settings: ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal))

        #expect(batch.jobs.map(\.source) == [present])
        #expect(batch.skipped == [missing])
    }

    @Test func jobsRecordWhatTheyArePredictedToLose() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jobfactory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lossy = folder.appending(path: "a.mov")
        let clean = folder.appending(path: "b.mov")
        try Data([1]).write(to: lossy)
        try Data([2]).write(to: clean)
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal)

        let jobs = JobFactory.makeJobs(
            for: [lossy, clean], settings: settings,
            losses: [lossy: PredictedLoss(id: UUID(), lost: ["Cinematic depth data"], keys: ["x"])]
        ).jobs
        let decoded = try jobs.map { try JSONDecoder().decode(ConvertJobSettings.self, from: $0.settings) }

        #expect(decoded.map(\.predictedLost) == [["Cinematic depth data"], []])
        // Without a loss check the prediction is unknown, as for jobs saved before it existed.
        let unknown = try #require(JobFactory.makeJobs(for: [clean], settings: settings).jobs.first)
        #expect(try JSONDecoder().decode(ConvertJobSettings.self, from: unknown.settings).predictedLost == nil)
    }

    @Test func settingsSavedBeforePredictedLossDecode() throws {
        let old = #"{"preset":"balanced","saveTo":{"nextToOriginal":{}}}"#
        let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: Data(old.utf8))
        #expect(decoded == ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal))
    }

    @Test func advancedOptionsBuildACustomSpecOnlyWhenOn() {
        var options = AdvancedOptions()
        #expect(options.spec == nil)
        options.isEnabled = true
        options.resolution = .p720
        options.bitRateMbps = 5
        options.frameRate = .fps30
        #expect(options.spec == DownscaleSpec(targetShortSide: 720, averageBitRate: 5_000_000, maxFrameRate: 30))
        options.resolution = .keep
        options.frameRate = .keep
        options.bitRateMbps = 0
        #expect(options.spec == DownscaleSpec(targetShortSide: nil, averageBitRate: 1_000_000, maxFrameRate: nil))
    }

    @Test func queueButtonTitlesAreSentenceCaseAndSayWhenNothingCanBeAdded() {
        #expect(QueueButtonTitle.title(count: 1, preset: .balanced, isCustom: false) == "Add to queue · Balanced")
        #expect(QueueButtonTitle.title(count: 1, preset: .balanced, isCustom: true) == "Add to queue · Custom")
        #expect(QueueButtonTitle.title(count: 3, preset: .high, isCustom: false) == "Add 3 to queue")
        #expect(QueueButtonTitle.title(count: 0, preset: .high, isCustom: false) == "Nothing to add")
    }

    @Test func theToolbarButtonIsShortAndTitleCase() {
        #expect(QueueButtonTitle.toolbarTitle(count: 0) == "Add to Queue")
        #expect(QueueButtonTitle.toolbarTitle(count: 1) == "Add to Queue")
        #expect(QueueButtonTitle.toolbarTitle(count: 3) == "Add 3 to Queue")
    }

    @Test func iosDefaultOptionsEnableCustomSpecAndPersistQualityKeys() {
        let suite = UserDefaults(suiteName: "IOSSettingsTests-\(UUID().uuidString)")!
        var initial = AppSettings.defaultAdvancedOptions(suite, platform: .iOS)
        #expect(initial.isEnabled)
        #expect(initial.resolution == .p1080)
        #expect(initial.bitRateMbps == 10.0)
        // Changing resolution while bit rate is at the previous suggestion tracks the new suggestion.
        initial.resolution = .p720
        #expect(initial.bitRateMbps == 4.0)
        // Custom bit rate stays untouched when switching resolution.
        initial.bitRateMbps = 14.0
        initial.resolution = .p1440
        #expect(initial.bitRateMbps == 14.0)

        // Mac stays preset-based by default.
        #expect(!AppSettings.defaultAdvancedOptions(suite, platform: .macOS).isEnabled)

        suite.set(AdvancedOptions.Resolution.p720.rawValue, forKey: AppSettings.Keys.defaultResolution)
        suite.set(AdvancedOptions.FrameRate.fps30.rawValue, forKey: AppSettings.Keys.defaultFrameRate)
        suite.set(VideoCodec.h264Compatible.rawValue, forKey: AppSettings.Keys.defaultCodec)
        // Without an explicit stored bit rate, H.264 @ 720p picks its suggested rate (6.4 Mbps).
        let derived = AppSettings.defaultAdvancedOptions(suite, platform: .iOS)
        #expect(derived.bitRateMbps == 6.4)
        suite.set(8.5, forKey: AppSettings.Keys.defaultBitRateMbps)
        let explicit = AppSettings.defaultAdvancedOptions(suite, platform: .iOS)
        #expect(explicit.resolution == .p720)
        #expect(explicit.frameRate == .fps30)
        #expect(explicit.codec == .h264Compatible)
        #expect(explicit.bitRateMbps == 8.5)

        // Plain-English bit rate classification and guide track the chosen resolution and codec.
        #expect(AdvancedOptions.bitRateTier(mbps: 4.0, resolution: .p1080, codec: .hevcKeepHDR) == .compact)
        #expect(AdvancedOptions.bitRateTier(mbps: 10.0, resolution: .p1080, codec: .hevcKeepHDR) == .recommended)
        #expect(AdvancedOptions.bitRateTier(mbps: 18.0, resolution: .p1080, codec: .hevcKeepHDR) == .highDetail)
        #expect(AdvancedOptions.bitRateGuide(for: .p1080, codec: .hevcKeepHDR).contains("8–12 Mbps"))
    }

    @MainActor
    @Test func photosSelectionEstimatesAndQueuesCustomSpecWhenEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "PhotosCustomSpec-\(UUID().uuidString)")!
        let asset = PhotoAsset(
            id: "clip/L0/001", creationDate: Date(timeIntervalSince1970: 1_700_000_000), location: nil,
            pixelSize: CGSize(width: 3840, height: 2160), duration: 60, originalFileName: "clip.mov",
            originalByteSize: bytes(mbps: 100), modificationDate: nil)
        let services = AppServices(
            directory: directory, defaults: defaults, photoStore: FakePhotoStore(assets: [asset]))
        let model = ConvertModel(services: services)
        await model.start()
        await model.photos.start()
        await model.photos.waitUntilIdle()
        model.selection = .photosVideos
        model.photosBrowser.selection = Set(model.photos.items.map(\.id))
        model.advanced.isEnabled = true
        model.advanced.resolution = .p720
        model.advanced.bitRateMbps = 5.0

        // Photos items carry empty inventory in the sandbox, yet estimation and selection savings still work.
        #expect(model.couldFreeSelected > 0)

        model.addPhotosSelectionToQueue()
        await model.services.waitForQueueCommands()
        for _ in 0..<20 { await Task.yield() }
        let job = try #require(model.jobs.first)
        let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
        #expect(decoded.custom == model.advanced.spec)
    }
}
