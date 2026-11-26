import AVFoundation
import CoreMedia
import Foundation
import MediaTestSupport
import Testing

@testable import MediaEngine

/// How the engine behaves on input that isn't a tidy constant-rate clip: damaged files and variable frame rate.
/// (Cancellation mid-encode is `VideoDownscalerTests.cancelRemovesPartialOutput`; a full disk is
/// `DiskSpacePreflightTests` in DownscaleVideoTests, where the free-space rule lives.)
@Suite struct EngineRobustnessTests {
    private let spec = DownscaleSpec(targetShortSide: 360, averageBitRate: 2_000_000)

    private func options(_ configure: (inout ClipOptions) -> Void = { _ in }) -> ClipOptions {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.hdr = .sdr
        configure(&options)
        return options
    }

    private func expectNothingLeftBeside(_ output: URL, source: URL) throws {
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains(".partial-") }, "leaked: \(names)")
        #expect(names.contains(source.lastPathComponent), "the source must still be there")
    }

    private func failsCleanly(_ source: URL) async throws {
        let output = source.deletingLastPathComponent().appending(path: "output.mov")
        let before = try Data(contentsOf: source)
        await #expect(throws: (any Error).self) {
            try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }
        }
        try expectNothingLeftBeside(output, source: source)
        #expect(try Data(contentsOf: source) == before, "the input is never touched")
    }

    // MARK: - Corrupted input

    @Test(.timeLimit(.minutes(2))) func aFileThatIsNotAVideoFailsWithoutOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "garbage.mov")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: source)
        try await failsCleanly(source)
    }

    @Test(.timeLimit(.minutes(2))) func anEmptyFileFailsWithoutOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "empty.mov")
        try Data().write(to: source)
        try await failsCleanly(source)
    }

    @Test(.timeLimit(.minutes(2))) func aTruncatedClipFailsWithoutOutput() async throws {
        let clip = try await FixtureFactory.makeClip(options { $0.seconds = 2 })
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        // The writer puts the index (moov) after the media, so cutting the file in half loses it: what an
        // interrupted copy or download leaves.
        let whole = try Data(contentsOf: clip)
        try whole.prefix(whole.count / 2).write(to: clip)
        try await failsCleanly(clip)
    }

    @Test(.timeLimit(.minutes(2))) func aDamagedMiddleNeverYieldsAKeptOutputThatLooksComplete() async throws {
        let clip = try await FixtureFactory.makeClip(options { $0.seconds = 2 })
        let directory = clip.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Overwrite a stretch of media with noise; the index is intact, so the file opens.
        var data = try Data(contentsOf: clip)
        let start = data.count / 3
        for index in start..<(start + 20_000) { data[index] = UInt8(truncatingIfNeeded: index &* 131) }
        try data.write(to: clip)
        let output = directory.appending(path: "output.mov")

        do {
            try await VideoDownscaler().downscale(source: clip, output: output, spec: spec) { _ in }
            // Decoders conceal damage, so finishing is allowed; then the file must be a whole, readable video.
            let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.timeRange).duration.seconds > 0)
        } catch {
            // Failing is allowed too; but then nothing is left behind.
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".partial-") }, "leaked: \(names)")
        #expect(try Data(contentsOf: clip) == data)
    }

    // MARK: - Variable frame rate

    private func presentationTimes(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            // Skip the reader's empty marker buffers (no timestamp).
            if sample.presentationTimeStamp.isNumeric { times.append(sample.presentationTimeStamp.seconds) }
        }
        return times.sorted()
    }

    @Test(.timeLimit(.minutes(2))) func variableFrameRateKeepsEveryFrameAndItsTiming() async throws {
        let source = try await FixtureFactory.makeClip(
            options {
                $0.fps = 10
                $0.seconds = 3
                $0.variableFrameRate = true
            })
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "output.mov")

        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { _ in }

        let input = try await presentationTimes(of: source)
        let result = try await presentationTimes(of: output)
        // The fixture really has uneven gaps.
        let gaps = zip(input, input.dropFirst()).map { $1 - $0 }
        #expect(Set(gaps.map { ($0 * 1000).rounded() }).count > 1, "the fixture must be variable: \(gaps)")
        // Every frame survives (no dropping, no duplicating), at the time it had.
        #expect(result.count == input.count)
        for (before, after) in zip(input, result) {
            #expect(abs(before - after) < 0.002, "frame at \(before) moved to \(after)")
        }
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let outputDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(outputDuration - sourceDuration) < 0.15, "\(outputDuration) vs \(sourceDuration)")
    }

    @Test(.timeLimit(.minutes(2))) func variableFrameRateWithAFrameRateCapStillKeepsTheDuration() async throws {
        let source = try await FixtureFactory.makeClip(
            options {
                $0.fps = 30
                $0.seconds = 2
                $0.variableFrameRate = true
            })
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "output.mov")
        var capped = spec
        capped.maxFrameRate = 15

        try await VideoDownscaler().downscale(source: source, output: output, spec: capped) { _ in }

        let input = try await presentationTimes(of: source)
        let result = try await presentationTimes(of: output)
        #expect(result.count < input.count)
        #expect(result.count >= input.count / 2 - 2, "dropped far more than the cap needs: \(result.count)")
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let outputDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(outputDuration - sourceDuration) < 0.15, "\(outputDuration) vs \(sourceDuration)")
    }
}
