import Foundation
import Testing

@testable import AppCore

// MARK: - Helpers

private func makeStore() throws -> (JobStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("JobQueueConcurrencyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (JobStore(directory: dir), dir)
}

private func makeJob(_ name: String) -> Job {
    Job(
        toolID: "fake", source: URL(fileURLWithPath: "/tmp/concurrency-\(name).mov"),
        sourceBookmark: Data(), settings: Data())
}

private func done() -> JobState {
    .completed(
        JobOutcome(
            output: URL(fileURLWithPath: "/tmp/out.mov"), bytesBefore: 10, bytesAfter: 5,
            report: MetadataReport(), replacedOriginal: false))
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

/// A runner whose jobs finish only when the test says so, and that counts how many run at the same moment.
private actor GatedRunner: JobRunner {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var cancelled: [UUID] = []
    private var pending: [UUID: CheckedContinuation<JobState, any Error>] = [:]
    private var early: [UUID: Result<JobState, any Error>] = [:]
    private let startedContinuation: AsyncStream<UUID>.Continuation
    nonisolated let started: AsyncStream<UUID>

    init() {
        (started, startedContinuation) = AsyncStream.makeStream(of: UUID.self)
    }

    func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> JobState {
        active += 1
        maxActive = max(maxActive, active)
        startedContinuation.yield(job.id)
        defer { active -= 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result = early.removeValue(forKey: job.id) {
                    continuation.resume(with: result)
                } else {
                    pending[job.id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(job.id) }
        }
    }

    private func cancel(_ id: UUID) {
        cancelled.append(id)
        finish(id, .failure(CancellationError()))
    }

    func finish(_ id: UUID, _ result: Result<JobState, any Error> = .success(done())) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(with: result)
        } else {
            early[id] = result
        }
    }
}

private func waitUntil(_ queue: JobQueue, _ predicate: @Sendable ([Job]) -> Bool) async {
    for await jobs in await queue.updates() where predicate(jobs) { return }
}

private func isRunning(_ job: Job) -> Bool {
    if case .running = job.state { true } else { false }
}

private func isCompleted(_ job: Job) -> Bool {
    if case .completed = job.state { true } else { false }
}

private func isQueued(_ job: Job) -> Bool { job.state == .queued }

// MARK: - Tests

@Test(.timeLimit(.minutes(1))) func runsUpToTheLimitAtOnceAndReallyOverlaps() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 3)
    let jobs = ["a", "b", "c", "d", "e"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    // Three jobs started and none finished: they run at the same time, in queue order.
    #expect(await starts.next() == jobs[0].id)
    #expect(await starts.next() == jobs[1].id)
    #expect(await starts.next() == jobs[2].id)
    #expect(await runner.active == 3)
    #expect(await queue.jobs.filter(isRunning).map(\.id) == jobs.prefix(3).map(\.id))
    #expect(await queue.jobs.filter(isQueued).map(\.id) == jobs.suffix(2).map(\.id))

    // A finished job lets the next waiting one start, in order.
    await runner.finish(jobs[1].id)
    #expect(await starts.next() == jobs[3].id)
    await runner.finish(jobs[0].id)
    #expect(await starts.next() == jobs[4].id)
    for job in jobs { await runner.finish(job.id) }
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }

    #expect(await runner.maxActive == 3)
    #expect(store.load().allSatisfy(isCompleted))
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func theDefaultStaysOneAtATime() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let jobs = ["a", "b"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    #expect(await starts.next() == jobs[0].id)
    #expect(await queue.jobs.filter(isRunning).count == 1)
    await runner.finish(jobs[0].id)
    #expect(await starts.next() == jobs[1].id)
    await runner.finish(jobs[1].id)
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    #expect(await runner.maxActive == 1)
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func raisingTheLimitStartsWaitingJobsAtOnce() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner])
    let jobs = ["a", "b", "c"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    #expect(await starts.next() == jobs[0].id)
    await queue.setConcurrency(3)
    #expect(await starts.next() == jobs[1].id)
    #expect(await starts.next() == jobs[2].id)
    #expect(await queue.currentConcurrency() == 3)
    for job in jobs { await runner.finish(job.id) }
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func loweringTheLimitNeverStopsRunningJobsAndHoldsBackNewOnes() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 3)
    let jobs = ["a", "b", "c", "d", "e"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    for _ in 0..<3 { _ = await starts.next() }
    await queue.setConcurrency(1)
    #expect(await runner.active == 3)
    #expect(await runner.cancelled.isEmpty)

    // Two finish; one still runs, which fills the lowered limit, so nothing new starts yet.
    await runner.finish(jobs[0].id)
    await runner.finish(jobs[1].id)
    await waitUntil(queue) { $0.filter(isCompleted).count == 2 }
    #expect(await queue.jobs.filter(isRunning).count == 1)
    #expect(await queue.jobs.filter(isQueued).count == 2)
    // The last one running ends: exactly one new job starts.
    await runner.finish(jobs[2].id)
    #expect(await starts.next() == jobs[3].id)
    #expect(await queue.jobs.filter(isRunning).count == 1)
    for job in jobs { await runner.finish(job.id) }
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func cancellingOneRunningJobLeavesTheOthersRunningAndStartsTheNext() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b", "c"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    await queue.cancel(jobs[0].id)
    #expect(await starts.next() == jobs[2].id)

    #expect(await runner.cancelled == [jobs[0].id])
    #expect(await queue.jobs.map(\.id) == [jobs[1].id, jobs[2].id])
    #expect(await queue.jobs.allSatisfy(isRunning))
    #expect(store.load().map(\.id) == [jobs[1].id, jobs[2].id])
    for job in jobs { await runner.finish(job.id) }
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func cancelAllStopsEveryRunningJobAndClearsTheQueue() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b", "c"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    await queue.cancelAll()
    await waitUntil(queue) { $0.isEmpty }

    #expect(Set(await runner.cancelled) == [jobs[0].id, jobs[1].id])
    #expect(store.load().isEmpty)
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func pausingWhileSeveralRunLetsThemFinishAndStartsNothingNew() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b", "c", "d"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    await queue.pause()
    #expect(await runner.active == 2)

    await runner.finish(jobs[0].id)
    await runner.finish(jobs[1].id)
    await waitUntil(queue) { $0.filter(isCompleted).count == 2 }
    #expect(await queue.jobs.filter(isQueued).map(\.id) == jobs.suffix(2).map(\.id))
    #expect(await runner.active == 0)

    await queue.resume()
    #expect(await starts.next() == jobs[2].id)
    #expect(await starts.next() == jobs[3].id)
    for job in jobs { await runner.finish(job.id) }
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func automaticHoldWithSeveralRunningStartsNothingUntilLifted() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b", "c"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    await queue.setAutomaticHold(true)
    await runner.finish(jobs[0].id)
    await runner.finish(jobs[1].id)
    await waitUntil(queue) { $0.filter(isCompleted).count == 2 }
    #expect(await queue.jobs.filter(isQueued).map(\.id) == [jobs[2].id])

    await queue.setAutomaticHold(false)
    #expect(await starts.next() == jobs[2].id)
    await runner.finish(jobs[2].id)
    await waitUntil(queue) { $0.allSatisfy(isCompleted) }
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func quittingPutsEveryRunningJobAndTheRestBackInTheQueue() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 3)
    let jobs = ["a", "b", "c", "d"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    for _ in 0..<3 { _ = await starts.next() }
    await queue.shutdown()

    #expect(await runner.active == 0)
    #expect(store.load().map(\.id) == jobs.map(\.id))
    #expect(store.load().allSatisfy(isQueued))
    #expect(await queue.jobs.allSatisfy(isQueued))
    let relaunched = JobQueue(store: store, runners: ["fake": GatedRunner()], startPaused: true)
    #expect(await relaunched.jobs.allSatisfy(isQueued))
    #expect(await relaunched.jobs.count == 4)
    await relaunched.shutdown()
}

