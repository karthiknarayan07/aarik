import AVFoundation
import AppCore
import CoreMedia
import Foundation
import MediaTestSupport
import Synchronization
import Testing

@testable import MediaEngine

@Suite struct VideoDownscalerTests {
    private static let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String

    private func clip(_ configure: (inout ClipOptions) -> Void = { _ in }) -> ClipOptions {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        configure(&options)
        return options
    }

    private func outputURL(next source: URL) -> URL {
        source.deletingLastPathComponent().appending(path: "output.mov")
    }

    /// A small spec for the 720p fixtures: 720 → 360 keeps the tests fast.
    private let smallSpec = DownscaleSpec(targetShortSide: 360, averageBitRate: 2_000_000)

    private func downscale(_ source: URL, spec: DownscaleSpec) async throws -> URL {
        let output = outputURL(next: source)
        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
        return output
    }

    private func expectNoPartial(beside output: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains(".partial-") }, "leaked: \(names)")
    }

    private func duration(of url: URL, _ mediaType: AVMediaType) async throws -> Double {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: mediaType).first)
        return try await track.load(.timeRange).duration.seconds
    }

    @Test(.timeLimit(.minutes(5))) func hlg4KTo1080KeepsEverything() async throws {
        var options = ClipOptions()
        options.quickTimeMetadata = [
            "com.apple.quicktime.make": "Apple",
            "com.apple.quicktime.model": "iPhone 17 Pro",
            "com.apple.quicktime.location.ISO6709": "+37.3349-122.0090+010.000/",
            "com.apple.quicktime.creationdate": "2026-11-25T10:00:00+0000",
        ]
        options.includeTimedMetadataTrack = true
        options.finderTags = ["Red"]
        options.extendedAttributes = ["com.example.fixture": Data("x".utf8)]
        let source = try await FixtureFactory.makeClip(options)

        let output = try await downscale(source, spec: DownscaleSpec())

        let sourceInventory = try await MediaInspector().inventory(of: source)
        let outputInventory = try await MediaInspector().inventory(of: output)
        let report = MetadataDiff.report(source: sourceInventory, output: outputInventory)
        #expect(report.lost.isEmpty, "lost: \(report.lost.map(\.key))")
        let changedKeys = Set(report.changed.map(\.key))
        #expect(changedKeys.isSubset(of: ["video.dimensions", "hdr.dolbyVision"]), "changed: \(report.changed)")
        #expect(outputInventory["video.dimensions"]?.value == "1920x1080")
        #expect(outputInventory["video.transferFunction"]?.value == Self.hlg)
        #expect(outputInventory["video.bitDepth"]?.value == "10")
        // The HLG fixture is a Dolby Vision 8.4 source; the level may follow the resolution, nothing else may change.
        #expect(sourceInventory["hdr.dolbyVision"] != nil)
        let dolbyVision = try #require(outputInventory["hdr.dolbyVision"])
        #expect(dolbyVision.value.hasPrefix("profile 8, level ") && dolbyVision.value.hasSuffix(", compat 4"))
    }

    @Test(.timeLimit(.minutes(5))) func sdrSourceDoesNotGainDolbyVision() async throws {
        let source = try await FixtureFactory.makeClip(clip { $0.hdr = .sdr })
        let output = try await downscale(source, spec: smallSpec)

        let sourceInventory = try await MediaInspector().inventory(of: source)
        let outputInventory = try await MediaInspector().inventory(of: output)
        #expect(outputInventory["hdr.dolbyVision"] == nil)
        let transfer = try #require(sourceInventory["video.transferFunction"]?.value)
        #expect(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(outputInventory["video.transferFunction"]?.value == transfer)
        #expect(sourceInventory["video.bitDepth"]?.value == "8")
        #expect(outputInventory["video.bitDepth"]?.value == "8")
        let report = MetadataDiff.report(source: sourceInventory, output: outputInventory)
        #expect(report.lost.isEmpty, "lost: \(report.lost.map(\.key))")
        #expect(Set(report.changed.map(\.key)).isSubset(of: ["video.dimensions"]), "changed: \(report.changed)")
    }

    /// Downscales and checks the report: nothing lost, only `video.dimensions` changed. Returns both inventories.
    private func roundTrip(_ options: ClipOptions) async throws -> (MetadataInventory, MetadataInventory, URL) {
        let source = try await FixtureFactory.makeClip(options)
        let output = try await downscale(source, spec: smallSpec)
        let sourceInventory = try await MediaInspector().inventory(of: source)
        let outputInventory = try await MediaInspector().inventory(of: output)
        let report = MetadataDiff.report(source: sourceInventory, output: outputInventory)
        #expect(report.lost.isEmpty, "lost: \(report.lost.map(\.key))")
        let allowed: Set<String> = ["video.dimensions", "hdr.dolbyVision"]
        #expect(Set(report.changed.map(\.key)).isSubset(of: allowed), "changed: \(report.changed)")
        return (sourceInventory, outputInventory, output)
    }

    @Test(.timeLimit(.minutes(5))) func videoTrackMetadataAndLanguageSurvive() async throws {
        let (source, output, outputURL) = try await roundTrip(
            clip {
                $0.videoTrackMetadata = ["com.example.fixture.track": "track value"]
                $0.videoLanguage = "eng"
            })
        let key = "trackmeta.0.com.example.fixture.track"
        #expect(source[key]?.value == "track value")
        #expect(output[key]?.value == "track value")
        let track = try #require(try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.languageCode) == "eng")
    }

    @Test(.timeLimit(.minutes(5))) func audioGroupEnabledStateAndFallbackSurvive() async throws {
        let (source, output, _) = try await roundTrip(clip { $0.includeFallbackAudioTrack = true })
        let expected = [
            "audio.0.enabled": "true", "audio.1.enabled": "false",
            "audio.0.alternateGroup": "audio 0, audio 1", "audio.1.alternateGroup": "audio 0, audio 1",
            "audio.0.fallback": "audio 1", "audio.1.fallback": "none",
        ]
        for (key, value) in expected {
            #expect(source[key]?.value == value, "source \(key)")
            #expect(output[key]?.value == value, "output \(key)")
        }
    }

    @Test(.timeLimit(.minutes(5))) func staticHDRMetadataIsCarried() async throws {
        let (source, output, _) = try await roundTrip(
            clip {
                // BT.2020 primaries, D65, 1000 / 0.005 nits; MaxCLL 1000, MaxFALL 400; 314 lux, D65.
                $0.masteringDisplay = Data([
                    0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40, 0x42,
                    0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
                ])
                $0.contentLightLevel = Data([0x03, 0xE8, 0x01, 0x90])
                $0.ambientViewingEnvironment = Data([0x00, 0x04, 0xCA, 0x80, 0x3D, 0x13, 0x40, 0x42])
            })
        for key in ["hdr.masteringDisplay", "hdr.contentLightLevel", "hdr.ambientViewingEnvironment"] {
            let value = try #require(source[key]?.value, "fixture lacks \(key)")
            #expect(output[key]?.value == value, "\(key)")
        }
    }

    @Test(.timeLimit(.minutes(5))) func unknownQuickTimeKeysSurvive() async throws {
        let source = try await FixtureFactory.makeClip(
            clip { $0.quickTimeMetadata = ["com.apple.quicktime.some-future-key": "42"] })
        let output = try await downscale(source, spec: smallSpec)
        let inventory = try await MediaInspector().inventory(of: output)
        #expect(inventory["qt.com.apple.quicktime.some-future-key"]?.value == "42")
    }

    @Test(.timeLimit(.minutes(5))) func portraitRotationPreserved() async throws {
        let source = try await FixtureFactory.makeClip(
            {
                var options = ClipOptions()
                options.rotationDegrees = 90
                return options
            }())
        let output = try await downscale(source, spec: DownscaleSpec())

        let sourceTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let outputTrack = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (sourceTransform, outputSize, outputTransform) = (
            try await sourceTrack.load(.preferredTransform), try await outputTrack.load(.naturalSize),
            try await outputTrack.load(.preferredTransform)
        )
        #expect(outputSize == CGSize(width: 1920, height: 1080))
        #expect(outputTransform == sourceTransform)
        #expect(sourceTransform != .identity)
    }

    @Test(.timeLimit(.minutes(5))) func refusesToUpscale() async throws {
        let source = try await FixtureFactory.makeClip(
            clip {
                $0.width = 1920
                $0.height = 1080
            })
        let output = outputURL(next: source)
        await #expect(throws: DownscaleError.sourceAlreadySmall) {
            try await VideoDownscaler().downscale(source: source, output: output, spec: DownscaleSpec()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.timeLimit(.minutes(5))) func refusesExistingOutput() async throws {
        let source = try await FixtureFactory.makeClip(clip())
        let output = outputURL(next: source)
        let existing = Data("keep me".utf8)
        try existing.write(to: output)
        await #expect(throws: DownscaleError.outputExists) {
            try await VideoDownscaler().downscale(source: source, output: output, spec: smallSpec) { _ in }
        }
        #expect(try Data(contentsOf: output) == existing)
    }

    /// A file that appears at the final path after the pre-check (another job writing the same name) is not this
    /// run's: it must survive, and the run fails at the exclusive commit.
    @Test(.timeLimit(.minutes(5))) func keepsOutputCreatedByOthersDuringRun() async throws {
        let source = try await FixtureFactory.makeClip(clip())
        let output = outputURL(next: source)
        let other = Data("another job's output".utf8)
        var downscaler = VideoDownscaler()
        downscaler.beforeStartWriting = { _ in try? other.write(to: output) }
        await #expect(throws: DownscaleError.outputExists) {
            try await downscaler.downscale(source: source, output: output, spec: smallSpec) { _ in }
        }
        #expect(try Data(contentsOf: output) == other)
        try expectNoPartial(beside: output)
    }

    @Test(.timeLimit(.minutes(5))) func cancelRemovesPartialOutput() async throws {
        let source = try await FixtureFactory.makeClip(clip { $0.seconds = 4 })
        let output = outputURL(next: source)
        let spec = smallSpec

        // The progress callback cancels the task the first time progress exceeds 0.1. The flag covers a callback
        // that fires before the task handle is stored.
        let state = Mutex<(task: Task<Void, any Error>?, cancelRequested: Bool)>((nil, false))
        let task = Task {
            try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { progress in
                guard progress > 0.1 else { return }
                state.withLock {
                    $0.cancelRequested = true
                    $0.task?.cancel()
                }
            }
        }
        state.withLock {
            $0.task = task
            if $0.cancelRequested { task.cancel() }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(state.withLock { $0.cancelRequested })
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try expectNoPartial(beside: output)
    }

    @Test(.timeLimit(.minutes(5))) func sixtyToThirtyKeepsDurationAndSync() async throws {
        let source = try await FixtureFactory.makeClip(
            clip {
                $0.fps = 60
                $0.seconds = 2
            })
        var spec = smallSpec
        spec.maxFrameRate = 30
        let output = try await downscale(source, spec: spec)

        let inventory = try await MediaInspector().inventory(of: output)
        #expect(inventory["video.frameRate"]?.value == "30.00")
        let sourceVideo = try await duration(of: source, .video)
        let outputVideo = try await duration(of: output, .video)
        let outputAudio = try await duration(of: output, .audio)
        #expect(abs(outputVideo - sourceVideo) <= 1.0 / 30, "video \(outputVideo) vs source \(sourceVideo)")
        #expect(abs(outputAudio - outputVideo) <= 1.0 / 30, "audio \(outputAudio) vs video \(outputVideo)")
    }

    @Test(.timeLimit(.minutes(5))) func audioIsPassedThrough() async throws {
        let source = try await FixtureFactory.makeClip(clip())
        let output = try await downscale(source, spec: smallSpec)
        let sourceInventory = try await MediaInspector().inventory(of: source)
        let outputInventory = try await MediaInspector().inventory(of: output)
        for key in ["audio.0.format", "audio.0.channels", "audio.0.sampleRate"] {
            let value = try #require(sourceInventory[key]?.value)
            #expect(outputInventory[key]?.value == value, "\(key)")
        }
    }

    /// A reader that stops early (here: cancelled once video is done, standing in for a read failure) makes every
    /// passthrough output return nil, which looks like the end of the track. The run must fail, not write a
    /// truncated file.
    @Test(.timeLimit(.minutes(5))) func readerStoppingEarlyFailsAndRemovesOutput() async throws {
        let source = try await FixtureFactory.makeClip(clip { $0.audioTailSeconds = 5 })
        let output = outputURL(next: source)
        var downscaler = VideoDownscaler()
        downscaler.beforePassthroughDrain = { reader in reader.cancelReading() }
        await #expect(throws: DownscaleError.self) {
            try await downscaler.downscale(source: source, output: output, spec: smallSpec) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try expectNoPartial(beside: output)
    }

    /// Regression: once video is finished, the passthrough drain must feed every track. Draining one track at a time
    /// hangs: with the timed-metadata track first, its input runs ahead of the audio and stays not ready while the
    /// audio is never fed. (With audio first, macOS 27.2 does not throttle audio against metadata, so no hang.)
    @Test(.timeLimit(.minutes(5))) func audioTailWithTimedMetadataCompletes() async throws {
        let source = try await FixtureFactory.makeClip(
            clip {
                $0.includeTimedMetadataTrack = true
                $0.timedMetadataBeforeAudio = true
                $0.audioTailSeconds = 10
            })
        let output = try await downscale(source, spec: smallSpec)
        let video = try await duration(of: output, .video)
        let audio = try await duration(of: output, .audio)
        #expect(abs(audio - (video + 10)) <= 0.05, "audio \(audio) vs video \(video)")
        let inventory = try await MediaInspector().inventory(of: output)
        #expect(inventory["timed.mdta/com.example.fixture.timed"]?.value == "present")
    }
}
