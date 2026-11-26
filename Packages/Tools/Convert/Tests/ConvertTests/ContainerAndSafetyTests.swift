import AVFoundation
import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import Testing

@testable import DownscaleVideo

/// The output container follows the source, slo-mo keeps its frame rate, and a Replace never trashes an original
/// that changed or a job that was cancelled.
@Suite struct ContainerAndSafetyTests {
    /// Whether the runner asked to trash something.
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    private let spec = RunnerFixture.spec

    /// A runner whose trash moves the file into the test's directory and records that it was asked to.
    private func trashingRunner(
        into directory: URL, called: Flag,
        inspect: @escaping @Sendable (URL) async throws -> MetadataInventory = {
            try await MediaInspector().inventory(of: $0)
        }
    ) -> DownscaleRunner {
        DownscaleRunner(
            trash: { url in
                called.set()
                let trashed = directory.appending(path: "trashed-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: trashed)
                return trashed
            }, inspect: inspect,
            diskSpace: RunnerFixture.roomy)
    }

    @Test(.timeLimit(.minutes(5))) func mp4SourceGivesARealMP4WithAnMP4Name() async throws {
        let source = try await RunnerFixture.source(name: "x.mp4", fileType: .mp4)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "x (1080p).mp4")
        #expect(["mp42", "isom"].contains(try RunnerFixture.majorBrand(outcome.output)))
        #expect(outcome.isVerified)
    }

    @Test(.timeLimit(.minutes(5))) func replacingAnMP4KeepsItsName() async throws {
        let source = try await RunnerFixture.source(name: "x.mp4", fileType: .mp4)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Flag()
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await trashingRunner(into: directory, called: called).run(
            try RunnerFixture.job(source, settings)
        ) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.replacedOriginal)
        #expect(outcome.output == source)
        #expect(["mp42", "isom"].contains(try RunnerFixture.majorBrand(source)))
    }

    @Test(.timeLimit(.minutes(5))) func trackTheSourceContainerCantCarryMakesAQuickTimeOutput() async throws {
        // An MPEG-4 file named .m4v with a timed metadata track, which the M4V container refuses.
        let source = try await RunnerFixture.source(name: "x.m4v", fileType: .mp4, timedMetadata: true)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await OutputContainer.pathExtension(forSource: source) == "mov")
        let called = Flag()
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await trashingRunner(into: directory, called: called).run(
            try RunnerFixture.job(source, settings)
        ) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(try RunnerFixture.majorBrand(outcome.output) == "qt  ")
        #expect(outcome.report.lost.isEmpty)
        // The original's name with the new container's extension; the original itself is gone (trashed).
        #expect(outcome.replacedOriginal)
        #expect(outcome.output.lastPathComponent == "x.mov")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func containerFollowsTheExtension() {
        #expect(OutputContainer.fileType(for: URL(filePath: "/a/b.MP4")) == .mp4)
        #expect(OutputContainer.fileType(for: URL(filePath: "/a/b.m4v")) == .m4v)
        #expect(OutputContainer.fileType(for: URL(filePath: "/a/b.mov")) == .mov)
        let mp4 = URL(filePath: "/a/IMG_1.mp4")
        let mov = URL(filePath: "/a/IMG_1 (1080p).mov")
        #expect(DownscaleRunner.replacementURL(for: mp4, output: mov).path == "/a/IMG_1.mov")
        #expect(DownscaleRunner.replacementURL(for: mp4, output: URL(filePath: "/a/IMG_1 (1080p).mp4")) == mp4)
    }

    @Test(.timeLimit(.minutes(5))) func sloMoKeepsItsFrameRateWhateverTheCap() async throws {
        var options = ClipOptions()
        options.width = 1280
        options.height = 720
        options.fps = 120
        options.hdr = .sdr
        options.videoBitRate = 8_000_000
        let source = try await FixtureFactory.makeClip(options)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let custom = DownscaleSpec(targetShortSide: 360, averageBitRate: 500_000, maxFrameRate: 30)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: custom)

        let state = try await RunnerFixture.runner().run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        let before = try await MediaInspector().inventory(of: source)["video.frameRate"]?.value
        let after = try await MediaInspector().inventory(of: outcome.output)["video.frameRate"]?.value
        #expect(after == before)
        #expect(!outcome.report.changed.contains { $0.key == "video.frameRate" })
        #expect(outcome.isVerified)
    }

    @Test(.timeLimit(.minutes(5))) func originalReplacedDuringConversionIsNotTrashed() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Flag()
        // Someone saves a new file over the original while it converts.
        let runner = trashingRunner(into: directory, called: called) { url in
            try Data("someone else's file".utf8).write(to: source, options: .atomic)
            return try await MediaInspector().inventory(of: url)
        }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(!outcome.replacedOriginal)
        #expect(!called.isSet)
        #expect(outcome.warnings.contains("The original changed during conversion"))
        #expect(try Data(contentsOf: source) == Data("someone else's file".utf8))
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
    }

    @Test(.timeLimit(.minutes(5))) func originalGrownDuringConversionIsNotTrashed() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Flag()
        let runner = trashingRunner(into: directory, called: called) { url in
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: 16))
            try handle.close()
            return try await MediaInspector().inventory(of: url)
        }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(!outcome.replacedOriginal)
        #expect(!called.isSet)
        #expect(outcome.warnings == ["The original changed during conversion"])
        #expect(outcome.warningCodes == [.originalChangedDuringConversion])
    }

    @Test(.timeLimit(.minutes(5))) func cancelledAfterTheOutputIsWrittenRemovesItAndKeepsTheOriginal() async throws {
        let source = try await RunnerFixture.source()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Flag()
        // The user cancels just as the finished output is being checked.
        let runner = trashingRunner(into: directory, called: called) { url in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaInspector().inventory(of: url)
        }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        await #expect(throws: CancellationError.self) {
            _ = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }
        }
        #expect(!called.isSet)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
    }
}