@Test(.timeLimit(.minutes(1))) func relaunchAfterACrashWithSeveralRunningRequeuesAllOfThem() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var jobs = ["a", "b", "c"].map(makeJob)
    jobs[0].state = .running(progress: 0.4)
    jobs[1].state = .running(progress: 0.1)
    try store.save(jobs)

    let queue = JobQueue(store: store, runners: [:], startPaused: true, concurrency: 2)
    #expect(await queue.jobs.allSatisfy(isQueued))
    #expect(store.load().allSatisfy(isQueued))
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func duplicatesOfRunningAndQueuedFilesAreSkippedWhileSeveralRun() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b", "c"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    // The same files as two running jobs and a queued one; only a new file is added.
    let again = await queue.enqueue(["a", "b", "c", "d"].map(makeJob))
    #expect(again.map(\.source.lastPathComponent) == ["concurrency-d.mov"])
    #expect(await queue.jobs.count == 4)
    await queue.shutdown()
}

@Test(.timeLimit(.minutes(1))) func aFailureInOneJobDoesNotAffectTheOthersRunning() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = GatedRunner()
    let queue = JobQueue(store: store, runners: ["fake": runner], concurrency: 2)
    let jobs = ["a", "b"].map(makeJob)
    var starts = runner.started.makeAsyncIterator()

    await queue.enqueue(jobs)
    _ = await starts.next()
    _ = await starts.next()
    await runner.finish(jobs[0].id, .failure(Boom()))
    await waitUntil(queue) { $0.first?.state == .failed(reason: "boom", code: .conversionFailed) }
    #expect(await queue.jobs.last.map(isRunning) == true)
    await runner.finish(jobs[1].id)
    await waitUntil(queue) { $0.last.map(isCompleted) == true }
    await queue.shutdown()
}

@Test func activitySummaryAveragesTheProgressOfRunningJobs() {
    var a = makeJob("a")
    var b = makeJob("b")
    a.state = .running(progress: 0.2)
    b.state = .running(progress: 0.6)
    let summary = ActivitySummary(jobs: [a, b, makeJob("c")])
    #expect(summary.queue == 3)
    #expect(abs((summary.runningProgress ?? -1) - 0.4) < 0.0001)
    #expect(ActivitySummary(jobs: [makeJob("c")]).runningProgress == nil)
}
