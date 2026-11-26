import AppCore
import Foundation
import MediaEngine
import MediaTestSupport
import Synchronization
import Testing

@testable import DownscaleVideo

@Suite struct RunnerTests {
    private func makeSource(name: String = "x.mov") async throws -> URL {
        try await RunnerFixture.source(name: name)
    }

    private func job(_ source: URL, _ settings: DownscaleJobSettings) throws -> Job {
        try RunnerFixture.job(source, settings)
    }

    private let spec = RunnerFixture.spec

    @Test func descriptorMatchesTheRuling() {
        #expect(DownscaleTool.toolID == "downscale-video")
        #expect(DownscaleTool.descriptor.name == "Downscale Video")
        #expect(DownscaleTool.descriptor.symbol == "arrow.down.right.and.arrow.up.left")
        #expect(DownscaleTool.descriptor.category == .video)
    }

    @Test(.timeLimit(.minutes(5))) func runnerNextToOriginalNamesAndReports() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seen = Mutex(0.0)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await RunnerFixture.runner().run(try job(source, settings)) { value in
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
        #expect(outcome.isVerified)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".partial-") })
    }

    @Test(.timeLimit(.minutes(5))) func existingOutputGetsNextName() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taken = directory.appending(path: "x (1080p).mov")
        try Data("mine".utf8).write(to: taken)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        let state = try await RunnerFixture.runner().run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(outcome.output.lastPathComponent == "x (1080p) 2.mov")
        #expect(try Data(contentsOf: taken) == Data("mine".utf8))
    }

    @Test(.timeLimit(.minutes(5))) func staleOwnPartialsAreRemovedOthersKept() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appending(path: ".x (1080p).mov.partial-\(UUID().uuidString)")
        let other = directory.appending(path: ".y (1080p).mov.partial-\(UUID().uuidString)")
        try Data("a".utf8).write(to: stale)
        try Data("b".utf8).write(to: other)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: spec)

        _ = try await RunnerFixture.runner().run(try job(source, settings)) { _ in }

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test(.timeLimit(.minutes(5))) func folderDestinationWritesThere() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        let folder = directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try folder.bookmarkData()
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .folder(bookmark: bookmark), custom: spec)

        let state = try await RunnerFixture.runner().run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(
            outcome.output.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }

    @Test(.timeLimit(.minutes(5))) func replaceTrashesOriginalOnlyAfterVerify() async throws {
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

    @Test(.timeLimit(.minutes(5))) func keptAsIsNeverTrashesTheOriginal() async throws {
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
            _ = try await RunnerFixture.runner().run(try job(missing, settings)) { _ in }
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
            _ = try await RunnerFixture.runner().run(try job(file, settings)) { _ in }
            Issue.record("expected a throw")
        } catch let error as DownscaleRunnerError {
            #expect(error == .sourceUnavailable)
        }
    }

    @Test func labelsFollowTheSpec() {
        func label(_ target: Int?, _ preset: Preset, custom: Bool) -> String {
            let spec = DownscaleSpec(targetShortSide: target)
            let settings = DownscaleJobSettings(
                preset: preset, saveTo: .nextToOriginal, custom: custom ? spec : nil)
            return DownscaleRunner.label(for: spec, settings: settings)
        }
        #expect(label(1080, .balanced, custom: false) == "1080p")
        #expect(label(720, .balanced, custom: true) == "720p")
        #expect(label(nil, .high, custom: false) == "High")
        #expect(label(nil, .balanced, custom: false) == "Balanced")
        #expect(label(nil, .smaller, custom: false) == "Smaller")
        #expect(label(nil, .high, custom: true) == "Compressed")
    }

    @Test func verificationRejectsUnexpectedChangesAndLosses() {
        let spec = DownscaleSpec()
        let predicted = MetadataReport()
        let ok = MetadataReport(
            changed: [MetadataChange(key: "video.dimensions", displayName: "d", from: "a", to: "b")])
        #expect(DownscaleRunner.isVerified(ok, predicted: predicted, spec: spec))
        let changed = MetadataReport(
            changed: [MetadataChange(key: "video.bitDepth", displayName: "d", from: "10", to: "8")])
        #expect(!DownscaleRunner.isVerified(changed, predicted: predicted, spec: spec))
        let item = MetadataItem(key: "audio.0.format", category: .audio, displayName: "a", value: "aac ")
        let lost = MetadataReport(lost: [item])
        #expect(!DownscaleRunner.isVerified(lost, predicted: predicted, spec: spec))
        #expect(DownscaleRunner.isVerified(lost, predicted: lost, spec: spec))
    }

    @Test(.timeLimit(.minutes(5))) func replaceWithUnverifiedOutputNeverTrashes() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Mutex(false)
        // The output reads back with a bit depth that differs from the 8-bit source, audio intact: only the
        // unexpected change makes it unverified.
        let runner = DownscaleRunner(
            trash: { url in
                called.withLock { $0 = true }
                return url
            },
            inspect: { url in
                var inventory = try await MediaInspector().inventory(of: url)
                inventory.items = inventory.items.map {
                    $0.key == "video.bitDepth"
                        ? MetadataItem(key: $0.key, category: $0.category, displayName: $0.displayName, value: "10")
                        : $0
                }
                return inventory
            },
            diskSpace: RunnerFixture.roomy)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(!outcome.replacedOriginal)
        #expect(!called.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
        #expect(outcome.output != source)
        #expect(outcome.report.lost.isEmpty)
        #expect(outcome.report.changed.contains { $0.key == "video.bitDepth" })
        // Decided once, by the runner: the unexpected change is a warning, and so is the original being kept.
        #expect(!outcome.isVerified)
        #expect(outcome.warnings.contains("Bit depth changed from 8 to 10"))
        #expect(outcome.warnings.contains("The original was kept because the copy couldn't be verified"))
    }

    @Test(.timeLimit(.minutes(5))) func failedTrashKeepsBothFiles() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        struct Refused: Error {}
        let called = Mutex(false)
        let runner = DownscaleRunner(
            trash: { _ in
                called.withLock { $0 = true }
                throw Refused()
            },
            diskSpace: RunnerFixture.roomy)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try job(source, settings)) { _ in }

        guard case .completed(let outcome) = state else {
            Issue.record("expected completed, got \(state)")
            return
        }
        #expect(called.withLock { $0 })
        #expect(!outcome.replacedOriginal)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(outcome.output.lastPathComponent == "x (1080p).mov")
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
    }

    @Test(.timeLimit(.minutes(5))) func customSpecSavingTooLittleIsKeptAsIs() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A 100 Mbps target estimates far above the source size.
        let custom = DownscaleSpec(targetShortSide: 1080, averageBitRate: 100_000_000)
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: custom)

        let state = try await RunnerFixture.runner().run(try job(source, settings)) { _ in }

        #expect(state == .keptAsIs(reason: "Would save less than 10%"))
    }

    @Test(.timeLimit(.minutes(5))) func outputNotSmallEnoughIsRemovedAndKeptAsIs() async throws {
        let source = try await makeSource()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let called = Mutex(false)
        // Make the finished output look as big as the original.
        let runner = DownscaleRunner(
            trash: { url in
                called.withLock { $0 = true }
                return url
            },
            sizeOf: { url in try DownscaleRunner.fileSize(url.lastPathComponent.hasPrefix("x (") ? source : url) })
        let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: spec)

        let state = try await runner.run(try job(source, settings)) { _ in }

        #expect(state == .keptAsIs(reason: "Would save less than 10%"))
        #expect(!called.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: source.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == [source.lastPathComponent])
    }
}
