import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import Testing

@testable import DownscaleVideo

@Suite struct RunnerTests {
    /// 2560x1440 so a 1080 short side really shrinks it; small and fast.
    private func makeSource(name: String = "x.mov") async throws -> URL {
        var options = ClipOptions()
        options.width = 2560
        options.height = 1440
        options.fps = 10
        options.hdr = .sdr
        let clip = try await FixtureFactory.makeClip(options)
        let renamed = clip.deletingLastPathComponent().appending(path: name)
        try FileManager.default.moveItem(at: clip, to: renamed)
        return renamed
    }

    private func job(_ source: URL, _ settings: DownscaleJobSettings) throws -> Job {
        Job(
            toolID: DownscaleTool.toolID, source: source, sourceBookmark: Data(),
            settings: try JSONEncoder().encode(settings))
    }

    private let spec = DownscaleSpec(targetShortSide: 1080, averageBitRate: 2_000_000)

    @Test func descriptorMatchesTheRuling() {
        #expect(DownscaleTool.toolID == "downscale-video")
        #expect(DownscaleTool.descriptor.name == "Downscale Video")
        #expect(DownscaleTool.descriptor.symbol == "arrow.down.right.and.arrow.up.left")
        #expect(DownscaleTool.descriptor.category == .video)
    }

    @Test(.timeLimit(.minutes(2))) func runnerNextToOriginalNamesAndReports() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = Mutex(0.0)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await DownscaleRunner().run(try job(source, settings)) { value in
            seen.withLock { $0 = max($0, value) }
        }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output == directory.appending(path: "x (1080p).mov"))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(outcome.bytesBefore > 0 && outcome.bytesAfter > 0)
        #expect(!outcome.replacedOriginal)
        #expect(seen.withLock { $0 } > 0)
        #expect(outcome.report.lost.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".partial-") })
    }

    @Test(.timeLimit(.minutes(2))) func existingOutputGetsNextName() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = directory.appending(path: "x (1080p).mov")
        try Data("mine".utf8).write(to: taken)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await DownscaleRunner().run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "x (1080p) 2.mov")
        #expect(try Data(contentsOf: taken) == Data("mine".utf8))
    }

    @Test(.timeLimit(.minutes(2))) func staleOwnPartialsAreRemovedOthersKept() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appending(path: ".x (1080p).mov.partial-\(UUID().uuidString)")
        let other = directory.appending(path: ".y (1080p).mov.partial-\(UUID().uuidString)")
        try Data("a".utf8).write(to: stale)
        try Data("b".utf8).write(to: other)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        _ = try await DownscaleRunner().run(try job(source, settings)) { _ in }

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test(.timeLimit(.minutes(2))) func folderDestinationWritesThere() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        let folder = directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try folder.bookmarkData()
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .folder(bookmark: bookmark), custom: spec)

        let state = try await DownscaleRunner().run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(
            outcome.output.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }

    @Test(.timeLimit(.minutes(2))) func replaceTrashesOriginalOnlyAfterVerify() async throws {
        let source = try await makeSource(name: "replace-\(UUID().uuidString).mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trashed = Mutex<URL?>(nil)
        let runner = DownscaleRunner { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            let resulting = (result as URL?) ?? url
            trashed.withLock { $0 = resulting }
            return resulting
        }
        defer { trashed.withLock { $0 }.map { try? FileManager.default.removeItem(at: $0) } }
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.replacedOriginal)
        #expect(outcome.output == source)
        // The file at the original path is now the converted one, and the original is in the Trash.
        let size = try #require(FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64)
        #expect(size == outcome.bytesAfter)
        let trashedURL = try #require(trashed.withLock { $0 })
        let trashedSize = try #require(
            FileManager.default.attributesOfItem(atPath: trashedURL.path)[.size] as? Int64)
        #expect(trashedSize == outcome.bytesBefore)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == [source.lastPathComponent])
    }

    @Test(.timeLimit(.minutes(2))) func keptAsIsNeverTrashesTheOriginal() async throws {
        // A replace job that ends Kept As Is must never touch the Trash.
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Mutex(false)
        let runner = DownscaleRunner { url in
            called.withLock { $0 = true }
            return url
        }
        // A target above the source short side makes the downscaler refuse: already small.
        let settings = DownscaleJobSettings(
            preset: .balanced, saveTo: .replace, custom: DownscaleSpec(targetShortSide: 2000, averageBitRate: 2_000_000)
        )

        let state = try await runner.run(try job(source, settings)) { _ in }

        #expect(state == .keptAsIs(reason: "Already small"))
        #expect(!called.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func missingSourceFails() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal)
        do {
            _ = try await DownscaleRunner().run(try job(missing, settings)) { _ in }
            Issue.record("expected a throw")
        } catch let error as LocalizedError {
            #expect(error.errorDescription == "Original file is missing or the drive isn't connected")
        }
    }

    @Test func sourceInsideATrashFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "\(UUID().uuidString)/.Trashes/501", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent())
        }
        let file = directory.appending(path: "a.mov")
        try Data("x".utf8).write(to: file)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal)
        do {
            _ = try await DownscaleRunner().run(try job(file, settings)) { _ in }
            Issue.record("expected a throw")
        } catch let error as DownscaleRunnerError {
            #expect(error == .sourceUnavailable)
        }
    }

    @Test func labelsFollowTheSpec() {
        #expect(DownscaleRunner.label(for: DownscaleSpec(targetShortSide: 1080)) == "1080p")
        #expect(DownscaleRunner.label(for: DownscaleSpec(targetShortSide: 720)) == "720p")
        #expect(DownscaleRunner.label(for: DownscaleSpec(targetShortSide: nil)) == "High")
    }
}
