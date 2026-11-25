import AarikCore
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

/// The Dolby Vision release gate (spec 8.3a) on real iPhone clips. Every test is skipped until the matching clip is
/// in `Fixtures/iphone/` (see `Fixtures/README.md`).
@Suite struct RealClipGateTests {
    private struct Run {
        let source: MetadataInventory
        let output: MetadataInventory
        let outputURL: URL
        var report: MetadataReport { MetadataDiff.report(source: source, output: output) }
    }

    private func downscaleReal(_ fixture: RealFixture) async throws -> Run {
        let source = try #require(RealFixtures.url(fixture))
        let directory = FileManager.default.temporaryDirectory.appending(path: "aarik-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "output.mov")
        try await VideoDownscaler().downscale(source: source, output: output, spec: DownscaleSpec()) { _ in }
        print("gate output for \(fixture.rawValue): \(output.path)")
        return Run(
            source: try await MediaInspector().inventory(of: source),
            output: try await MediaInspector().inventory(of: output), outputURL: output)
    }

    private func expectDolbyVisionSurvives(_ fixture: RealFixture) async throws {
        let run = try await downscaleReal(fixture)
        let before = try #require(run.source["hdr.dolbyVision"])
        #expect(before.value.hasPrefix("profile 8,") && before.value.hasSuffix("compat 4"), "source: \(before.value)")
        let after = try #require(run.output["hdr.dolbyVision"])
        // The level may follow the resolution; the report treats that as changed, never lost.
        #expect(after.value.hasPrefix("profile 8,") && after.value.hasSuffix("compat 4"), "output: \(after.value)")
        #expect(run.report.lost.isEmpty, "lost: \(run.report.lost.map(\.key))")
    }

    @Test(.enabled(if: RealFixtures.url(.dolbyVision4K60) != nil), .timeLimit(.minutes(5)))
    func dolbyVisionSurvives4K60() async throws {
        try await expectDolbyVisionSurvives(.dolbyVision4K60)
    }

    @Test(.enabled(if: RealFixtures.url(.dolbyVision4K30) != nil), .timeLimit(.minutes(5)))
    func dolbyVisionSurvives4K30() async throws {
        try await expectDolbyVisionSurvives(.dolbyVision4K30)
    }

    @Test(.enabled(if: RealFixtures.url(.dolbyVision4K30) != nil), .timeLimit(.minutes(5)))
    func iPhoneMetadataSurvives() async throws {
        let run = try await downscaleReal(.dolbyVision4K30)
        let sourceKeys = run.source.items.filter { $0.key.hasPrefix("qt.") }
        #expect(!sourceKeys.isEmpty, "the clip has no QuickTime metadata; was it exported unmodified?")
        for item in sourceKeys {
            let kept = run.output[item.key]
            #expect(kept != nil, "missing in output: \(item.key)")
            #expect(kept?.value == item.value, "\(item.key): \(item.value) -> \(kept?.value ?? "nil")")
        }
    }

    @Test(.enabled(if: RealFixtures.url(.spatialAudio) != nil), .timeLimit(.minutes(5)))
    func spatialAudioPassesThrough() async throws {
        let run = try await downscaleReal(.spatialAudio)
        let audio = run.source.items.filter { $0.key.hasPrefix("audio.") }
        #expect(!audio.isEmpty, "the clip has no audio items")
        for item in audio {
            let got = run.output[item.key]?.value
            #expect(got == item.value, "\(item.key): \(item.value) -> \(got ?? "nil")")
        }
    }

    @Test(.enabled(if: RealFixtures.url(.spatialVideo) != nil), .timeLimit(.minutes(5)))
    func spatialVideoIsRefused() async throws {
        let source = try #require(RealFixtures.url(.spatialVideo))
        let directory = FileManager.default.temporaryDirectory.appending(path: "aarik-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "output.mov")
        await #expect(throws: DownscaleError.unsupportedSource("spatial video")) {
            try await VideoDownscaler().downscale(source: source, output: output, spec: DownscaleSpec()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: RealFixtures.url(.sloMo) != nil), .timeLimit(.minutes(5)))
    func sloMoKeepsFrameRate() async throws {
        let run = try await downscaleReal(.sloMo)
        let rate = try #require(run.source["video.frameRate"])
        #expect(run.output["video.frameRate"]?.value == rate.value)
    }

    @Test(.enabled(if: RealFixtures.url(.livePhoto) != nil), .timeLimit(.minutes(5)))
    func livePhotoKeepsContentIdentifier() async throws {
        let run = try await downscaleReal(.livePhoto)
        let key = "qt.com.apple.quicktime.content.identifier"
        let identifier = try #require(run.source[key], "the Live Photo clip has no content identifier")
        #expect(run.output[key]?.value == identifier.value)
    }

    @Test(.enabled(if: RealFixtures.url(.sdr) != nil), .timeLimit(.minutes(5)))
    func sdrClipStaysSDR() async throws {
        let run = try await downscaleReal(.sdr)
        let transfer = try #require(run.source["video.transferFunction"])
        #expect(run.output["video.transferFunction"]?.value == transfer.value)
        #expect(run.output["hdr.dolbyVision"] == nil)
        #expect(run.report.lost.isEmpty, "lost: \(run.report.lost.map(\.key))")
    }

    /// Records what a Cinematic clip loses; the printed list feeds ADR 0001. Only completion is asserted.
    @Test(.enabled(if: RealFixtures.url(.cinematic) != nil), .timeLimit(.minutes(5)))
    func cinematicReportsLosses() async throws {
        let run = try await downscaleReal(.cinematic)
        #expect(FileManager.default.fileExists(atPath: run.outputURL.path))
        let lost = run.report.lost
        print("cinematic lost (\(lost.count)): \(lost.map { "\($0.key) [\($0.displayName)]" })")
    }
}
