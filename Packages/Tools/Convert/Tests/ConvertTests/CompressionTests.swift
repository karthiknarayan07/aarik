import AVFoundation
import AppCore
import AppServices
import CoreMedia
import Foundation
import LocalLibrary
import MediaEngine
import MediaTestSupport
import PhotosLibrary
import Testing

@testable import Convert
@testable import ConvertUI

@Suite struct CompressionTests {
    private static let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String

    private func inventory(
        size: String, fps: String = "30.00", durationMs: Int = 60_000, extra: [MetadataItem] = []
    ) -> MetadataInventory {
        func item(_ key: String, _ value: String) -> MetadataItem {
            MetadataItem(key: key, category: .video, displayName: key, value: value)
        }
        return MetadataInventory(
            items: [
                item("video.dimensions", size), item("video.frameRate", fps),
                item("video.duration", String(durationMs)), item("audio.0.format", "aac "),
            ] + extra)
    }

    /// A file of `megabits` per second for 60 s.
    private func bytes(mbps: Double) -> Int64 { Int64(mbps * 1_000_000 * 60 / 8) }

    // MARK: - Persistence & Extensibility

    @Test func oldJobsDecodeAsShrink() throws {
        let legacySettingsJSON = #"{"preset":"balanced","saveTo":{"nextToOriginal":{}}}"#
        let encodedSettings = Data(legacySettingsJSON.utf8).base64EncodedString()
        let legacyJobID = UUID()
        let legacyJobJSON = """
            [
              {
                "createdAt": 0,
                "id": "\(legacyJobID.uuidString)",
                "settings": "\(encodedSettings)",
                "source": "file:///tmp/legacy.mov",
                "sourceBookmark": "",
                "state": { "queued": {} },
                "toolID": "downscale-video"
              }
            ]
            """
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "old-jobs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JobStore(directory: directory)
        try Data(legacyJobJSON.utf8).write(to: directory.appending(path: "jobs.json"))
        let loaded = store.load()
        #expect(loaded.count == 1)
        let job = try #require(loaded.first)
        #expect(job.id == legacyJobID)
        #expect(job.toolID == ConvertTool.toolID)

        let decodedSettings = try JSONDecoder().decode(ConvertJobSettings.self, from: job.settings)
        #expect(decodedSettings.kind == .shrink)
        #expect(decodedSettings.preset == .balanced)
        #expect(decodedSettings.saveTo == .nextToOriginal)
    }

