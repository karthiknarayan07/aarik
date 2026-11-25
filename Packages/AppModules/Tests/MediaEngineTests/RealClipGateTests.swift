import AppCore
import CoreGraphics
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

/// The Dolby Vision release gate (spec 8.3a) on real iPhone clips. Every test is skipped until the matching clip is
/// in `Fixtures/iphone/` (see `Fixtures/README.md`). With `REAL_CLIP_GATE=1` a missing clip fails instead.
@Suite struct RealClipGateTests {
    /// `REAL_CLIP_GATE=1`: the gate run proper, where every clip must be present.
    static let isGateRun = ProcessInfo.processInfo.environment["REAL_CLIP_GATE"] == "1"

    static func runs(_ fixture: RealFixture) -> Bool {
        isGateRun || RealFixtures.url(fixture) != nil
    }

    private struct Run {
        let source: MetadataInventory
        let output: MetadataInventory
        let outputURL: URL
        let spec: DownscaleSpec
        var report: MetadataReport { MetadataDiff.report(source: source, output: output) }
    }

    private func clip(_ fixture: RealFixture) throws -> URL {
        try #require(
            RealFixtures.url(fixture),
            "missing Fixtures/iphone/\(fixture.rawValue); REAL_CLIP_GATE=1 needs every clip (see Fixtures/README.md)")
    }

    private func outputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "real-clip-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "output.mov")
    }

    /// `"3840x2160"` → (3840, 2160).
    private static func size(_ dimensions: String?) -> CGSize? {
        let parts = dimensions?.split(separator: "x").compactMap { Int($0) } ?? []
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// Strictly below the source short side, so no clip is refused as already small: 720 if the short side is above
    /// 720, else half the short side rounded down to even.
    static func nonDolbyVisionTarget(shortSide: Int) -> Int {
        shortSide > 720 ? 720 : shortSide / 4 * 2
    }

    /// Dolby Vision clips go to 1080 and must be 4K; every other clip to `nonDolbyVisionTarget`.
    private func downscaleReal(_ fixture: RealFixture, dolbyVision: Bool = false) async throws -> Run {
        let source = try clip(fixture)
        let sourceInventory = try await MediaInspector().inventory(of: source)
        let natural = try #require(Self.size(sourceInventory["video.dimensions"]?.value), "no video dimensions")
        let shortSide = Int(min(natural.width, natural.height))
        if dolbyVision {
            try #require(
                shortSide >= 2160,
                "\(fixture.rawValue) is \(Int(natural.width))x\(Int(natural.height)); record it in 4K")
        }
        let spec = DownscaleSpec(targetShortSide: dolbyVision ? 1080 : Self.nonDolbyVisionTarget(shortSide: shortSide))
        let output = try outputURL()
        print("gate output for \(fixture.rawValue) (short side \(spec.targetShortSide ?? 0)): \(output.path)")
        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
        return Run(
            source: sourceInventory, output: try await MediaInspector().inventory(of: output), outputURL: output,
            spec: spec)
    }

    /// `"profile 8, level 9, compat 4"` → (8, 9, 4).
    static func dolbyVisionParts(_ value: String) -> (profile: Int, level: Int, compat: Int)? {
        let numbers = value.split(separator: ",").compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
        return numbers.count == 3 ? (numbers[0], numbers[1], numbers[2]) : nil
    }

    /// Only `video.dimensions` may change, plus `video.codec` when the source isn't HEVC already, plus the Dolby
    /// Vision level (profile and compatibility kept) when the source has Dolby Vision.
    private func expectOnlyExpectedChanges(_ run: Run) {
        var allowed: Set<String> = ["video.dimensions"]
        if run.source["video.codec"]?.value != run.output["video.codec"]?.value { allowed.insert("video.codec") }
        for change in run.report.changed {
            if change.key == "hdr.dolbyVision", let from = Self.dolbyVisionParts(change.from),
                let to = Self.dolbyVisionParts(change.to)
            {
                #expect(
                    from.profile == to.profile && from.compat == to.compat,
                    "Dolby Vision may change level only: \(change.from) -> \(change.to)")
                continue
            }
            #expect(allowed.contains(change.key), "unexpected change \(change.key): \(change.from) -> \(change.to)")
        }
        let expected = run.spec.outputSize(forNaturalSize: Self.size(run.source["video.dimensions"]?.value) ?? .zero)
        #expect(run.output["video.dimensions"]?.value == "\(Int(expected.width))x\(Int(expected.height))")
    }

    private func expectDolbyVisionSurvives(_ fixture: RealFixture) async throws {
        let run = try await downscaleReal(fixture, dolbyVision: true)
        let before = try #require(run.source["hdr.dolbyVision"])
        #expect(before.value.hasPrefix("profile 8,") && before.value.hasSuffix("compat 4"), "source: \(before.value)")
        let after = try #require(run.output["hdr.dolbyVision"])
        // The level may follow the resolution; the report treats that as changed, never lost.
        #expect(after.value.hasPrefix("profile 8,") && after.value.hasSuffix("compat 4"), "output: \(after.value)")
        #expect(run.output["video.dimensions"]?.value == "1920x1080")
        #expect(run.report.lost.isEmpty, "lost: \(run.report.lost.map(\.key))")
        expectOnlyExpectedChanges(run)
    }

    @Test(.enabled(if: runs(.dolbyVision4K60)), .timeLimit(.minutes(5)))
    func dolbyVisionSurvives4K60() async throws {
        try await expectDolbyVisionSurvives(.dolbyVision4K60)
    }

    @Test(.enabled(if: runs(.dolbyVision4K30)), .timeLimit(.minutes(5)))
    func dolbyVisionSurvives4K30() async throws {
        try await expectDolbyVisionSurvives(.dolbyVision4K30)
    }

    @Test(.enabled(if: runs(.dolbyVision4K30)), .timeLimit(.minutes(5)))
    func iPhoneMetadataSurvives() async throws {
        let run = try await downscaleReal(.dolbyVision4K30, dolbyVision: true)
        let locationKey = "qt.com.apple.quicktime.location.ISO6709"
        let location = try #require(
            run.source[locationKey],
            """
            dv-4k30.mov has no location. Record it again with Location Services on for the Camera app \
            (Settings > Privacy & Security > Location Services > Camera).
            """)
        #expect(run.output[locationKey]?.value == location.value, "location changed or lost")
        let sourceKeys = run.source.items.filter { $0.key.hasPrefix("qt.") }
        for item in sourceKeys {
            let kept = run.output[item.key]
            #expect(kept != nil, "missing in output: \(item.key)")
            #expect(kept?.value == item.value, "\(item.key): \(item.value) -> \(kept?.value ?? "nil")")
        }
    }

    @Test(.enabled(if: runs(.spatialAudio)), .timeLimit(.minutes(5)))
    func spatialAudioPassesThrough() async throws {
        let run = try await downscaleReal(.spatialAudio)
        let audio = run.source.items.filter { $0.key.hasPrefix("audio.") }
        #expect(!audio.isEmpty, "the clip has no audio items")
        for item in audio {
            let got = run.output[item.key]?.value
            #expect(got == item.value, "\(item.key): \(item.value) -> \(got ?? "nil")")
        }
        expectOnlyExpectedChanges(run)
    }

    /// The stereo check runs before the size check, so the default 1080 target cannot mask the refusal.
    @Test(.enabled(if: runs(.spatialVideo)), .timeLimit(.minutes(5)))
    func spatialVideoIsRefused() async throws {
        let source = try clip(.spatialVideo)
        let output = try outputURL()
        await #expect(throws: DownscaleError.unsupportedSource("spatial video")) {
            try await VideoDownscaler().downscale(source: source, output: output, spec: DownscaleSpec()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.enabled(if: runs(.sloMo)), .timeLimit(.minutes(5)))
    func sloMoKeepsFrameRate() async throws {
        let run = try await downscaleReal(.sloMo)
        let rate = try #require(run.source["video.frameRate"])
        #expect(run.output["video.frameRate"]?.value == rate.value)
        expectOnlyExpectedChanges(run)
    }

    @Test(.enabled(if: runs(.livePhoto)), .timeLimit(.minutes(5)))
    func livePhotoKeepsContentIdentifier() async throws {
        let run = try await downscaleReal(.livePhoto)
        let key = "qt.com.apple.quicktime.content.identifier"
        let identifier = try #require(run.source[key], "the Live Photo clip has no content identifier")
        #expect(run.output[key]?.value == identifier.value)
        expectOnlyExpectedChanges(run)
    }

    @Test(.enabled(if: runs(.sdr)), .timeLimit(.minutes(5)))
    func sdrClipStaysSDR() async throws {
        let run = try await downscaleReal(.sdr)
        let transfer = try #require(run.source["video.transferFunction"])
        #expect(run.output["video.transferFunction"]?.value == transfer.value)
        #expect(run.output["hdr.dolbyVision"] == nil)
        #expect(run.report.lost.isEmpty, "lost: \(run.report.lost.map(\.key))")
        expectOnlyExpectedChanges(run)
    }

    /// Records what a Cinematic clip keeps and loses; the printed lists feed ADR 0001. Losses are not asserted.
    @Test(.enabled(if: runs(.cinematic)), .timeLimit(.minutes(5)))
    func cinematicReportsLosses() async throws {
        let run = try await downscaleReal(.cinematic)
        #expect(FileManager.default.fileExists(atPath: run.outputURL.path))
        let report = run.report
        print("cinematic lost (\(report.lost.count)): \(report.lost.map { "\($0.key) [\($0.displayName)]" })")
        let trackPrefixes = ["timed.", "track.", "trackmeta."]
        let kept = report.kept.filter { item in trackPrefixes.contains { item.key.hasPrefix($0) } }
        print("cinematic kept tracks (\(kept.count)): \(kept.map { "\($0.key) = \($0.value)" })")
        let changed = report.changed.map { "\($0.key): \($0.from) -> \($0.to)" }
        print("cinematic changed (\(changed.count)): \(changed)")
        expectOnlyExpectedChanges(run)
    }
}

/// The gate's target-size rule, checked without clips.
@Suite struct RealClipGateTargetTests {
    @Test(arguments: [(2160, 720), (1080, 720), (721, 720), (720, 360), (480, 240), (362, 180)])
    func nonDolbyVisionTargetIsBelowShortSide(shortSide: Int, target: Int) {
        #expect(RealClipGateTests.nonDolbyVisionTarget(shortSide: shortSide) == target)
        #expect(target < shortSide && target % 2 == 0)
    }

    @Test func dolbyVisionValueParses() throws {
        let parts = try #require(RealClipGateTests.dolbyVisionParts("profile 8, level 4, compat 4"))
        #expect(parts.profile == 8 && parts.level == 4 && parts.compat == 4)
        #expect(RealClipGateTests.dolbyVisionParts("present") == nil)
    }
}
