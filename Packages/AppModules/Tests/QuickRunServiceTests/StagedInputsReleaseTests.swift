import AppCore
import Foundation
import MediaEngine
import Testing

@testable import QuickRunService

@Suite struct StagedInputsReleaseTests {
    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func makeJob(_ source: URL, _ state: JobState) -> Job {
        Job(toolID: "t", source: source, sourceBookmark: Data(), settings: Data(), state: state)
    }

    @Test func anOutputNextToACopySurvivesRemoveAndSweep() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let copy = try staged.stage(name: "clip.mov", data: Data("c".utf8))
        let output = copy.deletingLastPathComponent().appending(path: "clip (1080p).mov")
        try Data("o".utf8).write(to: output)

        // A folder holding more than its copy is left alone, copy included.
        staged.sweep(keeping: [URL]())
        #expect(exists(output))
        #expect(exists(copy))

        // Removing the copy takes only the copy.
        staged.remove(copy)
        #expect(!exists(copy))
        #expect(exists(output))
        #expect(exists(output.deletingLastPathComponent()))
    }

    @Test func aFolderHoldingOnlyTheCopyIsRemovedBySweepAndRemove() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let swept = try staged.stage(name: "a.mov", data: Data("a".utf8))
        staged.sweep(keeping: [URL]())
        #expect(!exists(swept))
        #expect(!exists(swept.deletingLastPathComponent()))

        let removed = try staged.stage(name: "b.mov", data: Data("b".utf8))
        staged.remove(removed)
        #expect(!exists(removed.deletingLastPathComponent()))
    }

    @Test func aFailedJobKeepsItsCopyForRetryUntilItIsRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let copy = try staged.stage(name: "a.mov", data: Data("a".utf8))

        var watching = staged.release(watching: [copy], jobs: [makeJob(copy, .failed(reason: "disk full"))])
        #expect(watching == [copy])
        #expect(exists(copy))

        // Retry puts it back in the queue: still needed.
        watching = staged.release(watching: watching, jobs: [makeJob(copy, .queued)])
        #expect(exists(copy))

        // The failed job is taken out of the queue.
        watching = staged.release(watching: watching, jobs: [])
        #expect(watching.isEmpty)
        #expect(!exists(copy))
    }

    @Test func aCompletedKeptAsIsOrCancelledJobReleasesItsCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let completed = try staged.stage(name: "a.mov", data: Data("a".utf8))
        let keptAsIs = try staged.stage(name: "b.mov", data: Data("b".utf8))
        let cancelled = try staged.stage(name: "c.mov", data: Data("c".utf8))
        let running = try staged.stage(name: "d.mov", data: Data("d".utf8))
        let outcome = JobOutcome(
            output: URL(filePath: "/out.mov"), bytesBefore: 2, bytesAfter: 1, report: MetadataReport(),
            replacedOriginal: false)

        let watching = staged.release(
            watching: [completed, keptAsIs, cancelled, running],
            jobs: [
                makeJob(completed, .completed(outcome)), makeJob(keptAsIs, .keptAsIs(reason: "small")),
                makeJob(running, .running(progress: 0.5)),
            ])

        #expect(watching == [running])
        #expect(!exists(completed))
        #expect(!exists(keptAsIs))
        #expect(!exists(cancelled))
        #expect(exists(running))
    }

    @Test func aSweepKeepsTheCopyOfAFailedJob() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = StagedInputs(directory: directory)
        let failed = try staged.stage(name: "a.mov", data: Data("a".utf8))
        let jobs = [makeJob(failed, .failed(reason: "x"))]

        staged.sweep(keeping: jobs.filter(StagedInputs.isNeeded(by:)).map(\.source))

        #expect(exists(failed))
    }
}