    @Test func compressJobKindRoundTripsThroughJobStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compress-jobs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jobs = try CompressPreset.allCases.map { preset in
            let settings = ConvertJobSettings(kind: .compress(preset), saveTo: .nextToOriginal)
            return Job(
                toolID: ConvertTool.toolID, source: URL(filePath: "/tmp/\(preset.rawValue).mov"),
                sourceBookmark: Data(), settings: try JSONEncoder().encode(settings))
        }
        let store = JobStore(directory: directory)
        try store.save(jobs)
        let loaded = store.load()
        #expect(loaded.count == 3)
        for (index, preset) in CompressPreset.allCases.enumerated() {
            let decoded = try JSONDecoder().decode(ConvertJobSettings.self, from: loaded[index].settings)
            #expect(decoded.kind == .compress(preset))
        }
    }

    // MARK: - Ratios, Floors & Planner

    @Test func presetRatiosAndDataRateLimitsFollowADR0005() {
        #expect(CompressPreset.smaller.bitRateRatio == 0.25)
        #expect(CompressPreset.balanced.bitRateRatio == 0.40)
        #expect(CompressPreset.bestQuality.bitRateRatio == 0.60)

        let uhd = inventory(size: "3840x2160")
        let sourceBytes = bytes(mbps: 50)
        // Video bitrate = 50 Mbps - 256 kbps audio = 49.744 Mbps, so even Smaller (0.25x = 12.4 Mbps) is above floor.
        let expectedVideoRate = 50_000_000.0 - 256_000.0

        for preset in CompressPreset.allCases {
            let spec = preset.spec(for: uhd, byteSize: sourceBytes)
            #expect(spec.targetShortSide == nil)
            #expect(spec.maxFrameRate == nil)
            #expect(spec.codec == .hevcKeepHDR)
            let expectedTarget = Int((expectedVideoRate * preset.bitRateRatio).rounded())
            #expect(abs(spec.averageBitRate - expectedTarget) <= 1000)
            #expect(spec.maxBitRate == spec.averageBitRate * 2)
        }
    }

    @Test func floorPreventsCrushingAndNeverInflatesLowBitrateSources() {
        let uhd = inventory(size: "3840x2160", fps: "30.00")
        // 4K30 floor is 0.04 * 3840 * 2160 * 30 ≈ 9.95 Mbps.
        let floor4K = CompressPreset.smaller.spec(for: uhd, byteSize: bytes(mbps: 12))
        #expect((9_900_000...10_100_000).contains(floor4K.averageBitRate))

        // A 4K30 source at 8 Mbps is already below the ~10 Mbps floor: never inflated, kept as "Already small".
        let low4K = ConvertPlanner.decide(
            source: URL(filePath: "/x.mov"), inventory: uhd, byteSize: bytes(mbps: 8),
            kind: .compress(.smaller))
        #expect(low4K == .keptAsIs(reason: "Already small", code: .alreadySmall))

        let hd = inventory(size: "1920x1080", fps: "30.00")
        // 1080p30 floor is 0.04 * 1920 * 1080 * 30 ≈ 2.49 Mbps.
        let floor1080 = CompressPreset.smaller.spec(for: hd, byteSize: bytes(mbps: 4))
        #expect((2_400_000...2_600_000).contains(floor1080.averageBitRate))

        // A 1080p30 source at 2 Mbps is below the ~2.5 Mbps floor.
        let low1080 = ConvertPlanner.decide(
            source: URL(filePath: "/y.mov"), inventory: hd, byteSize: bytes(mbps: 2),
            kind: .compress(.balanced))
        #expect(low1080 == .keptAsIs(reason: "Already small", code: .alreadySmall))
    }

    @Test func compressEstimatesAndLabelsFollowADR0005() {
        let uhd = inventory(size: "3840x2160")
        let sourceBytes = bytes(mbps: 50)
        let estimates = SavingsCalculator.compressEstimates(byteSize: sourceBytes, inventory: uhd)
        #expect(estimates.map(\.preset) == CompressPreset.allCases)
        for estimate in estimates {
            #expect(estimate.estimatedBytes != nil)
            #expect((estimate.savedFraction ?? 0) > 0.3)
        }
        #expect((estimates[0].estimatedBytes ?? 0) < (estimates[1].estimatedBytes ?? 0))
        #expect((estimates[1].estimatedBytes ?? 0) < (estimates[2].estimatedBytes ?? 0))

        #expect(
            ConvertRunner.label(
                for: DownscaleSpec(targetShortSide: nil),
                settings: ConvertJobSettings(kind: .compress(.smaller), saveTo: .nextToOriginal)) == "Smaller")
        #expect(
            ConvertRunner.label(
                for: DownscaleSpec(targetShortSide: nil),
                settings: ConvertJobSettings(kind: .compress(.balanced), saveTo: .nextToOriginal)) == "Balanced")
        #expect(
            ConvertRunner.label(
                for: DownscaleSpec(targetShortSide: nil),
                settings: ConvertJobSettings(kind: .compress(.bestQuality), saveTo: .nextToOriginal)) == "Best Quality")
    }

    @Test func displayTitlesAreTitleCaseAndDetailsAreSentenceCase() {
        #expect(CompressPreset.smaller.displayName == "Smaller")
        #expect(CompressPreset.balanced.displayName == "Balanced")
        #expect(CompressPreset.bestQuality.displayName == "Best Quality")
        for preset in CompressPreset.allCases {
            #expect(preset.detail.first?.isUppercase == true)
            #expect(preset.detail.hasSuffix("."))
        }
    }

    // MARK: - Model & UI helpers

    @MainActor
    @Test func modelPersistsCompressPresetAndBuildsCompressJobLabel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "compress-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "CompressionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let services = AppServices(directory: directory, defaults: defaults, photoStore: FakePhotoStore())
        let model = ConvertModel(services: services)
        #expect(model.compressPreset == .balanced)
        model.compressPreset = .bestQuality

        let reloaded = ConvertModel(
            services: AppServices(
                directory: directory, defaults: UserDefaults(suiteName: suiteName)!, photoStore: FakePhotoStore()))
        #expect(reloaded.compressPreset == .bestQuality)

        let settings = ConvertJobSettings(kind: .compress(.bestQuality), saveTo: .nextToOriginal)
        let job = Job(
            toolID: ConvertTool.toolID, source: URL(filePath: "/tmp/clip.mov"), sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings))
        #expect(job.presetLabel == "Compress · Best Quality")

        let prompt = OutcomeExplainer.prompt(job: job, outcome: nil, report: nil)
        #expect(prompt.contains("Mode: Compress (keeps resolution)"))
        #expect(prompt.contains("Preset: Best Quality"))
    }
}

/// Fixture-backed quality tests run serially so `FixtureFactory` doesn't contend with concurrent 4K encodes.
@Suite(.serialized) struct CompressionFixtureTests {
    private static let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String

