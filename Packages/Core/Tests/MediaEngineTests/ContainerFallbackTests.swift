import AVFoundation
import AppCore
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

/// An MPEG-4 source written as QuickTime (because MPEG-4 can't carry one of its tracks) loses its ISO user data
/// items: QuickTime has no such key space. The loss is known before the run.
@Suite struct ContainerFallbackTests {
    private static let spec = DownscaleSpec(targetShortSide: 360, averageBitRate: 500_000)

    private func clip(_ fileType: AVFileType, timedMetadata: Bool = false) async throws -> URL {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.fps = 10
        options.hdr = .sdr
        options.fileType = fileType
        options.includeTimedMetadataTrack = timedMetadata
        // The MPEG-4 writer stores these as ISO user data (`uiso/loci`, `uiso/date`, `uiso/auth`, ...).
        options.quickTimeMetadata = [
            "com.apple.quicktime.location.ISO6709": "+37.3349-122.0090+010.000/",
            "com.apple.quicktime.creationdate": "2026-11-25T10:00:00+0000",
            "com.apple.quicktime.make": "Apple",
            "com.apple.quicktime.author": "Someone",
            "com.apple.quicktime.title": "Title",
        ]
        return try await FixtureFactory.makeClip(options)
    }

    // Full software-HEVC re-encode: too slow on the Simulator, whose encoder is not representative (a smoke encode stays).
    @Test(
        .timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative),
        arguments: [AVFileType.mp4, .m4v])
    func quickTimeOutputOfAnMPEG4SourceLosesExactlyThePredictedItems(_ fileType: AVFileType) async throws {
        let source = try await clip(fileType)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let inventory = try await MediaInspector().inventory(of: source)
        let output = source.deletingLastPathComponent().appending(path: "out.mov")

        try await VideoDownscaler().downscale(source: source, output: output, spec: Self.spec) { _ in }

        let report = MetadataDiff.report(source: inventory, output: try await MediaInspector().inventory(of: output))
        let predicted = OutputContainer.lostInQuickTimeFallback(inventory)
        #expect(predicted.contains { $0.key == "qt.uiso/loci" })
        #expect(Set(report.lost.map(\.key)) == Set(predicted.map(\.key)))
    }

    @Test(.timeLimit(.minutes(5))) func sameContainerOutputLosesNothing() async throws {
        let source = try await clip(.mp4)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let inventory = try await MediaInspector().inventory(of: source)
        let output = source.deletingLastPathComponent().appending(path: "out.mp4")

        try await VideoDownscaler().downscale(source: source, output: output, spec: Self.spec) { _ in }

        let report = MetadataDiff.report(source: inventory, output: try await MediaInspector().inventory(of: output))
        #expect(report.lost.isEmpty)
    }

    // Full software-HEVC re-encode: too slow on the Simulator, whose encoder is not representative (a smoke encode stays).
    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func decisionSaysWhenAnMPEG4SourceFallsBackToQuickTime() async throws {
        // The M4V writer refuses timed metadata, so this is an MPEG-4 file with one, named .m4v.
        let written = try await clip(.mp4, timedMetadata: true)
        let m4v = written.deletingPathExtension().appendingPathExtension("m4v")
        try FileManager.default.moveItem(at: written, to: m4v)
        let mp4 = try await clip(.mp4)
        let mov = try await clip(.mov, timedMetadata: true)
        defer {
            for url in [m4v, mp4, mov] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }

        #expect(
            try await OutputContainer.decide(for: m4v)
                == .init(pathExtension: "mov", fallsBackToQuickTime: true))
        #expect(
            try await OutputContainer.decide(for: mp4)
                == .init(pathExtension: "mp4", fallsBackToQuickTime: false))
        #expect(
            try await OutputContainer.decide(for: mov)
                == .init(pathExtension: "mov", fallsBackToQuickTime: false))
    }

    // Full software-HEVC re-encode: too slow on the Simulator, whose encoder is not representative (a smoke encode stays).
    @Test(.timeLimit(.minutes(5)), .enabled(if: EncoderEnvironment.isRepresentative))
    func isoUserDataItemsHaveReadableNames() async throws {
        let source = try await clip(.mp4)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let inventory = try await MediaInspector().inventory(of: source)

        #expect(inventory["qt.uiso/loci"]?.displayName == "Location")
        #expect(inventory["qt.uiso/loci"]?.category == .location)
        #expect(inventory["qt.uiso/date"]?.displayName == "Creation date")
        #expect(inventory["qt.uiso/date"]?.category == .date)
        #expect(inventory["qt.uiso/auth"]?.displayName == "Author")
    }

    @Test func onlyISOUserDataIsPredictedLost() {
        let items = [
            MetadataItem(key: "qt.uiso/loci", category: .location, displayName: "Location", value: "+1+2/"),
            MetadataItem(key: "qt.itsk/©mak", category: .other, displayName: "©mak", value: "Apple"),
            MetadataItem(key: "video.codec", category: .video, displayName: "Codec", value: "hvc1"),
        ]
        #expect(OutputContainer.lostInQuickTimeFallback(MetadataInventory(items: items)).map(\.key) == ["qt.uiso/loci"])
    }
}
