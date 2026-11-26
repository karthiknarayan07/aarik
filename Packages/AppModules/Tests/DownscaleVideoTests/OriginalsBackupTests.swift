import AppCore
import Foundation
import MediaEngine
import Synchronization
import Testing

@testable import DownscaleVideo

/// Keep a copy of originals: a Replace copies the original into the backup folder, checks the copy's size, and only
/// then trashes the original. Any problem with the copy leaves the original where it is.
@Suite struct OriginalsBackupTests {
    private let settings = DownscaleJobSettings(preset: .balanced, saveTo: .replace, custom: RunnerFixture.spec)

    /// A stand-in for the Trash: moves the file into `<directory>/Trash` so tests never touch the real one.
    private static func fakeTrash(in directory: URL) -> DownscaleRunner.Trasher {
        { url in
            let trash = directory.appending(path: "Trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func completedOutcome(_ state: JobState) -> JobOutcome? {
        if case .completed(let outcome) = state { return outcome }
        Issue.record("expected completed, got \(state)")
        return nil
    }

    @Test(.timeLimit(.minutes(2))) func keepOriginalsCopiesBeforeTrash() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let originalSize = try #require(RunnerFixture.size(source))
        let copyAtTrashTime = Mutex<Int64?>(nil)
        let trash = Self.fakeTrash(in: directory)
        let runner = DownscaleRunner(
            trash: { url in
                // The copy is already complete when the original is about to go.
                copyAtTrashTime.withLock { $0 = RunnerFixture.size(backup.appending(path: "clip.mov")) }
                return try trash(url)
            },
            originalsBackup: { OriginalsBackup(folder: backup) },
            diskSpace: RunnerFixture.roomy)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(copyAtTrashTime.withLock { $0 } == originalSize)
        #expect(outcome.replacedOriginal)
        #expect(outcome.isVerified)
        #expect(outcome.output == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path) == ["clip.mov"])
    }

    @Test(.timeLimit(.minutes(2))) func missingBackupFolderNeverTrashes() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // An external drive that isn't connected.
        let backup = directory.appending(path: "Unplugged/Originals", directoryHint: .isDirectory)
        let called = Mutex(false)
        let runner = DownscaleRunner(
            trash: { url in
                called.withLock { $0 = true }
                return url
            },
            originalsBackup: { OriginalsBackup(folder: backup) },
            diskSpace: RunnerFixture.roomy)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(!called.withLock { $0 })
        #expect(!outcome.replacedOriginal)
        #expect(outcome.output != source)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(
            outcome.warnings == [
                "The original was kept because the originals folder is missing or the drive isn't connected"
            ])
    }

    @Test(.timeLimit(.minutes(2))) func takenBackupNameGetsCounterAndIsNeverOverwritten() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let existing = backup.appending(path: "clip.mov")
        try Data("an earlier backup".utf8).write(to: existing)
        let originalSize = try #require(RunnerFixture.size(source))
        let runner = DownscaleRunner(
            trash: Self.fakeTrash(in: directory), originalsBackup: { OriginalsBackup(folder: backup) },
            diskSpace: RunnerFixture.roomy)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(outcome.replacedOriginal)
        #expect(try Data(contentsOf: existing) == Data("an earlier backup".utf8))
        #expect(RunnerFixture.size(backup.appending(path: "clip 2.mov")) == originalSize)
        let names = try FileManager.default.contentsOfDirectory(atPath: backup.path).sorted()
        #expect(names == ["clip 2.mov", "clip.mov"])
    }

    @Test(.timeLimit(.minutes(2))) func backupOfTheWrongSizeNeverTrashes() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let called = Mutex(false)
        // Anything written in the backup folder reads back one byte long: a truncated copy.
        let runner = DownscaleRunner(
            trash: { url in
                called.withLock { $0 = true }
                return url
            },
            sizeOf: { url in
                url.deletingLastPathComponent().lastPathComponent == "Originals" ? 1 : try DownscaleRunner.fileSize(url)
            },
            originalsBackup: { OriginalsBackup(folder: backup) },
            diskSpace: RunnerFixture.roomy)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(!called.withLock { $0 })
        #expect(!outcome.replacedOriginal)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))
        // Only our own unfinished copy is cleaned up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path) == [])
        #expect(outcome.warnings == ["The original was kept because its copy in the originals folder didn't match"])
    }

    @Test(.timeLimit(.minutes(2))) func backupIsOnlyMadeForReplace() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let runner = RunnerFixture.runner(originalsBackup: { OriginalsBackup(folder: backup) })
        let nextTo = DownscaleJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: RunnerFixture.spec)

        let state = try await runner.run(try RunnerFixture.job(source, nextTo)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(!outcome.replacedOriginal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path) == [])
    }

    @Test(.timeLimit(.minutes(2))) func staleBackupPartialsOfThisSourceAreRemovedOthersKept() async throws {
        let source = try await RunnerFixture.source(name: "clip.mov")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appending(path: "Originals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        // Left by a copy interrupted by a crash, and by another source's interrupted copy.
        let stale = backup.appending(path: ".clip.mov.partial-\(UUID().uuidString)")
        let other = backup.appending(path: ".other.mov.partial-\(UUID().uuidString)")
        let lookalike = backup.appending(path: ".clip.mov 2.partial-\(UUID().uuidString)")
        for file in [stale, other, lookalike] { try Data("half".utf8).write(to: file) }
        let runner = DownscaleRunner(
            trash: Self.fakeTrash(in: directory), originalsBackup: { OriginalsBackup(folder: backup) },
            diskSpace: RunnerFixture.roomy)

        let state = try await runner.run(try RunnerFixture.job(source, settings)) { _ in }

        let outcome = try #require(completedOutcome(state))
        #expect(outcome.replacedOriginal)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "clip.mov").path))
    }
}