    private func isolatedRunner() -> ConvertRunner {
        ConvertRunner(
            trash: ConvertRunner.trashItem,
            diskSpace: DiskSpaceCheck(provider: FakeDiskSpace(available: 100_000_000_000), ledger: SpaceLedger()))
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func compress4K30SDRKeepsResolutionFpsAndMetadataAcrossAllPresets() async throws {
        var options = ClipOptions()
        options.width = 3840
        options.height = 2160
        options.fps = 30
        options.seconds = 2
        options.hdr = .sdr
        options.videoBitRate = 40_000_000
        options.quickTimeMetadata = [
            "com.apple.quicktime.make": "Apple",
            "com.apple.quicktime.model": "iPhone 17 Pro",
            "com.apple.quicktime.location.ISO6709": "+37.3349-122.0090+010.000/",
        ]
        options.includeTimedMetadataTrack = true
        let source = try await FixtureFactory.makeClip(options)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        for preset in CompressPreset.allCases {
            let job = try RunnerFixture.job(
                source, ConvertJobSettings(kind: .compress(preset), saveTo: .nextToOriginal))
            let state = try await isolatedRunner().run(job) { _ in }
            guard case .completed(let outcome) = state else {
                Issue.record("expected completed for \(preset), got \(state)")
                continue
            }
            #expect(outcome.isVerified)
            #expect(outcome.bytesAfter < outcome.bytesBefore)
            #expect(outcome.report.lost.isEmpty, "lost for \(preset): \(outcome.report.lost.map(\.key))")
            let outputInventory = try await MediaInspector().inventory(of: outcome.output)
            #expect(outputInventory["video.dimensions"]?.value == "3840x2160")
            #expect(outputInventory["video.frameRate"]?.value == "30.00")
            #expect(outputInventory["video.bitDepth"]?.value == "8")
            #expect(outputInventory["hdr.dolbyVision"] == nil)
            #expect(outputInventory["qt.com.apple.quicktime.make"]?.value == "Apple")
            #expect(outputInventory["timed.\(FixtureFactory.timedMetadataIdentifier)"]?.value == "present")
        }
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func compress4K60HLGAndDolbyVisionKeepsHDRAndRPU() async throws {
        var options = ClipOptions()
        options.width = 3840
        options.height = 2160
        options.fps = 60
        options.seconds = 2
        options.hdr = .hlg
        // Synthetic gradients encode efficiently below nominal target rates; 120 Mbps asks the fixture encoder for
        // plenty of headroom above the 15 Mbps 4K60 floor so Balanced (0.40x) compresses cleanly.
        options.videoBitRate = 120_000_000
        options.maximumQuality = true
        options.masteringDisplay = Data([
            0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
        ])
        options.contentLightLevel = Data([0x03, 0xE8, 0x01, 0x90])
        options.ambientViewingEnvironment = Data([0x00, 0x04, 0xCA, 0x80, 0x3D, 0x13, 0x40, 0x42])
        let source = try await FixtureFactory.makeClip(options)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let job = try RunnerFixture.job(
            source, ConvertJobSettings(kind: .compress(.balanced), saveTo: .nextToOriginal))
        let state = try await isolatedRunner().run(job) { _ in }
        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.isVerified)
        #expect(outcome.bytesAfter < outcome.bytesBefore)
        #expect(outcome.report.lost.isEmpty, "lost: \(outcome.report.lost.map(\.key))")

        let sourceInventory = try await MediaInspector().inventory(of: source)
        let outputInventory = try await MediaInspector().inventory(of: outcome.output)
        #expect(outputInventory["video.dimensions"]?.value == "3840x2160")
        #expect(outputInventory["video.frameRate"]?.value == "60.00")
        #expect(outputInventory["video.bitDepth"]?.value == "10")
        #expect(outputInventory["video.transferFunction"]?.value == Self.hlg)
        let dv = try #require(outputInventory["hdr.dolbyVision"]?.value)
        #expect(dv.hasPrefix("profile 8, level ") && dv.hasSuffix(", compat 4"))
        for key in ["hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment"] {
            #expect(outputInventory[key]?.value == sourceInventory[key]?.value, "\(key)")
        }
    }

    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func compress1080p30ShrinksAndLowBitrateIsAlreadySmall() async throws {
        var high = ClipOptions()
        high.width = 1920
        high.height = 1080
        high.fps = 30
        high.seconds = 2
        high.hdr = .sdr
        high.videoBitRate = 25_000_000
        let highSource = try await FixtureFactory.makeClip(high)
        defer { try? FileManager.default.removeItem(at: highSource.deletingLastPathComponent()) }

        let highJob = try RunnerFixture.job(
            highSource, ConvertJobSettings(kind: .compress(.balanced), saveTo: .nextToOriginal))
        let highState = try await isolatedRunner().run(highJob) { _ in }
        guard case .completed(let outcome) = highState else {
            Issue.record("expected completed, got \(highState)")
            return
        }
        #expect(outcome.isVerified)
        #expect(outcome.bytesAfter < outcome.bytesBefore)
        let outputInventory = try await MediaInspector().inventory(of: outcome.output)
        #expect(outputInventory["video.dimensions"]?.value == "1920x1080")
        #expect(outputInventory["video.frameRate"]?.value == "30.00")

        var low = ClipOptions()
        low.width = 1920
        low.height = 1080
        low.fps = 30
        low.seconds = 2
        low.hdr = .sdr
        low.videoBitRate = 1_500_000
        let lowSource = try await FixtureFactory.makeClip(low)
        defer { try? FileManager.default.removeItem(at: lowSource.deletingLastPathComponent()) }

        let lowJob = try RunnerFixture.job(
            lowSource, ConvertJobSettings(kind: .compress(.balanced), saveTo: .nextToOriginal))
        let lowState = try await isolatedRunner().run(lowJob) { _ in }
        #expect(lowState == .keptAsIs(reason: "Already small", code: .alreadySmall))
    }
}
