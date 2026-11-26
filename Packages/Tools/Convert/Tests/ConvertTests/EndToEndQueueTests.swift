import AarikCore
import Foundation
import Testing

@testable import Convert

/// The app's path without the UI: real jobs from `JobFactory`, the real queue and the real runner, on two
/// generated clips. One converts, one is kept as is.
@Suite struct EndToEndQueueTests {
    @Test(.timeLimit(.minutes(3))) func queueConvertsOneAndKeepsOneAsIs() async throws {
        let big = try await RunnerFixture.source(name: "big.mov")
        let small = try await RunnerFixture.smallSource(name: "small.mov")
        let storeDirectory = FileManager.default.temporaryDirectory.appending(path: "e2e-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: big.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: small.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        let queue = JobQueue(
            store: JobStore(directory: storeDirectory), runners: [ConvertTool.toolID: RunnerFixture.runner()])
        // The generated clips are a second long, too short for a preset's estimate to promise a 10% saving, so the
        // jobs carry the runner tests' custom spec: a 1080p downscale. The 640x360 clip is already below it.
        let settings = ConvertJobSettings(preset: .balanced, saveTo: .nextToOriginal, custom: RunnerFixture.spec)
        let jobs = JobFactory.makeJobs(for: [big, small], settings: settings).jobs
        var tracker = QueueRunTracker()
        #expect(tracker.observe(await queue.jobs) == nil)

        #expect(await queue.enqueue(jobs).count == 2)
        // Adding the same files again while they wait or run adds nothing.
        #expect(await queue.enqueue(JobFactory.makeJobs(for: [big, small], settings: settings).jobs).isEmpty)

        var summary: QueueRunSummary?
        var final: [Job] = []
        for await snapshot in await queue.updates() {
            if let finished = tracker.observe(snapshot) {
                summary = finished
                final = snapshot
                break
            }
        }
        await queue.shutdown()

        #expect(summary?.converted == 1)
        #expect(summary?.keptAsIs == 1)
        #expect(summary?.failed == 0)
        guard case .completed(let outcome) = final.first(where: { $0.source == big })?.state else {
            Issue.record("big clip did not convert: \(final)")
            return
        }
        #expect(outcome.isVerified)
        #expect(outcome.bytesAfter < outcome.bytesBefore)
        #expect(outcome.output.lastPathComponent == "big (1080p).mov")
        #expect(FileManager.default.fileExists(atPath: big.path))
        #expect(
            final.first(where: { $0.source == small })?.state == .keptAsIs(reason: "Already small", code: .alreadySmall)
        )
        let activity = ActivitySummary(jobs: final)
        #expect(activity.completed == 1 && activity.keptAsIs == 1 && activity.queue == 0)
        #expect(activity.savedBytes == outcome.bytesBefore - outcome.bytesAfter)
        #expect(summary?.savedBytes == activity.savedBytes)
    }
}
